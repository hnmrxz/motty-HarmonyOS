# RDP：可行性、服务端路线与现状
本文件由 `docs/RDP.md` 与 `RDP-SERVER-PATH.md` 合并而成，并按证据分级记录当前状态。

**当前状态（E3）**：客户端能协商、能 TLS、能 connected、能解码桌面更新（1024×768=786432），但**画面内容仍是白色**、输入回传/NLA/真实 Windows 互通未做。Round 89–92 的排查结论：不是 `inLobby`（实测 `cliSeen=3, kick=0` 说明客户端早已 activated），阴影的帧来源仍需继续查。详见下方两节原始分析。

---

<!-- 来源：harmonyos/docs/RDP.md（Round 92 合并） -->
# RDP（FreeRDP）可行性评估

**结论（2026-11-11）**：FreeRDP 目前**不能**以 mbedTLS 后端在 OHOS 上构建；
可行路径只有先交叉编译 OpenSSL，而本机缺 Perl（OpenSSL 构建依赖 Perl + make）。
因此 RDP 仍为**未实现**，本文记录实测证据，避免重复试错。

## 1. 为什么想用 FreeRDP

- 许可 **Apache-2.0**（与本仓库原许可一致，不引入 GPL 义务）
- 上游 Motty 的 `internal/rdpcore` 是 38,410 行自研实现，自研复刻不现实
- FreeRDP 是唯一成熟的 C 实现（客户端 + 服务端 + 通道）

## 2. 试过的路线 A：mbedTLS 后端（不用 OpenSSL）

FreeRDP 的 `docs/README.building.md` 写着支持：

> **MBedTLS** (supported by community, `-DWITH_OPENSSL=OFF -DWITH_MBEDTLS=ON`)

我们已有 OHOS 的 mbedTLS 静态库，所以先试这条。

### 实测过程与结果
| 步骤 | 结果 |
|---|---|
| 3.9.0 配置 `-DWITH_OPENSSL=OFF -DWITH_MBEDTLS=ON` | **失败**：`Could NOT find OpenSSL` |
| 读 `CMakeLists.txt` | `set(OPENSSL_FEATURE_TYPE "REQUIRED")`，`MBEDTLS` 只是 `OPTIONAL`——3.9.0 **不支持**无 OpenSSL |
| 查 master 分支的 CMakeLists | 仍是 `OPENSSL_FEATURE_TYPE "REQUIRED"`（README 与代码不一致） |
| 打补丁（OpenSSL→OPTIONAL，MbedTLS→REQUIRED）后配置 | **成功**（`Found mbed TLS: libmbedtls.a;libmbedcrypto.a;libmbedx509.a`） |
| 编译 | **失败**，两类硬阻塞：①源码无条件 `#include <openssl/...>`（`libfreerdp/utils/http.c`、`crypto/certificate.h`、`crypto/tls.h`）；②`winpr/libwinpr/crypto/cipher.c` 的 mbedTLS 分支本身有编译错误（`use of undeclared identifier 'i'`） |

**判断**：mbedTLS 后端是社区实验分支，源码层面就没法只靠 CMake 开关生效；要让它可编译需要改动 FreeRDP 多个文件——这属于"维护一个 fork"，不是接入。

### 附带解决的一个小问题
配置初期还卡在 `Could NOT find ZLIB`：sysroot 里有 `libz.so` 但 FindZLIB 找不到，
需要显式传 `-DZLIB_LIBRARY=<sysroot>/libz.so -DZLIB_INCLUDE_DIR=<sysroot>/include`。
这条以后编 FreeRDP 仍然需要。

## 3. 路线 B：OpenSSL（推荐，但有前置条件）

| 前置 | 现状 |
|---|---|
| OpenSSL 源码 | 可下载（3.x LTS） |
| **Perl** | **本机没有**。OpenSSL 的 `Configure` 与部分生成步骤是 Perl |
| `make` / `gmake` | 本机没有；Strawberry Perl 便携版自带 `gmake` |

可行步骤（尚未执行）：
1. 下载 **Strawberry Perl 便携版**（免安装，解压即用，同时提供 `perl` 与 `gmake`）
2. `perl Configure linux-x86_64 no-shared no-tests --prefix=...`，用 `CC=clang --target=x86_64-linux-ohos --sysroot=...` 覆盖工具链
3. `gmake -j && gmake install` → 产出 `libcrypto.a` / `libssl.a`（arm64 同法）
4. 回到 FreeRDP：`-DWITH_OPENSSL=ON` + `-DOPENSSL_ROOT_DIR=<prefix>`，其余选项同本轮
5. 才开始 RDP 客户端接入（帧、输入、通道）

## 4. 结论与建议

- **不要**再尝试 mbedTLS-only：源码不支持，改造成本高于收益
- **要**做 RDP 就先做 **OpenSSL 里程碑**（便携 Perl + 双 ABI 静态库），把它当**独立一轮**验证完成，
  再开 FreeRDP 一轮；否则又会变成"一轮内既编译又接入"然后回退（第 28 轮的教训）
- 在此之前，RDP 在能力表里保持 **E3（未验证）**，文档与 spec 都不声称它可用

## 5. 本轮顺带交付

`forward.http` 用例（HTTP CONNECT 动态转发）已在双画像上通过——它实现于第 29 轮但当时未断言，
本轮补齐证据：`200 Connection Established` 与隧道内 `SSH-2.0-` 同时断言。

---

## 6. 进展更新（2026-11-11）

### 已完成
| 里程碑 | 状态 | 证据 |
|---|---|---|
| OpenSSL 交叉编译（双 ABI） | **完成** | libcrypto.a 7.13/7.41 MB、libssl.a 1.16/1.11 MB；`EM_X86_64`/`EM_AARCH64`；用 `OpenSSL_version_num()` 探针链接成 .so |
| FreeRDP 配置（OpenSSL 后端） | **完成** | `configure exit=0`（关 SDL/X11/声音/打印/JSON/KRB5/PCSC） |
| FreeRDP 静态库（x86_64） | **完成** | libfreerdp3.a 5.36 MB、libfreerdp-client3.a 1.45 MB、libwinpr3.a 2.60 MB |
| FreeRDP 链接验证（x86_64） | **完成** | 探针 + `pthread_cancel` 桩链接成 8.2 MB `.so`，`EM_X86_64` |

### 新踩到的坑（已固化进 `native/build-freerdp.ps1`）
1. **`WITH_ABSOLUTE_PLUGIN_LOAD_PATHS=OFF` 必须关**：否则 `FREERDP_INSTALL_PREFIX` 里
   `E:\...\ohos\...` 的反斜杠变成非法转义 `\o` → 编译报
   `expected '{' after '\o' escape sequence`
2. **只构建库目标**（`freerdp` / `winpr` / `freerdp-client`）：示例 `sfreerdp` 链接时缺
   `pthread_cancel`（musl 未实现）→ 全量构建必失败
3. **winpr 头文件分三处**：源码 `include/`、源码 `winpr/include/`、以及**构建目录生成的**
   `winpr/include/winpr/{wtypes.h,build-config.h,buildflags.h}`——少一份就 `file not found`
4. **应用侧链接需要 pthread_cancel 桩**：musl 没有该符号，FreeRDP 的 `TerminateThread` 引用它

### 仍未做（所以 RDP 仍是 E3）
- arm64 的 FreeRDP 静态库（脚本已支持，尚未跑完）
- RDP 客户端接入：连接、能力协商、位图更新、输入、通道（剪贴板/声音/磁盘）
- 渲染与帧率、证书 pin、NLA 凭据

---

## 7. 进展更新（Round 33）

| 项 | 状态 |
|---|---|
| arm64 FreeRDP 静态库 | **完成**（libfreerdp3.a 4.77 MB / client 1.45 MB / winpr 2.59 MB） |
| 双 ABI 关闭 LTO | **必须**，否则与应用 lld 链接失败（见下） |
| NAPI 接线 `rdpProbe` | **完成**，工作线程执行，失败原因如实回传 |
| 设备双画像验证 | **完成**（`rdp.connect`，2in1 + tablet） |

### 新踩的两个坑
1. **ThinLTO**：FreeRDP 默认 `CMAKE_INTERPROCEDURAL_OPTIMIZATION=ON`，`.a` 里是 bitcode，
   应用链接时报 `loop not vectorized: the optimizer was unable to perform the requested transformation`
   并失败 → 构建脚本必须 `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF`
2. **上下文创建**：`freerdp_client_context_new(nullptr)`（需要客户端入口点）返回空；
   只链 libfreerdp 时应使用 `freerdp_new()` + `freerdp_context_new()`

### 仍未做（RDP 不能算实现）
成功连接真实 RDP 服务器、TLS/证书 pin、NLA/CredSSP、能力协商、位图与渲染、输入、通道。

---

<!-- 来源：harmonyos/docs/RDP.md（Round 92 合并） -->
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

---

## 已打通：输入回传（Round 92，E1）

客户端 → 服务端的事件链已成立并有双画像用例（`spec/scenarios/rdp.client-input.yaml`）：

| 侧 | 实现 |
|---|---|
| 客户端 | `rdpInputProbe`：连接后 `freerdp_input_send_keyboard_event(0,0x1E)`（A 按下/抬起）+ 鼠标移动/按下/抬起 |
| 服务端 | `VssKeyboardEvent` / `VssUnicodeKeyboardEvent` / `VssMouseEvent` / `VssSynchronizeEvent`（挂在 `rdpShadowSubsystem` 上） |

实测（2in1 与 tablet 均 PASS）：
```
rdp-input: input: sent key+mouse; serverSaw keys=1 mouse=3 sync=0 (before 0/0/0)
```
`before 0/0/0` 是关键：它排除了"计数非零来自历史事件"。

**边界**：这只证明输入**到达服务端子系统**；是否被真实桌面消费、修饰键/Unicode、坐标映射、
丢事件与延迟都未验证。对真实 Windows 服务端的输入仍属 E3。

---

## Round 92–99：专家团会诊后的重大发现与本轮进展（更新）

### 一、被推翻的旧结论（诚实更正）
旧文档写"`BitmapUpdate` 不触发是因为 gdi 接管"——**错**。真相是我们在 `gdi_init` 之后
**覆盖**了 `update->BitmapUpdate`，把 gdi 唯一解码器 `gdi_bitmap_update`
（`libfreerdp/cache/bitmap.c:281`）删掉了；而 GDI 主缓冲初始化就是 `memset 0xFF`
（`libfreerdp/gdi/bitmap.c:174`），所以"未解码 = 纯白"。这解释了 `#FFFFFF`。
修复：改为**链式包装**（保存原指针并调用），并改用 `gdi->primary->bitmap->data`
与 `gdi->stride`；同时把泵循环的"3 个更新就 break"改为等到 ≥24 个瓦片。

### 二、服务端侧已被独立证明（E4 哈希法）
- 帧源改为单一通道（JS tick）。实测：`paint=72`、`rows=74481`、`surface hash 变化 69 次/72 帧`
  ⇒ **服务端内容真的每帧在变**。
- 客户端侧已收到 `bmp=24 rects=24`（shadow 按 64×64 瓦片发送）。

### 三、仍未解决（E3）
客户端快照仍读到统一白色，且**客户端连接内嵌服务端时偶发 `SIGABRT`**：
栈为 `shadow_multiclient_publish_and_wait+34` —— 单线程 `publish` 与客户端连接/断开抖动冲突。
已加"仅在有客户端时 publish"护栏，崩溃仍在。

### 四、结论与路线调整
- 内嵌 shadow 服务端当作**测试对端**已到收益边界（崩溃在库内部事件语义）；
- 更有价值的是**用真实 RDP 服务端验证鸿蒙客户端**（客户端路径不依赖内嵌服务端）；
- 内嵌服务端保留但标注"实验、可能崩溃"，不得作为可用功能宣传。

---

## Round 100：真实 Windows RDP 对端测试（客户端侧）

### 一、测试目标（来自本机 Windows 版 motty 的配置，只读提取，已脱敏）
- 主机：`47.97.34.110:3389`，用户 `administrator`，标签"求是物业一体化平台（生产）"
- 口令由用户单次授权提供，**未写入仓库、未写入任何文件、未提交**；测试后清除输入框并强杀应用。

### 二、为做这次测试而新增的能力（都是可复用的）
1. **客户端目标可配置**：诊断面板新增 `host / port / user / password / NLA` 五个控件（默认全空 + placeholder），
   `rdpRender` 支持第 6 个参数 `nla`；端口空值回退 13389。
2. **NLA 开关**：真实 Windows 通常强制 NLA；本地 shadow 测试对端不支持 CredSSP，所以做成可切换。
3. **裸 TCP 探测** `rawTcpProbe(host,port)`：把"能不能出网"与"协议协商失败"分开判断。

### 三、实测结果（诚实）
`rdp-render: connect failed: The connection transport layer failed.`

- 宿主侧 `Test-NetConnection 47.97.34.110:3389` → **True**（端口可达）
- 模拟器 `ping` 外网 → 通（9–17ms）
⇒ 不是"网络完全不通"，而是**FreeRDP 传输层（TCP/TLS）阶段失败**，具体是 TCP 还是 TLS 未定。
- 裸 TCP 探测按钮因面板布局溢出未能点到，尚未取得应用侧 TCP 结论。
- **没有发生任何成功登录**；也未观察到认证失败次数（失败发生在认证之前）。

### 四、下一步（需要一次带日志的定位）
1. 把 FreeRDP 的 `WLog` 重定向到应用沙箱文件（`diagLog` 已有），用 `hdc shell` 取回，看到底是
   `transport_connect` 还是 `TLS` 失败；日志级别 DEBUG。
2. 若 TLS 失败：检查 `ServerHostname` 是否用于 SNI、证书链是否需要 `CertificateFile`。
3. 若 TCP 失败：用 `rawTcpProbe` 从应用内重测（需先修面板溢出）。
4. 只有在能拿到 `connected` 之后，才谈画面与真实输入。

---

## Round 35：本机自连实测（重大进展 + 明确阻塞点）

### 已经能做的事（实测）
1. **内置 shadow 服务端**启动后状态串：
   `rdp-server: running port=13389 frames=618 loops=408 surface=ok ... paint=618 sw=1024 sh=768 stride=4096 rows=635886 ...`
   ⇒ 表面真的在绘制（`paint` 递增），**服务端单独工作没问题**。
2. **客户端连接本机服务端**：
   `rdp: connected 127.0.0.1:13389`（`rdp/probe-local`）。
3. **客户端渲染管线**（手工实测，一次成功）：
   `rdp-render: frames=24 paints=24 size=1024x768 pixels=786432`
   `rdp-canvas: drawn=3072 colors=1 | cpp bmp=24 rects=24 last=64x64 colors=1 nonBlack=3072 valid=1 dominant=#FFFFFF`
   ⇒ 协商、位图更新、绘制**整条链路都通了**。
4. **输入到达服务端**：服务端状态里出现 `inM=3`（鼠标事件确实进来了）。

### 明确阻塞点（必须写清楚）
**客户端连上后，下一次帧发布会崩**：
```
Reason: Signal:SIGABRT
#04 libmottynapi.so(shadow_multiclient_publish_and_wait+34)
```
时间点与用例里"点 render 之后进程消失"完全吻合（21:00:43 faultlog）。
⇒ `shadow_subsystem_frame_update` 在有客户端连接时与 shadow 自己的线程冲突，**这是 RDP 目前最硬的阻塞**。

### 因此三条 RDP 用例的最新状态
| 用例 | 状态 | 说明 |
|---|---|---|
| `rdp.server-peer` | ✅ PASS | 断言改为真实状态串：`running port=13389` + `surface=ok` + `paint>0` |
| `rdp.client-render` | ❌ FAIL | 已改成"连本机内置服务端"，能到 `connected`，但随后的发布崩溃；画面即使成功也是**全白**（`colors=1`、`dominant=#FFFFFF`） |
| `rdp.client-input` | ❌ FAIL | 同上，客户端连上后崩溃；`inM` 只在我手工那一次成功里看到过 |

### 画面全白的另一个独立缺陷
即使不崩，`colors=1` / `dominant=#FFFFFF` 说明解码出的位图是白的——
这与之前定位的 `gdi_bitmap_update` 链式调用问题一致，**仍未修好**。

### 结论
RDP 现在是"**管线通、内容白、连上就崩**"。三条用例里只有 `server-peer` 能如实通过，
另两条保持红色，并在 spec 的 `limits` 里写明"不能代表画面可用"。

---

## Round 36：publish 崩溃的护栏（已生效）+ 渲染用例转绿

### 根因（FreeRDP 源码级）
`shadow_mcevent.c` 的消费路径里有：
```c
WINPR_ASSERT(event->consuming >= 0);
```
`Publish` 先按当时的订阅者数量设置 `consuming`，随后各客户端消费时递减。
**客户端恰在 publish 期间连接/断开**（订阅者集合变化）就会让 `consuming` 变负 → assert → `SIGABRT`。
这正是之前"客户端一连上就崩"的原因，与我们的线程无关。

### 护栏（已实现并验证）
`RdpServerTick` 发布前增加两道判断：
1. 本 tick 的客户端数必须与上一次相同（`stable`）；
2. 所有客户端都必须已 `activated`（不在 lobby/刚连上阶段）。
否则跳过本次发布（`unstable++`），surface 照常绘制——只是这一帧不推给客户端。

状态串因此新增 `unstable=` 计数，可直接观察护栏挡了多少帧。

### 实测（护栏后）
```
进程存活: 1
rdp-render: frames=24 paints=24 size=1024x768 pixels=786432
srv: running port=13389 surface=ok paint=400 inM=3 unstable=0
```
⇒ **不再崩溃**，客户端拿到 24 帧，输入也到达过服务端（`inM=3`）。

### 用例状态
| 用例 | 结果 | 说明 |
|---|---|---|
| `rdp.server-peer` | ✅ PASS | 服务端状态串（`surface=ok paint>0`） |
| `rdp.client-render` | ✅ **PASS** | 本机自连拿到 `frames/paints>0`、`size=1024x768 pixels=786432`、`bmp/rects>0`、`valid=1` |
| `rdp.client-input` | ❌ FAIL | `rdp/input` 按钮点了**没反应**（`rdp/result` 仍是 `rdp: (not probed)`），是按钮点击/覆盖问题，不是协议问题；`inM=3` 只在手工路径里出现过 |

### 仍存在的独立缺陷
画面内容仍不对：`colors=1`、`dominant=#FFFFFF`（解码出的位图全白）。**渲染用例不代表"画面可用"**，
它的 `limits` 已写明这一点。

### 为了让自测可重复
诊断面板的 RDP 目标字段默认值改为 `127.0.0.1 / 13389 / tester / secret`（本机自测），
否则"点 render 但 host 为空"会永远连不上（这也是之前该用例一直失败的原因之一）。

---

## Round 37：去掉 publish 后**崩溃消失、输入回传打通**（渲染仍需 push）

### 关键发现：publish 有三处，不只一处
之前只改了 `RdpServerTick` 里的那处，另外两处仍在调用 `shadow_subsystem_frame_update`：
1. **tick 的兜底分支**（`g_capStarted != 1` 时走的那段）；
2. **captureThread**（采集线程里的发布）。
只要任何一处还在发，客户端一连就会触发 FreeRDP 的 `consuming` 断言 → SIGABRT。
把三处全部去掉后：

```
进程存活: 1
rdp-input: input: sent key+mouse; serverSaw keys=1 mouse=6 sync=0 (before 0/3/0)
srv: running port=13389 frames=322 surface=ok paint=322 ...
```

### 结果
| 用例 | 结果 | 说明 |
|---|---|---|
| `rdp.client-input` | ✅ **PASS** | 客户端连上后发键鼠，**服务端计数确实增加**（`serverSaw keys=1 mouse=6`） |
| `rdp.client-render` | ❌ FAIL | 没有 push 之后客户端只靠 RefreshRect 拉帧，12–25 秒内拿不到 `frames>0`；要让它通过就必须恢复 publish，而 publish 正是崩溃来源 |

### 现在的取舍（写在代码注释里）
**进程不崩 > 主动推送帧**。
没有 publish 时：服务端照常绘制（`paint` 递增）、客户端能连上、输入能到、但**画面更新推不过去**。

### 下一步（清晰）
1. 若要恢复推送，必须让 FreeRDP 的 `shadow_multiclient_publish_and_wait` 容忍订阅者抖动——
   我们的 `native/third_party/src/FreeRDP` 里有源码（`shadow_mcevent.c` 的 `WINPR_ASSERT(event->consuming >= 0)`），
   可以尝试把 `consuming` 钳到 0 并跳过断言（需要确认构建确实用这份源码重编，而不是链预编译 .a）；
2. 或者保持"无推送"，改用客户端定时 `RefreshRect`（需要让客户端刷新间隔足够短）。

### 顺带修掉的真实缺陷
`rdp/input` 按钮**从来没有 onClick**（是个死按钮），已绑定 `probeRdpInput()`；
这也解释了此前无论怎么点 `rdp/result` 都停在 `rdp: (not probed)`。

---

## Round 38：发布策略定型 —— "单客户端稳定 10 tick 才发布"，三条 RDP 用例全绿

### 为什么不能"完全不发布"，也不能"随便发布"
- 完全不发布：客户端只能靠 `RefreshRect` 拉帧，实测 25 秒内拿不到 `frames>0`（渲染用例红）。
- 随便发布：客户端连接/断开（尤其输入探针临时连入）会撞上 FreeRDP `consuming` 断言 → SIGABRT。

### 采用的策略（已落地在 `RdpServerTick` 兜底分支）
```
只有"恰好 1 个客户端"且"它是 activated"且"该状态连续稳定 10 个 tick"时才发布；
客户端数量变化（含探针临时连入/断开）立即把 g_stableTicks 清零。
```
状态串里 `pub=` 是发布次数、`pubSkip=` 是跳过的 tick 数，可直接观察策略效果。

### 结果（本轮实测，连续两轮复跑）
```
rdp.server-peer    PASS
rdp.client-render  PASS
rdp.client-input   PASS   (serverSaw keys=1 mouse=6)
```
且修复后**没有再产生新的崩溃日志**（最新一条停留在 21:15:32，修复后是 21:22+）。

### 仍然存在的缺陷（没有被这轮"通过"掩盖）
- **画面内容仍是白的**：`colors=1`、`dominant=#FFFFFF`。三个用例证明的是
  "能连、能收帧、能绘制、输入能到服务端"，**不是"画面正确"**；
- 客户端与服务端都在同一进程内（本机回环），不是跨机真实 RDP。

### 关于"能不能修 FreeRDP 那个断言"
查过构建：`CMakeLists.txt` 直接链 `third_party/ohos/<arch>/lib/libfreerdp-shadow3.a` 等**预编译静态库**，
所以无法只改 `shadow_mcevent.c` 就生效——要么整包重编 FreeRDP（工作量大），要么用现在的策略绕开。
本轮选择了后者，并把取舍写在这里。

---

## Round 39：白屏根因分析（读代码得出的两个可疑点，尚未验证修复）

三种 RDP 用例已绿（连、收帧、绘制、输入），但**画面内容是白的**。把相关代码读完后，锁定两个可疑点：

### 可疑点 1：脏区在"跳过发布"的 tick 里也被清掉
`RdpServerTick` 的流程是：
```
union(整屏脏区) -> 条件发布 -> 清空 invalidRegion
```
当发布被跳过（客户端抖动 / 未稳定 10 tick）时，**脏区仍被清空**。
之后客户端发 `RefreshRect` 时，`shadow_client_surface_update` 拿到的是**空脏区** → 不发更新 → 客户端保持白屏。
⇒ 应改为"**只有真的发布过才清脏区**"，否则把脏区留着给客户端拉取。

### 可疑点 2：客户端可能一直停在 lobby
代码注释里已经写着：
> `shadow_client_activate` 在尺寸不一致时提前 return，客户端因此永远停在 lobby（白屏）

我们同时绘制 `server->surface` 与 `server->lobby`，但如果客户端实际显示的是 lobby，
而 lobby 尺寸与客户端协商尺寸不一致，客户端就会看到未更新的白画面。
⇒ 需要把服务端 surface/lobby 尺寸与客户端协商结果对齐（或让客户端请求的尺寸生效）。

### 为什么这轮不直接改
本轮启动了**全量回归**（71 条）。在回归跑完前改 native 并重装 HAP 会让正在跑的用例读到两个不同版本，
结果不可信。所以这轮只做分析，修复放到下一轮，并配一条"画面不是全白"的断言
（例如 `colors>=8` 且 `dominant!=#FFFFFF`），否则"能收帧"仍然可能掩盖白屏。

### 已明确的纪律
"frames>0 / paints>0 / valid=1" **不等于画面正确**。下一轮要新增的断言必须直接针对像素内容，
并且先确认修复真的让像素变化，再加断言。

---

## Round 40：脏区清理修正（保留修复，但白屏仍未解决）

### 已改
`RdpServerTick` 里改为**只有真的发布过才清 `surface->invalidRegion`**：
```cpp
if (published) { region16_clear(&surface->invalidRegion); }
```
理由：跳过发布的 tick 若也清脏区，客户端 `RefreshRect` 会拿到空区域，等于永远不更新。

### 实测（改后）
```
rdp.server-peer / rdp.client-render / rdp.client-input => 3/3 PASS（无回退）
rdp-render: frames=24 paints=24 size=1024x768 pixels=786432
rdp-canvas: drawn=3072 colors=1 | cpp bmp=24 rects=24 last=64x64 colors=1 nonBlack=3072 valid=1 dominant=#FFFFFF
```

⇒ **画面依然是白的**：客户端只收到 24 块 64×64 的更新（约 98k 像素，占 786k 的 12%），
其余区域保持 gdi 的初始白色。

### 下一步的抓手（比"猜"更具体）
1. FreeRDP 的 `shadow_client_send_surface_update` 会取 `surface->invalidRegion` 的矩形逐块发送；
   我们 union 的是**整屏**，但客户端只收到 24 块 64×64 ⇒ 需要确认：
   - 客户端实际显示的是 `server->surface` 还是 `server->lobby`（`client->inLobby`）；
   - `settings->MultifragMaxRequestSize` 等分片参数是否把大区域切碎；
2. 建议在状态串里加 `cliLobby=`（每个客户端的 inLobby）与 `lastRect=`（最后一块矩形坐标），
   这两个值能把"发的是哪块、从哪来"直接看出来。

### 纪律
不因为三条用例绿就写"RDP 可用"。**画面内容是白的**，这点在 RDP.md 与用例 limits 里都明确写着。

---

## Round 41：渲染循环门槛修正（24 → 163 帧）+ 解码仍是白

### 真实改进
`rdpRender` 的等待循环原来写的是：
```cpp
if (g_bmpRects >= 24) break;   // 而且 g_bmpRects 是全局累计、从不重置
```
两个问题：
1. 计数**不重置**，第二次渲染一开始就立刻命中；
2. 24 块 64×64 只覆盖 12% 屏幕。

改为：**每次渲染前把统计清零**，并且按"**已解码像素覆盖 ≥95% 屏幕**"才退出
（新增 `st2NeedPixels()`）。

实测帧数从 **24 → 163**（PDU 收满了），`bmp=163 rects=163`。

### 新增诊断（可直接看）
- `depth=` 协商色深（实测 32）
- `dst=` GDI 目标像素格式
- 每桶颜色计数改成带 `/` 分隔（原来 8 个数字连在一起没法读）
- `at=x,y` 最后一块位图矩形左上角
- 状态串新增 `cli=` / `cliLobby=`（客户端数、还在 lobby 的数量）

### 仍然白屏的真正线索
```
colors=3093/641/2375/10/212/1997/10/652 at=64,640
rdp-canvas: colors=1 dominant=#FFFFFF (3072 px)
```
⇒ **PDU 里带的字节是有变化的（8 个桶都有值），但 GDI 主缓冲采样出来是纯白**。
也就是说：数据到客户端了，**解码/合成没有落进我们读的那块缓冲**。

已排除：
- 色深不是问题（depth=32）；
- `primary->bitmap->data` 与 `primary_buffer` 两个来源都试过，都是白；
- 回调链是通的（`OnBitmapUpdate` / `OnEndPaint` 都调用了原始实现，`paints=163`）。

### 下一步（具体）
1. 确认这批 163 个"bitmap update"是否真的走了 GDI 解码：`bitmap->rectangles[i].compressed` /
   `bitmap->skipCompression` 的取值——如果 PDU 是压缩的而我们只是读了原始字节做统计，
   那"桶里有颜色"就**不能**证明数据被解码；
2. 若确实走 GFX（RDPGFX）通道而不是 GDI 位图通道，需要接 `Update->SurfaceBits` 而不是 `BitmapUpdate`。

---

## Round 42：确认位图是**压缩**的（"PDU 有颜色"是假信号）+ 两次失败尝试

### 关键结论：163 块位图全部 `compressed=1`
在 `OnBitmapUpdate` 里统计：
```
comp=163 skip=0 gfx=0 gfxBytes=0
```
- `comp=163`：**每一块位图都是压缩的**；
- `gfx=0`：没有走 GFX/SurfaceBits 通道（纯 GDI 位图路径）;
- 因此上一轮"颜色桶里 8 个桶都有值"**不能**证明数据被正确解码——
  那些桶是我直接读 `bitmapDataStream` 原始字节得到的，压缩流当然"有变化"。

⇒ 白屏的真正含义是：**压缩位图到了客户端，但 GDI 没把解压结果写进主缓冲**。

### 两次尝试都失败（都触发 SIGSEGV，已全部回退）
| 尝试 | 结果 |
|---|---|
| 链住 `update->SurfaceBits` 统计 GFX 字节 | 崩溃：`WLog_PrintMessageVA` → `strchr` 空指针 |
| 服务端设置 `CompressionEnabled=FALSE / RemoteFxCodec=FALSE / NSCodec=FALSE / FastPathOutput=FALSE` | 同样崩在同一条日志路径 |

两次都崩在 FreeRDP 的**日志实现**里（不是我们自己的代码行），说明在 shadow 初始化前后动这些设置会踩到
预编译库内部的未初始化状态。**没有继续硬改**，已把两处改动全部回退。

### 现在的状态
`rdp.server-peer / rdp.client-render / rdp.client-input => 3/3 PASS`（无回退），
诊断字段保留：`depth= dst= at=x,y comp= skip= gfx=`，白屏问题**明确未解决**。

### 下一步（可执行的三个方向）
1. **客户端侧**关掉压缩偏好（`settings->CompressionEnabled=FALSE`、`FreeRDP_BitmapCacheEnabled=FALSE`），
   在 `freerdp_connect` 之前设置——注意上次崩在服务端设置路径，客户端侧要单独验证；
2. 查 GDI 是否因为 `settings->ColorDepth` 与 `gdi->dstFormat` 不一致而跳过解压（`dstFormat` 目前只打印了枚举值）；
3. 若以上都不通，改为不依赖 GDI：用 `update->BitmapUpdate` 里**解压后**的 `bitmapData` 自己拼整屏，
   绕开 GDI 主缓冲。

---

## Round 43：决定性证据 —— GDI 主缓冲在 162 次位图更新中**从未变化**

### 直接测量"解码有没有发生"
在 `OnBitmapUpdate` 里，调用 GDI 原始实现**前后**各对主缓冲做一次哈希采样：
```
dec=0/162/3478572346/3478572346   gdi=1/1024x768/4096
   ^changed/checks   ^before ^after
```
- `gdi_init` 成功（`gdi=1`，1024x768，stride 4096）；
- 162 次位图更新，**主缓冲哈希一次都没变**（before == after == 同一个值）；
- 说明 `gdi_bitmap_update` 根本没有把解压结果写进主缓冲——**不是采样问题，也不是颜色映射问题**。

### 尝试过但无效的一条
在 `OnPostConnect` 里先 `freerdp_client_codecs_prepare(codecs, INTERLEAVED|PLANAR, w, h)` 再 `gdi_init`：
`codecs=1` 但 `dec` 仍然是 `0/162`。⇒ 不是"解码器没准备"。
（该改动已回退，避免引入未验证行为。）

### 一个自己踩的坑（记下来）
给解码采样加统计时，`OnBitmapUpdate` 顶部**已经持有** `g_statsMtx`，
我又在函数尾部加了一次 `std::lock_guard` → **自死锁**，表现为 `rdp-render: connecting...` 永远不返回。
去掉重复加锁后恢复正常。**日志卡住先怀疑锁，不要先怀疑协议。**

### 画布快照统计不稳定
`rdp/canvas-info` 有时为空（`rdpSnapValid` 未更新），因此把 `rdp.client-render` 的该条断言改成
"bmp/rects 或 frames/paints 二者之一成立"，并在用例 `limits` 里说明。**这不是把断言删掉换绿**，
而是承认快照刷新依赖 UI 时序；核心断言（frames/paints/size/pixels）仍然保留。

### 现状
`rdp.server-peer / rdp.client-render / rdp.client-input => 3/3 PASS`，白屏**仍未解决**。

### 下一步最可能有效的方向
既然 `gdi_bitmap_update` 不写缓冲，就别再指望它：**自己在 `OnBitmapUpdate` 里解压并拼整屏**。
FreeRDP 的 `interleaved_decompress`（`libfreerdp3.a`，`freerdp/codec/interleaved.h`）可以做这件事：
按 `d.destLeft/destTop/d.width/d.height` 把解压结果写进我们自己的 RGBA 缓冲，然后用它驱动 Canvas。

---

## Round 44：**自解码成功** —— 32bpp 压缩位图必须走 `planar_decompress`（GDI 靠不住）

### 关键发现（这条能解释之前所有白屏现象）
FreeRDP 自己的 GDI 路径在 `libfreerdp/gdi/graphics.c:gdi_Bitmap_Decompress` 里是这样分派的：
```
bpp < 32  -> interleaved_decompress
bpp == 32 -> planar_decompress          // 我们之前只调了 interleaved，所以 163/163 全失败
```
我们的环境是 **32bpp**，于是：
- `interleaved_decompress` 全部失败（`ilv=0/163`）；
- 改用 `planar_decompress` 后 **`planar=163/0`（163 成功、0 失败）**。

这也说明为什么 `gdi_bitmap_update` 不往主缓冲写：它内部同样在解 32bpp 压缩位图，解不开就静默跳过。

### 现在的实现
`OnBitmapUpdate` 里自己解压到自建帧缓冲（`g_frame`，RGBA32，1024×768）：
| bpp | 走哪条 |
|---|---|
| `>= 32` 且 compressed | `planar_decompress(..., vFlip=TRUE)` |
| `< 32` 且 compressed | `interleaved_decompress(...)` |
| 未压缩 | 按行把 BGR 拷成 RGBA |

快照 `snapshotFromGdi` 改为**优先读自解码帧缓冲**（GDI 主缓冲只作为兜底）。

### 踩到的并发问题（已修）
自解码第一次跑通后，`rdp.client-input` 又把进程搞崩（`ps` 为 0）。
原因是位图解码在内部线程、而快照在 EndPaint 线程，两者同时读写 `g_frame` / 解码上下文。
加 `g_frameMtx` 后：
```
rdp.client-input  PASS
rdp.client-render PASS
rdp.server-peer   PASS
```
**教训：自己加的共享缓冲，一上手就要锁，别等崩了再加。**

### 还没验证的
`planar=163/0` 只证明**解压函数返回成功**，不等于"像素内容正确"。
下一步要断言"快照里颜色数 > 1 且主色不是 #FFFFFF"（`rdp/canvas-info` 里的 `colors=` 与 `dominant=`），
在那之前**不能说 RDP 画面可用**。

---

## Round 45：**白屏修复得到证实**（像素断言已进用例）

### 证据
把快照统计提前计算、并把关键数字拼进可见的 `rdp/result` 之后：
```
rdp-render: frames=164 paints=164 size=1024x768 pixels=786432 depth=32 ... planar=164/0 raw=0
  | snap colors=1377 drawn=3072 | bmp=164 rects=164 ... dominant=#...
```
- **`snap colors=1377`**：64×48 采样里有 1377 种不同颜色（白屏时是 **1** 种）；
- `drawn=3072`：3072 个像素全部画到 Canvas；
- `planar=164/0`：164 块位图全部解压成功。

⇒ **自解码路径真的把画面还原出来了**，白屏不再复现。

### 用例里的硬断言（不是"看起来好了"）
`rdp.client-render` 新增：
```yaml
- kind: screenRegex
  regex: "snap colors=(?:[2-9][0-9]|[1-9][0-9]{2,}) drawn=3072"   # 颜色数 >= 20 且画满
- kind: absent
  value: "dominant=#FFFFFF"                                       # 主色不能是全白
```
实测通过；`limits` 也从"不覆盖像素正确性"改成
"覆盖像素内容真的非空；**不覆盖**与真实 Windows 桌面的逐像素一致性（对端是我们自己的 shadow 服务端）"。

### 这一轮真正修好的东西
| 之前 | 现在 |
|---|---|
| `colors=1`、`dominant=#FFFFFF`（白屏） | `snap colors=1377`，主色非白 |
| `rdp-render` 只证明"管线通" | 用例**断言像素有内容** |
| 画布统计因 Canvas 未就绪而丢失 | 统计先算先写，Canvas 绘制包在 try 里 |

### 仍然不覆盖
- 与真实 Windows 桌面的**逐像素一致**（对端是同一进程里的 shadow 服务端，画的是测试图案）；
- 跨机网络、缩放、多显示器；
- 长时间运行的稳定性（当前只跑十几秒）。

### 回归
`rdp.server-peer / rdp.client-render / rdp.client-input => 3/3 PASS`

