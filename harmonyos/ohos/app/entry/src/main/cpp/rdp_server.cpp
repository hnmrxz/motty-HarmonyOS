// rdp_server.cpp —— 应用内的 RDP 服务端（FreeRDP shadow server + 自定义 capture 子系统）
//
// 目的：给 RDP 客户端一个**真实协议**的可验证对端。协议协商、licensing、能力集、
// 位图编码、输入通道全部由 FreeRDP 的 shadow server 实现（Apache-2.0），
// 我们只补"像素从哪来"——一个纯色/渐变图案的虚拟屏幕。
//
// 这不是"RDP 服务端产品功能"，而是测试对端。界面里只作诊断入口。
//
// 仍然没做（不假装做了）：
//   - 输入事件没有回传到 UI（KeyboardEvent/MouseEvent 回调为空实现）
//   - 只支持单一 640x480 监视器、固定帧率
//   - NLA/CredSSP 未启用（走 shadow 的简单认证回调）
#include <napi/native_api.h>

#include <freerdp/freerdp.h>
#include <freerdp/server/shadow.h>
#include <winpr/synch.h>
#include <winpr/tools/makecert.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cerrno>
#include <pthread.h>
#include <winpr/wlog.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

extern "C" {
rdpShadowScreen *shadow_screen_new(rdpShadowServer *server);
rdpShadowCapture *shadow_capture_new(rdpShadowServer *server);
}

namespace {

constexpr UINT32 kVssWidth = 640;
constexpr UINT32 kVssHeight = 480;
constexpr UINT32 kVssFps = 10;

struct VssSubsystem {
    rdpShadowSubsystem common;     // 必须是第一个成员（FreeRDP 用容器转换）
    std::thread worker;
    std::atomic<bool> stop{false};
    std::atomic<uint32_t> frames{0};
    std::atomic<uint32_t> loops{0};
    std::atomic<int> surfaceSeen{0};
    char user[64];
    char password[64];
};

rdpShadowServer *g_server = nullptr;
char g_authUser[64] = {0};
char g_authPass[64] = {0};
VssSubsystem *g_subsystem = nullptr;
std::thread g_serverThread;
std::atomic<bool> g_running{false};
// 构建指纹：用来确认"设备上跑的到底是哪一份 .so"（用例 vs 手动点击）
const char *g_buildStamp = __DATE__ " " __TIME__;
std::string g_lastError;
// 我们自己的 ep.Init 是否被调用过：用来把失败点切在 shadow_subsystem_init 的前半段/后半段
int g_vssInitCalls = 0;
int g_vssStartCalls = 0;
int g_threadEntered = 0;
int g_threadExited = 0;
int g_startRc = -2;
int g_startStage = 0;
int g_lockOk = 0;
int g_paintOk = 0;
int g_updateOk = 0;
int g_paintSkipped = 0;
uint32_t g_tickFrames = 0;
int g_lobbyPaint = 0;
int g_lobbyNull = 0;
int g_paintRows = 0;
int g_capStarted = -1;
int g_afterSleep = 0;
int g_frameAdds = 0;
unsigned long long g_threadSubPtr = 0;
unsigned long long g_subPtr = 0;
unsigned long long g_surfW = 0, g_surfH = 0, g_surfStride = 0;
int g_surfDataNull = 1;
std::string g_threadError;
unsigned long long g_basePtr = 0;
unsigned long long g_gPtr = 0;
std::string g_lastConfigDir;
int g_lastRc = -1;

// 诊断日志：自己 fopen 写文件，不依赖 stderr（OHOS 上 stderr 不进 hilog，
// freopen 也可能失败）。文件名固定，方便 hdc file recv 拉回来。
static FILE *g_diag = nullptr;
void diagLog(const char *fmt, ...) {
    if (g_diag == nullptr) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_diag, fmt, ap);
    va_end(ap);
    fputc('\n', g_diag);
    fflush(g_diag);
}

void serverLog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char buf[512];
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(stderr, "[MOTTY_RDP] %s\n", buf);
    fflush(stderr);
}

// 把一帧图案写进 shadow 的表面：左半暖色、右半冷色，横向渐变便于肉眼确认
void paintSurface(rdpShadowSurface *surface, uint32_t frame) {
    if (surface == nullptr || surface->data == nullptr) {
        g_paintSkipped++;
        return;
    }
    // 护栏：surface 的宽高来自 shadow 内部，实测可能读到脏值；
    // 若不做上界检查，paintSurface 会变成"看似死循环"。
    if (surface->width == 0 || surface->height == 0 || surface->width > 8192 ||
        surface->height > 8192 || surface->scanline < surface->width * 4) {
        g_paintSkipped++;
        return;
    }
    const UINT32 w = surface->width;
    const UINT32 h = surface->height;
    uint8_t *base = surface->data;
    for (UINT32 y = 0; y < h; y++) {
        uint8_t *row = base + static_cast<size_t>(y) * surface->scanline;
        for (UINT32 x = 0; x < w; x++) {
            // BGRA32
            const uint8_t gx = static_cast<uint8_t>((x * 255u) / (w > 1 ? w - 1 : 1));
            const uint8_t gy = static_cast<uint8_t>((y * 255u) / (h > 1 ? h - 1 : 1));
            const bool moving = ((x + frame * 4) / 32 + y / 32) % 2 == 0;
            uint8_t *px = row + static_cast<size_t>(x) * 4;
            px[0] = moving ? gy : 0x20;          // B
            px[1] = moving ? gx : 0x20;          // G
            px[2] = moving ? 0x40 : gx;          // R
            px[3] = 0xFF;                        // A
        }
        g_paintRows++;
    }
}

void captureThread(VssSubsystem *sub) {
    g_threadSubPtr = reinterpret_cast<unsigned long long>(sub);
    g_threadEntered++;
    uint32_t frame = 0;
    if (sub == nullptr) {
        return;
    }
    while (!sub->stop.load()) {
        rdpShadowServer *server = sub->common.server;
        sub->loops.fetch_add(1);
        if (server != nullptr && server->surface != nullptr) {
            sub->surfaceSeen.store(1);
            rdpShadowSurface *surface = server->surface;
            EnterCriticalSection(&surface->lock);
            g_lockOk++;
            g_surfW = surface->width;
            g_surfH = surface->height;
            g_surfStride = surface->scanline;
            g_surfDataNull = (surface->data == nullptr) ? 1 : 0;
            paintSurface(surface, frame++);
            g_paintOk++;
            {
                RECTANGLE_16 rect = {0, 0, static_cast<UINT16>(surface->width - 1),
                                     static_cast<UINT16>(surface->height - 1)};
                region16_union_rect(&surface->invalidRegion, &surface->invalidRegion, &rect);
            }
            LeaveCriticalSection(&surface->lock);
            // 通知 shadow：有新帧可编码/发送
            shadow_subsystem_frame_update(&sub->common);
            g_updateOk++;
            sub->frames.fetch_add(1);
            g_frameAdds++;
        }
        g_afterSleep++;
        std::this_thread::sleep_for(std::chrono::milliseconds(1000 / kVssFps));
    }
    g_threadExited++;
}

rdpShadowSubsystem *vss_new(void) {
    auto *sub = static_cast<VssSubsystem *>(calloc(1, sizeof(VssSubsystem)));
    if (sub == nullptr) {
        return nullptr;
    }
    sub->common.captureFrameRate = kVssFps;
    return &sub->common;
}

void vss_free(rdpShadowSubsystem *base) {
    free(reinterpret_cast<VssSubsystem *>(base));
}

UINT32 vss_enum_monitors(MONITOR_DEF *monitors, UINT32 maxMonitors) {
    if (maxMonitors < 1 || monitors == nullptr) {
        return 0;
    }
    monitors[0].left = 0;
    monitors[0].top = 0;
    monitors[0].right = static_cast<INT32>(kVssWidth) - 1;
    monitors[0].bottom = static_cast<INT32>(kVssHeight) - 1;
    monitors[0].flags = 1;
    return 1;
}

int vss_init(rdpShadowSubsystem *base) {
    g_vssInitCalls++;
    auto *sub = reinterpret_cast<VssSubsystem *>(base);
    if (sub == nullptr) {
        return -1;
    }
    sub->common.numMonitors = vss_enum_monitors(sub->common.monitors, 16);
    sub->common.virtualScreen = sub->common.monitors[0];
    serverLog("subsystem init: %ux%u fps=%u", kVssWidth, kVssHeight, kVssFps);
    return 0;
}

int vss_uninit(rdpShadowSubsystem *base) {
    (void)base;
    return 0;
}

int vss_start(rdpShadowSubsystem *base) {
    g_vssStartCalls++;
    g_startStage = 1;
    g_basePtr = reinterpret_cast<unsigned long long>(base);
    // 注意（实测）：在 shadow_server_thread 里构造 std::thread 会**卡住不返回**
    // （stage 停在 5、无异常、startRc 保持初值）。因此这里只确认子系统就绪，
    // 采集线程改由 RdpServerStart 在 shadow_server_start 成功之后创建（全进程仅此一处）。
    g_startStage = 6;
    return 0;
}

int vss_stop(rdpShadowSubsystem *base) {
    auto *sub = reinterpret_cast<VssSubsystem *>(base);
    if (sub == nullptr) {
        return -1;
    }
    sub->stop.store(true);
    if (sub->worker.joinable()) {
        sub->worker.join();
    }
    return 0;
}

// 认证：固定账号口令。返回值语义见 shadow_client.c：<0 失败，>=0 通过
int vss_authenticate(rdpShadowSubsystem *base, rdpShadowClient *client, const char *user,
                     const char *domain, const char *password) {
    (void)client;
    (void)domain;
    auto *sub = reinterpret_cast<VssSubsystem *>(base);
    if (sub == nullptr) {
        return -1;
    }
    const bool ok = user != nullptr && password != nullptr &&
                    strcmp(user, g_authUser) == 0 && strcmp(password, g_authPass) == 0;
    serverLog("authenticate user=%s ok=%d", user == nullptr ? "(null)" : user, ok ? 1 : 0);
    return ok ? 1 : -1;
}

int vss_entry_points(RDP_SHADOW_ENTRY_POINTS *ep) {
    if (ep == nullptr) {
        return 0;
    }
    ep->New = vss_new;
    ep->Free = vss_free;
    ep->Init = vss_init;
    ep->Uninit = vss_uninit;
    ep->Start = vss_start;
    ep->Stop = vss_stop;
    ep->EnumMonitors = vss_enum_monitors;
    return 1;
}

// 线程生命周期：必须先停并 join，再 stop/uninit/free shadow server。
// 上一版直接起线程但没 join 就 free，导致 std::terminate / 野指针。
// 启动采集线程：shadow 不会调用 ep.Start（实测），所以由我们起。
// 用 try/catch 兜住 std::system_error，避免 std::terminate。
int startCaptureThread() {
    if (g_subsystem == nullptr || g_subsystem->worker.joinable()) {
        return 0;
    }
    g_subsystem->stop.store(false);
    try {
        g_subsystem->worker = std::thread(captureThread, g_subsystem);
        g_capStarted = 1;
        return 1;
    } catch (const std::exception &e) {
        g_capStarted = 0;
        g_threadError = std::string("capture: ") + e.what();
        serverLog("capture thread creation failed: %s", e.what());
        return 0;
    } catch (...) {
        g_capStarted = 2;
        return 0;
    }
}

void stopCaptureThread() {
    if (g_subsystem == nullptr) {
        return;
    }
    g_subsystem->stop.store(true);
    if (g_subsystem->worker.joinable()) {
        g_subsystem->worker.join();
    }
}

void stopServerLocked() {
    stopCaptureThread();
    if (g_server != nullptr) {
        shadow_server_stop(g_server);
        shadow_server_uninit(g_server);
        shadow_server_free(g_server);
        g_server = nullptr;
    }
    g_subsystem = nullptr;
    g_running.store(false);
}

std::string getStringArg(napi_env env, napi_value v) {
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

// rdpServerStart(port, user, password, configDir) -> 0 成功；非 0 失败（错误写入 lastError 可查）
// configDir 必须是应用可写目录：OHOS 上没有 XDG 配置目录，
// shadow_server_init 会因 ConfigPath 为空直接失败（实测 err=shadow_server_init failed）。
napi_value RdpServerStart(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_type_error(env, nullptr, "rdpServerStart(port, user, password, configDir)");
        return nullptr;
    }
    int32_t port = 13389;
    napi_get_value_int32(env, args[0], &port);
    const std::string user = getStringArg(env, args[1]);
    const std::string password = getStringArg(env, args[2]);
    const std::string configDir = getStringArg(env, args[3]);
    g_lastConfigDir = configDir;

    int32_t rc = 0;
    if (g_running.load()) {
        rc = 2;   // 已在运行
    } else {
        snprintf(g_authUser, sizeof(g_authUser), "%s", user.c_str());
        snprintf(g_authPass, sizeof(g_authPass), "%s", password.c_str());
        shadow_subsystem_set_entry(vss_entry_points);
        g_server = shadow_server_new();
        if (g_server == nullptr) {
            g_lastError = "shadow_server_new failed";
            rc = 3;
        } else {
            g_server->port = static_cast<DWORD>(port);
            // 测试对端默认不要求认证：我们的 shadow 认证回调走的是非 NLA 路径，
            // 而客户端默认可能协商 NLA，导致'认证失败'。先用无认证证明协议链路，再单独查认证。
            g_server->authentication = FALSE;
            if (!configDir.empty()) {
                // 把 stderr 重定向到应用目录：FreeRDP 的 WLog 默认写 stderr，
                // 而 OHOS 上 stderr 不进 hilog，导致失败时"什么都看不到"。
                const std::string logPath = configDir + "/motty-rdp-server.log";
                g_diag = fopen("/data/storage/el2/base/cache/motty-rdp-server.log", "w");
                if (g_diag == nullptr) {
                    g_diag = fopen(logPath.c_str(), "w");
                }
                diagLog("=== rdp server start port=%d configDir=%s diagOpen=%d", port,
                        configDir.c_str(), g_diag != nullptr ? 1 : 0);
                {
                    // 目录可写性自检：shadow_server_init 会在该目录下建 shadow/ 子目录
                    const std::string probe = configDir + "/rdp-write-probe";
                    FILE *fp = fopen(probe.c_str(), "w");
                    diagLog("write probe: %s", fp != nullptr ? "ok" : "FAILED");
                    if (fp != nullptr) {
                        fclose(fp);
                        remove(probe.c_str());
                    }
                }
                serverLog("=== rdp server start port=%d configDir=%s", port, configDir.c_str());
                g_server->ConfigPath = _strdup(configDir.c_str());
                serverLog("config path: %s", configDir.c_str());
            }
            // subsystem 在 shadow_server_init 里才由 entry points 创建；
            // 凭据用文件级静态量传递（顺序坑：之前在这里取 g_server->subsystem 是空的）
            // FreeRDP 约定：shadow_server_init 成功返回 0，失败返回 <0（不是布尔！）
            const bool initOk = shadow_server_init(g_server) >= 0;
            diagLog("shadow_server_init -> %s", initOk ? "ok" : "FAILED");
            if (!initOk) {
                // 分阶段自检：证书/私钥/监听器/子系统，结果拼进状态行（不依赖日志文件）
                std::string stageTrace = "stage[";
                if (g_server->CertificateFile != nullptr) {
                    rdpCertificate *c = freerdp_certificate_new_from_file(g_server->CertificateFile);
                    stageTrace += std::string("cert=") + (c != nullptr ? "ok" : "FAIL");
                    if (c != nullptr) {
                        freerdp_certificate_free(c);
                    }
                } else {
                    stageTrace += "cert=unset";
                }
                if (g_server->PrivateKeyFile != nullptr) {
                    rdpPrivateKey *k = freerdp_key_new_from_file(g_server->PrivateKeyFile);
                    stageTrace += std::string(" key=") + (k != nullptr ? "ok" : "FAIL");
                    if (k != nullptr) {
                        freerdp_key_free(k);
                    }
                } else {
                    stageTrace += " key=unset";
                }
                {
                    freerdp_listener *l = freerdp_listener_new();
                    stageTrace += std::string(" listener=") + (l != nullptr ? "ok" : "FAIL");
                    if (l != nullptr) {
                        freerdp_listener_free(l);
                    }
                }
                {
                    // shadow_subsystem_new/free 是内部函数（不在公开头里）；
                    // 这里直接调用我们自己注册的 entry 的 New/Free 验证子系统本身可用
                    RDP_SHADOW_ENTRY_POINTS ep{};
                    const int epOk = vss_entry_points(&ep);
                    rdpShadowSubsystem *ss = (epOk == 1 && ep.New != nullptr) ? ep.New() : nullptr;
                    stageTrace += std::string(" subsystem=") + (ss != nullptr ? "ok" : "FAIL");
                    if (ss != nullptr && ep.Free != nullptr) {
                        ep.Free(ss);
                    }
                }
                stageTrace += std::string(" vssInit=") + std::to_string(g_vssInitCalls) + "]";
                g_lastError = "shadow_server_init failed " + stageTrace;
                // 单测 makecert：自签证书是 init 里最容易在 OHOS 上失败的环节
                MAKECERT_CONTEXT *mc = makecert_context_new();
                diagLog("makecert_context_new -> %s", mc != nullptr ? "ok" : "NULL");
                if (mc != nullptr) {
                    char *argv[6] = {const_cast<char *>("makecert"), const_cast<char *>("-rdp"),
                                     const_cast<char *>("-live"), const_cast<char *>("-silent"),
                                     const_cast<char *>("-y"), const_cast<char *>("5")};
                    const int prc = makecert_context_process(mc, 6, argv);
                    diagLog("makecert_context_process -> %d", prc);
                    makecert_context_free(mc);
                }
                shadow_server_free(g_server);
                g_server = nullptr;
                rc = 4;
            } else {
                // shadow 默认先给客户端一个"lobby"画面并要求交互才进桌面；
                // 直接授权，避免客户端看到的是 lobby 而不是真实桌面内容。
                g_server->mayView = TRUE;
                g_server->mayInteract = TRUE;
                g_subsystem = reinterpret_cast<VssSubsystem *>(g_server->subsystem);
                g_subPtr = reinterpret_cast<unsigned long long>(g_subsystem);
                if (g_subsystem != nullptr) {
                    g_subsystem->common.Authenticate = vss_authenticate;
                    serverLog("subsystem ready: monitors=%u", g_subsystem->common.numMonitors);
                } else {
                    serverLog("warning: server->subsystem is null after init");
                }
                // shadow_server_start 同样是"成功返回 0、失败 <0"（见 shadow_server.c 的 return 0）
                if (shadow_server_start(g_server) < 0) {
                    {
                    // 分阶段：start 内部会自己建 screen/capture，先把它们单独测一遍，
                    // 剩下唯一可能就是监听器绑定（端口/权限）
                    std::string t2 = " start[";
                    rdpShadowScreen *sc = shadow_screen_new(g_server);
                    t2 += std::string("screen=") + (sc != nullptr ? "ok" : "FAIL");
                    rdpShadowCapture *cap = shadow_capture_new(g_server);
                    t2 += std::string(" capture=") + (cap != nullptr ? "ok" : "FAIL");
                    t2 += "]";
                    // 直接测"应用能不能监听这个端口"：OHOS 对 listen 是否有额外限制
                    {
                        int fd = socket(AF_INET, SOCK_STREAM, 0);
                        int bindProbe = -1;
                        if (fd >= 0) {
                            struct sockaddr_in addr{};
                            addr.sin_family = AF_INET;
                            addr.sin_addr.s_addr = htonl(INADDR_ANY);
                            addr.sin_port = htons(static_cast<uint16_t>(port));
                            bindProbe = bind(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr));
                            if (bindProbe == 0) {
                                bindProbe = listen(fd, 4);
                            }
                            const int err = errno;
                            t2 += std::string(" bindProbe=") + (bindProbe == 0 ? "ok" : "FAIL") +
                                  "(errno=" + std::to_string(err) + ")";
                            close(fd);
                        } else {
                            t2 += " bindProbe=socketFAIL";
                        }
                    }
                    // 端口已被占用说明 open_port 成功 -> 失败在 CreateThread；单独测一下
                    {
                        pthread_t th{};
                        const int trc = pthread_create(&th, nullptr, [](void *) -> void * {
                            return nullptr;
                        }, nullptr);
                        t2 += std::string(" threadProbe=") + (trc == 0 ? "ok" : "FAIL(" + std::to_string(trc) + ")");
                        if (trc == 0) {
                            pthread_join(th, nullptr);
                        }
                        HANDLE h = CreateThread(nullptr, 0, [](void *) -> DWORD { return 0; }, nullptr, 0, nullptr);
                        t2 += std::string(" winprThread=") + (h != nullptr ? "ok" : "FAIL");
                        if (h != nullptr) {
                            (void)WaitForSingleObject(h, 1000);
                            CloseHandle(h);
                        }
                    }
                    g_lastError = "shadow_server_start failed" + t2;
                }
                    shadow_server_uninit(g_server);
                    shadow_server_free(g_server);
                    g_server = nullptr;
                    rc = 5;
                } else {
                    g_running.store(true);
                    serverLog("server listening on port %d", port);
                    // 采集线程在这里创建（唯一位置）：vss_start 不再建线程，
                    // 因为实测在 shadow 线程里构造 std::thread 会卡住。
                    // 结论（多轮实测）：在 shadow 的上下文里创建 std::thread 不可靠——
                    // 有时线程函数从不执行（tsp=0）、有时整屏绘制卡住、有时 8x8 能完成。
                    // 因此本版本**不启动采集线程**：服务端只监听，不提供画面。
                    // 这比"看起来有画面但其实没发出去"更诚实。
                    serverLog("capture disabled in this build (see INDEX Round 62)");
                }
            }
    }
    }
    g_lastRc = rc;
    napi_value out = nullptr;
    napi_create_int32(env, rc, &out);
    return out;
}

// rdpServerTick()：由 ArkTS 定时器驱动，画一帧并通知 shadow（在 JS 线程执行）。
// 为什么不用 std::thread：实测在 shadow 上下文创建线程有时根本不被调度（tsp=0）。
napi_value RdpServerTick(napi_env env, napi_callback_info info) {
    (void)info;
    int32_t drawn = 0;
    if (g_running.load() && g_server != nullptr && g_server->surface != nullptr) {
        // 客户端的激活流程没有走到"进入桌面"，shadow 会一直发 lobby 画面（实测纯白 #FFFFFF）。
        // 测试服务端把 lobby 也画成我们的图案，这样"像素能到客户端并能显示"就可验证。
        if (g_server->lobby == nullptr || g_server->lobby->data == nullptr) {
            g_lobbyNull++;
        }
        if (g_server->lobby != nullptr && g_server->lobby->data != nullptr) {
            g_lobbyPaint++;
            paintSurface(g_server->lobby, static_cast<uint32_t>(g_tickFrames));
            {
                RECTANGLE_16 rect = {0, 0, static_cast<UINT16>(g_server->lobby->width - 1),
                                     static_cast<UINT16>(g_server->lobby->height - 1)};
                region16_union_rect(&g_server->lobby->invalidRegion,
                                    &g_server->lobby->invalidRegion, &rect);
            }
        }
        rdpShadowSurface *surface = g_server->surface;
        EnterCriticalSection(&surface->lock);
        paintSurface(surface, static_cast<uint32_t>(g_tickFrames));
        {
            RECTANGLE_16 rect = {0, 0, static_cast<UINT16>(surface->width - 1),
                                 static_cast<UINT16>(surface->height - 1)};
            region16_union_rect(&surface->invalidRegion, &surface->invalidRegion, &rect);
        }
        LeaveCriticalSection(&surface->lock);
        shadow_subsystem_frame_update(g_server->subsystem);
        if (g_subsystem != nullptr) {
            g_subsystem->frames.fetch_add(1);
        }
        g_tickFrames++;
        g_paintOk++;
        g_updateOk++;
        drawn = 1;
    }
    napi_value out = nullptr;
    napi_create_int32(env, drawn, &out);
    return out;
}

napi_value RdpServerStop(napi_env env, napi_callback_info info) {
    (void)info;
    stopServerLocked();
    napi_value out = nullptr;
    napi_create_int32(env, 0, &out);
    return out;
}

// rdpServerStatus() -> "running port=3389 frames=42" / "stopped err=..."
napi_value RdpServerStatus(napi_env env, napi_callback_info info) {
    (void)info;
    std::string text;
    if (g_running.load() && g_server != nullptr) {
        const uint32_t frames = g_subsystem != nullptr ? g_subsystem->frames.load() : 0;
        const uint32_t loops = g_subsystem != nullptr ? g_subsystem->loops.load() : 0;
        const int surfaceSeen = g_subsystem != nullptr ? g_subsystem->surfaceSeen.load() : 0;
        text = "running port=" + std::to_string(static_cast<unsigned>(g_server->port)) +
               " frames=" + std::to_string(frames) + " loops=" + std::to_string(loops) +
               " surface=" + (surfaceSeen != 0 ? "ok" : "null") + " stage=" + std::to_string(g_startStage) + " lock=" + std::to_string(g_lockOk) +
               " paint=" + std::to_string(g_paintOk) + " sw=" + std::to_string(g_surfW) +
               " sh=" + std::to_string(g_surfH) + " stride=" + std::to_string(g_surfStride) +
               " dnull=" + std::to_string(g_surfDataNull) + " skip=" + std::to_string(g_paintSkipped) + " cap=" + std::to_string(g_capStarted) + " tsp=" + std::to_string(g_threadSubPtr) +
               " gsp=" + std::to_string(g_subPtr) + " slp=" + std::to_string(g_afterSleep) +
               " fadd=" + std::to_string(g_frameAdds) + " rows=" + std::to_string(g_paintRows) +
               " lob=" + std::to_string(g_lobbyPaint) + " lobNull=" + std::to_string(g_lobbyNull) + " upd=" + std::to_string(g_updateOk) +
               " base=" + std::to_string(g_basePtr) + " g=" + std::to_string(g_gPtr) +
               (g_threadError.empty() ? "" : (" err=" + g_threadError)) + " built=" + g_buildStamp;
    } else {
        text = "stopped rc=" + std::to_string(g_lastRc) + " built=" + g_buildStamp + " dir=" +
               (g_lastConfigDir.empty() ? "(empty)" : g_lastConfigDir) +
               (g_lastError.empty() ? "" : (" err=" + g_lastError));
    }
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

}  // namespace

void RegisterRdpServerFunctions(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"rdpServerStart", nullptr, RdpServerStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpServerStop", nullptr, RdpServerStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpServerTick", nullptr, RdpServerTick, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpServerStatus", nullptr, RdpServerStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
}
