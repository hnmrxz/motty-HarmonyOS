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
#include <freerdp/update.h>
#include <freerdp/primary.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

// 位图更新统计：只用来证明"客户端真的收到并解析了服务端画面"。
// 不做像素级渲染（UI 用 fillRect 画整屏代价太大），只统计尺寸与颜色聚类。
struct RenderStats {
    int width = 0;
    int height = 0;
    int updates = 0;
    int pixels = 0;
    // 简单聚类：把像素按 R/G/B 是否高于中值分成 8 类
    int buckets[8] = {0};
};

static RenderStats g_stats;
static std::mutex g_statsMtx;

static BOOL OnBitmapUpdate(rdpContext *context, const BITMAP_UPDATE *bitmap) {
    if (context == nullptr || bitmap == nullptr) {
        return TRUE;
    }
    std::lock_guard<std::mutex> lock(g_statsMtx);
    for (UINT32 i = 0; i < bitmap->number; i++) {
        const BITMAP_DATA &d = bitmap->rectangles[i];
        if (g_stats.width == 0 && d.width > 0) {
            g_stats.width = static_cast<int>(d.width);
        }
        if (g_stats.height == 0 && d.height > 0) {
            g_stats.height = static_cast<int>(d.height);
        }
        g_stats.updates++;
        const int px = static_cast<int>(d.width) * static_cast<int>(d.height);
        g_stats.pixels += px;
        // 采样 bitmapData 里的字节做粗聚类（BGRA）
        if (d.bitmapDataStream != nullptr && d.bitmapLength >= 4) {
            const int step = (static_cast<int>(d.bitmapLength) / 4) / 64 + 1;
            for (UINT32 off = 0; off + 3 < d.bitmapLength; off += 4 * step) {
                const int b = d.bitmapDataStream[off];
                const int g = d.bitmapDataStream[off + 1];
                const int r = d.bitmapDataStream[off + 2];
                int idx = ((r > 127) ? 4 : 0) + ((g > 127) ? 2 : 0) + ((b > 127) ? 1 : 0);
                if (idx < 0 || idx > 7) idx = 0;
                g_stats.buckets[idx]++;
            }
        }
    }
    return TRUE;
}

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
// 接受自签证书：LAN 里的 RDP 服务端几乎都是自签，默认校验会卡在 TLS 阶段。
// 返回 2 = 仅本次会话接受（不落盘），避免"默默永久信任"。
static DWORD VerifyCertEx(freerdp *instance, const char *host, UINT16 port, const char *commonName,
                          const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
    (void)instance; (void)host; (void)port; (void)commonName;
    (void)subject; (void)issuer; (void)flags;
    fprintf(stderr, "[MOTTY_RDP_CLIENT] self-signed cert accepted fingerprint=%s\n",
            fingerprint != nullptr ? fingerprint : "(null)");
    return 2;
}

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
    instance->VerifyCertificateEx = VerifyCertEx;
    // 显式关掉 NLA：shadow 服务端不支持 CredSSP，客户端若坚持 NLA 就会报"认证失败"
    freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, TRUE);

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

// rdpRender(host, port, user, password, cb)：连接 → 泵事件若干秒 → 回调画面上传统计
void renderWorker(RdpJob *job) {
    std::string result;
    // 与 rdpTryConnect 一致：只链 libfreerdp 时用 freerdp_new + freerdp_context_new
    freerdp *instance = freerdp_new();
    if (instance == nullptr || !freerdp_context_new(instance)) {
        result = "error context";
    } else {
        rdpContext *context = instance->context;
        rdpSettings *settings = context->settings;
        freerdp_settings_set_string(settings, FreeRDP_ServerHostname, job->host.c_str());
        freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, static_cast<uint32_t>(job->port));
        freerdp_settings_set_string(settings, FreeRDP_Username, job->user.c_str());
        freerdp_settings_set_string(settings, FreeRDP_Password, job->password.c_str());
        instance->VerifyCertificateEx = VerifyCertEx;
        freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE);
        freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
        if (context->update != nullptr) {
            context->update->BitmapUpdate = OnBitmapUpdate;
        }
        {
            std::lock_guard<std::mutex> lock(g_statsMtx);
            g_stats = RenderStats();
        }
        if (!freerdp_connect(instance)) {
            result = std::string("connect failed: ") +
                     freerdp_get_last_error_string(freerdp_get_last_error(context));
        } else {
            // 泵事件：让 shadow 把桌面更新送上来
            for (int i = 0; i < 200; i++) {   // ~10s 上限
                if (!freerdp_check_fds(instance)) {
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                RenderStats snapshot;
                {
                    std::lock_guard<std::mutex> lock(g_statsMtx);
                    snapshot = g_stats;
                }
                if (snapshot.updates >= 3) {
                    break;
                }
            }
            RenderStats st;
            {
                std::lock_guard<std::mutex> lock(g_statsMtx);
                st = g_stats;
            }
            char buf[256];
            snprintf(buf, sizeof(buf), "frames=%d size=%dx%d pixels=%d colors=%d%d%d%d%d%d%d%d",
                     st.updates, st.width, st.height, st.pixels, st.buckets[0], st.buckets[1],
                     st.buckets[2], st.buckets[3], st.buckets[4], st.buckets[5], st.buckets[6],
                     st.buckets[7]);
            result = buf;
            freerdp_disconnect(instance);
        }
        freerdp_context_free(instance);
        freerdp_free(instance);
    }
    auto *payload = new std::string(result);
    napi_call_threadsafe_function(job->cb, payload, napi_tsfn_blocking);
    napi_release_threadsafe_function(job->cb, napi_tsfn_release);
    delete job;
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

// rdpRender(host, port, user, password, cb)
napi_value RdpRender(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) {
        napi_throw_type_error(env, nullptr, "rdpRender(host, port, user, password, cb)");
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
    napi_create_string_utf8(env, "motty.rdp.render", NAPI_AUTO_LENGTH, &name);
    if (napi_create_threadsafe_function(env, args[4], nullptr, name, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &job->cb) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "tsfn failed");
        return nullptr;
    }
    std::thread(renderWorker, job).detach();
    return nullptr;
}

}  // namespace

void RegisterRdpFunctions(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"rdpProbe", nullptr, RdpProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpRender", nullptr, RdpRender, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
}
