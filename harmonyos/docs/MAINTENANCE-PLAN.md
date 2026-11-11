# 剩余开发 / 清理 / 文档压缩 —— 可执行方案

> 编写依据：本文件所有数字与行号均来自 2026-11-11 对工作区的**实测**（详见 §0.1）。
> 证据分级不变：**E1** = 模拟器双画像实测 ｜ **E2** = 编译/静态 ｜ **E3** = 未验证。
> **本文件没有执行任何设备测试。** §1 的根因结论是源码级静态判定（E2），
> 修复是否生效必须由新的 E1 用例证明。

---

## 0. 实测底账

### 0.1 复跑过的门禁（今天执行，输出为准）

| 命令 | 结果 |
|---|---|
| `python spec/lint.py` | `全部通过`，exit 0，56 条用例 |
| `python tools/gen-sbom.py --check` | `校验通过：16 个组件、36 份产物`，exit 0 |

### 0.2 体积构成（总计 2,693.4 MB；git 跟踪仅 140 文件 / 1.20 MB）

| 路径 | 大小 | 是否入库 |
|---|---|---|
| `spec/runs/` | 1,352.1 MB | 否（`.gitignore`） |
| `.bin/tools/`（portable perl + zip） | 671.7 MB | 否 |
| `native/third_party/src/` | 319.2 MB | 否 |
| `ohos/app/entry/build/` | 112.3 MB | 否 |
| `native/build/` | 102.4 MB | 否 |
| `.bin/` 其余杂物 | 60.6 MB | 否 |
| `native/third_party/ohos/`（双 ABI `.a`） | 54.9 MB | 否 |
| `ohos/app/entry/.cxx/` | 18.0 MB | 否 |

**关键事实：被忽略的部分占 99.96%，git 工作树干净（`git status` 无输出）。
所以清理是纯文件系统操作，不需要任何 `git rm`，也不会产生提交。**

---

## 1. 剩余开发方案（按性价比排序）

### 1.1 【最高性价比】RDP 画面：根因已定位，且**不需要打补丁重编 FreeRDP**

#### 1.1.1 先纠正一个错误前提

`docs/history/INDEX.md` Round 89 与 `docs/history/FINAL-STATUS.md` §4 写着：

> `rdpShadowClient` 是不透明结构，`shadow.h` 只有前置声明，公共 API 改不了 `inLobby`，必须改源码重编。

**这条不成立。** Round 89 检查的是 FreeRDP **源码树内部**的 `server/shadow/shadow.h`
（1,194 字节，只有 `#include`），而应用实际 `#include` 的是**安装后的公共头**
`include/freerdp/server/shadow.h`（13,431 字节），其中：

| 公共头位置 | 内容 |
|---|---|
| `include/freerdp/server/shadow.h:104` | `struct rdp_shadow_client {` —— **完整定义，无 `#ifdef` 保护** |
| `:109` | `BOOL activated;` |
| `:111` | `BOOL inLobby;` |
| `:112-113` | `BOOL mayView; BOOL mayInteract;` |
| `:141-177` | `struct rdp_shadow_server { ... wArrayList* clients; ... }` —— 客户端链表也可见 |

反证（自洽性）：`rdp_server.cpp:556` 已经在解引用 `g_server->lobby`、`:569` 已解引用
`g_server->surface`，这些字段与 `inLobby` 同在 `rdp_shadow_server` / 相邻结构中。
**若该头真不透明，现有代码根本编译不过。**

#### 1.1.2 真正根因：桌面尺寸不匹配导致 `activate` 提前返回

证据链（FreeRDP 3.9.0，`native/third_party/src/FreeRDP`）：

1. `server/shadow/shadow_screen.c:46-80` —— `server->surface` 与 `server->lobby` 的尺寸
   取自 `subsystem->monitors[selectedMonitor]`；
   本项目 `vss_enum_monitors` 声明 **640×480**（`rdp_server.cpp:41-42, 203-213`）。
2. 客户端从未设置 `FreeRDP_DesktopWidth/Height`（`rdp_napi.cpp:322-334` 只设了 host/port/凭据），
   于是用 FreeRDP 默认 **1024×768**。
3. `server/shadow/shadow_client.c:392-394` —— `shadow_client_recalc_desktop_size()`
   比较客户端 `DesktopWidth/Height` 与服务端 surface 尺寸，不等则返回 `TRUE`。
4. `shadow_client.c:685-686` —— `shadow_client_activate()`：

```c
if (shadow_client_recalc_desktop_size(client))
    return shadow_send_desktop_resize(client);   /* ← 提前返回 */
...
client->activated = TRUE;                        /* :689 永远到不了 */
client->inLobby  = client->mayView ? FALSE : TRUE; /* :690 永远到不了 */
```

5. `shadow_client.c:2314` —— 出帧闸门是 `if (client->activated && !client->suppressOutput)`。
   因 `activated` 恒为 `FALSE`，走 `:2077` 的 `shadow_client_no_surface_update()`，
   而 `:1866`/`:2077` 都写着 `surface = client->inLobby ? server->lobby : server->surface;`
   —— **推给客户端的永远是 lobby。**

这解释了此前所有实测现象：

| 旧观测 | 本根因下的解释 |
|---|---|
| `dominant=#FFFFFF`（Round 76） | lobby 640×480 贴进客户端 1024×768 缓冲，其余是白底，白色占多数 |
| 客户端 `size=1024x768`（`rdp.client-render` 断言） | 客户端 gdi 尺寸来自它自己的 settings，从未被 resize 成功改写 |
| `mayView=TRUE` 已设却无效（Round 76/75） | `mayView` 只在 `:690` 参与判定，而 `:690` 没执行 |
| 画 lobby 表面 `lob=24` 仍无变化（Round 77） | 客户端本就在收 lobby，改 lobby 内容不改变"停在 lobby"这一事实 |

> `rdp.client-render.yaml:63` 的 `deviations` 已写下 "1024x768 是 shadow 默认值，不是我们 capture 的 640x480"
> —— 当时把它当成无害的注记，实际它就是卡点的成因。

#### 1.1.3 改造点（文件 / 函数级，按推荐顺序）

**改动 A（首选，单点最小，改 2 个常量）** —— 让服务端监视器等于客户端默认尺寸

- 文件：`ohos/app/entry/src/main/cpp/rdp_server.cpp`
- 位置：`namespace {` 内 `kVssWidth` / `kVssHeight`（`:41-42`）
- 动作：`640×480` → `1024×768`（二者必须同时改，且 `kVssWidth*kVssHeight` 决定 `vss_enum_monitors`）。
- 原理：`recalc` 返回 `FALSE` → `activate` 走完全程 → `inLobby=FALSE` → 推 `server->surface`
  （而 `server->surface` 正是 `RdpServerTick` 每帧画的渐变图案）。
- 注意：`shadow_surface_resize` 只在尺寸变化时重分配（`shadow_surface.c:73-104`），
  改常量后**必须重新 `shadow_server_init`**（即重启服务端），否则旧 surface 尺寸不会自动跟随。

**改动 B（强化，可选）** —— 客户端显式对齐尺寸

- 文件：`ohos/app/entry/src/main/cpp/rdp_napi.cpp`
- 函数：`renderWorker()`（`:311`），在 `freerdp_settings_set_string(...ServerHostname...)` 之后追加
  `freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, 1024)` /
  `...FreeRDP_DesktopHeight, 768)`。
- 价值：把"尺寸契约"写在客户端侧，服务端将来改分辨率时不会又静默掉回 lobby。

**改动 C（兜底断言，推荐同时做）** —— 在 tick 里强制脱 lobby

- 文件：`ohos/app/entry/src/main/cpp/rdp_server.cpp`
- 函数：`RdpServerTick()`（`:550`），在 `g_running` 判定之后加一段：

```cpp
/* 兜底：公开头 include/freerdp/server/shadow.h:104-139 含完整结构，
   clients 链表在 :146。把仍在 lobby 的客户端推进桌面。
   注：server->clients 是 ArrayList_New(TRUE) 建的同步链表（shadow_server.c:928），
   单次 Count/GetItem 各自持有内部锁；两次调用之间客户端可能断开，
   故逐项判 NULL（上游 shadow_server.c:911 同样是这个用法）。 */
wArrayList *clients = g_server->clients;
if (clients != nullptr) {
    const size_t n = ArrayList_Count(clients);
    for (size_t i = 0; i < n; i++) {
        auto *c = static_cast<rdpShadowClient *>(ArrayList_GetItem(clients, i));
        if (c == nullptr)
            continue;
        if (c->inLobby) {
            c->inLobby   = FALSE;
            c->activated = TRUE;   /* :2314 的闸门也要求 activated */
        }
    }
}
```

- API 签名已核对：`ArrayList_Count(wArrayList*) -> size_t`、`ArrayList_GetItem(wArrayList*, size_t) -> void*`
  （`winpr/include/winpr/collections.h:220,229`）。
- 需要 `#include <winpr/collections.h>`（公共头 `shadow.h:46` 已包含）。
- 价值：即使将来尺寸又错配，画面也不会退回 lobby——把"功能正确"从"参数恰好匹配"解耦。
- **这是 Round 89 认为"做不到"的那一步，实际上只是十来行代码。**
- 诚实边界：改动 C 是**兜底**，不是正确修法。它从 UI 线程写客户端线程读的字段，
  严格说是数据竞争（对 `BOOL` 在本平台实践上安全，但不构成内存序保证）。
  **优先用改动 A**；C 只保证"再次错配时不会静默白屏"，并应配一条用例守住。

**改动 D（不要做）** —— 打补丁重编 FreeRDP。
`native/build-freerdp.ps1` 会引入 fork 维护成本，而上述 A/B/C 全部在应用侧完成。

#### 1.1.4 新验收用例（把 E3 变成 E1）

现状 `rdp.client-render.yaml:46` 只断言 `size=1024x768 pixels=786432`——**尺寸对不代表内容对**，
这正是它当初能"通过"却画面错误的漏洞。建议：

1. `rdp_napi.cpp` 增 `rdpSnapProbe(x, y)`：返回 `g_snap` 指定像素的 `#RRGGBB`
   （`g_snap` 已存在，`:134`；采样逻辑 `snapshotFromGdi` `:141`）。新函数与
   `RdpSnapStats`（`:530`）同形，注册进 `RegisterRdpFunctions`（`:542`）。
2. `paintSurface()`（`rdp_server.cpp:119`）改成分区定色，便于精确断言：
   左上 32×32 纯红 `#FF0000`、右上 32×32 纯绿 `#00FF00`、其余渐变。
   （当前实现在 `:140` 用棋盘 + 渐变，只能证明"非白"，不能证明"内容正确"。）
3. 新用例 `spec/scenarios/rdp.client-content.yaml`（`profile: [2in1, tablet]`），断言：
   - `size=1024x768`（与改动 A 一致）
   - `probe(16,16)=#FF0000` 且 `probe(1008,16)=#00FF00` —— **内容保真，不是"非白"**
   - `absent: "#FFFFFF"` 作为主导色
4. 同步 `spec/capabilities.json` 里 RDP 相关条目 `evidence` 与 `partialCoverage`，
   并删掉 `rdp.client-render.yaml:63` 那条"1024x768 是默认值"的 deviations（已不成立）。

> **可完成性：全部可在 x86_64 模拟器（`motty_pc` / `motty_tablet`）上完成，不需要 Windows、
> 不需要 arm64 真机。** 因为对端是我们自己的内嵌 shadow 服务端。

---

### 1.2 【高性价比】RDP 输入回传：回调已就绪，只是没接线

#### 1.2.1 现状（静态确认）

`FreeRDP` 把协议输入路由到子系统回调：

| 位置 | 内容 |
|---|---|
| `server/shadow/shadow_input.c:109-113` | 安装 `Synchronize/Keyboard/UnicodeKeyboard/Mouse/ExtendedMouse` 五个 handler |
| `shadow_input.c:31-104` | 各自 `IFCALLRESULT(TRUE, subsystem->XxxEvent, ...)` —— **回调为 NULL 时静默返回 TRUE** |
| `include/freerdp/server/shadow.h:233-243` | `SynchronizeEvent/KeyboardEvent/UnicodeKeyboardEvent/MouseEvent/ExtendedMouseEvent` + `Authenticate/ClientConnect/ClientDisconnect/ClientCapabilities` 全在公开结构里 |

而 `rdp_server.cpp:468` **只设了** `g_subsystem->common.Authenticate = vss_authenticate;`
→ 其余全为 `NULL` → 输入被静默丢弃（与"输入未打通"的观测一致）。

#### 1.2.2 改造点

- 文件：`ohos/app/entry/src/main/cpp/rdp_server.cpp`
- 位置 A：新增回调实现（`vss_authenticate` 附近，`:256-268` 之后）

```cpp
std::atomic<int> g_inKeyboard{0}, g_inMouse{0}, g_inSync{0};
std::atomic<int> g_lastKeyCode{0}, g_lastX{0}, g_lastY{0};

BOOL vss_keyboard(rdpShadowSubsystem *, rdpShadowClient *, UINT16 flags, UINT8 code) {
    g_inKeyboard.fetch_add(1); g_lastKeyCode.store(code); return TRUE;
}
BOOL vss_mouse(rdpShadowSubsystem *, rdpShadowClient *, UINT16 flags, UINT16 x, UINT16 y) {
    g_inMouse.fetch_add(1); g_lastX.store(x); g_lastY.store(y); return TRUE;
}
BOOL vss_unicode_keyboard(rdpShadowSubsystem *, rdpShadowClient *, UINT16, UINT16) { return TRUE; }
BOOL vss_extended_mouse(rdpShadowSubsystem *, rdpShadowClient *, UINT16, UINT16, UINT16) { return TRUE; }
BOOL vss_sync(rdpShadowSubsystem *, rdpShadowClient *, UINT32) { g_inSync.fetch_add(1); return TRUE; }
```

- 位置 B：`RdpServerStart()` 中 `:468` 那一行旁边补齐注册
  （字段名严格照 `shadow.h:233-238`：`SynchronizeEvent`/`KeyboardEvent`/`UnicodeKeyboardEvent`/
  `MouseEvent`/`ExtendedMouseEvent`）。
- 位置 C：`RdpServerStatus()`（`:601`）状态串追加 `in-kbd=%d in-mouse=%d last=%d@%d,%d`，
  沿用现有"用状态行做机器判定"的手法（`rdpServerStatus` 已被 3 条用例断言过）。

- 配套：`rdp_napi.cpp:349-354` 的 `renderWorker` 已发 3 个鼠标事件，
  改动后这些事件会落到服务端 —— **同一个进程内闭环，无需外部服务端**。

#### 1.2.3 新验收用例

`spec/scenarios/rdp.server-input.yaml`：起服务端 → 起客户端 → 断言状态行
`in-mouse=[1-9]`、`last=..@10,10`，并 `absent: "in-mouse=0"`。

> **可完成性：可在模拟器完成（E1）。** 但注意边界：这只证明
> **我们客户端 → 我们服务端** 的回传闭环；**不代表**能与真实 Windows 服务端互通。

---

### 1.3 【中等性价比】NLA / CredSSP / 真实 Windows 互通 —— 部分可做

| 子项 | 可行性 | 说明 |
|---|---|---|
| 客户端 NLA 配置与协商路径 | ✅ 可做（E2/E1） | `rdp_napi.cpp:292` 目前硬关 `FreeRDP_NlaSecurity=false`；可加参数化并断言"服务端不支持 NLA 时如实报错" |
| CredSSP 当服务端 | ⚠️ 不可在此完成 | FreeRDP shadow 走简单认证，无 NLA 服务端口；需真实 Windows 或自建 CredSSP 端点 |
| 真实 Windows 互通 | ❌ 不可在此完成 | 需可开远程桌面的 Windows 主机（`RDP-SERVER-PATH.md` §8 路线 A 已判为"未采纳"） |

建议：只做"客户端 NLA 可配置 + 失败语义如实"，并继续在文档里把真实互通标 **E3**。
**不要**为了凑一项能力去伪造互通证据。

---

### 1.4 【必须做，纯本地】arm64 真机脚本与指引的完善点

现状 `tools/verify-arm64.ps1`（87 行）可跑，但有 6 个会**在真机现场**咬人的问题：

| # | 问题 | 位置 | 修法 |
|---|---|---|---|
| 1 | 判据数字自相矛盾：脚本遍历**全部 56** 条 YAML，`ARM64-REAL-DEVICE.md:63-64` 却写 **41 条** | 脚本 `:54` vs 文档 §4 | 二者取一。建议脚本读 `spec/scenarios/*.yaml` 实际数量并把期望值写进矩阵，文档改为"当前 56 条（以 `lint.py` 输出为准）" |
| 2 | 解释器路径硬编码 `C:\Python315\python.exe` | 脚本 `:72`；`ARM64-REAL-DEVICE.md:104` 同样写死 | 改为 `$py = (Get-Command python).Source`，失败则 exit 2 并提示 |
| 3 | hdc 路径硬编码 DevEco 默认安装位 | 脚本 `:12` | 依次尝试 `$env:DEVECO_SDK_HOME`、默认路径、`Get-Command hdc`；都失败则 exit 2 |
| 4 | 失败即中断，不落证据 | 脚本 `:73-78` 只收 stdout | 真机现场最需要 `faultlog`。每条失败用例后追加 `hdc -t $Serial file recv /data/log/faultlog/...` 与 `hdc -t $Serial shell "hilog -x"` 到 `$out` |
| 5 | 无设备/系统信息入库 | 缺失 | 跑之前采集 `hdc -t $Serial shell param get const.product.model / const.product.software.version`，写进 `matrix-device.json` 头部（对应文档 §6 记录模板的"设备型号/系统版本"，现在靠人手填） |
| 6 | 覆盖已有矩阵 | 脚本 `:83` 直接 `Set-Content` | 改为读入已有矩阵并按 `spec` 名合并，避免一次局部重跑抹掉全量结果 |

指引（`docs/RELEASE.md`）需补：

- §2 前置条件补"**签名 Profile 必须含该设备 UDID**"的可验证判定：`hdc shell bm dump -n <bundle>` 失败时的读法；
- §4 判据把 41 改为实测值，并写明"矩阵文件里的 `expectTotal` 由脚本写入"；
- §5 风险清单补两条真机高概率项：**arm64 上 18 个 `.a` 的链接顺序**（`CMakeLists.txt` 现按 x86_64 调的序）与**首启系统引导对话框**（`docs/RUNBOOK.md` §8 已记录，模拟器与真机文案可能不同）；
- 新增 §8"跑完要交什么"：`matrix-device.json` + `faultlog` + §6 模板，三者缺一不算完成。

> **可完成性：脚本与指引的全部改动可在本机完成并自测（E2）。真机 56 项仍需硬件，
> 状态保持 E2，不得改成 E1。**

---

### 1.5 【上架材料缺口清单】—— 区分"能在仓库里做完"与"必须外部条件"

| 项 | 状态 | 能否在此完成 |
|---|---|---|
| SBOM（16 组件 / 36 产物，含 sha256，`--check` 通过） | ✅ 已完成 | — |
| 许可声明 `LICENSING.md`（GPLv3 组合分发） | ✅ 已完成 | — |
| 权限说明（仅 `ohos.permission.INTERNET`） | ✅ 已完成 | — |
| 隐私声明**正文**（`docs/RELEASE.md` §3） | ✅ 草案就绪 | 可直接用 |
| **AI 端点默认值合规**：现默认 `http://127.0.0.1:2297/v1/ai`（自测桩） | ❌ **硬阻塞** | ✅ **可做**：改默认为空 + 首次使用二次确认。这是唯一"纯代码即可消除"的上架阻塞，优先级最高 |
| release 证书 / Profile（.cer + .p7b） | ❌ 缺 | ❌ 需华为开发者账号与实名 |
| 隐私政策**可访问 URL** | ❌ 缺 | ❌ 需域名/托管（正文已有，缺托管） |
| 用户协议 | ❌ 缺 | ⚠️ 可起草（E2），法律审阅需外部 |
| 渗透测试报告 | ❌ 缺 | ❌ 需第三方；但可先产出**自测清单**（见下） |
| `docs/RELEASE.md` §5 数字错误 | ⚠️ 写 "13 组件 / 29 份产物" | ✅ **可做**：改为实测的 16/36 |
| 混淆/strip：`STORE-READINESS.md:53` 称 native 未 strip | ⚠️ 待核实 | ✅ **可做**：`build-profile.json5` 开 `strip` 并核对产物体积 |

**可自测的安全清单（替代"等渗透测试"的空转）**：hostkey 算法白名单缺失、
DNS 未防 rebinding、VNC 不校验证书（`COMPLETION-REPORT.md:43` 已列）——
这三条可先写成 `spec/scenarios/security.*.yaml` 的**负向断言**，把已知弱点变成可回归事实。

---

## 2. 工作目录清理清单

### 2.1 判定标准（先立规矩，再删东西）

| 类别 | 判据 | 处置 |
|---|---|---|
| **纯中间产物** | 可由仓库内脚本确定性重建 | 删 |
| **可重下载依赖** | 有 pin 的 URL/commit，重建需网络 | 删（但**必须**先把 pin 写进脚本，见 §2.4） |
| **机器判定证据** | 断言结论的原始产物（`result.json`） | **必须保留**，且应入库 |
| **视觉证据** | `final.png` | 保留**高价值子集**，其余删 |
| **E2 编译产物** | 双 ABI 静态库 `.a` | 保留（体积小、是 E2 的直接物证） |
| **运行依赖** | 脚本硬依赖的夹具/密钥/HAP | 保留（删了下一步就跑不动） |

### 2.2 可删（按"安全删除顺序"，先删最没争议的）

**第 1 批 —— 零风险，共约 62 MB**

```powershell
cd E:\motty-HarmonyOS\harmonyos
Remove-Item .bin\sshfixture.exe~ -Force                      # 7.38 MB，备份残留
Remove-Item .bin\cppcrash.log,.bin\crash-rdp.log,.bin\crash2.log,.bin\crash3.log,.bin\crash4.log -Force  # 2.33 MB
Remove-Item .bin\d.json,.bin\d2.json,.bin\dc.json,.bin\dd.json,.bin\de.json,.bin\df.json,`
           .bin\dl.json,.bin\dl2.json,.bin\dp.json,.bin\dr.json,.bin\dz.json,.bin\x.json -Force        # 0.94 MB
Remove-Item .bin\hapsx,.bin\hapsx2,.bin\hapsx3,.bin\hapsx4,.bin\hapsx5 -Recurse -Force                # 38.5 MB，打包实验解包
Remove-Item .bin\freerdp-arm64.log,.bin\freerdp-master-cmake.txt,.bin\k.log,.bin\sweep-tablet.log,`
           .bin\sshfixture-auth.*,.bin\sshfixture-resize.* -Force                                    # 逐条排查日志
```

> `hapsx*` 已核对：`hapsx2..5` 的 `lib.so` sha256 各不相同，**不是**同一文件的重复副本，
> 而是 5 次不同构建的解包结果。作为中间产物仍可全删。

**第 2 批 —— 构建中间物，约 233 MB**

```powershell
Remove-Item native\build -Recurse -Force                     # 102.4 MB，cmake 中间物
Remove-Item ohos\app\entry\.cxx -Recurse -Force              #  18.0 MB，native 中间物
Remove-Item ohos\app\.hvigor,ohos\app\oh_modules -Recurse -Force  # 1.0 MB
Remove-Item ohos\app\entry\build -Recurse -Force             # 112.3 MB —— 见下方保留例外
```

**`ohos/app/entry/build` 的例外**：`tools/verify-arm64.ps1:13` 与
`tools/rdp-selfcheck.py` 都依赖
`entry/build/default/outputs/default/entry-default-signed.hap`（20.1 MB）。
若要保留"下一步能直接跑"的能力，**只删中间物、留 HAP**：

```powershell
# 保留 signed HAP，其余 build 中间物全删
$keep = "ohos\app\entry\build\default\outputs\default\entry-default-signed.hap"
Get-ChildItem ohos\app\entry\build -Recurse -Force |
  Where-Object { $_.FullName -ne (Resolve-Path $keep).Path -and -not $_.PSIsContainer } |
  Where-Object { $_.FullName -notmatch 'outputs\\default$' } | Remove-Item -Force
```

**第 3 批 —— 可重下载依赖，约 421 MB（必须先做 §2.4 的 pin 固化）**

```powershell
Remove-Item .bin\tools -Recurse -Force                       # 671.7 MB（perl + zip），确认 §2.4 后再删
```

### 2.3 必须保留（附理由）

| 保留项 | 大小 | 理由 |
|---|---|---|
| 全部 git 跟踪文件 | 1.20 MB | 仓库本体 |
| `spec/runs/**/result.json` | 0.5 MB / 239 个 | **唯一的机器判定产物**。删了 Assertion 就只剩文字声明 |
| `spec/matrix/*.json`（5 个） | ~4 KB | 已入库的矩阵结论 |
| `native/third_party/ohos/{x86_64,arm64}/lib/*.a` | 54.9 MB（各 18 个） | E2「双 ABI 三方库就绪」的直接物证；重建需 NDK+网络 |
| `.bin/sshfixture.exe` + `.bin/.sshfixture/hostkey` | 11.3 MB | `verify-arm64.ps1:14-15`、`sweep.ps1`、`rdp-selfcheck.py` 的硬依赖 |
| `entry-default-signed.hap` | 20.1 MB | 同上，安装步骤的输入 |
| `spec/runs/**/final.png` 的**入选子集** | 见下 | 视觉证据，见 §2.5 |

### 2.4 删除前的唯一硬前置：把"pin"固化进脚本

`native/third_party/src/`（319.2 MB）里混了两类东西，处置不同：

| 子项 | 大小 | 处置 |
|---|---|---|
| `openssl-3.0.15/` + `openssl-3.0.15.tar` + `.tar.gz` | 71.9 + 55.6 + 14.6 | **可删**（`native/build-openssl.ps1` 已有下载逻辑）；`.tar` 与 `.tar.gz` 是同源重复，二者留一 |
| `mbedtls-3.6.2/` + `-gh/` + `rel.tar.bz2` + `.tar.gz` | 42.9 + 40.3 + 4.7 + 5.1 | `-gh`（40.3 MB）来自 archive/refs，**脚本注释已明确它是坏的**（缺 framework 子模块）→ **立即删**；`.tar.gz` 与 `rel.tar.bz2` 重复留一 |
| `libssh2-1.11.1/` + `.tar.gz` | 5.0 + 1.0 | `build-thirdparty.ps1:51` 有 pin URL → 可删 |
| `FreeRDP/`（git） | 74.1 | 可删，但**必须**先固化 pin（下表） |
| `libvncserver/`、`libvterm/`（git） | 3.3 + 0.5 | 同上 |

**实测 pin（本次从各仓库 `rev-parse` 读出，务必写进脚本/文档后再删）**：

```
FreeRDP     4ae5b6c25452211f01f370d3e6e481553e72778a  (tag 3.9.0)  https://github.com/FreeRDP/FreeRDP.git
libvncserver 98aaee0560baa0332339b2ef464ea96ed9b9b28c               https://github.com/LibVNC/libvncserver.git
libvterm    934bc2fbf21800ac3458a499df8820ca5fb45fd3               https://github.com/neovim/libvterm.git
```

> ⚠️ **不要**在 pin 未落盘时删 `third_party/src/FreeRDP`。§1.1 的分析依赖 3.9.0 的
> `shadow_client.c` 行号；换版本后 `:685-690` 的提前返回可能已变，整套结论要重核。
> 建议：pin 写进 `native/build-freerdp.ps1` 顶部（目前它没有 `git clone` 分支，只 build）。

### 2.5 `spec/runs`（1,352.1 MB）—— 最需要决策的一块

内部构成（实测）：

| 类型 | 文件数 | 大小 | 判定 |
|---|---|---|---|
| `step-*.json` | 3,388 | 320.0 MB | **纯中间产物**（每步 UI 树 dump，`result.json` 已含结论）→ 删 |
| `final.png` | 238 | **908.8 MB** | 视觉证据 → 见下 |
| `result.json` | 239 | 0.5 MB | **判定结论** → 保留，并入库 |
| 其余（`launch.json`、`tree*.json` 等） | 1,318 | 122.8 MB | 中间产物 → 删 |

推荐做法（**这是本次最高价值的一条建议**）：
`spec/runs/` 被 `.gitignore` 忽略，意味着**现有证据不在任何版本控制里，删了就永久消失**。
先把证据"升格"为可版本化的形式，再删原始目录：

1. 新建 **入库**目录 `spec/evidence/<case>/<profile>/`，每条用例每画像保留：
   `result.json`（原样）+ `final.png`（**缩放到宽 720**，从 ~3.8 MB 降到 ~0.2 MB）。
2. 覆盖范围：56 用例 × 2 画像 = 112 组 → 约 **25–30 MB 入库**。
   体积来源明确（PNG 无损 2880×1920 截图），缩放不改变"是否通过"的判定，只降视觉证据精度。
3. 校验：生成后 `git status` 应显示约 224 个新文件；抽查 3 个 `result.json` 的
   `"passed"` 与对应 `final.png` 内容是否一致。
4. **最后**才 `Remove-Item spec\runs -Recurse -Force`。

把 1.35 GB 的临时目录换成 ~30 MB 的入库证据，是本清单里性价比最高的一步。
若不接受"缩放截图"，退一步：只保留 112 组 `result.json`（0.3 MB 入库）+ 每用例 1 张代表性截图。

### 2.6 清理后的预期结果

| 指标 | 现在 | 清理后 |
|---|---|---|
| 工作区总大小 | 2,693.4 MB | **约 80–90 MB** |
| `spec/runs` | 1,352.1 MB | 0（改为 30 MB 入库证据） |
| `.bin` | 732.3 MB | ~12 MB |
| `native/build` + `.cxx` + `ohos build` | 232.7 MB | ~21 MB（只剩 HAP） |
| 可重跑性 | — | `lint.py`、`gen-sbom.py --check` 立即可跑；`sweep.ps1`/`verify-arm64.ps1` 需先 `devecocli build` |

清理后**必须**复跑一次门禁作为验收：

```powershell
python spec\lint.py                 # 期望：全部通过
python tools\gen-sbom.py --check    # 期望：16 个组件、36 份产物
git status --porcelain              # 期望：只有 §2.5 新增的 spec/evidence/（若采纳）
```

---

## 3. 文档压缩方案

### 3.1 现状（实测）

| 文件 | 行数 | 大小 | 问题 |
|---|---|---|---|
| `docs/history/INDEX.md` | 2,491 | 146 KB | 412 个标题、91 个 Round，实际是**开发日志**，不是索引 |
| `PLAN.md` | — | 73 KB | 路线决策历史 |
| `A-PRIME-ENGINEERING.md` | — | 54 KB | 工程方案 |
| `docs/RUNBOOK.md` | 699 | 50 KB | 36 节，**最有价值但埋得深** |
| `docs/history/COMPLETION-REPORT.md` | 139 | 9.8 KB | §1-6 已被 §7-8 取代，三套数字并存 |
| `docs/history/FINAL-STATUS.md` | 94 | 5.8 KB | 与上面的 §8 重复 |
| `docs/RELEASE.md` | 107 | 6.0 KB | 数字过期（13/29 vs 16/36） |
| `docs/RELEASE.md` | 119 | 5.5 KB | 41 vs 56 矛盾 |
| `docs/RDP.md` | 110 | 6.5 KB | 开头"RDP 未实现"被 §6/§7 推翻 |
| `RDP-SERVER-PATH.md` | 62 | 3.8 KB | 承接上面的 §8-§11 |
| `A-PRIME-STATUS.md` | — | 5.0 KB | 又一个状态页 |
| `CAPABILITY-MATRIX.md` | — | 13 KB | 保留（`capabilities.json` 的上游） |

**12 份一级 Markdown，4 个"状态/结论"文档互相矛盾**——这是本次要解决的真问题，不是排版问题。

### 3.2 目标：4 份一级文档 + 1 个归档区

```
harmonyos/
├── README.md          ← 新·唯一入口（一页）
├── RUNBOOK.md         ← 由 docs/RUNBOOK.md 上提 + 收编散落的坑表
├── RDP.md             ← 新建：RDP-FEASIBILITY + RDP-SERVER-PATH + Round 54–79 结论
├── RELEASE.md         ← 新建：STORE-READINESS + ARM64-REAL-DEVICE + LICENSING
├── SBOM.json          ← 保留（机器可读，不动）
├── CAPABILITY-MATRIX.md ← 保留（机器可读的上游，不动）
└── docs/
    ├── history/      ← INDEX.md 全量迁入（改名 ROUNDS-01-91.md）
    └── design/       ← PLAN.md、A-PRIME-ENGINEERING.md、A-PRIME-STATUS.md
```

一级从 12 份降到 **4 份 + 2 份机器文件**。

### 3.3 判定标准：什么留一级，什么进 appendix

**留一级（4 条判据，任一命中即留）**

1. **可执行**：含能直接复制运行、且**当前仍正确**的命令/路径。
2. **当前真相**：给出*当前*状态的数字或结论（含"未做到"的诚实边界）。
3. **会改变行为**：踩坑记录里，"不知道就会做错"的那一类（如 `bm clean -d` 回滚、
   `type` 是插入不是替换、NAPI 返回 `Uint8Array`）。
4. **待办判据**：未跑测试的验收条件（arm64 56 项、上架阻塞 4 项）。

**进 appendix（3 条判据，任一命中即迁）**

1. **过程叙述**：某轮"试了什么、为什么失败"——除非失败能防重复踩（那压缩成 RUNBOOK 一行）。
2. **已被取代**：`docs/history/COMPLETION-REPORT.md` §1-6、`docs/RDP.md` 开头结论、
   一切旧数字（13/29、41 条）。
3. **推导细节**：如 FreeRDP 编译选项逐个调试过程——只留最终可复用命令与 3 条关键坑。

**一条硬规矩**：**任何数字只能有唯一出处**。文档里的数字要么来自命令输出（并写出命令），
要么不写。本次发现 3 处数字漂移全部源于"手抄一遍"。

### 3.4 迁移映射（逐节对应）

| 来源 | 章节 | 去向 | 动作 |
|---|---|---|---|
| `docs/history/FINAL-STATUS.md` | §1-3、§5-6 | `README.md` | 压缩为"现状表 + 不声称清单" |
| `docs/history/FINAL-STATUS.md` | §4 接手最短路径 | `README.md` | 保留（可执行），并修正 §1.1 的"需打补丁"错误 |
| `docs/history/COMPLETION-REPORT.md` | §8.1 数字 | `README.md` | 作为唯一数字源（并补 §0.1 的复跑命令） |
| `docs/history/COMPLETION-REPORT.md` | §2 能力覆盖表 | `README.md` 或 `CAPABILITY-MATRIX.md` | 保留（是唯一的能力全景） |
| `docs/history/COMPLETION-REPORT.md` | §1-7 | `docs/history/` | 归档（旧数字/旧结论） |
| `docs/RUNBOOK.md` | §1-36 全部 | `docs/RUNBOOK.md` | **整体上提到一级**（它是最高频文档，埋两层太深） |
| `docs/history/FINAL-STATUS.md` | §5 踩坑表 | `docs/RUNBOOK.md` 开篇 | 作为"速查 Top-9" |
| `docs/RUNBOOK.md` | §26 重复编号（两节都叫 26） | `docs/RUNBOOK.md` | 合并并重编号 |
| `docs/RDP.md` | §1-3 路线 A/B 试错 | `RDP.md` 附录 | 压缩为"为什么选 OpenSSL + 3 条坑" |
| `docs/RDP.md` | §6-7 里程碑 | `RDP.md` §「已完成(E2)」 | 保留结论，删过程 |
| `RDP-SERVER-PATH.md` | §8-11 | `RDP.md` §「服务端选型」 | 合并 |
| `docs/history/INDEX.md` | Round 54-79 的 RDP 结论 | `RDP.md` §「历史结论与证据」 | 抽 6-8 条结论，含 **Round 89 的更正** |
| `docs/RELEASE.md` | §1-2、§4-7 | `RELEASE.md` | 保留；**修正 13/29 → 16/36** |
| `docs/RELEASE.md` | §3 隐私声明 | `RELEASE.md` | 保留（可直接用作商店文案） |
| `docs/RELEASE.md` | 附录 A | `RELEASE.md` | 保留（RDP 实验性标注有用例守着，是上架资产） |
| `docs/RELEASE.md` | §1-7 + 附录 B | `RELEASE.md` | 保留；**41 → 实测条数**，补 §1.4 的 6 项脚本完善 |
| `LICENSING.md` | 全部 | `RELEASE.md` 引用 | 保留原文件，`RELEASE.md` 仅链接（许可声明宜独立可引用） |
| `A-PRIME-STATUS.md` | 全部 | `README.md` | 融合后删除（与 FINAL-STATUS 重复度最高） |
| `docs/history/INDEX.md` | 全部 91 轮 | `docs/history/ROUNDS-01-91.md` | **整体迁入，不改内容**，只在头部加"这是历史日志，当前状态见 README.md" |
| `PLAN.md`、`A-PRIME-ENGINEERING.md` | 全部 | `docs/design/` | 移动，不改（它们是决策记录，属 ADR 性质，应保留原文） |

### 3.5 执行顺序（每步可独立验证）

```powershell
cd E:\motty-HarmonyOS\harmonyos

# 1) 先建立归档区并迁移（纯移动，零信息损失，可 git mv）
git mv INDEX.md            docs/history/ROUNDS-01-91.md
git mv PLAN.md             docs/design/PLAN.md
git mv A-PRIME-ENGINEERING.md docs/design/A-PRIME-ENGINEERING.md
git mv A-PRIME-STATUS.md   docs/design/A-PRIME-STATUS.md
git mv docs/RUNBOOK.md     RUNBOOK.md        # 上提到一级

# 2) 新建 README.md（吸收 FINAL-STATUS + COMPLETION-REPORT §8 + A-PRIME-STATUS）
# 3) 新建 RDP.md（吸收 RDP-FEASIBILITY + RDP-SERVER-PATH + INDEX Round 54-79 结论）
# 4) 新建 RELEASE.md（吸收 STORE-READINESS + ARM64-REAL-DEVICE，修正数字）
# 5) 删除已被完全吸收的文件
git rm FINAL-STATUS.md COMPLETION-REPORT.md STORE-READINESS.md `
       ARM64-REAL-DEVICE.md RDP-FEASIBILITY.md RDP-SERVER-PATH.md

# 6) 验收：一级文档只剩 4 份 + 2 份机器文件
Get-ChildItem *.md,*.json | Select-Object Name
```

**第 6 步的验收判据**（必须全中）：

- 一级 `.md` = `README.md`、`docs/RUNBOOK.md`、`RDP.md`、`RELEASE.md`、`LICENSING.md`、`CAPABILITY-MATRIX.md`（6 份，其中后两份是"应当独立"的）
- `grep -r "13 组件\|29 份产物\|41 条\|41/41"` 无命中（旧数字清零）
- `grep -r "不透明\|只有前置声明"` 无命中（Round 89 的错误前提已清除）
- README 里的每条命令都能在本机跑通
- `docs/history/ROUNDS-01-91.md` 与原 `docs/history/INDEX.md` 行数一致（2,491 行，纯迁移不删改）

### 3.6 一条重要保留

`docs/history/ROUNDS-01-91.md` **不要删也不要摘要**。理由：
91 轮里包含大量"某个方案为什么被否掉"的判据（例如 mbedTLS-only 为何不可行、
`putImageData` 为何会崩）。这类信息**无法从最终代码反推**，一旦丢失，
接手者会重复付出同样的成本。归档 ≠ 丢弃。

---

## 4. 执行优先级总表

| 优先级 | 动作 | 可完成性 | 产出证据 |
|---|---|---|---|
| P0 | RDP 画面：改 `kVssWidth/Height` → 1024×768 + 新用例 `rdp.client-content` | ✅ 模拟器 | E1 |
| P0 | 纠正 `docs/history/FINAL-STATUS.md` §4 / `INDEX` Round 89 的错误前提 | ✅ 纯文档 | — |
| P0 | 清理第 1 批（62 MB，零风险） | ✅ 纯本地 | — |
| P1 | RDP 输入：接线 5 个回调 + `rdp.server-input` 用例 | ✅ 模拟器 | E1 |
| P1 | `spec/evidence/` 入库 + 删 `spec/runs` | ✅ 纯本地 | 证据入库 |
| P1 | 文档压缩到 4 份 + 归档区 | ✅ 纯文档 | — |
| P2 | arm64 脚本 6 项完善 + 指引对齐 | ✅ 本机自测 | E2 |
| P2 | AI 端点默认为空 + 首次确认（唯一可消除的上架阻塞） | ✅ 纯代码 | E1 |
| P3 | 清理第 2/3 批（构建物与可重下载依赖） | ✅ pin 固化后 | — |
| ❌ | 真实 Windows 互通 / NLA 互操作 | ❌ 需 Windows 主机 | 保持 E3 |
| ❌ | arm64 真机 56 项 | ❌ 需硬件 | 保持 E2 |
| ❌ | release 证书 / 隐私 URL / 渗透测试 | ❌ 需账号与第三方 | 保持缺口 |

---

## 5. 本文件自身的位置

本文件是**一次性维护方案**，不属于 3.2 的目标文档集。
执行完 §1 与 §3 后，本文件的结论应已被吸收进 `RDP.md` / `README.md`，
届时可直接删除（或同样迁入 `docs/history/`）。
