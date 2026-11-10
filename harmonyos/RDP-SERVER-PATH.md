# RDP 服务端路径可行性（Round 54 更新）

> 承接 §6/§7：mbedTLS-only 不可行、OpenSSL 路线已打通、客户端静态库已就绪。
> 本文记录 **"可验证对端"** 这条支线的最新进展：FreeRDP **server** 组件已能为 OHOS 编译（E2）。

## 8. 对端三条路，选哪条

| 路线 | 说明 | 代价 | 结论 |
|---|---|---|---|
| A. 开启宿主远程桌面 | 把 Windows 宿主作为真实 RDP 服务端 | 需管理员授权 + 改宿主安全设置；还要真实凭据 | **未采纳**（未经授权不改宿主；且凭据不可得） |
| B. 自研最小 RDP 服务端夹具 | 用 Go 从零写 X.224/MCS/安全/能力协商 | 协议栈极大，数周量级 | 备选 |
| C. **FreeRDP server 组件 + 自定义 capture 子系统** | 复用 FreeRDP 的完整服务端实现（Apache-2.0），只实现"像素从哪来" | 需要写 ~300–600 行 C | **选定** |

选 C 的理由：协议（协商、licensing、能力集、位图编码、输入通道）全部由 FreeRDP 实现，
与我们客户端链接的是**同一套协议栈**，因此验证是"真实协议互通"，不是自说自话；
我们只补一个"虚拟屏幕"实现。

## 9. 已完成（E2，实测）

| 项 | 结果 |
|---|---|
| `-DWITH_SERVER=ON` 配置 | **成功**（x86_64 与 arm64 都通过，`-- Adding ... freerdp-server`） |
| `libfreerdp-server3.a` | x86_64 **850 KB**、arm64 **950 KB** |
| 链接探针 | 引用 `shadow_server_new/shadow_server_start` 与 `rdpShadowServer` 结构，
与 `libfreerdp/libwinpr/libssl/libcrypto` 一起链接成 **10 KB `.so`**，`EM_X86_64` |
| 头文件完备性 | **关键发现**：安装后的 `freerdp/server/shadow.h` 里已经包含
`RDP_SHADOW_ENTRY_POINTS`、`rdpShadowSubsystem` 全部字段与 `shadow_capture_*` API，
因此**不需要 FreeRDP 源码树内部头**就能实现自定义子系统 |

## 10. 下一步实现（Round 55+）

自定义子系统需要实现的最小集合（全部在公开头里）：

```c
static rdpShadowSubsystem* vss_new(void);       /* 分配 + 填 ep */
static void  vss_free(rdpShadowSubsystem*);
static int   vss_init(rdpShadowSubsystem*);     /* 设置 numMonitors/monitors[] 尺寸、captureFrameRate */
static int   vss_uninit(rdpShadowSubsystem*);
static int   vss_start(rdpShadowSubsystem*);    /* 起一个生产者线程，周期性喂帧 */
static int   vss_stop(rdpShadowSubsystem*);
static UINT32 vss_enum_monitors(MONITOR_DEF*, UINT32);
```

要点：
1. `Init` 里设置 `subsystem->numMonitors = 1`、`monitors[0] = {0,0,W-1,H-1}`、`captureFrameRate`
2. `Start` 起线程：向 shadow 的 surface 写入图案（左半红/右半蓝 + 一个走动的方块），
   用 `shadow_capture_compare*` 判断"这一帧有没有变"，变了才推
3. 通过 `shadow_subsystem_set_entry(&entry)` 注册，再 `shadow_server_new()` →
   设置端口/认证回调 → `shadow_server_start()`
4. 认证回调（`pfnShadowAuthenticate`）接受固定口令，用于验证 NLA/CredSSP 之外的简单路径；
   NLA 需要 `certificate` 与 `SAM` 配置，先走"不一致也不崩"的路径，并在文档里写清

**验收计划**：App 内启动服务端（`rdpServerStart(port)`）→ 客户端 `rdpProbe` 连 `127.0.0.1:<port>`
→ 断言 `connected`（当前客户端只到连接路径）→ 再补客户端位图/输入后断言画面。

## 11. 仍然诚实的边界

- 服务端是**我们用来验证自己**的组件，不等于"能与真实 Windows RDP 服务端互通"；
  真正的互操作验证仍需路线 A（真实 Windows/其他 RDP 服务端）
- 客户端目前只有连接路径：即使服务端能跑，`rdpProbe` 也只能断言"连上了"，
  **没有**画面、没有输入、没有通道
- NLA/CredSSP、证书 pin、多显示器、RDPGFX 动态通道都未验证
