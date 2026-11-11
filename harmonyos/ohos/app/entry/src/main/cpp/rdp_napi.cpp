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
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/freerdp.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <freerdp/client.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/primary.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <cerrno>
#include <set>
#include <map>
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

// gdi_init 会注册真正的解码器 gdi_bitmap_update（见 libfreerdp/cache/bitmap.c），
// 我们之前直接覆盖它，导致位图永远进不了 GDI 缓冲（白屏根因）。
static pBitmapUpdate g_origBitmapUpdate = nullptr;
static int g_bmpUpdates = 0;
static int g_bmpRects = 0;
static int g_bmpLastW = 0;
static int g_bmpLastH = 0;
static int g_bmpLastX = 0;
static int g_bmpLastY = 0;
static pEndPaint g_origEndPaint = nullptr;

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
    // 记录 PDU 级别的信息：rect 数与最后一块尺寸，用来区分"没收到"与"收到但没写进缓冲"
    g_bmpUpdates++;
    g_bmpRects += static_cast<int>(bitmap->number);
    if (bitmap->number > 0) {
        g_bmpLastW = static_cast<int>(bitmap->rectangles[bitmap->number - 1].width);
        g_bmpLastX = static_cast<int>(bitmap->rectangles[bitmap->number - 1].destLeft);
        g_bmpLastY = static_cast<int>(bitmap->rectangles[bitmap->number - 1].destTop);
        g_bmpLastH = static_cast<int>(bitmap->rectangles[bitmap->number - 1].height);
    }
    if (g_origBitmapUpdate != nullptr) {
        return g_origBitmapUpdate(context, bitmap);
    }
    return TRUE;
}

struct RdpJob {
    bool useNla = false;
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

// 官方客户端入口点：只有走这条路，context 才带完整的 update/gdi 管线，
// 服务端的桌面更新才会被路由到 BitmapUpdate 回调。
// （之前用 freerdp_new()+freerdp_context_new() 虽然能连上，但收不到位图 —— Round 71 结论）
namespace {
// 最小客户端上下文子类：ContextSize 必须非 0，否则 freerdp_context_new_ex 会除零（实测 SIGFPE）
struct MottyRdpContext {
    rdpContext common;
};
int ClientGlobalInit(void) { return 0; }
void ClientGlobalUninit(void) { }
// EndPaint：每帧绘制结束都会调用。用它判断"更新到底有没有到达"。
// 比 BitmapUpdate 回调更可靠：gdi_init 之后 gdi 自己会接管解码。
static std::atomic<int> g_paints{0};

// 最近一帧的 64x48 RGBA 采样（供 ArkTS 画到 Canvas）
static const int kSnapW = 64;
static const int kSnapH = 48;
static uint8_t g_snap[kSnapW * kSnapH * 4] = {0};
static std::atomic<int> g_snapValid{0};
static std::atomic<int> g_snapColors{0};
static std::atomic<int> g_snapNonBlack{0};
static std::atomic<uint32_t> g_snapDom{0};
static std::atomic<int> g_snapDomCount{0};

static void snapshotFromGdi(rdpContext *context) {
    if (context == nullptr || context->gdi == nullptr || context->gdi->primary_buffer == nullptr) {
        return;
    }
    // primary_buffer 可能指向初始化时就固定下来的旧缓冲；优先用 primary bitmap 的实际数据指针
    const BYTE *buf = context->gdi->primary_buffer;
    UINT32 w = context->gdi->width;
    UINT32 h = context->gdi->height;
    size_t stride = (context->gdi->stride > 0) ? static_cast<size_t>(context->gdi->stride)
                                               : static_cast<size_t>(w) * 4;
    if (context->gdi->primary != nullptr && context->gdi->primary->bitmap != nullptr &&
        context->gdi->primary->bitmap->data != nullptr) {
        buf = context->gdi->primary->bitmap->data;
        if (context->gdi->primary->bitmap->width > 0) {
            w = static_cast<UINT32>(context->gdi->primary->bitmap->width);
        }
        if (context->gdi->primary->bitmap->height > 0) {
            h = static_cast<UINT32>(context->gdi->primary->bitmap->height);
        }
        if (context->gdi->primary->bitmap->scanline > 0) {
            stride = static_cast<size_t>(context->gdi->primary->bitmap->scanline);
        }
    }
    if (w == 0 || h == 0) {
        return;
    }
    for (int y = 0; y < kSnapH; y++) {
        const UINT32 sy = static_cast<UINT32>(y) * h / static_cast<UINT32>(kSnapH);
        for (int x = 0; x < kSnapW; x++) {
            const UINT32 sx = static_cast<UINT32>(x) * w / static_cast<UINT32>(kSnapW);
            const size_t src = static_cast<size_t>(sy) * stride + static_cast<size_t>(sx) * 4;
            const size_t dst = (static_cast<size_t>(y) * kSnapW + x) * 4;
            g_snap[dst + 0] = buf[src + 0];
            g_snap[dst + 1] = buf[src + 1];
            g_snap[dst + 2] = buf[src + 2];
            g_snap[dst + 3] = 255;
        }
    }
    {
        // 在 C++ 侧先算一遍，用于判断"是采样问题"还是"跨语言传参问题"
        std::set<uint32_t> seen;
        int nonBlack = 0;
        for (int i = 0; i < kSnapW * kSnapH; i++) {
            const uint32_t c = (static_cast<uint32_t>(g_snap[i * 4 + 2]) << 16) |
                               (static_cast<uint32_t>(g_snap[i * 4 + 1]) << 8) |
                               g_snap[i * 4 + 0];
            seen.insert(c);
            if (c != 0) nonBlack++;
        }
        // 出现最多的颜色（排查"纯色到底是什么色"）
        {
            std::map<uint32_t, int> hist;
            for (int i = 0; i < kSnapW * kSnapH; i++) {
                const uint32_t c = (static_cast<uint32_t>(g_snap[i * 4 + 2]) << 16) |
                                   (static_cast<uint32_t>(g_snap[i * 4 + 1]) << 8) |
                                   g_snap[i * 4 + 0];
                hist[c]++;
            }
            uint32_t dom = 0;
            int best = 0;
            for (const auto &kv : hist) {
                if (kv.second > best) {
                    best = kv.second;
                    dom = kv.first;
                }
            }
            g_snapDom.store(dom);
            g_snapDomCount.store(best);
        }
        g_snapColors.store(static_cast<int>(seen.size()));
        g_snapNonBlack.store(nonBlack);
    }
    g_snapValid.store(1);
}

BOOL OnEndPaint(rdpContext *context) {
    g_paints.fetch_add(1);
    // 先让 gdi 完成自己的收尾（它负责把离屏缓冲刷到 primary），再采样
    if (g_origEndPaint != nullptr) {
        g_origEndPaint(context);
    }
    snapshotFromGdi(context);
    return TRUE;
}


// 需要覆盖多少像素才算"整屏到齐"（95%）：按 gdi 主缓冲尺寸算
static int st2NeedPixels(freerdp *instance) {
    if (instance == nullptr || instance->context == nullptr || instance->context->gdi == nullptr) return 0;
    const UINT32 w = instance->context->gdi->width;
    const UINT32 h = instance->context->gdi->height;
    if (w == 0 || h == 0) return 0;
    const double need = 0.95 * static_cast<double>(w) * static_cast<double>(h);
    return static_cast<int>(need);
}


// PostConnect：位图更新需要 GDI 表面来解码，否则更新会被丢弃（实测 frames=0）
BOOL OnPostConnect(freerdp *instance) {
    if (instance == nullptr || instance->context == nullptr) {
        return FALSE;
    }
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) {
        fprintf(stderr, "[MOTTY_RDP_CLIENT] gdi_init failed\n");
        return FALSE;
    }
    // 注意顺序：gdi_init 之后再挂回调，否则会被 gdi 的默认处理覆盖
    if (instance->context->update != nullptr) {
        instance->context->update->BitmapUpdate = OnBitmapUpdate;
        instance->context->update->EndPaint = OnEndPaint;
    }
    return TRUE;
}

void OnPostDisconnect(freerdp *instance) {
    if (instance != nullptr) {
        gdi_free(instance);
    }
}

int ClientNew(freerdp *instance, rdpContext *context) {
    (void)context;
    if (instance != nullptr) {
        instance->PostConnect = OnPostConnect;
        instance->PostDisconnect = OnPostDisconnect;
    }
    // 必须是 TRUE：返回 0 会被当成"上下文创建失败"，于是 freerdp_client_context_new 返回 NULL
    // （样例 tf_client_new 也是 return TRUE）
    return 1;
}
void ClientFree(freerdp *instance, rdpContext *context) { (void)instance; (void)context; }
int ClientStart(rdpContext *context) { (void)context; return 0; }
int ClientStop(rdpContext *context) { (void)context; return 0; }
}  // namespace

int RdpClientEntry(RDP_CLIENT_ENTRY_POINTS *pEntryPoints) {
    if (pEntryPoints == nullptr) {
        return -1;
    }
    ZeroMemory(pEntryPoints, sizeof(RDP_CLIENT_ENTRY_POINTS));
    pEntryPoints->Version = RDP_CLIENT_INTERFACE_VERSION;
    pEntryPoints->Size = sizeof(RDP_CLIENT_ENTRY_POINTS);
    pEntryPoints->GlobalInit = ClientGlobalInit;
    pEntryPoints->GlobalUninit = ClientGlobalUninit;
    pEntryPoints->ContextSize = sizeof(MottyRdpContext);
    pEntryPoints->ClientNew = ClientNew;
    pEntryPoints->ClientFree = ClientFree;
    pEntryPoints->ClientStart = ClientStart;
    pEntryPoints->ClientStop = ClientStop;
    return 0;
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

// 服务端侧计数（定义在 rdp_server.cpp），用于证明"输入真的到达服务端"
extern "C" void MottyRdpInputStats(int *keys, int *mouse, int *sync);

// rdpInputProbe(host, port, user, password, cb)：连接 → 发键鼠 → 回报服务端收到多少
void inputProbeWorker(RdpJob *job) {
    std::string result;
    RDP_CLIENT_ENTRY_POINTS entryPoints = {0};
    RdpClientEntry(&entryPoints);
    rdpContext *context = freerdp_client_context_new(&entryPoints);
    freerdp *instance = context != nullptr ? context->instance : nullptr;
    if (instance == nullptr) {
        result = "input: error context";
    } else {
        rdpSettings *settings = context->settings;
        freerdp_settings_set_string(settings, FreeRDP_ServerHostname, job->host.c_str());
        freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, static_cast<uint32_t>(job->port));
        freerdp_settings_set_string(settings, FreeRDP_Username, job->user.c_str());
        freerdp_settings_set_string(settings, FreeRDP_Password, job->password.c_str());
        instance->VerifyCertificateEx = VerifyCertEx;
        freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE);
        freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
        instance->PostConnect = OnPostConnect;
        instance->PostDisconnect = OnPostDisconnect;
        if (!freerdp_connect(instance)) {
            result = std::string("input: connect failed: ") +
                     freerdp_get_last_error_string(freerdp_get_last_error(context));
        } else {
            // 每次渲染都从零开始统计：这些是全局累计量，不重置的话"24 块就 break"会立刻命中
            {
                std::lock_guard<std::mutex> lock(g_statsMtx);
                g_stats = RenderStats();
                g_bmpUpdates = 0;
                g_bmpRects = 0;
                g_bmpLastW = 0;
                g_bmpLastH = 0;
                g_paints.store(0);
            }
            int keyBefore = 0, mouseBefore = 0, syncBefore = 0;
            MottyRdpInputStats(&keyBefore, &mouseBefore, &syncBefore);
            for (int i = 0; i < 40; i++) {   // ~2s 抖动，让连接稳定
                if (!freerdp_check_fds(instance)) {
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            if (context->input != nullptr) {
                // 'A' = 0x1E（RDP scancode），按下 + 抬起
                freerdp_input_send_keyboard_event(context->input, 0, 0x1E);
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                freerdp_input_send_keyboard_event(context->input, 0x8000, 0x1E);
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                freerdp_input_send_mouse_event(context->input, PTR_FLAGS_MOVE, 33, 44);
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                freerdp_input_send_mouse_event(context->input,
                                               PTR_FLAGS_BUTTON1 | PTR_FLAGS_DOWN, 33, 44);
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                freerdp_input_send_mouse_event(context->input, PTR_FLAGS_BUTTON1, 33, 44);
            }
            for (int i = 0; i < 60; i++) {   // 再泵一会儿，等输入送达
                if (!freerdp_check_fds(instance)) {
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            int keyAfter = 0, mouseAfter = 0, syncAfter = 0;
            MottyRdpInputStats(&keyAfter, &mouseAfter, &syncAfter);
            char buf[256];
            snprintf(buf, sizeof(buf),
                     "input: sent key+mouse; serverSaw keys=%d mouse=%d sync=%d (before %d/%d/%d)",
                     keyAfter, mouseAfter, syncAfter, keyBefore, mouseBefore, syncBefore);
            result = buf;
            freerdp_disconnect(instance);
        }
        freerdp_client_context_free(context);
    }
    auto *payload = new std::string(result);
    napi_call_threadsafe_function(job->cb, payload, napi_tsfn_blocking);
    napi_release_threadsafe_function(job->cb, napi_tsfn_release);
    delete job;
}

// rdpRender(host, port, user, password, cb)：连接 → 泵事件若干秒 → 回调画面上传统计
void renderWorker(RdpJob *job) {
    std::string result;
    // 与 rdpTryConnect 一致：只链 libfreerdp 时用 freerdp_new + freerdp_context_new
    RDP_CLIENT_ENTRY_POINTS entryPoints = {0};
    RdpClientEntry(&entryPoints);
    rdpContext *context = freerdp_client_context_new(&entryPoints);
    freerdp *instance = context != nullptr ? context->instance : nullptr;
    if (instance == nullptr) {
        result = "error context";
    } else {
        rdpSettings *settings = context->settings;
        freerdp_settings_set_string(settings, FreeRDP_ServerHostname, job->host.c_str());
        freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, static_cast<uint32_t>(job->port));
        freerdp_settings_set_string(settings, FreeRDP_Username, job->user.c_str());
        freerdp_settings_set_string(settings, FreeRDP_Password, job->password.c_str());
        instance->VerifyCertificateEx = VerifyCertEx;
        freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE);
        freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
        // 只接受原始位图：GFX/H264/RemoteFX 一旦协商成功，我们的 gdi 会解不出来 -> 纯色画面（实测）
        freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, FALSE);
        freerdp_settings_set_bool(settings, FreeRDP_GfxH264, FALSE);
        freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, FALSE);
        freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, FALSE);
        freerdp_settings_set_bool(settings, FreeRDP_NSCodec, FALSE);
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
            // shadow 服务端有"lobby"：客户端必须发一次输入才会进入桌面，否则永远收不到位图
            auto leaveLobby = []() {};
            (void)leaveLobby;
            if (context->input != nullptr) {
                freerdp_input_send_mouse_event(context->input, PTR_FLAGS_MOVE, 10, 10);
                freerdp_input_send_mouse_event(context->input,
                                               PTR_FLAGS_BUTTON1 | PTR_FLAGS_DOWN, 10, 10);
                freerdp_input_send_mouse_event(context->input, PTR_FLAGS_BUTTON1, 10, 10);
            }
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
                // 不要在第 3 个更新就退出：shadow 按 64x64 瓦片发送，
                // 整屏需要几十个 PDU，提前 break 会留下大片未解码的白色区域。
                {
                    const int need = st2NeedPixels(instance);
                    if (need > 0 && snapshot.pixels >= need) {
                        break;
                    }
                }
            }
            RenderStats st;
            {
                std::lock_guard<std::mutex> lock(g_statsMtx);
                st = g_stats;
            }
            // 采样必须放在泵循环之后：EndPaint 时刻缓冲可能还是空白（实测 colors=1）
            snapshotFromGdi(instance->context);
            // 若 EndPaint 有计数，说明更新到达了：直接从 GDI 主缓冲读像素做统计
            RenderStats st2;
            {
                std::lock_guard<std::mutex> lock(g_statsMtx);
                st2 = g_stats;
            }
            {
                const int paints = g_paints.load();
                if (paints > 0 && instance->context->gdi != nullptr &&
                    instance->context->gdi->primary_buffer != nullptr) {
                    const BYTE *buf = instance->context->gdi->primary_buffer;
                    const UINT32 w = instance->context->gdi->width;
                    const UINT32 h = instance->context->gdi->height;
                    st2.width = static_cast<int>(w);
                    st2.height = static_cast<int>(h);
                    st2.pixels = static_cast<int>(w * h);
                    const size_t total = static_cast<size_t>(w) * h;
                    const size_t step = total / 512 + 1;
                    for (size_t i = 0; i < total; i += step) {
                        const BYTE b = buf[i * 4 + 0];
                        const BYTE g = buf[i * 4 + 1];
                        const BYTE r = buf[i * 4 + 2];
                        const int idx = ((r > 127) ? 4 : 0) + ((g > 127) ? 2 : 0) + ((b > 127) ? 1 : 0);
                        st2.buckets[idx]++;
                    }
                }
            }
            char buf[256];
            const int depth = (instance->context->settings != nullptr)
                ? static_cast<int>(freerdp_settings_get_uint32(instance->context->settings, FreeRDP_ColorDepth)) : -1;
            const int dstFmt = (instance->context->gdi != nullptr) ? static_cast<int>(instance->context->gdi->dstFormat) : -1;
            snprintf(buf, sizeof(buf),
                     "frames=%d paints=%d size=%dx%d pixels=%d depth=%d dst=%d colors=%d/%d/%d/%d/%d/%d/%d/%d at=%d,%d",
                     st2.updates, g_paints.load(), st2.width, st2.height, st2.pixels, depth, dstFmt,
                     st2.buckets[0], st2.buckets[1], st2.buckets[2], st2.buckets[3],
                     st2.buckets[4], st2.buckets[5], st2.buckets[6], st2.buckets[7], g_bmpLastX, g_bmpLastY);
            result = buf;
            freerdp_disconnect(instance);
        }
        freerdp_client_context_free(context);
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
    size_t argc = 6;
    napi_value args[6] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) {
        napi_throw_type_error(env, nullptr, "rdpRender(host, port, user, password, cb, nla?)");
        return nullptr;
    }
    auto *job = new RdpJob();
    job->host = getString(env, args[0]);
    int32_t port = 3389;
    napi_get_value_int32(env, args[1], &port);
    job->port = port;
    job->user = getString(env, args[2]);
    job->password = getString(env, args[3]);
    if (argc >= 6) {
        bool nla = false;
        napi_get_value_bool(env, args[5], &nla);
        job->useNla = nla;
    }
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

// rdpSnapshot() -> ArrayBuffer(64*48*4, RGBA)：Windows 端最近一帧的采样
// rawTcpProbe(host, port) -> "tcp: ok|errno=N"：确认应用能否出网（不含任何协议）
napi_value RawTcpProbe(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string host = argc >= 1 ? getString(env, args[0]) : "127.0.0.1";
    int32_t port = 3389;
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &port);
    }
    std::string result;
    struct addrinfo hints = {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = nullptr;
    const std::string portStr = std::to_string(port);
    const int gai = getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res);
    if (gai != 0 || res == nullptr) {
        result = "tcp: dns fail gai=" + std::to_string(gai);
    } else {
        const int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (fd < 0) {
            result = "tcp: socket fail errno=" + std::to_string(errno);
        } else {
            const int rc = connect(fd, res->ai_addr, res->ai_addrlen);
            result = (rc == 0) ? "tcp: ok" : ("tcp: connect fail errno=" + std::to_string(errno));
            close(fd);
        }
        freeaddrinfo(res);
    }
    napi_value out = nullptr;
    napi_create_string_utf8(env, result.c_str(), NAPI_AUTO_LENGTH, &out);
    return out;
}

napi_value RdpSnapshot(napi_env env, napi_callback_info info) {
    (void)info;
    // 直接返回 Uint8Array：ArkTS 侧收到的类型才与 `Uint8Array` 匹配
    // （返回裸 ArrayBuffer 时实测读出来全是 0）
    void *data = nullptr;
    napi_value buffer = nullptr;
    if (napi_create_arraybuffer(env, sizeof(g_snap), &data, &buffer) != napi_ok) {
        return nullptr;
    }
    memcpy(data, g_snap, sizeof(g_snap));
    napi_value typed = nullptr;
    if (napi_create_typedarray(env, napi_uint8_array, sizeof(g_snap), buffer, 0, &typed) != napi_ok) {
        return nullptr;
    }
    return typed;
}

// rdpSnapStats() -> "colors=N nonBlack=M"（C++ 侧采样统计，用于排查跨语言传参）
napi_value RdpSnapStats(napi_env env, napi_callback_info info) {
    (void)info;
    char buf[96];
    const uint32_t d = g_snapDom.load();
    snprintf(buf, sizeof(buf), "bmp=%d rects=%d last=%dx%d colors=%d nonBlack=%d valid=%d dominant=#%02X%02X%02X (%d px)",
             g_bmpUpdates, g_bmpRects, g_bmpLastW, g_bmpLastH,
             g_snapColors.load(), g_snapNonBlack.load(), g_snapValid.load(),
             (d >> 16) & 0xFF, (d >> 8) & 0xFF, d & 0xFF, g_snapDomCount.load());
    napi_value out = nullptr;
    napi_create_string_utf8(env, buf, NAPI_AUTO_LENGTH, &out);
    return out;
}

napi_value RdpInputProbe(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) {
        napi_throw_type_error(env, nullptr, "rdpInputProbe(host, port, user, password, cb)");
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
    napi_create_string_utf8(env, "motty.rdp.input", NAPI_AUTO_LENGTH, &name);
    if (napi_create_threadsafe_function(env, args[4], nullptr, name, 0, 1, nullptr, nullptr, nullptr,
                                        callJs, &job->cb) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "tsfn failed");
        return nullptr;
    }
    std::thread(inputProbeWorker, job).detach();
    return nullptr;
}

void RegisterRdpFunctions(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"rdpProbe", nullptr, RdpProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpRender", nullptr, RdpRender, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpSnapshot", nullptr, RdpSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpInputProbe", nullptr, RdpInputProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpSnapStats", nullptr, RdpSnapStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rawTcpProbe", nullptr, RawTcpProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
}
