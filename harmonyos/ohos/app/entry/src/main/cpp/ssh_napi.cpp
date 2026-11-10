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

#include <cstring>
#include <string>
#include <thread>

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

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
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
