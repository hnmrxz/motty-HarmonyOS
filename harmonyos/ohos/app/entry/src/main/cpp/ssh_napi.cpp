// ssh_napi.cpp —— A′ 的「协议层 C 库 + NAPI 薄封装」
//
// 本文件的两个不可违反点（对应 PLAN §7.4 的 P1）：
//   1) 主机密钥必须先校验，再谈认证。未知主机只返回指纹、**不认证**；指纹不匹配则
//      直接失败且**不认证**。绝不存在"仍要信任"的自动放行路径。
//   2) 绝不阻塞 UI 线程：网络与握手在 std::thread，结果经 ThreadSafeFunction 回 ArkTS。
//
// 仍然没做的事（不假装做了）：
//   - known_hosts 持久化在 ArkTS 层（relationalStore），C 层只负责校验与拒绝
//   - 没有会话复用、没有端口转发、没有 VNC/RDP；SFTP 只做了 list/read
//   - 没有 hostkey 算法白名单（依赖 libssh2 协商结果）
#include <napi/native_api.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <mbedtls/des.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
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
void RegisterRdpFunctions(napi_env env, napi_value exports);

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
    bool resizePending = false;   // window-change 由工作线程执行（libssh2 非线程安全）
    int resizeCols = 0;
    int resizeRows = 0;
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

        bool doResize = false;
        int rc = 0;
        int rr = 0;
        {
            std::lock_guard<std::mutex> lock(sess->mtx);
            if (sess->resizePending) {
                sess->resizePending = false;
                doResize = true;
                rc = sess->resizeCols;
                rr = sess->resizeRows;
            }
        }
        if (doResize && rc > 0 && rr > 0) {
            libssh2_channel_request_pty_size_ex(sess->channel, rc, rr, 0, 0);
        }

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

// openChannel(host, port, user, password, expectedFingerprint, cols, rows, usePty, onData, onDone)
// usePty=true: pty-req + shell（真 shell 会话）；false: exec "term-echo"（行回显，用于最小验证）
napi_value OpenChannel(napi_env env, napi_callback_info info) {
    size_t argc = 10;
    napi_value args[10] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 10) {
        napi_throw_type_error(env, nullptr,
            "openChannel(host, port, user, password, expectedFp, cols, rows, usePty, onData, onDone)");
        return nullptr;
    }
    auto readStr = [&](size_t i, std::string &dst) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[i], static_cast<char *>(nullptr), 0, &len);
        if (len == 0) { dst.clear(); return; }
        dst.resize(len);
        napi_get_value_string_utf8(env, args[i], &dst[0], len + 1, &len);
    };
    std::string host, user, pass, expected;
    readStr(0, host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    readStr(2, user);
    readStr(3, pass);
    readStr(4, expected);
    int32_t cols = 80, rows = 24;
    napi_get_value_int32(env, args[5], &cols);
    napi_get_value_int32(env, args[6], &rows);
    bool usePty = false;
    napi_get_value_bool(env, args[7], &usePty);

    auto reply = [&](int code, const char *msg) {
        napi_value out = nullptr;
        napi_create_int32(env, code, &out);
        if (msg != nullptr) { napi_throw_error(env, nullptr, msg); }
        return out;
    };

    std::string err;
    int fd = tcpConnect(host, port, err);
    if (fd < 0) { return reply(0, "connect failed"); }
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (session == nullptr) { close(fd); return reply(0, "session init failed"); }
    if (libssh2_session_handshake(session, fd) != 0) {
        libssh2_session_free(session); close(fd); return reply(0, "handshake failed");
    }
    const char *hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    std::string fp = hash ? "SHA256:" + base64(reinterpret_cast<const unsigned char *>(hash), 32) : "unavailable";
    if (expected.empty() || expected != fp) {
        libssh2_session_disconnect(session, "hostkey not trusted");
        libssh2_session_free(session); close(fd);
        return reply(0, expected.empty() ? "unknown host key" : "host key mismatch");
    }
    if (libssh2_userauth_password(session, user.c_str(), pass.c_str()) != 0) {
        libssh2_session_disconnect(session, "auth failed");
        libssh2_session_free(session); close(fd);
        return reply(0, "auth failed");
    }
    LIBSSH2_CHANNEL *channel = libssh2_channel_open_session(session);
    if (channel == nullptr) {
        libssh2_session_disconnect(session, "channel failed");
        libssh2_session_free(session); close(fd);
        return reply(0, "channel open failed");
    }

    if (usePty) {
        // 先申请 pty：不给尺寸的 shell 会让远端拿到 80x24 默认值，与真实终端不符
        if (libssh2_channel_request_pty_ex(channel, "xterm-256color", 14, nullptr, 0,
                                           cols, rows, 0, 0) != 0) {
            libssh2_channel_free(channel);
            libssh2_session_disconnect(session, "pty failed");
            libssh2_session_free(session); close(fd);
            return reply(0, "pty-req failed");
        }
        if (libssh2_channel_shell(channel) != 0) {
            libssh2_channel_free(channel);
            libssh2_session_disconnect(session, "shell failed");
            libssh2_session_free(session); close(fd);
            return reply(0, "shell failed");
        }
    } else {
        if (libssh2_channel_exec(channel, "term-echo") != 0) {
            libssh2_channel_free(channel);
            libssh2_session_disconnect(session, "exec failed");
            libssh2_session_free(session); close(fd);
            return reply(0, "exec failed");
        }
    }

    libssh2_session_set_blocking(session, 0);

    auto *sess = new ShellSession();
    sess->session = session;
    sess->channel = channel;
    sess->fd = fd;
    napi_value n1 = nullptr;
    napi_value n2 = nullptr;
    napi_create_string_utf8(env, "motty.ssh.channel.data", NAPI_AUTO_LENGTH, &n1);
    napi_create_string_utf8(env, "motty.ssh.channel.done", NAPI_AUTO_LENGTH, &n2);
    if (napi_create_threadsafe_function(env, args[8], nullptr, n1, 0, 1, nullptr, nullptr, nullptr, callJs, &sess->onData) != napi_ok ||
        napi_create_threadsafe_function(env, args[9], nullptr, n2, 0, 1, nullptr, nullptr, nullptr, callJs, &sess->onDone) != napi_ok) {
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
    std::thread([sess, id]() { shellLoop(sess, id); }).detach();
    return reply(id, nullptr);
}

// resizeShell(id, cols, rows)：只入队，真正的 window-change 在工作线程里发
napi_value ResizeShell(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0, cols = 0, rows = 0;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_int32(env, args[1], &cols);
    napi_get_value_int32(env, args[2], &rows);
    ShellSession *sess = findSession(id);
    int ok = 0;
    if (sess != nullptr && !sess->closed.load()) {
        std::lock_guard<std::mutex> lock(sess->mtx);
        sess->resizePending = true;
        sess->resizeCols = cols;
        sess->resizeRows = rows;
        ok = 1;
    }
    napi_value out = nullptr;
    napi_create_int32(env, ok, &out);
    return out;
}

// ---------------- SFTP（M2 起点：列目录 / 读文件）----------------
// 与 probe 一样严格的密钥语义：未知/不匹配不认证，因此不会碰到任何文件。
struct SftpJob {
    std::string host;
    int port = 22;
    std::string user;
    std::string password;
    std::string expectedFingerprint;
    std::string op;    // "list" | "read" | "write" | "delete"
    std::string path;
    std::string content;   // 仅 write 使用
    napi_threadsafe_function cb = nullptr;
};

// 建立到 SFTP 子系统的会话；失败返回空字符串并写入 err
bool sftpHandshake(const SftpJob &job, LIBSSH2_SESSION **outSession, LIBSSH2_SFTP **outSftp, std::string &err) {
    int fd = tcpConnect(job.host, job.port, err);
    if (fd < 0) {
        return false;
    }
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (session == nullptr) {
        close(fd);
        err = "session init failed";
        return false;
    }
    if (libssh2_session_handshake(session, fd) != 0) {
        libssh2_session_free(session);
        close(fd);
        err = "handshake failed";
        return false;
    }
    const char *hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    std::string fp = hash ? "SHA256:" + base64(reinterpret_cast<const unsigned char *>(hash), 32) : "unavailable";
    if (job.expectedFingerprint.empty() || job.expectedFingerprint != fp) {
        libssh2_session_disconnect(session, "hostkey not trusted");
        libssh2_session_free(session);
        close(fd);
        err = job.expectedFingerprint.empty() ? ("unknown_host " + fp)
                                              : ("hostkey-mismatch actual=" + fp);
        return false;
    }
    if (libssh2_userauth_password(session, job.user.c_str(), job.password.c_str()) != 0) {
        libssh2_session_disconnect(session, "auth failed");
        libssh2_session_free(session);
        close(fd);
        err = "auth failed";
        return false;
    }
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(session);
    if (sftp == nullptr) {
        libssh2_session_disconnect(session, "sftp init failed");
        libssh2_session_free(session);
        close(fd);
        err = "sftp init failed";
        return false;
    }
    *outSession = session;
    *outSftp = sftp;
    return true;
}

std::string sftpRun(const SftpJob &job) {
    LIBSSH2_SESSION *session = nullptr;
    LIBSSH2_SFTP *sftp = nullptr;
    std::string err;
    if (!sftpHandshake(job, &session, &sftp, err)) {
        return err;   // 已是可断言的字符串：error… / unknown_host… / hostkey-mismatch…
    }
    std::string result;
    if (job.op == "list") {
        LIBSSH2_SFTP_HANDLE *dir = libssh2_sftp_opendir(sftp, job.path.c_str());
        if (dir == nullptr) {
            result = "error opendir failed";
        } else {
            char name[512];
            char longentry[512];
            LIBSSH2_SFTP_ATTRIBUTES attrs{};
            for (;;) {
                int n = libssh2_sftp_readdir_ex(dir, name, sizeof(name), longentry, sizeof(longentry), &attrs);
                if (n <= 0) {
                    break;
                }
                std::string entry(name, static_cast<size_t>(n));
                if (entry == "." || entry == "..") {
                    continue;
                }
                // 目录加尾斜杠，让 UI 与 spec 都能分辨
                const bool isDir = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 &&
                                   LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
                if (!result.empty()) {
                    result += "\n";
                }
                result += entry;
                if (isDir) {
                    result += "/";
                }
                result += "|" + std::to_string(static_cast<long long>(attrs.filesize));
            }
            libssh2_sftp_closedir(dir);
        }
    } else if (job.op == "read") {
        LIBSSH2_SFTP_HANDLE *file = libssh2_sftp_open(sftp, job.path.c_str(), LIBSSH2_FXF_READ, 0);
        if (file == nullptr) {
            result = "error open failed";
        } else {
            char buf[4096];
            std::string content;
            const size_t kLimit = 256 * 1024;   // 单次读取上限，避免把大文件塞进字符串
            for (;;) {
                ssize_t n = libssh2_sftp_read(file, buf, sizeof(buf));
                if (n <= 0) {
                    break;
                }
                content.append(buf, static_cast<size_t>(n));
                if (content.size() > kLimit) {
                    content = content.substr(0, kLimit) + "\n[truncated]";
                    break;
                }
            }
            libssh2_sftp_close(file);
            result = content;
        }
    } else if (job.op == "write") {
        // 先写临时文件再重命名，避免写一半留下坏文件
        const std::string tmp = job.path + ".motty-tmp";
        LIBSSH2_SFTP_HANDLE *file = libssh2_sftp_open(sftp, tmp.c_str(),
            LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC, 0644);
        if (file == nullptr) {
            result = "error open for write failed";
        } else {
            size_t sent = 0;
            bool failed = false;
            while (sent < job.content.size()) {
                ssize_t n = libssh2_sftp_write(file, job.content.data() + sent, job.content.size() - sent);
                if (n < 0) {
                    failed = true;
                    break;
                }
                sent += static_cast<size_t>(n);
            }
            libssh2_sftp_close(file);
            if (failed) {
                libssh2_sftp_unlink(sftp, tmp.c_str());
                result = "error write failed";
            } else if (libssh2_sftp_rename_ex(sftp, tmp.c_str(), static_cast<unsigned int>(tmp.size()),
                                              job.path.c_str(), static_cast<unsigned int>(job.path.size()),
                                              LIBSSH2_SFTP_RENAME_OVERWRITE) != 0) {
                libssh2_sftp_unlink(sftp, tmp.c_str());
                result = "error rename failed";
            } else {
                result = "wrote " + std::to_string(static_cast<long long>(sent)) + " bytes to " + job.path;
            }
        }
    } else if (job.op == "delete") {
        if (libssh2_sftp_unlink(sftp, job.path.c_str()) == 0) {
            result = "deleted " + job.path;
        } else if (libssh2_sftp_rmdir(sftp, job.path.c_str()) == 0) {
            result = "removed dir " + job.path;
        } else {
            result = "error delete failed";
        }
    } else {
        result = "error unknown op";
    }
    libssh2_sftp_shutdown(sftp);
    libssh2_session_disconnect(session, "bye");
    libssh2_session_free(session);
    return result;
}

void sftpWorker(SftpJob *job) {
    auto *payload = new std::string(sftpRun(*job));
    napi_call_threadsafe_function(job->cb, payload, napi_tsfn_blocking);
    napi_release_threadsafe_function(job->cb, napi_tsfn_release);
    delete job;
}

// sftpWrite(host, port, user, password, expectedFingerprint, path, content, cb)
napi_value SftpWrite(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 8) {
        napi_throw_type_error(env, nullptr, "sftpWrite(host, port, user, password, expectedFp, path, content, cb)");
        return nullptr;
    }
    auto *job = new SftpJob();
    auto readStr = [&](size_t i, std::string &dst) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[i], static_cast<char *>(nullptr), 0, &len);
        if (len == 0) { dst.clear(); return; }
        dst.resize(len);
        napi_get_value_string_utf8(env, args[i], &dst[0], len + 1, &len);
    };
    readStr(0, job->host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    job->port = port;
    readStr(2, job->user);
    readStr(3, job->password);
    readStr(4, job->expectedFingerprint);
    job->op = "write";
    readStr(5, job->path);
    readStr(6, job->content);
    napi_value n1 = nullptr;
    napi_create_string_utf8(env, "motty.sftp.write", NAPI_AUTO_LENGTH, &n1);
    if (napi_create_threadsafe_function(env, args[7], nullptr, n1, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &job->cb) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "tsfn failed");
        return nullptr;
    }
    std::thread(sftpWorker, job).detach();
    return nullptr;
}

// sftpDelete(host, port, user, password, expectedFingerprint, path, cb)
napi_value SftpDelete(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 7) {
        napi_throw_type_error(env, nullptr, "sftpDelete(host, port, user, password, expectedFp, path, cb)");
        return nullptr;
    }
    auto *job = new SftpJob();
    auto readStr = [&](size_t i, std::string &dst) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[i], static_cast<char *>(nullptr), 0, &len);
        if (len == 0) { dst.clear(); return; }
        dst.resize(len);
        napi_get_value_string_utf8(env, args[i], &dst[0], len + 1, &len);
    };
    readStr(0, job->host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    job->port = port;
    readStr(2, job->user);
    readStr(3, job->password);
    readStr(4, job->expectedFingerprint);
    job->op = "delete";
    readStr(5, job->path);
    napi_value n1 = nullptr;
    napi_create_string_utf8(env, "motty.sftp.delete", NAPI_AUTO_LENGTH, &n1);
    if (napi_create_threadsafe_function(env, args[6], nullptr, n1, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &job->cb) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "tsfn failed");
        return nullptr;
    }
    std::thread(sftpWorker, job).detach();
    return nullptr;
}

// sftp(host, port, user, password, expectedFingerprint, op, path, cb)
napi_value Sftp(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 8) {
        napi_throw_type_error(env, nullptr,

            "sftp(host, port, user, password, expectedFp, op, path, cb)");
        return nullptr;
    }
    auto *job = new SftpJob();
    auto readStr = [&](size_t i, std::string &dst) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[i], static_cast<char *>(nullptr), 0, &len);
        if (len == 0) { dst.clear(); return; }
        dst.resize(len);
        napi_get_value_string_utf8(env, args[i], &dst[0], len + 1, &len);
    };
    readStr(0, job->host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    job->port = port;
    readStr(2, job->user);
    readStr(3, job->password);
    readStr(4, job->expectedFingerprint);
    readStr(5, job->op);
    readStr(6, job->path);
    napi_value n1 = nullptr;
    napi_create_string_utf8(env, "motty.sftp.cb", NAPI_AUTO_LENGTH, &n1);
    if (napi_create_threadsafe_function(env, args[7], nullptr, n1, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &job->cb) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "tsfn failed");
        return nullptr;
    }
    std::thread(sftpWorker, job).detach();
    return nullptr;
}

// ---- 代理握手（SOCKS5 / HTTP CONNECT）：从客户端请求里取出目标地址 ----
// 返回 true 表示握手成功且目标已填好，false 表示应关闭连接。
bool readExactFd(int fd, unsigned char *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n <= 0) {
            return false;
        }
        got += static_cast<size_t>(n);
    }
    return true;
}

bool writeAllFd(int fd, const unsigned char *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, buf + sent, len - sent, 0);
        if (n <= 0) {
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool socks5Handshake(int fd, std::string &targetHost, int &targetPort, std::string &err) {
    unsigned char head[2];
    if (!readExactFd(fd, head, 2) || head[0] != 5) {
        err = "socks5: bad greeting";
        return false;
    }
    std::vector<unsigned char> methods(head[1]);
    if (!methods.empty() && !readExactFd(fd, methods.data(), methods.size())) {
        err = "socks5: bad methods";
        return false;
    }
    const unsigned char ok[2] = {5, 0};   // 无需认证
    if (!writeAllFd(fd, ok, 2)) {
        err = "socks5: write method";
        return false;
    }
    unsigned char req[4];
    if (!readExactFd(fd, req, 4) || req[0] != 5 || req[1] != 1) {
        err = "socks5: unsupported request";
        return false;
    }
    if (req[3] == 1) {           // IPv4
        unsigned char addr[4];
        if (!readExactFd(fd, addr, 4)) {
            err = "socks5: bad ipv4";
            return false;
        }
        char buf[32];
        snprintf(buf, sizeof(buf), "%u.%u.%u.%u", addr[0], addr[1], addr[2], addr[3]);
        targetHost = buf;
    } else if (req[3] == 3) {     // 域名
        unsigned char len = 0;
        if (!readExactFd(fd, &len, 1)) {
            err = "socks5: bad domain len";
            return false;
        }
        std::vector<unsigned char> name(len);
        if (len > 0 && !readExactFd(fd, name.data(), name.size())) {
            err = "socks5: bad domain";
            return false;
        }
        targetHost.assign(reinterpret_cast<char *>(name.data()), name.size());
    } else {
        err = "socks5: unsupported address type";
        return false;
    }
    unsigned char portBuf[2];
    if (!readExactFd(fd, portBuf, 2)) {
        err = "socks5: bad port";
        return false;
    }
    targetPort = (portBuf[0] << 8) | portBuf[1];
    const unsigned char reply[10] = {5, 0, 0, 1, 0, 0, 0, 0, 0, 0};
    if (!writeAllFd(fd, reply, sizeof(reply))) {
        err = "socks5: write reply";
        return false;
    }
    return true;
}

bool httpConnectHandshake(int fd, std::string &targetHost, int &targetPort, std::string &err) {
    std::string raw;
    char ch = 0;
    while (raw.size() < 4096) {
        if (recv(fd, &ch, 1, 0) != 1) {
            err = "http: read failed";
            return false;
        }
        raw.push_back(ch);
        if (raw.size() >= 4 && raw.compare(raw.size() - 4, 4, "\r\n\r\n") == 0) {
            break;
        }
    }
    // 期望第一行：CONNECT host:port HTTP/1.1
    const size_t eol = raw.find("\r\n");
    if (eol == std::string::npos) {
        err = "http: no request line";
        return false;
    }
    const std::string line = raw.substr(0, eol);
    if (line.compare(0, 8, "CONNECT ") != 0) {
        err = "http: only CONNECT is supported";
        return false;
    }
    const size_t space = line.find(' ', 8);
    const std::string hostport = line.substr(8, space == std::string::npos ? std::string::npos : space - 8);
    const size_t colon = hostport.rfind(':');
    if (colon == std::string::npos) {
        err = "http: no port";
        return false;
    }
    targetHost = hostport.substr(0, colon);
    targetPort = atoi(hostport.c_str() + colon + 1);
    const char *resp = "HTTP/1.1 200 Connection Established\r\n\r\n";
    if (!writeAllFd(fd, reinterpret_cast<const unsigned char *>(resp), strlen(resp))) {
        err = "http: write 200";
        return false;
    }
    return true;
}

// ---------------- 端口转发（本地 forward，direct-tcpip）----------------
// 设计取舍：一个转发任务独占一条 SSH 会话 + 一个监听 socket，串行处理连接。
// libssh2 会话非线程安全，与其冒险并发多路复用，不如先做"一次连接"的可靠实现。
// 明确限制（写进文档）：同时只有一个活动连接；没有 ACL；没有远程(remote)转发。
struct ForwardJob {
    std::string host;
    int port = 22;
    std::string user;
    std::string password;
    std::string expectedFingerprint;
    int listenPort = 0;
    std::string targetHost;
    int targetPort = 0;
    std::string mode;   // local | socks5 | http
    napi_threadsafe_function onEvent = nullptr;
};

std::mutex g_fwdMtx;
std::map<int, std::atomic<bool> *> g_forwards;
std::atomic<int> g_nextFwd{1};

void emit(const napi_threadsafe_function fn, const std::string &text) {
    auto *payload = new std::string(text);
    napi_call_threadsafe_function(fn, payload, napi_tsfn_blocking);
}

void forwardWorker(ForwardJob *job, std::atomic<bool> *stopFlag) {
    std::string err;
    int fd = tcpConnect(job->host, job->port, err);
    if (fd < 0) {
        emit(job->onEvent, "error connect: " + err);
        goto done;
    }
    {
        LIBSSH2_SESSION *session = libssh2_session_init();
        if (session == nullptr) {
            close(fd);
            emit(job->onEvent, "error session init");
            goto done;
        }
        if (libssh2_session_handshake(session, fd) != 0) {
            emit(job->onEvent, "error handshake");
            libssh2_session_free(session);
            close(fd);
            goto done;
        }
        const char *hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
        std::string fp = hash ? "SHA256:" + base64(reinterpret_cast<const unsigned char *>(hash), 32) : "unavailable";
        if (job->expectedFingerprint.empty() || job->expectedFingerprint != fp) {
            emit(job->onEvent, job->expectedFingerprint.empty() ? ("error unknown_host " + fp)
                                                                : "error hostkey-mismatch");
            libssh2_session_disconnect(session, "hostkey not trusted");
            libssh2_session_free(session);
            close(fd);
            goto done;
        }
        if (libssh2_userauth_password(session, job->user.c_str(), job->password.c_str()) != 0) {
            emit(job->onEvent, "error auth failed");
            libssh2_session_disconnect(session, "auth failed");
            libssh2_session_free(session);
            close(fd);
            goto done;
        }

        // 转发必须两端都非阻塞：任何一端阻塞都会让另一个方向饿死
        libssh2_session_set_blocking(session, 0);

        // 本地监听
        int lfd = socket(AF_INET, SOCK_STREAM, 0);
        if (lfd < 0) {
            emit(job->onEvent, "error listen socket");
            libssh2_session_free(session);
            close(fd);
            goto done;
        }
        int reuse = 1;
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        struct sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<uint16_t>(job->listenPort));
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(lfd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) < 0 ||
            listen(lfd, 4) < 0) {
            emit(job->onEvent, "error bind/listen on " + std::to_string(job->listenPort));
            close(lfd);
            libssh2_session_free(session);
            close(fd);
            goto done;
        }
        struct timeval tv{0, 200000};   // 200ms：让 stopFlag 能被及时看到
        setsockopt(lfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        emit(job->onEvent, "listening on 127.0.0.1:" + std::to_string(job->listenPort) +
                           " mode=" + job->mode +
                           (job->mode == "local"
                                ? (" -> " + job->targetHost + ":" + std::to_string(job->targetPort))
                                : std::string(" (target from client)")));

        // 串行处理连接
        while (!stopFlag->load()) {
            struct sockaddr_in peer{};
            socklen_t plen = sizeof(peer);
            int cfd = accept(lfd, reinterpret_cast<struct sockaddr *>(&peer), &plen);
            if (cfd < 0) {
                continue;   // 超时：回到循环检查 stopFlag
            }
            emit(job->onEvent, "accepted local connection");
            // 代理模式：先从客户端请求里解析目标；本地转发模式则用配置的目标
            std::string wantHost = job->targetHost;
            int wantPort = job->targetPort;
            if (job->mode == "socks5" || job->mode == "http") {
                std::string herr;
                const bool ok = (job->mode == "socks5")
                                    ? socks5Handshake(cfd, wantHost, wantPort, herr)
                                    : httpConnectHandshake(cfd, wantHost, wantPort, herr);
                if (!ok) {
                    emit(job->onEvent, "error " + herr);
                    close(cfd);
                    continue;
                }
                emit(job->onEvent, "proxy target " + wantHost + ":" + std::to_string(wantPort));
            }
            int flags = fcntl(cfd, F_GETFL, 0);
            fcntl(cfd, F_SETFL, flags | O_NONBLOCK);
            LIBSSH2_CHANNEL *ch = nullptr;
            for (int attempt = 0; attempt < 100 && ch == nullptr && !stopFlag->load(); attempt++) {
                ch = libssh2_channel_direct_tcpip_ex(session, wantHost.c_str(),
                    wantPort, "127.0.0.1", job->listenPort);
                if (ch == nullptr) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
            }
            if (ch == nullptr) {
                emit(job->onEvent, "error direct-tcpip failed");
                close(cfd);
                continue;
            }
            size_t total = 0;
            char buf[4096];
            for (;;) {
                if (stopFlag->load()) {
                    break;
                }
                bool progressed = false;

                // 本地 -> 远端
                ssize_t n = recv(cfd, buf, sizeof(buf), 0);
                if (n > 0) {
                    ssize_t off = 0;
                    while (off < n) {
                        ssize_t w = libssh2_channel_write(ch, buf + off, static_cast<size_t>(n - off));
                        if (w > 0) {
                            off += w;
                            progressed = true;
                        } else if (w == LIBSSH2_ERROR_EAGAIN) {
                            std::this_thread::sleep_for(std::chrono::milliseconds(5));
                        } else {
                            break;
                        }
                    }
                } else if (n == 0) {
                    break;   // 本地关闭
                } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
                    break;
                }

                // 远端 -> 本地
                ssize_t r = libssh2_channel_read(ch, buf, sizeof(buf));
                if (r > 0) {
                    ssize_t off = 0;
                    while (off < r) {
                        ssize_t w = send(cfd, buf + off, static_cast<size_t>(r - off), 0);
                        if (w > 0) {
                            off += w;
                        } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                            std::this_thread::sleep_for(std::chrono::milliseconds(5));
                        } else {
                            break;
                        }
                    }
                    total += static_cast<size_t>(r);
                    progressed = true;
                } else if (r < 0 && r != LIBSSH2_ERROR_EAGAIN) {
                    break;
                }

                if (libssh2_channel_eof(ch) == 1) {
                    break;
                }
                if (!progressed) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(15));
                }
            }
            libssh2_channel_close(ch);
            libssh2_channel_free(ch);
            close(cfd);
            emit(job->onEvent, "forwarded " + std::to_string(static_cast<long long>(total)) + " bytes");
            if (job->listenPort < 0) {
                break;
            }
        }
        close(lfd);
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session);
        close(fd);
        emit(job->onEvent, "stopped");
    }
done:
    napi_release_threadsafe_function(job->onEvent, napi_tsfn_release);
    delete job;
}

// forwardStart(host, port, user, password, expectedFp, listenPort, targetHost, targetPort, mode, onEvent) -> id
// mode: "local"（固定目标）| "socks5" | "http"（目标从客户端请求里解析）
napi_value ForwardStart(napi_env env, napi_callback_info info) {
    size_t argc = 10;
    napi_value args[10] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 10) {
        napi_throw_type_error(env, nullptr,
            "forwardStart(host,port,user,password,expectedFp,listenPort,targetHost,targetPort,mode,onEvent)");
        return nullptr;
    }
    auto *job = new ForwardJob();
    auto readStr = [&](size_t i, std::string &dst) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[i], static_cast<char *>(nullptr), 0, &len);
        if (len == 0) { dst.clear(); return; }
        dst.resize(len);
        napi_get_value_string_utf8(env, args[i], &dst[0], len + 1, &len);
    };
    readStr(0, job->host);
    int32_t port = 22;
    napi_get_value_int32(env, args[1], &port);
    job->port = port;
    readStr(2, job->user);
    readStr(3, job->password);
    readStr(4, job->expectedFingerprint);
    int32_t listenPort = 0;
    napi_get_value_int32(env, args[5], &listenPort);
    job->listenPort = listenPort;
    readStr(6, job->targetHost);
    int32_t targetPort = 0;
    napi_get_value_int32(env, args[7], &targetPort);
    job->targetPort = targetPort;
    readStr(8, job->mode);
    if (job->mode.empty()) {
        job->mode = "local";
    }

    napi_value n1 = nullptr;
    napi_create_string_utf8(env, "motty.fwd.event", NAPI_AUTO_LENGTH, &n1);
    if (napi_create_threadsafe_function(env, args[9], nullptr, n1, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &job->onEvent) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "tsfn failed");
        return nullptr;
    }
    auto *stopFlag = new std::atomic<bool>(false);
    const int id = g_nextFwd.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(g_fwdMtx);
        g_forwards[id] = stopFlag;
    }
    std::thread(forwardWorker, job, stopFlag).detach();
    napi_value out = nullptr;
    napi_create_int32(env, id, &out);
    return out;
}

// forwardStop(id)
napi_value ForwardStop(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    int ok = 0;
    {
        std::lock_guard<std::mutex> lock(g_fwdMtx);
        auto it = g_forwards.find(id);
        if (it != g_forwards.end()) {
            it->second->store(true);
            ok = 1;
        }
    }
    napi_value out = nullptr;
    napi_create_int32(env, ok, &out);
    return out;
}

// ---------------- VNC / RFB 3.8 客户端（Raw 编码）----------------
// 路线决定（先定许可证再写代码）：**自研 RFB**，不引 LibVNC。
// LibVNC 是 GPL-2.0，链进应用会传染整个产品、直接堵死上架；上游 Motty 也是自研 internal/rfb。
// 本轮只做：3.8 握手 + 安全类型 None + Raw 编码 + 一帧取色，用来证明协议通路。
// 明确不做：VNC Auth(DES)、Hextile/ZRLE/CopyRect、剪贴板、resize、鼠标键盘事件。
struct VncJob {
    std::string host;
    int port = 5900;
    napi_threadsafe_function cb = nullptr;
};

bool readExact(int fd, unsigned char *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n <= 0) {
            return false;
        }
        got += static_cast<size_t>(n);
    }
    return true;
}

bool writeAll(int fd, const unsigned char *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, buf + sent, len - sent, 0);
        if (n <= 0) {
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

std::string vncProbe(const VncJob &job) {
    std::string err;
    int fd = tcpConnect(job.host, job.port, err);
    if (fd < 0) {
        return "error connect: " + err;
    }
    std::string result;
    unsigned char buf[12];
    // 1) 版本
    if (!readExact(fd, buf, 12)) {
        close(fd);
        return "error handshake (no version)";
    }
    std::string serverVer(reinterpret_cast<char *>(buf), 12);
    const unsigned char ourVer[12] = {'R', 'F', 'B', ' ', '0', '0', '3', '.', '0', '0', '8', '\n'};
    if (!writeAll(fd, ourVer, 12)) {
        close(fd);
        return "error handshake (write version)";
    }
    // 2) 安全类型
    unsigned char nTypes = 0;
    if (!readExact(fd, &nTypes, 1) || nTypes == 0) {
        close(fd);
        return "error security (no types)";
    }
    std::vector<unsigned char> types(nTypes);
    if (!readExact(fd, types.data(), types.size())) {
        close(fd);
        return "error security (read types)";
    }
    bool hasNone = false;
    for (unsigned char t : types) {
        if (t == 1) {
            hasNone = true;
        }
    }
    if (!hasNone) {
        close(fd);
        return "error security (None not offered; VNC Auth/DES not implemented yet)";
    }
    const unsigned char pick = 1;
    if (!writeAll(fd, &pick, 1)) {
        close(fd);
        return "error security (write choice)";
    }
    unsigned char secRes[4] = {0, 0, 0, 0};
    if (!readExact(fd, secRes, 4)) {
        close(fd);
        return "error security (result)";
    }
    // 3) ClientInit(shared=1) + ServerInit
    const unsigned char shared = 1;
    if (!writeAll(fd, &shared, 1)) {
        close(fd);
        return "error client init";
    }
    unsigned char si[24];
    if (!readExact(fd, si, 24)) {
        close(fd);
        return "error server init";
    }
    // ServerInit 布局（合计 24 字节，nameLength 已包含在内）：
    //   width(2) height(2) PIXEL_FORMAT(16) nameLength(4)
    //   PIXEL_FORMAT: bpp(4) depth(5) bigendian(6) truecolor(7)
    //                 rmax(8,9) gmax(10,11) bmax(12,13) rshift(14) gshift(15) bshift(16) pad(17..19)
    // 曾经把 shifts 当成 16/17/18、还多读了 4 字节 nameLength，导致读名字时拿到垃圾长度而超时。
    const int width = (si[0] << 8) | si[1];
    const int height = (si[2] << 8) | si[3];
    const int bpp = si[4];
    const bool trueColor = si[7] != 0;
    const int redShift = si[14];
    const int greenShift = si[15];
    const int blueShift = si[16];
    const uint32_t nameLen = (static_cast<uint32_t>(si[20]) << 24) |
                             (static_cast<uint32_t>(si[21]) << 16) |
                             (static_cast<uint32_t>(si[22]) << 8) |
                             static_cast<uint32_t>(si[23]);
    std::string name(nameLen, '\0');
    if (nameLen > 0 && !readExact(fd, reinterpret_cast<unsigned char *>(&name[0]), nameLen)) {
        close(fd);
        return "error server init (name)";
    }
    if (bpp != 32 || !trueColor) {
        close(fd);
        return "error unsupported pixel format bpp=" + std::to_string(bpp) +
               " truecolor=" + std::to_string(trueColor);
    }
    // 4) SetEncodings: 只用 Raw(0)
    std::vector<unsigned char> enc = {2, 0, 0, 1, 0, 0, 0, 0};
    if (!writeAll(fd, enc.data(), enc.size())) {
        close(fd);
        return "error set encodings";
    }
    // 5) FramebufferUpdateRequest(非增量, 全屏)
    std::vector<unsigned char> req = {3, 0, 0, 0, 0, 0,
                                      static_cast<unsigned char>((width >> 8) & 0xFF),
                                      static_cast<unsigned char>(width & 0xFF),
                                      static_cast<unsigned char>((height >> 8) & 0xFF),
                                      static_cast<unsigned char>(height & 0xFF)};
    if (!writeAll(fd, req.data(), req.size())) {
        close(fd);
        return "error fb update request";
    }
    // 6) 读一帧 FramebufferUpdate
    unsigned char head[4];
    if (!readExact(fd, head, 4)) {
        close(fd);
        return "error fb update (head)";
    }
    if (head[0] != 0) {
        close(fd);
        return "error unexpected server message " + std::to_string(head[0]);
    }
    const int nRects = (head[2] << 8) | head[3];
    int decodedBytes = 0;
    unsigned int topLeft = 0;
    unsigned int center = 0;
    unsigned int right = 0;
    for (int r = 0; r < nRects; r++) {
        unsigned char rh[12];
        if (!readExact(fd, rh, 12)) {
            close(fd);
            return "error rect header";
        }
        const int rx = (rh[0] << 8) | rh[1];
        const int ry = (rh[2] << 8) | rh[3];
        const int rw = (rh[4] << 8) | rh[5];
        const int rhh = (rh[6] << 8) | rh[7];
        const int32_t encoding = (static_cast<int32_t>(rh[8]) << 24) | (rh[9] << 16) | (rh[10] << 8) | rh[11];
        if (encoding != 0) {
            close(fd);
            return "error unsupported encoding " + std::to_string(encoding) + " (only Raw)";
        }
        std::vector<unsigned char> pixels(static_cast<size_t>(rw) * rhh * 4);
        if (!readExact(fd, pixels.data(), pixels.size())) {
            close(fd);
            return "error rect pixels";
        }
        decodedBytes += static_cast<int>(pixels.size());
        auto pixelAt = [&](int px, int py) -> unsigned int {
            const size_t off = (static_cast<size_t>(py) * rw + px) * 4;
            const unsigned int raw = static_cast<unsigned int>(pixels[off]) |
                                     (static_cast<unsigned int>(pixels[off + 1]) << 8) |
                                     (static_cast<unsigned int>(pixels[off + 2]) << 16) |
                                     (static_cast<unsigned int>(pixels[off + 3]) << 24);
            const unsigned int rv = (raw >> redShift) & 0xFF;
            const unsigned int gv = (raw >> greenShift) & 0xFF;
            const unsigned int bv = (raw >> blueShift) & 0xFF;
            return (rv << 16) | (gv << 8) | bv;
        };
        if (r == 0) {
            topLeft = pixelAt(0, 0);
            center = pixelAt(rw / 4, rhh / 2);      // 左半区
            right = pixelAt(rw * 3 / 4, rhh / 2);   // 右半区
        }
    }
    char status[256];
    snprintf(status, sizeof(status),
             "fb=%dx%d name=%s bytes=%d top-left=%06X center=%06X right=%06X",
             width, height, name.c_str(), decodedBytes, topLeft, center, right);
    result = std::string(status);
    close(fd);
    return result;
}

void vncWorker(VncJob *job) {
    auto *payload = new std::string(vncProbe(*job));
    napi_call_threadsafe_function(job->cb, payload, napi_tsfn_blocking);
    napi_release_threadsafe_function(job->cb, napi_tsfn_release);
    delete job;
}

// vncProbe(host, port, cb)
napi_value VncProbe(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_type_error(env, nullptr, "vncProbe(host, port, cb)");
        return nullptr;
    }
    auto *job = new VncJob();
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], static_cast<char *>(nullptr), 0, &len);
    job->host.resize(len);
    napi_get_value_string_utf8(env, args[0], &job->host[0], len + 1, &len);
    int32_t port = 5900;
    napi_get_value_int32(env, args[1], &port);
    job->port = port;
    napi_value n1 = nullptr;
    napi_create_string_utf8(env, "motty.vnc.cb", NAPI_AUTO_LENGTH, &n1);
    if (napi_create_threadsafe_function(env, args[2], nullptr, n1, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &job->cb) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "tsfn failed");
        return nullptr;
    }
    std::thread(vncWorker, job).detach();
    return nullptr;
}

// ---------------- VNC 会话（帧循环 + 输入事件）----------------
// 与 vncProbe 的区别：那是一次性取色验证，这里是持续会话：
// 每帧把 RGBA 以 ArrayBuffer 交给 ArkTS 上屏，并把指针/键盘事件回送对端。
// 仍只支持 Raw 编码与 None 安全类型（VNC Auth/DES 未实现）。
struct VncSession {
    int fd = -1;
    int width = 0;
    int height = 0;
    int redShift = 16;
    int greenShift = 8;
    int blueShift = 0;
    std::string name;
    std::string password;      // VNC Auth 口令（空 = 只用 None）
    bool usedVncAuth = false;
    bool usedHextile = false;
    std::mutex mtx;
    std::string pendingEvents;   // 每行：P x y mask / K keysym down
    std::atomic<bool> closed{false};
    napi_threadsafe_function onFrame = nullptr;   // (ArrayBuffer, w, h)
    napi_threadsafe_function onStatus = nullptr;  // (string)
};

std::mutex g_vncMtx;
std::map<int, VncSession *> g_vncSessions;
std::atomic<int> g_nextVnc{1};

VncSession *findVnc(int id) {
    std::lock_guard<std::mutex> lock(g_vncMtx);
    auto it = g_vncSessions.find(id);
    return it == g_vncSessions.end() ? nullptr : it->second;
}

void vncStatus(VncSession *s, const std::string &text) {
    auto *payload = new std::string(text);
    napi_call_threadsafe_function(s->onStatus, payload, napi_tsfn_blocking);
}

// 单独的回调：ArrayBuffer 帧（callJs 只处理字符串）
void callJsBuffer(napi_env env, napi_value jsCb, void * /*context*/, void *data) {
    auto *payload = static_cast<std::pair<std::vector<unsigned char> *, std::pair<int, int>> *>(data);
    napi_value obj = nullptr;
    void *raw = nullptr;
    if (napi_create_arraybuffer(env, payload->first->size(), &raw, &obj) == napi_ok) {
        if (raw != nullptr && !payload->first->empty()) {
            memcpy(raw, payload->first->data(), payload->first->size());
        }
        napi_value global = nullptr;
        napi_get_global(env, &global);
        napi_value argv[3] = {obj, nullptr, nullptr};
        napi_create_int32(env, payload->second.first, &argv[1]);
        napi_create_int32(env, payload->second.second, &argv[2]);
        napi_call_function(env, global, jsCb, 3, argv, nullptr);
    }
    delete payload->first;
    delete payload;
}

unsigned char reverseBits(unsigned char b) {
    unsigned char r = 0;
    for (int i = 0; i < 8; i++) {
        r = static_cast<unsigned char>((r << 1) | ((b >> i) & 1u));
    }
    return r;
}

// VNC Auth：口令 -> 8 字节 DES key（每字节位反序，不足补 0），DES-ECB 加密 16 字节挑战
bool vncAuthResponse(const std::string &password, const unsigned char *challenge, unsigned char *response) {
    unsigned char key[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    for (size_t i = 0; i < password.size() && i < 8; i++) {
        key[i] = reverseBits(static_cast<unsigned char>(password[i]));
    }
    mbedtls_des_context ctx;
    mbedtls_des_init(&ctx);
    bool ok = mbedtls_des_setkey_enc(&ctx, key) == 0;
    if (ok) {
        ok = mbedtls_des_crypt_ecb(&ctx, challenge, response) == 0;
        ok = ok && mbedtls_des_crypt_ecb(&ctx, challenge + 8, response + 8) == 0;
    }
    mbedtls_des_free(&ctx);
    return ok;
}

bool vncHandshake(VncSession *sess, const std::string &host, int port, std::string &err) {
    int fd = tcpConnect(host, port, err);
    if (fd < 0) {
        return false;
    }
    sess->fd = fd;
    unsigned char buf[12];
    if (!readExact(fd, buf, 12)) { err = "no version"; return false; }
    const unsigned char ourVer[12] = {'R', 'F', 'B', ' ', '0', '0', '3', '.', '0', '0', '8', '\n'};
    if (!writeAll(fd, ourVer, 12)) { err = "write version"; return false; }
    unsigned char nTypes = 0;
    if (!readExact(fd, &nTypes, 1) || nTypes == 0) { err = "no security types"; return false; }
    std::vector<unsigned char> types(nTypes);
    if (!readExact(fd, types.data(), types.size())) { err = "read security types"; return false; }
    bool hasNone = false;
    bool hasVncAuth = false;
    for (unsigned char t : types) {
        if (t == 1) hasNone = true;
        if (t == 2) hasVncAuth = true;
    }
    // 优先 VNC Auth（给了口令就走认证）；否则回落到 None
    unsigned char pick = 0;
    if (hasVncAuth && !sess->password.empty()) {
        pick = 2;
    } else if (hasNone) {
        pick = 1;
    } else {
        err = hasVncAuth
                  ? ("server requires VNC Auth but no password was supplied (pwlen=" +
                     std::to_string(sess->password.size()) + ")")
                  : "no supported security type";
        return false;
    }
    if (!writeAll(fd, &pick, 1)) { err = "write security choice"; return false; }
    if (pick == 2) {
        // 3.8：选完类型后服务器发 16 字节挑战，客户端回 16 字节 DES 响应
        unsigned char challenge[16];
        if (!readExact(fd, challenge, 16)) { err = "auth challenge"; return false; }
        unsigned char response[16];
        if (!vncAuthResponse(sess->password, challenge, response)) {
            err = "auth des failed";
            return false;
        }
        if (!writeAll(fd, response, 16)) { err = "auth response"; return false; }
        sess->usedVncAuth = true;
    }
    unsigned char secRes[4];
    if (!readExact(fd, secRes, 4)) { err = "security result"; return false; }
    if (secRes[0] != 0 || secRes[1] != 0 || secRes[2] != 0 || secRes[3] != 0) {
        err = (pick == 2) ? "authentication failed (wrong password?)" : "security result not ok";
        return false;
    }
    const unsigned char shared = 1;
    if (!writeAll(fd, &shared, 1)) { err = "client init"; return false; }
    unsigned char si[24];
    if (!readExact(fd, si, 24)) { err = "server init"; return false; }
    sess->width = (si[0] << 8) | si[1];
    sess->height = (si[2] << 8) | si[3];
    const int bpp = si[4];
    const bool trueColor = si[7] != 0;
    sess->redShift = si[14];
    sess->greenShift = si[15];
    sess->blueShift = si[16];
    const uint32_t nameLen = (static_cast<uint32_t>(si[20]) << 24) |
                             (static_cast<uint32_t>(si[21]) << 16) |
                             (static_cast<uint32_t>(si[22]) << 8) |
                             static_cast<uint32_t>(si[23]);
    sess->name.assign(nameLen, '\0');
    if (nameLen > 0 && !readExact(fd, reinterpret_cast<unsigned char *>(&sess->name[0]), nameLen)) {
        err = "server init name";
        return false;
    }
    if (bpp != 32 || !trueColor) { err = "unsupported pixel format"; return false; }
    std::vector<unsigned char> enc = {2, 0, 0, 2, 0, 0, 0, 5, 0, 0, 0, 0};   // Hextile(5) + Raw(0)
    if (!writeAll(fd, enc.data(), enc.size())) { err = "set encodings"; return false; }
    return true;
}

void vncLoop(VncSession *sess, int id) {
    const int w = sess->width;
    const int h = sess->height;
    int frameNo = 0;
    std::vector<unsigned char> rgba(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, 0);
    while (!sess->closed.load()) {
        std::string ev;
        {
            std::lock_guard<std::mutex> lock(sess->mtx);
            ev.swap(sess->pendingEvents);
        }
        if (!ev.empty()) {
            std::vector<unsigned char> out;
            size_t pos = 0;
            while (pos < ev.size()) {
                size_t nl = ev.find('\n', pos);
                if (nl == std::string::npos) break;
                std::string line = ev.substr(pos, nl - pos);
                pos = nl + 1;
                if (line.empty()) continue;
                if (line[0] == 'P') {
                    int x = 0, y = 0, mask = 0;
                    sscanf(line.c_str() + 1, "%d %d %d", &x, &y, &mask);
                    out.push_back(5); out.push_back(0);
                    out.push_back(static_cast<unsigned char>((x >> 8) & 0xFF));
                    out.push_back(static_cast<unsigned char>(x & 0xFF));
                    out.push_back(static_cast<unsigned char>((y >> 8) & 0xFF));
                    out.push_back(static_cast<unsigned char>(y & 0xFF));
                    out.push_back(static_cast<unsigned char>(mask & 0xFF));
                } else if (line[0] == 'K') {
                    long keysym = 0;
                    int down = 1;
                    sscanf(line.c_str() + 1, "%ld %d", &keysym, &down);
                    out.push_back(4);
                    out.push_back(static_cast<unsigned char>(down ? 1 : 0));
                    out.push_back(0); out.push_back(0);
                    out.push_back(static_cast<unsigned char>((keysym >> 24) & 0xFF));
                    out.push_back(static_cast<unsigned char>((keysym >> 16) & 0xFF));
                    out.push_back(static_cast<unsigned char>((keysym >> 8) & 0xFF));
                    out.push_back(static_cast<unsigned char>(keysym & 0xFF));
                }
            }
            if (!out.empty()) {
                writeAll(sess->fd, out.data(), out.size());
            }
        }

        std::vector<unsigned char> req = {3, 1, 0, 0, 0, 0,
            static_cast<unsigned char>((w >> 8) & 0xFF), static_cast<unsigned char>(w & 0xFF),
            static_cast<unsigned char>((h >> 8) & 0xFF), static_cast<unsigned char>(h & 0xFF)};
        if (!writeAll(sess->fd, req.data(), req.size())) { vncStatus(sess, "error fb request"); break; }
        unsigned char head[4];
        if (!readExact(sess->fd, head, 4)) { vncStatus(sess, "error read update"); break; }
        if (head[0] != 0) { vncStatus(sess, "error unexpected message " + std::to_string(head[0])); break; }
        const int nRects = (head[2] << 8) | head[3];
        for (int r = 0; r < nRects && !sess->closed.load(); r++) {
            unsigned char rh[12];
            if (!readExact(sess->fd, rh, 12)) break;
            const int rx = (rh[0] << 8) | rh[1];
            const int ry = (rh[2] << 8) | rh[3];
            const int rw = (rh[4] << 8) | rh[5];
            const int rhh = (rh[6] << 8) | rh[7];
            const int32_t encoding = (static_cast<int32_t>(rh[8]) << 24) | (rh[9] << 16) | (rh[10] << 8) | rh[11];
            auto decodePixel = [&](const unsigned char *p) -> unsigned int {
                const unsigned int raw = static_cast<unsigned int>(p[0]) |
                                         (static_cast<unsigned int>(p[1]) << 8) |
                                         (static_cast<unsigned int>(p[2]) << 16) |
                                         (static_cast<unsigned int>(p[3]) << 24);
                const unsigned int rv = (raw >> sess->redShift) & 0xFF;
                const unsigned int gv = (raw >> sess->greenShift) & 0xFF;
                const unsigned int bv = (raw >> sess->blueShift) & 0xFF;
                return (rv << 16) | (gv << 8) | bv;
            };
            auto storePixel = [&](int gx, int gy, unsigned int rgb) {
                if (gx < 0 || gy < 0 || gx >= w || gy >= h) return;
                const size_t dst = (static_cast<size_t>(gy) * static_cast<size_t>(w) + gx) * 4;
                rgba[dst] = static_cast<unsigned char>((rgb >> 16) & 0xFF);
                rgba[dst + 1] = static_cast<unsigned char>((rgb >> 8) & 0xFF);
                rgba[dst + 2] = static_cast<unsigned char>(rgb & 0xFF);
                rgba[dst + 3] = 0xFF;
            };

            if (encoding == 5) {
                // Hextile：16x16 瓦片，subencoding 控制背景/前景/subrect
                sess->usedHextile = true;
                for (int ty = 0; ty < rhh; ty += 16) {
                    for (int tx = 0; tx < rw; tx += 16) {
                        unsigned char sub = 0;
                        if (!readExact(sess->fd, &sub, 1)) { break; }
                        const int tw = (tx + 16 <= rw) ? 16 : (rw - tx);
                        const int th = (ty + 16 <= rhh) ? 16 : (rhh - ty);
                        unsigned char pix[4];
                        unsigned int bg = 0, fg = 0;
                        if ((sub & 1) != 0) {   // Raw 瓦片
                            for (int y = 0; y < th; y++) {
                                for (int x = 0; x < tw; x++) {
                                    if (!readExact(sess->fd, pix, 4)) { break; }
                                    storePixel(rx + tx + x, ry + ty + y, decodePixel(pix));
                                }
                            }
                            continue;
                        }
                        if ((sub & 2) != 0) {
                            if (!readExact(sess->fd, pix, 4)) { break; }
                            bg = decodePixel(pix);
                        }
                        if ((sub & 4) != 0) {
                            if (!readExact(sess->fd, pix, 4)) { break; }
                            fg = decodePixel(pix);
                        }
                        for (int y = 0; y < th; y++) {
                            for (int x = 0; x < tw; x++) {
                                storePixel(rx + tx + x, ry + ty + y, bg);
                            }
                        }
                        if ((sub & 8) != 0) {
                            unsigned char nSub = 0;
                            if (!readExact(sess->fd, &nSub, 1)) { break; }
                            for (int i = 0; i < nSub; i++) {
                                unsigned int colour = fg;
                                if ((sub & 16) != 0) {
                                    if (!readExact(sess->fd, pix, 4)) { break; }
                                    colour = decodePixel(pix);
                                }
                                unsigned char xy = 0, wh = 0;
                                if (!readExact(sess->fd, &xy, 1) || !readExact(sess->fd, &wh, 1)) { break; }
                                const int sx = (xy >> 4) & 0x0F;
                                const int sy = xy & 0x0F;
                                const int sw = ((wh >> 4) & 0x0F) + 1;
                                const int sh = (wh & 0x0F) + 1;
                                for (int y = 0; y < sh; y++) {
                                    for (int x = 0; x < sw; x++) {
                                        storePixel(rx + tx + sx + x, ry + ty + sy + y, colour);
                                    }
                                }
                            }
                        }
                    }
                }
                continue;
            }
            if (encoding != 0) {
                vncStatus(sess, "error unsupported encoding " + std::to_string(encoding));
                sess->closed.store(true);
                break;
            }
            std::vector<unsigned char> px(static_cast<size_t>(rw) * static_cast<size_t>(rhh) * 4);
            if (!readExact(sess->fd, px.data(), px.size())) break;
            for (int y = 0; y < rhh; y++) {
                for (int x = 0; x < rw; x++) {
                    const size_t off = (static_cast<size_t>(y) * rw + x) * 4;
                    const unsigned int raw = static_cast<unsigned int>(px[off]) |
                                             (static_cast<unsigned int>(px[off + 1]) << 8) |
                                             (static_cast<unsigned int>(px[off + 2]) << 16) |
                                             (static_cast<unsigned int>(px[off + 3]) << 24);
                    const unsigned int rv = (raw >> sess->redShift) & 0xFF;
                    const unsigned int gv = (raw >> sess->greenShift) & 0xFF;
                    const unsigned int bv = (raw >> sess->blueShift) & 0xFF;
                    const int gx = rx + x;
                    const int gy = ry + y;
                    if (gx < 0 || gy < 0 || gx >= w || gy >= h) continue;
                    const size_t dst = (static_cast<size_t>(gy) * static_cast<size_t>(w) + gx) * 4;
                    rgba[dst] = static_cast<unsigned char>(rv);
                    rgba[dst + 1] = static_cast<unsigned char>(gv);
                    rgba[dst + 2] = static_cast<unsigned char>(bv);
                    rgba[dst + 3] = 0xFF;
                }
            }
        }
        frameNo++;
        long reds = 0, greens = 0, blues = 0, magentas = 0;
        for (size_t i = 0; i + 3 < rgba.size(); i += 4) {
            if (rgba[i] > 200 && rgba[i + 1] < 60) reds++;
            if (rgba[i + 1] > 200 && rgba[i] < 60) greens++;
            if (rgba[i + 2] > 200 && rgba[i] < 60) blues++;
            // 键盘事件的观测面：对端收到 KeyEvent 后画洋红块
            if (rgba[i] > 200 && rgba[i + 2] > 200 && rgba[i + 1] < 60) magentas++;
        }
        // 帧以 "WxH:<hex RGB>" 交给 ArkTS。为什么不用 ArrayBuffer：
        // 在 TSFN 回调里 napi_create_arraybuffer + napi_call_function 实测会让进程崩溃；
        // 字符串通道稳定。代价是体积（每像素 6 字符），对当前尺寸可接受，
        // 真正上屏应换成 Surface/XComponent 纹理，这一点写在 RUNBOOK §26。
        static const char *kHex = "0123456789ABCDEF";
        std::string frameStr = std::to_string(w) + "x" + std::to_string(h) + ":";
        frameStr.reserve(frameStr.size() + static_cast<size_t>(w) * h * 6);
        for (size_t i = 0; i + 3 < rgba.size(); i += 4) {
            unsigned char rgb[3] = {rgba[i], rgba[i + 1], rgba[i + 2]};
            for (unsigned char c : rgb) {
                frameStr.push_back(kHex[c >> 4]);
                frameStr.push_back(kHex[c & 0x0F]);
            }
        }
        // 帧以 hex 字符串交给 ArkTS 自行绘制（fillRect 网格）。
        // 不用 putImageData/ImageData：那条路会触发 SkiaImage::Serialize 崩溃（RUNBOOK §26）。
        napi_call_threadsafe_function(sess->onFrame, new std::string(frameStr), napi_tsfn_blocking);
        char status[192];
        snprintf(status, sizeof(status),
                 "frame=%d %dx%d red=%ld green=%ld blue=%ld magenta=%ld auth=%s enc=%s",
                 frameNo, w, h, reds, greens, blues, magentas,
                 sess->usedVncAuth ? "vncauth" : "none",
                 sess->usedHextile ? "hextile" : "raw");
        vncStatus(sess, std::string(status));
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
    }
    if (sess->fd >= 0) { close(sess->fd); sess->fd = -1; }
    vncStatus(sess, "closed");
    napi_release_threadsafe_function(sess->onFrame, napi_tsfn_release);
    napi_release_threadsafe_function(sess->onStatus, napi_tsfn_release);
    {
        std::lock_guard<std::mutex> lock(g_vncMtx);
        g_vncSessions.erase(id);
    }
    delete sess;
}

// vncStart(host, port, password, onFrame, onStatus) -> id
napi_value VncStart(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) {
        napi_throw_type_error(env, nullptr, "vncStart(host, port, password, onFrame, onStatus)");
        return nullptr;
    }
    std::string host;
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], static_cast<char *>(nullptr), 0, &len);
    host.resize(len);
    napi_get_value_string_utf8(env, args[0], &host[0], len + 1, &len);
    int32_t port = 5900;
    napi_get_value_int32(env, args[1], &port);
    std::string password;
    size_t plen = 0;
    napi_get_value_string_utf8(env, args[2], static_cast<char *>(nullptr), 0, &plen);
    if (plen > 0) {
        password.resize(plen);
        napi_get_value_string_utf8(env, args[2], &password[0], plen + 1, &plen);
    }

    auto *sess = new VncSession();
    sess->password = password;
    std::string err;
    if (!vncHandshake(sess, host, port, err)) {
        if (sess->fd >= 0) {
            close(sess->fd);
        }
        delete sess;
        napi_throw_error(env, nullptr, ("vnc handshake failed: " + err).c_str());
        return nullptr;
    }
    napi_value n1 = nullptr;
    napi_value n2 = nullptr;
    napi_create_string_utf8(env, "motty.vnc.frame", NAPI_AUTO_LENGTH, &n1);
    napi_create_string_utf8(env, "motty.vnc.status", NAPI_AUTO_LENGTH, &n2);
    if (napi_create_threadsafe_function(env, args[3], nullptr, n1, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &sess->onFrame) != napi_ok ||
        napi_create_threadsafe_function(env, args[4], nullptr, n2, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &sess->onStatus) != napi_ok) {
        close(sess->fd);
        delete sess;
        napi_throw_error(env, nullptr, "tsfn failed");
        return nullptr;
    }
    const int id = g_nextVnc.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(g_vncMtx);
        g_vncSessions[id] = sess;
    }
    std::thread(vncLoop, sess, id).detach();
    napi_value out = nullptr;
    napi_create_int32(env, id, &out);
    return out;
}

// vncPointer(id, x, y, mask)
napi_value VncPointer(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0, x = 0, y = 0, mask = 0;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_int32(env, args[1], &x);
    napi_get_value_int32(env, args[2], &y);
    napi_get_value_int32(env, args[3], &mask);
    VncSession *sess = findVnc(id);
    int ok = 0;
    if (sess != nullptr && !sess->closed.load()) {
        std::lock_guard<std::mutex> lock(sess->mtx);
        sess->pendingEvents += "P " + std::to_string(x) + " " + std::to_string(y) + " " +
                               std::to_string(mask) + "\n";
        ok = 1;
    }
    napi_value out = nullptr;
    napi_create_int32(env, ok, &out);
    return out;
}

// vncKey(id, keysym, down)
napi_value VncKey(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0, down = 1;
    int64_t keysym = 0;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_int64(env, args[1], &keysym);
    napi_get_value_int32(env, args[2], &down);
    VncSession *sess = findVnc(id);
    int ok = 0;
    if (sess != nullptr && !sess->closed.load()) {
        std::lock_guard<std::mutex> lock(sess->mtx);
        sess->pendingEvents += "K " + std::to_string(keysym) + " " + std::to_string(down) + "\n";
        ok = 1;
    }
    napi_value out = nullptr;
    napi_create_int32(env, ok, &out);
    return out;
}

// vncStop(id)
napi_value VncStop(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    VncSession *sess = findVnc(id);
    int ok = 0;
    if (sess != nullptr) {
        sess->closed.store(true);
        ok = 1;
    }
    napi_value out = nullptr;
    napi_create_int32(env, ok, &out);
    return out;
}

// sendRaw(id, text)：原样写入通道，不追加换行（用于 Ctrl-C 等控制字符）
napi_value SendRaw(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    std::string text;
    size_t len = 0;
    napi_get_value_string_utf8(env, args[1], static_cast<char *>(nullptr), 0, &len);
    if (len > 0) {
        text.resize(len);
        napi_get_value_string_utf8(env, args[1], &text[0], len + 1, &len);
    }
    ShellSession *sess = findSession(id);
    int ok = 0;
    if (sess != nullptr && !sess->closed.load()) {
        std::lock_guard<std::mutex> lock(sess->mtx);
        sess->pending += text;   // 原样，不补换行
        ok = 1;
    }
    napi_value out = nullptr;
    napi_create_int32(env, ok, &out);
    return out;
}

// sendKey(id, name)：发送 VT 方向键序列。
// 说明（限定范围）：只实现**普通光标模式**（CSI A/B/C/D）；应用模式（DECCKM, SS3 Ox）未实现。
// 想支持应用模式，需要能从 libvterm 读到当前 DECCKM 状态——本轮没做，写进文档而不是假装支持。
napi_value SendKey(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    std::string name;
    size_t len = 0;
    napi_get_value_string_utf8(env, args[1], static_cast<char *>(nullptr), 0, &len);
    if (len > 0) {
        name.resize(len);
        napi_get_value_string_utf8(env, args[1], &name[0], len + 1, &len);
    }
    const char *seq = nullptr;
    if (name == "up") seq = "\x1b[A";
    else if (name == "down") seq = "\x1b[B";
    else if (name == "right") seq = "\x1b[C";
    else if (name == "left") seq = "\x1b[D";
    else if (name == "home") seq = "\x1b[H";
    else if (name == "end") seq = "\x1b[F";
    else if (name == "tab") seq = "\t";
    else if (name == "esc") seq = "\x1b";
    else if (name == "backspace") seq = "\x7f";
    ShellSession *sess = findSession(id);
    int ok = 0;
    if (sess != nullptr && !sess->closed.load() && seq != nullptr) {
        std::lock_guard<std::mutex> lock(sess->mtx);
        sess->pending += seq;
        ok = 1;
    }
    napi_value out = nullptr;
    napi_create_int32(env, ok, &out);
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
        {"sendRaw", nullptr, SendRaw, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendKey", nullptr, SendKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"openChannel", nullptr, OpenChannel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resizeShell", nullptr, ResizeShell, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftp", nullptr, Sftp, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpWrite", nullptr, SftpWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpDelete", nullptr, SftpDelete, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"forwardStart", nullptr, ForwardStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"forwardStop", nullptr, ForwardStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vncProbe", nullptr, VncProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vncStart", nullptr, VncStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vncPointer", nullptr, VncPointer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vncKey", nullptr, VncKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vncStop", nullptr, VncStop, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    RegisterVtFunctions(env, exports);
    RegisterRdpFunctions(env, exports);
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
