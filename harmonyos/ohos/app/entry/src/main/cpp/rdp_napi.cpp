// rdp_napi.cpp —— RDP 客户端接入（FreeRDP）
//
// 现状（重要，别读成"RDP 可用了"）：
//   本轮只做**连接路径**的接线与失败语义：能建立 FreeRDP 上下文、尝试连接、
//   把失败原因如实返回。**没有**帧渲染、没有输入、没有通道（剪贴板/声音/磁盘）。
//   之所以先做这一步：FreeRDP 的坑集中在构建与初始化（见 RDP-FEASIBILITY.md），
//   先把"能起、能失败、能报错"跑通，再谈图像。
//
// 线程约束（本工程从第 12 轮起的硬规矩）：FreeRDP 的连接是同步阻塞的，
// 必须放在工作线程，绝不能占 JS 线程。
#include <napi/native_api.h>

#include <freerdp/client.h>
#include <freerdp/freerdp.h>
#include <freerdp/settings.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

struct RdpJob {
    std::string host;
    int port = 3389;
    std::string user;
    std::string password;
    napi_threadsafe_function cb = nullptr;
};

}  // namespace

// musl 没有 pthread_cancel，而 FreeRDP 的 TerminateThread 引用它。
// 最小桩：不实现真正的取消语义（本工程不依赖取消线程）。
// musl 没有 pthread_cancel，FreeRDP 的 TerminateThread 引用它。
// 最小桩：不实现真正的取消语义（本工程不依赖取消线程）。

// musl 没有 pthread_cancel，FreeRDP 的 TerminateThread 引用它；这里给最小桩。
// 不实现真正的取消语义（本工程不依赖取消线程）。
extern "C" int pthread_cancel(pthread_t t) {
    (void)t;
    return 0;
}

namespace {

// 尝试一次 RDP 连接，返回可断言的字符串（不抛异常、不崩溃）
std::string rdpTryConnect(const RdpJob &job) {
    // 用 freerdp_new + freerdp_context_new：client_context_new 需要注册客户端入口点，
    // 而本工程只链接 libfreerdp（没编 SDL/X11 客户端），传 nullptr 会返回空。
    freerdp *instance = freerdp_new();
    if (instance == nullptr) {
        return "error new";
    }
    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        return "error context";
    }
    rdpContext *context = instance->context;
    rdpSettings *settings = context != nullptr ? context->settings : nullptr;
    if (settings == nullptr) {
        freerdp_context_free(instance);
        freerdp_free(instance);
        return "error settings";
    }
    char hostPort[256];
    snprintf(hostPort, sizeof(hostPort), "%s:%d", job.host.c_str(), job.port);
    if (!freerdp_settings_set_string(settings, FreeRDP_ServerHostname, job.host.c_str()) ||
        !freerdp_settings_set_string(settings, FreeRDP_Username, job.user.c_str()) ||
        !freerdp_settings_set_string(settings, FreeRDP_Password, job.password.c_str())) {
        freerdp_context_free(instance);
        freerdp_free(instance);
        return "error settings fields";
    }
    freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, static_cast<uint32_t>(job.port));
    freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, TRUE);

    const BOOL ok = freerdp_connect(instance);
    std::string result;
    if (ok) {
        result = std::string("connected ") + hostPort;
        freerdp_disconnect(instance);
    } else {
        const char *msg = freerdp_get_last_error_string(freerdp_get_last_error(context));
        result = std::string("connect failed: ") + (msg != nullptr ? msg : "unknown");
    }
    freerdp_context_free(instance);
    freerdp_free(instance);
    return result;
}

void worker(RdpJob *job) {
    std::string result = rdpTryConnect(*job);
    auto *payload = new std::string(result);
    napi_call_threadsafe_function(job->cb, payload, napi_tsfn_blocking);
    napi_release_threadsafe_function(job->cb, napi_tsfn_release);
    delete job;
}

void callJs(napi_env env, napi_value jsCb, void * /*context*/, void *data) {
    auto *text = static_cast<std::string *>(data);
    napi_value str = nullptr;
    napi_create_string_utf8(env, text->c_str(), text->size(), &str);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCb, 1, &str, nullptr);
    delete text;
}

std::string getString(napi_env env, napi_value v) {
    size_t len = 0;
    napi_get_value_string_utf8(env, v, static_cast<char *>(nullptr), 0, &len);
    if (len == 0) {
        return std::string();
    }
    std::string s;
    s.resize(len);
    napi_get_value_string_utf8(env, v, &s[0], len + 1, &len);
    return s;
}

// rdpProbe(host, port, user, password, cb)
napi_value RdpProbe(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) {
        napi_throw_type_error(env, nullptr, "rdpProbe(host, port, user, password, cb)");
        return nullptr;
    }
    auto *job = new RdpJob();
    job->host = getString(env, args[0]);
    int32_t port = 3389;
    napi_get_value_int32(env, args[1], &port);
    job->port = port;
    job->user = getString(env, args[2]);
    job->password = getString(env, args[3]);

    napi_value name = nullptr;
    napi_create_string_utf8(env, "motty.rdp.cb", NAPI_AUTO_LENGTH, &name);
    if (napi_create_threadsafe_function(env, args[4], nullptr, name, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &job->cb) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "tsfn failed");
        return nullptr;
    }
    std::thread(worker, job).detach();
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

}  // namespace

void RegisterRdpFunctions(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"rdpProbe", nullptr, RdpProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
}
