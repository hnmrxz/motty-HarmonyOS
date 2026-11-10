// ssh_napi.cpp —— A′ 的「协议层 C 库 + NAPI 薄封装」
//
// 本文件的两个不可违反点（对应 PLAN §7.4 的 P1）：
//   1) 主机密钥必须先校验，再谈认证。未知主机只返回指纹、**不认证**；指纹不匹配则
//      直接失败且**不认证**。绝不存在"仍要信任"的自动放行路径。
//   2) 绝不阻塞 UI 线程：网络与握手在 std::thread，结果经 ThreadSafeFunction 回 ArkTS。
//
// 仍然没做的事（不假装做了）：
//   - 没有 known_hosts 持久化（本轮只做"校验与拒绝"，持久化 = M1-b）
//   - 没有会话复用、没有 pty、没有 SFTP/转发
//   - 没有 hostkey 算法白名单（依赖 libssh2 协商结果）
#include <napi/native_api.h>
#include <libssh2.h>

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <chrono>

// 定义在 vt_core.cpp。必须声明在匿名命名空间之外，否则是内部链接，链接期找不到。
void RegisterVtFunctions(napi_env env, napi_value exports);

namespace {

constexpr int kTimeoutMs = 8000;

struct ProbeJob {
    std::string host;
    int port = 22;
    std::string user;
    std::string password;
    std::string command;
    // 期望的主机密钥指纹（形如 "SHA256:xxxx"）。为空表示"未知主机"：
    // 此时只回指纹、不认证——这就是 TOFU 的第一步，把决定权交回给用户。
    std::string expectedFingerprint;
    napi_threadsafe_function tsfn = nullptr;
};

int tcpConnect(const std::string &host, int port, std::string &err) {
    struct addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = nullptr;
    const std::string service = std::to_string(port);
    int rc = getaddrinfo(host.c_str(), service.c_str(), &hints, &res);
    if (rc != 0 || res == nullptr) {
        err = "dns: " + std::string(gai_strerror(rc));
        return -1;
    }

    int fd = -1;
    for (auto *p = res; p != nullptr; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) {
            continue;
        }
        struct timeval tv {};
        tv.tv_sec = kTimeoutMs / 1000;
        tv.tv_usec = (kTimeoutMs % 1000) * 1000;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        if (connect(fd, p->ai_addr, p->ai_addrlen) == 0) {
            break;
        }
        err = "connect: " + std::string(strerror(errno));
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

std::string base64(const unsigned char *data, size_t len) {
    static const char *kTable = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    size_t i = 0;
    for (; i + 2 < len; i += 3) {
        uint32_t v = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
        out += kTable[(v >> 18) & 0x3F];
        out += kTable[(v >> 12) & 0x3F];
        out += kTable[(v >> 6) & 0x3F];
        out += kTable[v & 0x3F];
    }
    if (i + 1 == len) {
        uint32_t v = data[i] << 16;
        out += kTable[(v >> 18) & 0x3F];
        out += kTable[(v >> 12) & 0x3F];
        out += "==";
    } else if (i + 2 == len) {
        uint32_t v = (data[i] << 16) | (data[i + 1] << 8);
        out += kTable[(v >> 18) & 0x3F];
        out += kTable[(v >> 12) & 0x3F];
        out += kTable[(v >> 6) & 0x3F];
        out += "=";
    }
    // OpenSSH 的 SHA256 指纹不带 '=' 填充
    while (!out.empty() && out.back() == '=') {
        out.pop_back();
    }
    return out;
}

// 返回给 ArkTS 的单行摘要：状态前缀 + 细节
std::string runProbe(ProbeJob &job) {
    static bool inited = false;
    if (!inited) {
        libssh2_init(0);
        inited = true;
    }

    std::string err;
    int fd = tcpConnect(job.host, job.port, err);
    if (fd < 0) {
        return "error " + err;
    }

    std::string out;
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (session == nullptr) {
        close(fd);
        return "error session_init: out of memory";
    }

    if (libssh2_session_handshake(session, fd) != 0) {
        char *msg = nullptr;
        libssh2_session_last_error(session, &msg, nullptr, 0);
        out = std::string("error handshake: ") + (msg ? msg : "unknown");
    } else {
        // ---- 主机密钥校验：先于任何认证 ----
        const char *hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
        std::string fingerprint = "unavailable";
        if (hash != nullptr) {
            fingerprint = "SHA256:" + base64(reinterpret_cast<const unsigned char *>(hash), 32);
        }

        if (job.expectedFingerprint.empty()) {
            // 未知主机：只报指纹，**不认证**（TOFU 第一步）
            out = "unknown_host " + fingerprint;
        } else if (job.expectedFingerprint != fingerprint) {
            // 密钥变更：直接失败，**不认证**，也不提供任何"仍要信任"的放行路径
            out = "hostkey-mismatch expected=" + job.expectedFingerprint + " actual=" + fingerprint;
        } else {
            // 校验通过才认证
            if (libssh2_userauth_password(session, job.user.c_str(), job.password.c_str()) != 0) {
                char *msg = nullptr;
                libssh2_session_last_error(session, &msg, nullptr, 0);
                out = std::string("error auth: ") + (msg ? msg : "unknown");
            } else {
                LIBSSH2_CHANNEL *channel = libssh2_channel_open_session(session);
                if (channel == nullptr) {
                    out = "error channel: cannot open session";
                } else if (libssh2_channel_exec(channel, job.command.c_str()) != 0) {
                    out = "error exec: request refused";
                } else {
                    std::string stdoutText;
                    char buf[1024];
                    for (;;) {
                        ssize_t n = libssh2_channel_read(channel, buf, sizeof(buf));
                        if (n > 0) {
                            stdoutText.append(buf, static_cast<size_t>(n));
                            continue;
                        }
                        if (n == LIBSSH2_ERROR_EAGAIN) {
                            continue;
                        }
                        break;
                    }
                    libssh2_channel_close(channel);
                    libssh2_channel_free(channel);
                    std::string flat;
                    for (char ch : stdoutText) {
                        flat += (ch == '\n' || ch == '\r') ? ' ' : ch;
                    }
                    out = "verified " + fingerprint + " ok " + flat;
                }
            }
        }
    }

    libssh2_session_disconnect(session, "bye");
    libssh2_session_free(session);
    close(fd);
    return out;
}

// 前向声明：流式 exec 的 TSFN 回调复用同一个 callJs（定义在本段之后）
void callJs(napi_env env, napi_value jsCb, void *context, void *data);

// ---- 流式 exec：终端通路需要的形态（分块回调，而不是等全部读完）----
struct ExecJob {
    std::string host;
    int port = 22;
    std::string user;
    std::string password;
    std::string command;
    std::string expectedFingerprint;
    napi_threadsafe_function onData = nullptr;
    napi_threadsafe_function onDone = nullptr;
};

// 复用主机密钥校验语义：未知/不匹配绝不认证
std::string runExecStream(ExecJob &job, bool &started) {
    started = false;
    static bool inited2 = false;
    if (!inited2) {
        libssh2_init(0);
        inited2 = true;
    }
    std::string err;
    int fd = tcpConnect(job.host, job.port, err);
    if (fd < 0) {
        return "error " + err;
    }
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (session == nullptr) {
        close(fd);
        return "error session_init";
    }
    std::string result;
    if (libssh2_session_handshake(session, fd) != 0) {
        char *msg = nullptr;
        libssh2_session_last_error(session, &msg, nullptr, 0);
        result = std::string("error handshake: ") + (msg ? msg : "unknown");
    } else {
        const char *hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
        std::string fp = hash ? "SHA256:" + base64(reinterpret_cast<const unsigned char *>(hash), 32) : "unavailable";
        if (job.expectedFingerprint.empty()) {
            result = "unknown_host " + fp;
        } else if (job.expectedFingerprint != fp) {
            result = "hostkey-mismatch expected=" + job.expectedFingerprint + " actual=" + fp;
        } else if (libssh2_userauth_password(session, job.user.c_str(), job.password.c_str()) != 0) {
            char *msg = nullptr;
            libssh2_session_last_error(session, &msg, nullptr, 0);
            result = std::string("error auth: ") + (msg ? msg : "unknown");
        } else {
            LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(session);
            if (ch == nullptr) {
                result = "error channel";
            } else if (libssh2_channel_exec(ch, job.command.c_str()) != 0) {
                result = "error exec: refused";
            } else {
                started = true;
                char buf[512];
                for (;;) {
                    ssize_t n = libssh2_channel_read(ch, buf, sizeof(buf));
                    if (n > 0) {
                        auto *chunk = new std::string(buf, static_cast<size_t>(n));
                        napi_call_threadsafe_function(job.onData, chunk, napi_tsfn_blocking);
                        continue;
                    }
                    if (n == LIBSSH2_ERROR_EAGAIN) {
                        continue;
                    }
                    break;
                }
                libssh2_channel_close(ch);
                libssh2_channel_free(ch);
                result = "ok";
            }
        }
    }
    libssh2_session_disconnect(session, "bye");
    libssh2_session_free(session);
    close(fd);
    return result;
}

void execWorker(ExecJob *job) {
    bool started = false;
    std::string status = runExecStream(*job, started);
    auto *payload = new std::string(status);
    napi_call_threadsafe_function(job->onDone, payload, napi_tsfn_blocking);
    napi_release_threadsafe_function(job->onDone, napi_tsfn_release);
    napi_release_threadsafe_function(job->onData, napi_tsfn_release);
    delete job;
}

// exec(host, port, user, password, command, expectedFingerprint, onData, onDone)
napi_value Exec(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 8) {
        napi_throw_type_error(env, nullptr,
                              "exec(host, port, user, password, command, expectedFingerprint, onData, onDone)");
        return nullptr;
    }
    auto *job = new ExecJob();
    auto readStr = [&](size_t i, std::string &dst) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[i], static_cast<char *>(nullptr), 0, &len);
        if (len == 0) {
            dst.clear();
            return;
        }
        dst.resize(len);
        napi_get_value_string_utf8(env, args[i], &dst[0], len + 1, &len);
    };
    readStr(0, job->host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    job->port = port;
    readStr(2, job->user);
    readStr(3, job->password);
    readStr(4, job->command);
    readStr(5, job->expectedFingerprint);

    napi_value n1 = nullptr;
    napi_value n2 = nullptr;
    napi_create_string_utf8(env, "motty.ssh.exec.data", NAPI_AUTO_LENGTH, &n1);
    napi_create_string_utf8(env, "motty.ssh.exec.done", NAPI_AUTO_LENGTH, &n2);
    if (napi_create_threadsafe_function(env, args[6], nullptr, n1, 0, 1, nullptr, nullptr, nullptr, callJs, &job->onData) != napi_ok ||
        napi_create_threadsafe_function(env, args[7], nullptr, n2, 0, 1, nullptr, nullptr, nullptr, callJs, &job->onDone) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "cannot create threadsafe functions");
        return nullptr;
    }
    std::thread(execWorker, job).detach();
    return nullptr;
}

void callJs(napi_env env, napi_value jsCb, void * /*context*/, void *data) {
    auto *text = static_cast<std::string *>(data);
    if (env != nullptr && jsCb != nullptr && text != nullptr) {
        napi_value arg = nullptr;
        napi_create_string_utf8(env, text->c_str(), text->size(), &arg);
        napi_value global = nullptr;
        napi_get_global(env, &global);
        napi_call_function(env, global, jsCb, 1, &arg, nullptr);
    }
    delete text;
}

void worker(ProbeJob *job) {
    std::string result = runProbe(*job);
    auto *payload = new std::string(result);
    napi_call_threadsafe_function(job->tsfn, payload, napi_tsfn_blocking);
    napi_release_threadsafe_function(job->tsfn, napi_tsfn_release);
    delete job;
}

// probe(host, port, user, password, command, expectedFingerprint, callback)
napi_value Probe(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 7) {
        napi_throw_type_error(env, nullptr,
                              "probe(host, port, user, password, command, expectedFingerprint, callback)");
        return nullptr;
    }

    auto *job = new ProbeJob();
    auto readStr = [&](size_t i, std::string &dst) {
        size_t len = 0;
        // 两次坑：OHOS 头里 char*/char16_t* 重载让 nullptr 二义；C++11 的 data() 是 const。
        napi_get_value_string_utf8(env, args[i], static_cast<char *>(nullptr), 0, &len);
        if (len == 0) {
            dst.clear();
            return;
        }
        dst.resize(len);
        napi_get_value_string_utf8(env, args[i], &dst[0], len + 1, &len);
    };
    readStr(0, job->host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    job->port = port;
    readStr(2, job->user);
    readStr(3, job->password);
    readStr(4, job->command);
    readStr(5, job->expectedFingerprint);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "motty.ssh.probe", NAPI_AUTO_LENGTH, &resourceName);
    napi_status st = napi_create_threadsafe_function(env, args[6], nullptr, resourceName,
                                                     0, 1, nullptr, nullptr, nullptr, callJs, &job->tsfn);
    if (st != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "cannot create threadsafe function");
        return nullptr;
    }

    std::thread(worker, job).detach();
    return nullptr;
}

// ---- 交互式会话：把"一条命令"升级为"可写入的通道" ----
//
// 线程模型（刻意简单，避免 libssh2 的线程安全问题）：
//   * 每个会话一个工作线程，**所有 libssh2 调用都在这个线程里**（读、写、关）。
//   * sendInput 只把字节追加到 mutex 保护的待写队列，不碰 libssh2。
//   * close 只置标志位，由工作线程收尾。
struct ShellSession {
    LIBSSH2_SESSION *session = nullptr;
    LIBSSH2_CHANNEL *channel = nullptr;
    int fd = -1;
    std::mutex mtx;
    std::string pending;
    std::atomic<bool> closed{false};
    napi_threadsafe_function onData = nullptr;
    napi_threadsafe_function onDone = nullptr;
};

std::mutex g_sessionsMtx;
std::map<int, ShellSession *> g_sessions;
std::atomic<int> g_nextId{1};

ShellSession *findSession(int id) {
    std::lock_guard<std::mutex> lock(g_sessionsMtx);
    auto it = g_sessions.find(id);
    return it == g_sessions.end() ? nullptr : it->second;
}

void shellLoop(ShellSession *sess, int id) {
    std::string done = "ok";
    char buf[512];
    while (!sess->closed.load()) {
        bool progressed = false;

        // 1) 先把待写数据送出去
        std::string out;
        {
            std::lock_guard<std::mutex> lock(sess->mtx);
            if (!sess->pending.empty()) {
                out.swap(sess->pending);
            }
        }
        if (!out.empty()) {
            size_t sent = 0;
            while (sent < out.size() && !sess->closed.load()) {
                ssize_t n = libssh2_channel_write(sess->channel, out.data() + sent, out.size() - sent);
                if (n > 0) {
                    sent += static_cast<size_t>(n);
                    progressed = true;
                } else if (n == LIBSSH2_ERROR_EAGAIN) {
                    // 写满/暂不可写：把没送出去的部分放回队列，否则会静默丢字节
                    std::lock_guard<std::mutex> lock(sess->mtx);
                    sess->pending = out.substr(sent) + sess->pending;
                    break;
                } else {
                    done = "error write";
                    sess->closed.store(true);
                    break;
                }
            }
        }

        // 2) 再读远端输出
        ssize_t n = libssh2_channel_read(sess->channel, buf, sizeof(buf));
        if (n > 0) {
            auto *chunk = new std::string(buf, static_cast<size_t>(n));
            napi_call_threadsafe_function(sess->onData, chunk, napi_tsfn_blocking);
            progressed = true;
        } else if (n < 0 && n != LIBSSH2_ERROR_EAGAIN) {
            done = "error read";
            sess->closed.store(true);
        }

        if (libssh2_channel_eof(sess->channel) == 1) {
            done = "eof";
            break;
        }
        if (!progressed) {
            std::this_thread::sleep_for(std::chrono::milliseconds(15));
        }
    }

    libssh2_channel_close(sess->channel);
    libssh2_channel_free(sess->channel);
    libssh2_session_disconnect(sess->session, "bye");
    libssh2_session_free(sess->session);
    if (sess->fd >= 0) {
        close(sess->fd);
    }
    {
        std::lock_guard<std::mutex> lock(g_sessionsMtx);
        g_sessions.erase(id);   // 用真实会话 id 摘除（此前误用了 g_nextId，会泄漏条目）
    }
    auto *payload = new std::string(done);
    napi_call_threadsafe_function(sess->onDone, payload, napi_tsfn_blocking);
    napi_release_threadsafe_function(sess->onDone, napi_tsfn_release);
    napi_release_threadsafe_function(sess->onData, napi_tsfn_release);
    delete sess;
}

// openShell(host, port, user, password, expectedFingerprint, onData, onDone) -> 会话 id（>0 成功，0 失败）
napi_value OpenShell(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 7) {
        napi_throw_type_error(env, nullptr, "openShell(host, port, user, password, expectedFp, onData, onDone)");
        return nullptr;
    }
    auto readStr = [&](size_t i, std::string &dst) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[i], static_cast<char *>(nullptr), 0, &len);
        if (len == 0) {
            dst.clear();
            return;
        }
        dst.resize(len);
        napi_get_value_string_utf8(env, args[i], &dst[0], len + 1, &len);
    };
    std::string host, user, pass, expected;
    readStr(0, host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    readStr(2, user);
    readStr(3, pass);
    readStr(4, expected);   // 曾误写成 5（那是 onData 回调），导致指纹恒空 -> hostkey not trusted

    auto reply = [&](int code, const char *msg) {
        napi_value out = nullptr;
        napi_create_int32(env, code, &out);
        if (msg != nullptr) {
            napi_throw_error(env, nullptr, msg);
        }
        return out;
    };

    std::string err;
    int fd = tcpConnect(host, port, err);
    if (fd < 0) {
        return reply(0, ("connect failed: " + err).c_str());
    }
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (session == nullptr) {
        close(fd);
        return reply(0, "session init failed");
    }
    if (libssh2_session_handshake(session, fd) != 0) {
        libssh2_session_free(session);
        close(fd);
        return reply(0, "handshake failed");
    }
    const char *hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    std::string fp = hash ? "SHA256:" + base64(reinterpret_cast<const unsigned char *>(hash), 32) : "unavailable";
    if (expected.empty() || expected != fp) {
        libssh2_session_disconnect(session, "hostkey not trusted");
        libssh2_session_free(session);
        close(fd);
        return reply(0, expected.empty() ? "unknown host key" : "host key mismatch");
    }
    if (libssh2_userauth_password(session, user.c_str(), pass.c_str()) != 0) {
        libssh2_session_disconnect(session, "auth failed");
        libssh2_session_free(session);
        close(fd);
        return reply(0, "auth failed");
    }
    LIBSSH2_CHANNEL *channel = libssh2_channel_open_session(session);
    if (channel == nullptr) {
        libssh2_session_disconnect(session, "channel failed");
        libssh2_session_free(session);
        close(fd);
        return reply(0, "channel open failed");
    }
    if (libssh2_channel_exec(channel, "term-echo") != 0) {
        libssh2_channel_free(channel);
        libssh2_session_disconnect(session, "exec failed");
        libssh2_session_free(session);
        close(fd);
        return reply(0, "exec failed");
    }

    // 交互式会话必须非阻塞：否则 worker 会阻塞在 channel_read 上（受 SO_RCVTIMEO 影响
    // 最长 8 秒），键盘输入的写入要等到读超时才发出去。
    libssh2_session_set_blocking(session, 0);

    auto *sess = new ShellSession();
    sess->session = session;
    sess->channel = channel;
    sess->fd = fd;

    napi_value n1 = nullptr;
    napi_value n2 = nullptr;
    napi_create_string_utf8(env, "motty.ssh.shell.data", NAPI_AUTO_LENGTH, &n1);
    napi_create_string_utf8(env, "motty.ssh.shell.done", NAPI_AUTO_LENGTH, &n2);
    if (napi_create_threadsafe_function(env, args[5], nullptr, n1, 0, 1, nullptr, nullptr, nullptr, callJs, &sess->onData) != napi_ok ||
        napi_create_threadsafe_function(env, args[6], nullptr, n2, 0, 1, nullptr, nullptr, nullptr, callJs, &sess->onDone) != napi_ok) {
        libssh2_channel_free(channel);
        libssh2_session_free(session);
        close(fd);
        delete sess;
        return reply(0, "tsfn failed");
    }

    int id = g_nextId.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(g_sessionsMtx);
        g_sessions[id] = sess;
    }
    // 会话 id 交给工作线程，用于结束时从表里摘除
    std::thread([sess, id]() { shellLoop(sess, id); }).detach();
    return reply(id, nullptr);
}

// sendInput(id, text)
napi_value SendInput(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    size_t len = 0;
    napi_get_value_string_utf8(env, args[1], static_cast<char *>(nullptr), 0, &len);
    std::string text;
    if (len > 0) {
        text.resize(len);
        napi_get_value_string_utf8(env, args[1], &text[0], len + 1, &len);
    }
    ShellSession *sess = findSession(id);
    if (sess == nullptr || sess->closed.load()) {
        napi_value out = nullptr;
        napi_create_int32(env, 0, &out);
        return out;
    }
    {
        std::lock_guard<std::mutex> lock(sess->mtx);
        sess->pending += text;
        sess->pending += "\n";   // 交互式行输入：每次发送补一个换行
    }
    napi_value out = nullptr;
    napi_create_int32(env, 1, &out);
    return out;
}

// closeShell(id)
napi_value CloseShell(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    ShellSession *sess = findSession(id);
    if (sess != nullptr) {
        sess->closed.store(true);
    }
    napi_value out = nullptr;
    napi_create_int32(env, sess == nullptr ? 0 : 1, &out);
    return out;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exec", nullptr, Exec, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"openShell", nullptr, OpenShell, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendInput", nullptr, SendInput, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeShell", nullptr, CloseShell, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    RegisterVtFunctions(env, exports);
    return exports;
}

}  // namespace

static napi_module mottySshModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "mottynapi",  // 必须与 libmottynapi.so 的文件名一致，否则 ArkTS import 拿到空模块
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterMottySshModule(void) {
    napi_module_register(&mottySshModule);
}
