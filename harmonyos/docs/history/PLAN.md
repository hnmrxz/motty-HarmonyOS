# Motty → HarmonyOS PC / Tablet：1:1 复刻技术方案

> 由「技术方案评审团」（Software Architect / Application Security Engineer / Reality Checker）三份独立报告汇总、交叉核对而成。
> 评审日期：2026-11-10　仓库：`E:\motty-HarmonyOS`　HEAD：`f27254b`
> **本文档区分三类陈述：`已核实`（本机实测/代码证据）、`未验证`（需 spike 或真机证明）、`建议`（工程判断）。**

---

## 0. 结论摘要（先看这一节）

> **修订 2026-11-10（rev.2）**：测试基线由"真机"改为 **DevEco 鸿蒙模拟器（虚拟机）**。新增 §11 记录由此带来的 ABI、「可证/不可证」边界与验收口径变更，**覆盖 §4/§5/§7 中与设备相关的要求**。执行命令见 [docs/RUNBOOK.md](./docs/RUNBOOK.md)。

**1. 今天的实现度是 0%。** `git rev-list --left-right --count upstream/main...HEAD` = `0 0`，HEAD 与 `upstream/main` 同一个 commit `f27254b`，全仓无任何 `.ets` / `.ets` 之外要求 NAPI 或 `build-profile.json5` 文件。当前目录是上游原版快照，**不是**"已移植的鸿蒙版本"。

**2. 官方构建链无法产出鸿蒙产物，这是方案的第一性问题。** 官方 `build-from-source` 要求 Go 1.26 + `../viva` 检出 + macOS/Windows/Linux 三选一；`cmd/motty/main_unsupported.go` 对其它 GOOS 直接 `log.Fatal("motty: the interactive shell currently requires the macOS or Windows Viva backend")`（已核实）。也就是说：**Motty 的可执行形态与 Viva 渲染层在鸿蒙上根本不存在**，必须先决定"Go 内核怎么在鸿蒙上跑"。

**3. 整个项目被一个门禁支配：G1 = Go 能否在 OHOS 上运行。**
- G1 成立 → **路线 D1（给 Viva 加 OHOS 后端，Motty 源码零改动）是唯一能称"1:1"且成本最低的路**，估算 15–23 人月。
- G1 不成立 → **D1 和 B 一起死**（B 也需要 Go 在设备上跑）。只剩 A 全量 ArkTS 重写（55–70 人月，且"1:1"不可证伪）或 C 瘦客户端（破坏"独立可用/可上架"）。
- 因此：**任何编码开工前，先花 2–4 周做 G1/G3 两个 spike**。这是本方案最高优先级动作，不需要也不应该先写 ArkTS 界面。

**4. G2（Viva 许可证）已解除。** 评审团把它列为 release blocker，本机核验 `https://raw.githubusercontent.com/vivaui/viva/main/LICENSE` 为 **Apache License 2.0**（已核实）。可以新增 OHOS 后端、可以分发衍生版本；义务是保留 LICENSE/NOTICE、修改过的文件加显著变更说明、不得使用其商标暗示背书。仍需法务复核 Motty 的 `NOTICE`（rdpcore MIT fork、图标集、iTerm2 配色）在鸿蒙发行物中完整保留。

**5. "1:1" 必须换成可证伪的三层口径**（否则永远无法验收）：
| 层 | 定义 | 判定方式 | 是否计入 1:1 |
|---|---|---|---|
| **T1 行为等价** | 同一输入序列 → 同一终端状态/同一协议字节流/同一安全决策 | 机器判定（Go 单测 + e2e 场景回放） | 必须 100% |
| **T2 平台适配差异** | 实现等价但载体变了（密钥存 HUKS、目录变沙箱、URI 替代路径） | capability 声明 + 负测 | 必须 100% 声明 |
| **T3 不可复刻** | 鸿蒙上不存在对应机制 | 100% 移除 + 文档口径 | 不计入，需产品说明 |

**像素级 1:1 不可判定、也不应承诺**（ArkUI 与 Viva 是两套渲染管线，字形/连字/次像素/DPI 不同）。
**形态口径（已决策 2026-11-10）：PC 与平板都要求 1:1。** 两者的 1:1 是**同一套代码、同一套 T1 行为等价标准**；差异只体现在 T2（输入范式与窗口载体的映射），因为 hover / 滚轮 / 右键 / 物理修饰键本来就是 PC 输入范式，不是平板缺失的功能。详见 §12.3。

**6. 安全侧的硬约束（不接受即不算 1:1）：** 保留 Go 内核 = 保留已被验证的 9 万行安全关键实现与 fuzz 语料；NAPI 必须 capability 化（按会话句柄授权，不导出通用 `exec`）；密钥只进 Asset Store/HUKS，禁用 portable 文件回退；不得伪造后台保活。

---

## 1. 现状基线（已核实事实）

### 1.1 代码规模与耦合

| 指标 | 数值 | 来源 |
|---|---|---|
| Go 文件 / 总行数 | 1,638 / 413,844 | 实测 |
| 测试文件 / 行数 | 828 / 177,285（**42.8%**） | 实测 |
| 非测试行数 | 236,559 | 413,844 − 177,285 |
| `internal/workbench` | 901 文件 / 242,792 行 = 非测试 399 文件 / **131,012** 行 + 测试 502 / 111,780 | 实测 |
| 非 workbench 非测试 | 411 文件 / **105,547** 行 | 实测 |
| 引用 `viva` 的文件 | 719（其中 workbench 1,482 处引用） | 实测 |
| `internal/rdpcore` | 109 文件 / 38,410 行（MIT fork） | 实测 |
| e2e 脚本 | **82 个 `.txt` + 7 个 `.py`**（`tools/e2e/`） | 实测 |
| i18n 面 | 约 2,580 个叶串 × 3 语言（实测 english.go；943/947 只是顶层分组数） | 实测 |
| 桌面 GOOS 硬编码 | 约 117 个文件的 `//go:build` 只覆盖 darwin/windows/linux；57 个 `_os.go` 分叉文件 | 实测 |

**关键结构性判断：** 原版分层方向是健康的（协议包不 import UI 包，仅 `cmd/motty` 6 个文件 import workbench），但**"UI"与"被 UI 使用的状态"同包**——`internal/workbench/sftp.go:92-178` 的 `ui.ListState`/`text.Editor`/`*ui.Page` 直接内嵌 Viva 控件状态（已核实）。所以"保留 Go 内核、只换 UI"省不掉 workbench 的 131k 行。

**真实的 Viva 耦合点（比想象中少，但存在）：**
- `internal/term` → `viva/gfx` 仅 6 处（`keyboard.go:7`、`keys.go:7`、`win32input.go:6`），只是键盘码/修饰键常量 → **约 50 行适配即可脱钩**。
- `internal/sftpclient`、`internal/localshell` → `viva/leaks` 各 1 处（**测试辅助包出现在生产文件里**，属架构异味）。
- `internal/sshconn` → Viva 引用 **0**。
- 合计 8 处 import，是可清除的。

### 1.2 本机工具链实测

| 项 | 实测值 |
|---|---|
| Go 工具链 | **未安装**（PATH 无 `go`）→ 官方基线跑不起来 |
| `../viva` | **不存在** → UI 层无法编译对照 |
| DevEco Studio | `DS-261.23567.138.36.2600865`，位于 `C:\Program Files\Huawei\DevEco Studio` |
| SDK | `sdk\default`，**API 26 / platformVersion 26.0.0 / Release**，含 `openharmony`(ets,js,native,previewer,toolchains) + `hms`；`ets\api` 下 470 个 `.d.ts` |
| NDK | `native\llvm\bin` 下 `aarch64-unknown-linux-ohos-clang`、`armv7-…`、`x86_64-unknown-linux-ohos-clang`（musl 目标）；`native\sysroot\usr\lib\{aarch64,arm,x86_64}-linux-ohos\libc.so` |
| hdc | `sdk\default\openharmony\toolchains\hdc.exe`；`hdc list targets` = **空**（无真机/模拟器） |
| 命令行工具 | `C:\Program Files\Huawei\commandline-tools\command-line-tools\`（`ohpm`、`hvigor`、`hvigorw.bat`）；DevEco 自带 node；系统 node v24.21.0 |
| devecocli | 1.3.10 |

**已核验的鸿蒙 API 可用性**（`ets\api` 存在对应声明）：`@ohos.net.socket`（TCP，SSH/SFTP/转发的地基）、`@ohos.security.cryptoFramework`、`@ohos.security.huks`、`@ohos.security.asset`（密钥/凭据）、`@ohos.resourceschedule.backgroundTaskManager`（长时任务）、`@ohos.window`（自由窗口/多窗口）、`@ohos.pasteboard`、`@ohos.inputMethod*`、`@ohos.file.fs`、`@ohos.file.picker`、`@ohos.worker`、`@ohos.multimedia.image`。

### 1.3 官方文档给出的约束（`motty.page/zh/docs/development/*`）

- 构建要求：Go 1.26+；Viva 必须检出在**仓库旁 `../viva`**（独立项目、自有许可证、**不 vendor**）；平台三选一（macOS+Metal / Windows 10+ / Linux+X11）。
- 职责边界：Motty 管 SSH、认证、SFTP、终端模拟、转发、远程桌面协议、持久化、产品工作流；**Viva 管窗口、输入、文本与输入法、焦点、布局、组件、渲染**。
- 打包通过 Viva：`go run ./cmd/viva package`（app/dmg/tar.gz/deb）——**鸿蒙产物无对应打包器**。

→ 结论：官方文档描述的是"桌面三平台"路线，**鸿蒙不在其支持矩阵内**，1:1 复刻必须自带一条新的移植路线。这正是本方案的立足点。

---

## 2. 路线对比与推荐

五条候选路线、独立量化（两位成员分别估算，此处取交集区间；单位：人月，1 人月 ≈ 21 人日）：

| 路线 | 做法 | Go 内核 | UI 层 | 估算 | 能否称 1:1 | 致命依赖 |
|---|---|---|---|---|---|---|
| **A** 全量 ArkTS 重写 | UI + 协议全部 ArkTS 重写，Go 仅作参考 | 0 行保留 | ArkUI 全重写 | **55–70**（6 人 24–36 月） | ❌ 无 oracle，不可证伪 | 丢 65,505 行测试与 fuzz 语料 |
| **B** Go 内核 + NAPI | Go 编译为 `.so`，NAPI 暴露能力，ArkUI 只做视图 | 105.5k 行保留 | 131k 行重写 | **35–45**（6 人 12–17 月） | 行为等价（T1 可判定） | **G1**（Go on OHOS） |
| **C** 瘦客户端 / sidecar | 鸿蒙只做 UI，协议跑 PC 侧 | 0（远端复用） | 新 UI 协议 + ArkUI | 500–700 人日 | ❌ 平板脱离 PC 不可用 | 破坏"独立可上架" |
| **D1** Viva 加 OHOS 后端 | 给 Viva 写 OHOS 后端（窗口/GPU/输入/IME），**Motty 源码零改动** | 231k 行全保留 | Viva 后端新建 6–12 人月 | **15–23**（6 人 6–10 月） | ✅ **唯一真 1:1** | **G1** + Viva 上游协作 |
| **D2** Go→wasm 跑 ArkWeb | wasm 载入 ArkWeb | 部分 | Web 渲染 | 10–18 + 审查风险 | ❌ | wasm 无原始 TCP、套壳审查 |

### 推荐（决策树，而非单一押注）

```
                     ┌─ G1 通过 ─→ 路线 D1（首选，15–23 人月，真 1:1）
  Phase 0 门禁 spike ─┤              └ 若 Viva 上游拒绝/不跟进 → D1-fork（自维护 Viva 分支，+3–5 人月）
   （2–4 周）          │
                     └─ G1 失败 ─→ D1 与 B 同时作废【已决策 → 路线 A 全量重写】
                                    ├─ 路线 C：不采用（已决策否决）
                                    └─ 路线 A（55–70 人月 + oracle 重建 280–425 人日；"1:1"降级为"功能对齐"，见 §12.2）
```

**为什么首选 D1 而不是 B**（三位成员交叉后的判断）：
1. **成本**：D1 只新建 Viva 的 OHOS 后端（窗口/GPU surface/输入/IME/剪贴板/文件对话框/托盘），Motty 的 231k 行一行不动；B 需要重写 131k 行 UI 且要重新实现 Viva 的文本整形/连字/200+ 配色/2580×3 文案/图标体系，两位成员的独立估算都显示 B 比 D1 贵一倍以上。
2. **1:1 的唯一载体**：D1 让"像素/行为"保持一致成为可能（同一个 `Paint(&gfx.Canvas)` 立即模式管线），B 永远只是"行为等价"。
3. **跟版成本**：D1 对 Motty 的 diff = 0，上游 `f27254b` 前进时可直接 rebase；B/A 会永久分叉（评审团把"改动 upstream 文件数"列为路线评分项）。
4. **可复用现有后端**：Viva 已有 Linux（X11/EGL）后端，OHOS 的 `NativeWindow` + EGL/GLES 路径可大幅借鉴，不是从零写。

**推翻 D1 的条件（写明，避免事后扯皮）：**
- G1 失败，或 6 周内无法得到可加载的 `.so`（含 `-buildmode=c-shared` 在 ohos 目标的可用性）；
- Viva 上游明确不接受该后端，且团队不接受长期维护 Viva 分支；
- G3 渲染基线不达标（5000 行滚屏 <60fps）且无优化路径。

**B 保留为"G1 通过但 D1 受阻"的备选**，两者共享同一套前置工程（见 §3），切换成本可控。

---

## 3. 目标架构（路线无关的前置工程）

三条可行路线（B/D1/C）都要求**把"决策"与"呈现"拆开**。这就是 P0 重构，先做、且可独立验证。

### 3.1 分层与依赖方向（硬规则）

```
┌──────────────────────────────────────────────────────────┐
│  表现层   ArkUI (ArkTS) 或 Viva-OHOS 后端                 │ ← 只渲染，不做安全/协议判定
├──────────────────────────────────────────────────────────┤
│  端口层   5 个端口接口 + 1 个 Platform 适配层              │ ← 唯一允许跨语言/跨线程的边界
├──────────────────────────────────────────────────────────┤
│  应用层   internal/app（从 workbench 抽出的 16,026 行）    │ ← 状态机、会话编排、审批门
├──────────────────────────────────────────────────────────┤
│  内核层   term / sshconn / sftpclient / scpclient /       │ ← 105,547 行，零 UI 依赖
│           portforward / rfb / rdpcore / vault /           │
│           configstore / knownhosts / ppk / zmodem         │
├──────────────────────────────────────────────────────────┤
│  平台层   datadir / keystore / localshell / serial /      │ ← 每个平台一套实现
│           selfupdate / systemproxy                        │
└──────────────────────────────────────────────────────────┘
```

**规则（可 CI 断言）：**
- 内核层不得 import `internal/workbench` 或 `viva/*`；
- 表现层不得直接调用 socket / 文件 / 密钥 / 网络（只能经端口层）；
- 所有授权判定（gate / hostkey / transfer-root / vault 解锁）留在内核层。

### 3.2 五个端口（冻结契约，任何路线都适用）

| 端口 | 职责 | 鸿蒙侧实现选项 |
|---|---|---|
| `TerminalEngine` | PTY/会话字节流 ↔ 屏幕网格；键编码 | Go 内核（D1/B）或 ArkTS 重写（A） |
| `Transport` | SSH / SFTP / 转发 / RFB / RDP 连接 | Go 内核 + `@ohos.net.socket`（D1/B） |
| `Vault` | 保险库解锁、密钥存取 | Go 内核 + **HUKS / Asset Store** 适配器 |
| `DesktopSession` | VNC/RDP 会话与画面 | Go 内核 + ArkUI `XComponent` 上屏 |
| `AIControlPlane` | AI 工具调用、MCP 服务、审批门 | Go 内核（安全判定必须在 Go） |
| `Platform`（适配层） | 数据目录、文件 URI、剪贴板、后台任务、通知、更新 | ArkTS ↔ NAPI 双向 |

**收益：** 路线选择从"一次性不可逆下注"降级为"逐端口工程决策"。即使 D1 中途失败，已完成的端口契约与 Go 内核仍可接 B。

### 3.3 NAPI 契约（安全硬约束，来自 AppSec SEC-01/SEC-09）

- 每个导出 API **必须携带会话句柄**，Go 侧复检句柄归属；拒绝伪造/过期句柄。
- **禁止**导出通用 `exec(cmd)`、`eval`、任意路径读写、全局 env。
- 不新增网络监听（MCP 除外，默认关闭，保留 loopback-only + Host/Origin + 常量时间 token 校验）。
- 桥接层无权限提升收益（同进程），**沙箱即安全边界**——不要因为"有 NAPI"就放宽能力。

---

## 4. 分期计划

### Phase 0：门禁 spike（2–4 周，**开工前必须完成**）

| 门禁 | 内容 | 通过判定 | 当前状态 |
|---|---|---|---|
| **G1** Go→OHOS | 装 Go 1.26；`go tool dist list` 查 `ohos`；若无则 `GOOS=linux GOARCH=arm64 + NDK clang + -buildmode=c-shared` 产 `.so`；手写 NAPI 胶水；ArkTS 调 `Add(2,3)` 返回 5 | arm64 **与** x86_64 双 ABI 真机/模拟器均返回正确值；`nm -D` 断言导出符号；`-buildmode=c-shared` 是否被支持有明确结论 | **未验证** |
| **G2** 许可证 | Viva Apache-2.0 已核实；补：法务确认 NOTICE 义务、商标条款、"修改文件需显著标注"的落地方式 | 法务书面确认 | **部分已解决**（许可证 = Apache-2.0） |
| **G3** 渲染基线 | 在 ArkUI 上做 `XComponent` + `@ohos.graphics.drawing` 基准：5000 行滚屏、连字、SIXEL 图片、CJK 宽字符 | D1 口径：原生 surface 60fps；B 口径：ArkUI 画布 60fps 且字形可接受 | **未验证** |
| **G4** 能力矩阵签字 | 本文档 §6 的 T1/T2/T3 逐条确认，每条附降级实现与用户可见文案 | 产品 + 研发 + 安全三方签字 | 见 §6 草案 |
| **G5** 基线可运行 | 装 Go 1.26 + clone `vivaui/viva` 到 `E:\viva`，`go build ./...` + 至少 10 个 headless e2e 通过 | 有对照基线（否则后面所有"等价"都无参照） | **当前做不到**（无 Go、无 viva） |

> G1 与 G5 共用 Go 安装，建议同一天启动。**G1 的结论直接决定项目走向，不要在 G1 之前写任何 ArkTS 业务代码。**

### 里程碑（G1 通过后，以 D1 为基准排期；B 则 UI 期拉长）

| 期 | 目标 | 交付物 | 验收门 |
|---|---|---|---|
| **P0** 架构准备（与 Phase 0 并行，2–3 月） | 抽 `internal/app`（16,026 行）；`mottycore` 构建标签使内核脱离 Viva；term 键类型脱钩；5 端口契约冻结 | 纯 Go 可编译可测试的内核 | `go build/test -tags mottycore ./internal/{term,sshconn,sftpclient,vault,configstore}` 全绿 |
| **M1** 终端 + SSH（D1: 4–6 月 / B: 7–9 月） | 单机 SSH 会话、PTY、配色、回滚、分屏、标签、IME、鼠标、剪贴板 | 可日常使用的 SSH 客户端 | 10 个 e2e 等价（`terminal_protocols`、`terminal_flood`、`terminal_drag_scroll`、`clipboard_osc52`、`preedit`、`host_test`、`credentials`、`ppk`、`host_cert`、`agent_forward`）+ 4 项指标在目标机重标定 |
| **M2** 文件 + 转发（2–3 月） | SFTP 面板、内置编辑器、传输队列与续传、SCP 回退、本地/远程/SOCKS5/HTTP CONNECT、跳板链 | 文件与转发可用 | `sftp_*`、`scp_e2e`、`local_proxy`、`proxy_start_stop` 等价 |
| **M3** 远程桌面（2–3 月，**单独立项**） | VNC（RFB 3.3/3.7/3.8 + Raw/CopyRect/RRE/Hextile/ZRLE）、RDP（TLS/NLA/证书 pin） | 桌面可用 | `vnc_e2e`、`rdp_e2e`、`rdp_files_e2e` + 失败路径（证书变更即断） |
| **M4** AI + MCP + 同步（2 月） | Ask/Agent、审批门、脱敏、HTTP/stdio MCP、`.mottybak`、WebDAV/S3/Gist/Gitee | 智能与同步可用 | `ai_*`、`mcp_e2e.py`、`cloudsync_*`、`vault_*`；**MCP 可在无 UI 情况下启动** |
| **M5** 打包与上架（1–2 月） | HAP/HSP、双 ABI、发布签名、权限最小化、开源许可页、上架材料 | 可安装可分发的发行物 | 双 ABI 体积分别记录；发布签名真机安装；`.mottybak` 与 epoch 23 双向 round-trip |

> ⚠️ **不给绝对交付日期**。G1+G3 结论出来前给出的任何日期都是幻想（Reality Checker 立场，采纳）。

---

## 5. 风险登记册

严重度：**P0 阻断 / P1 高 / P2 中 / P3 低**。状态：`已核实` = 有代码/实测证据；`未验证` = 需实测；`已解决` = 本次已闭环。

### 5.1 阻断级（P0，必须在 Phase 0 闭环）

| ID | 风险 | 位置/依据 | 触发条件 | 影响 | 最小修复 | 验证方法 | 状态 |
|---|---|---|---|---|---|---|---|
| R01 | Go 无法产出 OHOS 可加载的 `.so` | 无官方 `GOOS=ohos`；社区 `gomobile-harmony` 采用 `GOOS=linux` + `ohos,harmonyos` 标签，且**不生成 NAPI 包装** | 用 `GOOS=ohos` 直接 build 失败后放弃 | **D1 与 B 同时作废**，只剩 A/C | G1 spike：`c-shared` + 手写 NAPI + 双 ABI | 真机 `Add(2,3)==5`；`nm -D` 断言符号 | **未验证** |
| R02 | `-buildmode=c-shared` 在 ohos 目标可能不被支持 | 第三方社区反馈（论坛标题，正文 JS 渲染未取到） | 同上 | 同上（可回落 `c-archive` + 静态链接进 NAPI 库） | 备选：`-buildmode=c-archive` + 自写 NAPI 宿主 | 两种 buildmode 各跑一次 | **未验证** |
| R03 | 内核无法脱离 Viva 编译 | `localshell/shell.go:11`、`sftpclient/worker.go:6` 引 `viva/leaks`；`term/{keyboard,keys,win32input}.go` 引 `viva/gfx` | 试图"零 Viva 编译内核" | 编译失败或被迫拖入 Viva | `mottycore` 构建标签；8 处 import 替换（约 50 行） | `go build -tags mottycore ./...` | **已核实** |
| R04 | 数据目录假设在沙箱不成立 | `internal/datadir/datadir.go:5-16`（可执行文件旁便携目录、`MOTTY_DATA_DIR`） | 直接移植 | 首次启动写失败 | 映射到沙箱 `filesDir`；**禁用 portable 模式** | 冷启动可写、重启可读 | **已核实** |
| R05 | 密钥落盘方式导致保险库等同明文 | `vault/keystore.go:11-28` `FileKeystore` 把 32B 数据密钥写在 vault 旁 | 照搬 portable 思路 or 云备份带上数据目录 | 备份/同步带走密钥 | 密钥存 **Asset Store/HUKS**（AES256-GCM，TEE 内加解密）；`IS_PERSISTENT=false`；锁屏等级"首次解锁后" | 备份产物 grep 不到 32B 密钥；卸载后密钥清除 | **已核实 / API 行为未验证** |
| R06 | NAPI 成为新授权边界 | 参照 `internal/ai/gate/gate.go:1-7,160` 的"单门"设计 | 把 gate/hostkey/transfer-root 判定移到 ArkTS，或导出宽接口 | 越权执行会话命令（Broken Access Control） | capability 化：每 API 带会话句柄，Go 侧复检归属 | 负测：伪造/过期句柄调 exec 必须失败 | **建议（设计约束）** |
| R07 | 外部意图注入（鸿蒙新入口） | `internal/workbench/launch.go:139-176`：`!link` 时直接 `connectParsed` 无确认；`xshellLaunchPath` 按路径直接导入 | 任意应用 `startAbility` 传 want 参数；或点 `ssh://` 链接 | 静默连接攻击者主机、导入恶意 Xshell 文件 | 所有外部来源（want/onNewWant/App Linking）一律入 backlog 并强制确认；`exported` 最小化；用 App Linking 域名校验而非裸 scheme | 4 类注入用例（裸参数/ssh://telnet:///文件路径）必须全部出确认框 | **已核实** |
| R08 | 后台保活不可用，且不能伪造 | 官方长时任务无"SSH 长连接"类型；`DATA_TRANSFER` 要求实况窗进度、首次超 10 分钟无更新即取消 | 产品要求"退后台不断" | 伪造 → 系统管控/上架风险；如实断开 → 功能降级 | 明确"退后台降级/断开并提示"，**不做伪造保活**；仅前台或真实传输时申请 | 真机切后台 10/30 分钟观察会话与通知 | **未验证（需查官方正文）** |
| R09 | 无 ArkTS 侧 oracle，验收退化 | `cmd/motty/headless.go:1` = `vivahead && (darwin\|windows\|linux)`；`tools/headless_drive.py` 驱动 Viva 行协议 | 选路线 A | "1:1"不可证伪 | 保留 Go 内核（自带 65,505 行测试）作 oracle；若走 A 必须先建 ArkTS uitest harness | 同一组 SSH/SFTP 轨迹两端状态等价报告 | **已核实** |

### 5.2 高危（P1）

| ID | 风险 | 位置/依据 | 影响 | 最小修复 | 验证 | 状态 |
|---|---|---|---|---|---|---|
| R10 | 平台标签**静默排除**而非编译报错 | 约 117 文件 `//go:build darwin\|\|windows\|\|linux`；`!windows` 反而匹配 | 功能静默缺失，最难发现 | 统一 platform 判定包 + CI 矩阵比对文件集合 | `go list -f {{.GoFiles}}` 桌面 vs 新目标差异 = 0 或白名单 | **已核实** |
| R11 | 文件访问边界由路径变 URI | 现有传输根校验只覆盖 agent/MCP（`agent_transfers.go:57-125`）；GUI SFTP 按 OS 路径 | 越权读写或授权丢失后回退过宽目录 | URI 白名单 + `persistPermission` + 真实路径复核 | 选目录 A 后访问 A 外必须失败；重启后授权仍在 | **已核实 / API 行为未验证** |
| R12 | RDP TLS 下限 1.0 + 依赖证书 pin | `rdpcore/client.go:628`（`InsecureSkipVerify:true`）、`:630`（`MinVersion TLS10`） | 弱套件；漏 pin 则 NLA 凭据可被中继 | 鸿蒙版 `MinVersion` ≥1.2；保留 pin 回调与"变更即断" | 抓包确认 ≥1.2；`VerifyCertificate` 非 nil | **已核实** |
| R13 | 剪贴板 OSC 52 默认放行 | `remote_clipboard.go:22-28` `defaultTerminalClipboard = allow`；e2e 断言"默认不询问" | 远端静默改写系统剪贴板 → 跨应用粘贴钓鱼（鸿蒙剪贴板全系统可见，风险更高） | 鸿蒙版默认改 **ask**（至少未知主机 ask）；读取需用户手势 | 默认策略测试；切 ask 后有预览框 | **已核实** |
| R14 | MCP token 明文落盘 | `ai_hub.go:136-142`（`ai.mcp.token` 存 ai.db，0600） | 拿到 token = 拿到终端工具权限 | token 存 Asset Store；诊断字段白名单；导出强制脱敏 | 诊断/备份产物 grep 不到 token | **已核实** |
| R15 | 审批目标 TOCTOU（外部 MCP 路径） | `gate.go:474-492`：重检 readiness 仅在 `g.Target != nil`（应用内），外部 MCP 走 `Target==nil` 不重检 | 命令落在与审批时不同的会话 | 重检改为**无条件**，用会话生成号而非 id 字符串 | 单测：审批中关闭并重连目标，命令不得执行 | **已核实** |
| R16 | 本地 PTY / 子进程在沙箱不可用 | `localshell` 2,807 行 + `creack/pty`；`main_unsupported.go:8` 已把三类 OS 之外判死 | 本地 shell、ProxyCommand、selfupdate 全挂 | capability 端口 + `Unsupported` 实现 + UI 不显示入口 | 启动扫描无 exec；降级清单与 README 逐条对应 | **代码已核实 / 不可行性未实测** |
| R17 | 双 ABI 体积翻倍 | 基线二进制 30MB（剥 21MB） | 超包体上限/审核风险 | HAP/HSP 分包；两 ABI 分别记录体积 | G6 实测 | **未验证** |
| R18 | 跨端数据向后兼容 | `tools/README.md:94,112-118`：`meta.format` epoch 23，单向不可回退，"never lower the stored number" | 鸿蒙端写库后回旧版数据不可读 | 强制"不抬 epoch" + 导出逃生口 | 双向 round-trip：桌面写→鸿蒙读→鸿蒙写→桌面读 | **已核实（文档）** |
| R19 | 性能基线不可直接引用 | `docs/performance-audit.md` 全为 Apple M2 Pro / macOS / Go 1.26.5，§8 自述"只在 macOS/arm64 跑过完整测试" | 拿别人机器数据给自己发证书 | 目标设备重标定；禁止引用非本机数字 | 冷启/键击回显 p95/解析吞吐/回滚区内存 4 项本机实测 | **已核实** |
| R20 | "全部测试通过"本身是假命题 | 同一文档 `:787-791`：HEAD 上 `go test ./...` 在 `internal/localshell`(pty) 与 `internal/remotetools`(/bin/ps) **已失败** | 掩盖已知失败 | 建立基线失败清单，鸿蒙侧同清单比对 | 失败清单差异 = 0 | **已核实** |

### 5.3 中低危（P2/P3）

| ID | 风险 | 最小修复 |
|---|---|---|
| R21 | `rdpcore` 38,410 行被当小里程碑 | M3 单独立项估工，独立验收 |
| R22 | 平板输入模型与 PC 不同（hover/右键/滚轮/修饰键/托盘） | **不做功能子集**：T1 两形态共用全量；T2 按形态映射（触控长按/双指滚动/外接键盘触控板/通知卡片），逐项落表并验收 |

> **R22 修订（2026-11-10）**：初稿建议"平板做适配子集"，用户已决策平板同为 1:1。修正后的做法是**功能面不打折、只换输入载体**——这比"两个版本"便宜得多，因为是一套代码 + 一层输入映射，而不是第二份实现。风险从"功能缺失"变为"映射冲突"，典型冲突见 §12.3 的长按与文本选择冲突。
| R23 | 供应链：仅 gofmt/vet/test/race，无 CodeQL/govulncheck/secret scan/dependabot/SECURITY.md | CI 加 govulncheck + CodeQL + gitleaks + dependabot；原生依赖出 SBOM 并锁 commit |
| R24 | 诊断/崩溃日志可能带出路径、命令、URL | 字段白名单化（`diagnostics.go:57-107` 现只隐藏主机/标签/用户名/代理） |
| R25 | 自动填充规则空 scope 可成"应答 oracle" | 空 scope 规则改为"仅本会话"；主机密钥变更后禁用自动填充 |
| R26 | 仅 debug 签名可用 | 早期打通发布签名 + 真机安装 |
| R27 | 社区 Go 工具链断供（第三方 fork） | 锁版本 + 自建镜像 + 可回退方案 |
| R28 | i18n 文案即测试契约（82 个 e2e 按本地化文案点击） | 由 Go 结构体生成 JSON 资源 + ArkTS 稳定 test id |
| R29 | "风险分级审批门"被宣传成安全控制 | `internal/ai/risk/risk.go:1-11` 自述"这不是安全边界"；文档口径改为"防误操作提醒"；allow-all 二次确认 + 审计 |

---

## 6. 能力矩阵（T1/T2/T3 草案，需 G4 签字）

完整逐项表见 [CAPABILITY-MATRIX.md](./CAPABILITY-MATRIX.md)。摘要：

- **T1 行为等价（必须做，可机器判定）**：SSH 全认证方式（agent / 私钥 / OpenSSH 证书 / `.ppk` v2v3 Argon2id / 密码 / keyboard-interactive 多问题）、自有 `known_hosts`、`@cert-authority`、跳板链、终端模拟全部特性（备用屏、回滚、宽字符、DECSET 2026、kitty 键盘协议、鼠标上报、OSC 8/52、SIXEL/Kitty/iTerm2 图片）、SFTP 全功能 + 原子重命名 + 续传、SCP 回退、转发、VNC、RDP(NLA/pin)、AI Ask/Agent + 审批门、MCP（HTTP/stdio）、`.mottybak`、云同步。
- **T2 适配等价（实现换载体）**：密钥 → HUKS/Asset Store；数据目录 → 沙箱 `filesDir`；文件选择 → filePicker URI + `persistPermission`；后台 → 前台优先 + 降级提示；窗口 → PC 自由窗口 / 平板分屏·平行视界·悬浮窗；输入 → PC 指针(hover/右键/滚轮) / 平板触控(长按菜单/双指滚动) + 外接键盘与触控板双通道；托盘 → PC 通知区 / 平板服务卡片；剪贴板 → ask 策略 + 手势限制；端口转发 → 只绑 loopback。
- **T3 不可复刻（移除 + 文档写明）**：`win32-input-mode`（仅 Windows console）、本地 PTY shell（沙箱限制，未实测）、X11 转发（需本机 X server + Xauthority）、`ProxyCommand` 子进程（沙箱禁 exec）、selfupdate 自安装（市场分发）、serial 串口（无 `/dev/ttyUSB*`，USB Kit 可否替代未验证）、portable 便携模式、桌面数据目录语义、Metal/D3D 逐像素渲染细节。**注意：托盘与跨窗口拖拽已从 T3 移入 T2**（平板上用服务卡片 / 分屏内等效操作实现，功能不缺）。

---

## 7. 验收清单

### 7.1 门禁（Phase 0）

- [ ] **G1a** `go tool dist list` 是否含 `ohos`（记录结论）
- [ ] **G1b** `-buildmode=c-shared` 产 arm64 `.so`，ArkTS NAPI 调用返回正确值
- [ ] **G1c** 同上 x86_64（PC 模拟器）
- [ ] **G1d** `nm -D` 断言导出符号；记录 Go 版本/NDK 版本/构建命令
- [ ] **G2** 法务确认 Apache-2.0 义务（LICENSE/NOTICE/修改标注/商标）+ Motty NOTICE 完整性
- [ ] **G3** 5000 行滚屏 ≥60fps；连字、CJK 宽字符、SIXEL 可显示（或文档化替代）
- [ ] **G4** 能力矩阵 T1/T2/T3 三方签字
- [ ] **G5** 原版基线：`go build ./...` + ≥10 个 headless e2e 通过；记录已知失败清单（R20）

### 7.2 架构门（P0 重构完成）

- [ ] `mottycore` 标签下 `go build ./...` 通过（内核零 Viva 依赖）
- [ ] `go test -tags mottycore ./internal/{term,sshconn,sftpclient,scpclient,portforward,vault,configstore,rfb,rdpcore}` 全绿
- [ ] 5 端口契约冻结并评审通过；依赖方向 CI 断言（内核不 import workbench/viva；表现层不直连 socket/文件/密钥）
- [ ] `internal/app` 抽取后，MCP/HTTP 控制面可**在无 UI 进程**下独立启动

### 7.3 安全门（每期复用）

- [ ] **S-G0** 威胁模型已更新并签字
- [ ] **S-G1** 负面测试全绿：伪造会话句柄（R06）、4 类 want 注入（R07）、目录外访问（R11）、ProxyCommand 必拒（R16）
- [ ] **S-G2** 自动断言：备份/诊断/导出产物中 grep 不到 token、私钥、口令、32B 数据密钥（R05/R14/R24）
- [ ] **S-G3** 策略判定单测在 Go 侧（OSC52 ask/block、主机密钥变更即断、审批门 allow-all 审计）（R13/R15/R29）
- [ ] **S-G4** 依赖扫描无高危；SBOM 产出（R23）

### 7.4 保留的安全不变量（违反即阻断，来自 AppSec）

| # | 不变量 | 位置 |
|---|---|---|
| P1 | 主机密钥变更**无**"仍要信任"按钮 | `sshconn/hostkey.go:97-145`（mismatch 121-128） |
| P2 | 所有 AI 工具调用只经 `gate.Run` 单点 | `ai/gate/gate.go:1-7,160` |
| P3 | MCP/stdio agent 默认 `ModeObserve`；未知值→observe | `workbench/ai_state.go:119`、`ai_hub.go:146-155` |
| P4 | 传输根：绝对路径 + `EvalSymlinks` + 逐段 `Lstat` 拒符号链接 | `workbench/agent_transfers.go:57-125` |
| P5 | 保险库 AES-256-GCM + HMAC 记录 ID + 原子 0600；**系统库拒权时不降级到文件** | `vault/vault.go:783-818,734-759`；`keystore.go:54-83` |
| P6 | 终端输入边界：`maxOSC` 4096 / 图像 64MiB / 剪贴板只写不读 | `term/terminal.go:5-14`；`clipboard.go:32`；`image.go:18-26` |
| P7 | RDP 证书 TOFU pin，拒绝即断 | `desktop_conn.go:96,199-205`；`rdpcore/client.go:626-645` |
| P8 | 常量时间比较 + loopback-only + Host/Origin 校验 | `ai/mcp/server.go:174-187,235-249,335-342` |

> 这 8 条有对应的现有测试与实现，是"选 D1/B（保留 Go 内核）"的最强论据；重写会丢。

### 7.5 每期通用产物

- 改动 upstream 文件数报告（跟版成本指标；D1 目标 = 0）
- build tag 变更清单 + `go list -f {{.GoFiles}}` 文件集合差异报告（R10）
- 每脚本 before/after 截图（沿用项目原生证据范式：`artifacts/headless/README.md:11-21` 的"PNG + 视口 + 命令结果表 + Limits"）

---

## 8. 决策台账（原有开放问题 → 已决）

> 本节取代初稿的"待用户决策"清单。逐条记录：原始问题、用户决策、工程后果。

| # | 问题 | 决策（2026-11-10） | 工程后果 |
|---|---|---|---|
| 1 | 目标设备 | ~~真机~~ → **鸿蒙模拟器**（2in1 + tablet，API 26） | 见 §11；ABI 变 x86_64，arm64 降为仅编译 |
| 2 | G1 失败走哪条 | **走 A（全量 ArkTS 重写）**，C 否决 | 见 §12.2；必须同时接受"1:1 → 功能对齐"的降级定义与 oracle 重建成本 |
| 3 | 是否必须上架 | **预留上架条件，实在不行则不上架** | 见 §12.1；合规项按"可上架"标准建设，但设 Plan B 内部分发 |
| 4 | 平板是否也要求 1:1 | **已决：平板同样 1:1**（PC 与平板共用一套代码与 T1 标准，差异只在 T2 输入/窗口映射） | 见 §12.3；增量约 **4–9 人月**（适配 + 双画像验收），不是重写 |
| 5 | 团队规模 | **仍未定** | 决定并行度；D1 路线下还决定是否自维护 Viva 分支 |

**本机无法补齐的材料（更新后）：**
- ~~Go 1.26~~ / ~~`../viva`~~ → 已在装（winget / `git clone` 到 `E:\viva`），见 §11.5。
- 华为官方正文：`GOOS=ohos` / `c-shared` 支持情况、BackgroundTasks 长时任务类型与配额、loopback 是否跨应用可达、asset store 行为、filePicker 授权持久化（华为文档页 JS 渲染，`web_fetch` 仅得壳）。
- 上架规则：包体上限、是否允许捆绑 `.so`、是否允许降级安装、**发布签名在模拟器上不可验**。

**未覆盖范围：** 未做动态渗透测试；未逐行审阅 413k 行（安全只精读约 20 个关键文件 ≈6k 行 + 30 余组跨包 grep）；未评估 `website/`、`.github/` 流程；未核实第三方 Go-OHOS 工具链的法律与许可状况；未做 RDP/VNC 编解码性能实测。

---

## 9. 覆盖度声明

| 成员 | 负责 | 结论要点 | 是否独立完成 |
|---|---|---|---|
| Software Architect | 架构与可扩展性 | 推荐 D1（Viva + OHOS 后端）为首选，A 为回落；P0 抽 `internal/app` + 5 端口；量化 4 条路线 | 是（静态分析，未执行构建） |
| Application Security Engineer | 授权与安全 | 否决 A（丢掉 9 万行安全实现与 fuzz 语料）与 C（信任边界搬到网络）；B/D1 须满足 5 个不可谈判条件 + 8 条不变量；未发现可直接利用的现有漏洞 | 是（静态审阅约 20 个文件） |
| Reality Checker | 验收边界与质量 | 实现度 0%（HEAD == upstream）；"1:1"必须三层可证伪；PC=1:1/平板=适配；性能基线不可引用；HEAD 已有 2 个包测试失败 | 是（只读勘察） |

**评审团内部的分歧与协调结果：**

1. **D1 vs B**：Architect 首选 D1（真 1:1、成本最低），Security 首选 B（"唯一不产生安全回归"）。**协调结论：两者不冲突且共享前置**——D1 与 B 都要求 Go 在 OHOS 运行（G1），安全约束（capability 化 NAPI、判定留 Go）对两者同等适用。差别只在"视图层用 Viva-Go 还是 ArkUI"，因此**先过 G1，再按 G1/G3 结果二选一**，不必现在下注。Security 的"若 G1 不成立不要退化成 A"被部分采纳：A 仅在用户明确接受"功能对齐而非 1:1"时启用。
2. **B 与 A 的成本关系**：Architect 称"B 总价 ≈ A"，与其自身分项（B 省 13 人月协议移植、加 2–4 人月桥）及 Reality Checker 的独立估算（B 37–43 人月 vs A 62–70 人月）不一致。**协调结论：以"B 显著低于 A（约省 40%）"为准**，Architect 的"≈"表述在本次汇总中不予采用。
3. **e2e 脚本数**：Architect 记 82，Reality Checker 记 91，Security 记 100+。**本机实测为 82 个 `.txt` + 7 个 `.py`**，以 82/7 为准，其余口径视为包含不同统计范围。
4. **Viva 许可**：Architect/Reality Checker 均标为 release blocker（本机无源码、许可不可得）。**本次已核验为 Apache-2.0**，该阻断项关闭，仅余法务复核义务项。

**未达成共识的开放问题**：G1 失败后的产品走向（C vs A）——需用户决策，评审团不代为决定。

---

## 10. 附录：本机工具链速查

```powershell
# Go（需先安装 Go 1.26，与 go.mod 一致）
go version
go tool dist list | Select-String ohos        # G1a

# Viva（官方要求检出到仓库旁）
git clone https://github.com/vivaui/viva E:\viva

# NDK 交叉编译器（已实测存在）
$NDK = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native"
& "$NDK\llvm\bin\aarch64-unknown-linux-ohos-clang" --version
& "$NDK\llvm\bin\x86_64-unknown-linux-ohos-clang" --version

# 设备与 SDK
& "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" list targets
# ohpm / hvigorw:
#   C:\Program Files\Huawei\commandline-tools\command-line-tools\bin\{ohpm,hvigorw}.bat
```

参考文档：
- [从源码构建](https://motty.page/zh/docs/development/build-from-source)
- [架构](https://motty.page/zh/docs/development/architecture)
- [Viva（Apache-2.0）](https://github.com/vivaui/viva)
- [OpenHarmony 第三方库移植（Lycium / tpc_c_cplusplus）——OpenSSH/libssh2/openssl 交叉编译实践](https://raw.gitcode.com/oh-tpc/openssh/raw/633e04f4666e4f2b2dd43200476fee549979daa7/docs/porting_openssh_ohos.md)

---

## 11. 测试基线：鸿蒙模拟器（虚拟机）— 2026-11-10 修订

> 本节**覆盖** §4 的 Phase 0、§5 的 R01/R16/R17/R19、§7 的门禁定义。命令见 [docs/RUNBOOK.md](./docs/RUNBOOK.md)。

### 11.1 为什么这个变更改变了方案的性质

用模拟器替代真机，解掉了一个阻塞、也换入了一个新的、必须写在验收报告里的缺口。

**解掉的阻塞**（原本卡死 Phase 0 的三件事）：
1. 没有真机 → `hdc list targets` 为空，G1/G3 无法执行。
2. 无法验证 PC 形态 → 现在镜像目录里 **`2in1`（PC）与 `tablet` 在 API 26 都有**，正好覆盖两个目标形态。
3. 环境未知 → 已实测：模拟器二进制存在、`HypervisorPresent: True`（Hyper-V 在跑，虚拟化就绪）、华为账号已登录、许可已接受、镜像可下载。

**换入的缺口（最关键的一条）**：

> **模拟器 guest 是 x86_64，不是 arm64。**
> 证据：镜像落盘路径为 `AppData\Local\Huawei\Sdk\system-image\HarmonyOS-7.0.0\pc_all_x86\`，镜像大小 2,383,721,240 字节（≈2.38 GB）。

这意味着：
- Go 在模拟器上的可执行目标是 `linux/amd64` —— 恰好是 Go 支持最好、最不可能出坑的架构。**G1 的技术风险因此显著下降**（原本 arm64 + 未验证 GOOS 是最大变数）。
- 但**真机（Kirin，arm64）从此变成"仅交叉编译验证"**：能证明"编得出来"，不能证明"跑得起来"。
- 所以"1:1"在模拟器阶段最高只能认证到 **模拟器级**。**上线前必须有一轮 arm64 真机抽验**，这条进 M5 的 release 条件。

### 11.2 ABI 与门禁的调整

| 项 | 原（真机） | 现（模拟器） |
|---|---|---|
| G1 可执行 ABI | arm64（未验证） | **x86_64（可执行）** |
| arm64 | — | **仅 `c-shared` 编译 + `llvm-nm` 符号断言** |
| `abiFilters` | `["arm64-v8a","x86_64"]` | 先 `["x86_64"]`，arm64 随 CI 追加 |
| 设备画像 | 未定 | PC = 2in1 3120×2080 @304dpi；平板 = 2560×1600 @360dpi |
| G3 渲染门 | 60fps 性能门 | **功能门**（画面正确、不崩、不 OOM）；性能门改名 G3-device，标"未执行" |

### 11.3 证据等级（新增，写进每一条验收结论）

从本节起，所有验收结论必须标注证据等级，不允许把后两级写成前一级：

| 级 | 含义 | 可覆盖 |
|---|---|---|
| **E1 模拟器实测** | 在 2in1/tablet 镜像上真跑并留证据（截图/日志/hdc 输出） | Go 运行时、NAPI 桥、UI 功能布局交互、filePicker/URI 授权、应用间 loopback |
| **E2 仅编译/静态** | 交叉编译通过、符号断言、代码审阅 | arm64 运行、真机驱动行为 |
| **E3 未验证** | 无任何证据 | 模拟器无此设备：USB/串口、发布签名上架、真机性能（帧率/功耗/热）、HUKS 的**安全属性**、后台保活的真实策略 |

**高风险假通过点（必须在报告里显式写"不代表真机"）**：
1. **后台长时任务**：模拟器策略通常比真机宽松，"退后台不断"极可能是假通过（对应 R08）。
2. **HUKS/Asset Store**：可能软件实现，能验代码路径，不能验 TEE 与锁屏等级语义（对应 R05）。
3. **渲染性能**：宿主 GPU 中介，帧率数字无可比性（对应 R19）。
4. **发布签名**：模拟器只吃 debug 签名，"能装"不等于"能上架"（对应 R26）。

### 11.4 新增风险

| ID | 风险 | 触发 | 影响 | 最小修复 | 验证 | 状态 |
|---|---|---|---|---|---|---|
| R30 | 模拟器 x86_64 与真机 arm64 不等价 | 直接以模拟器结论定"1:1 完成" | 真机首启即失败的隐性缺口 | arm64 编译纳入 CI（每次提交）；M5 前安排一轮真机抽验 | `llvm-nm` 双 ABI 符号一致 + 真机安装冒烟 | **已确认（镜像路径 `pc_all_x86`）** |
| R31 | 模拟器策略宽松导致后台/密钥项假通过 | 只在模拟器上验 R05/R08 | 上线后被系统回收/密钥不可用 | 这两项标 E3，真机复验后才可关闭 | 真机 8h soak + 卸载重装解锁 | **未验证** |
| R32 | 镜像/许可/账号前置（2.38 GB×2 + 华为账号） | 换机/换账号/CI 环境 | 新环境无法复现测试 | 记录镜像版本与下载命令；CI 环境预置 | 全新账号走一遍 §0 | **已解决（本机）** |
| R33 | 模拟器不支持某些 Kit（USB/部分安全能力） | 计划用模拟器验串口/上架 | 该能力永无 E1 证据 | capability 表直接标"模拟器不可测"，不排期 | 逐条在 §C 表中标注 | **已确认** |

### 11.5 修订后的 Phase 0 顺序（可直接执行）

1. **拉镜像**：2in1（进行中）→ tablet。
2. **建并启动实例**：`emulator create` → `emulator start` → `hdc list targets` 拿到 serial。
3. **确认 guest ABI**：`hdc shell getprop ro.product.cpu.abi`（预期 `x86_64`）、`getprop ro.build.version.sdk`（预期 `26`）。**这行输出决定后面所有 GOARCH。**
4. **装 Go 1.26 + clone Viva**（G5 基线）。
5. **G1 三级 ramp**：静态二进制（hdc shell 内）→ `c-shared` x86_64 + arm64 → NAPI 闭环。
6. **G3 功能门**（并行）。
7. **填 G1 结论表 → 走 §D 决策表**。

> 顺序上唯一不可省的判断是第 3 步：如果 `getprop` 返回 `arm64-v8a`（有些镜像会），那么"模拟器可执行目标"就是 arm64，本节的 ABI 结论要整体反过来重写。**先测，再写方案。**

---

## 12. 两项用户决策的落地方案

### 12.1 上架：预留条件，不把上架当作必经门（决策 3）

**口径**：从第一天起按"可上架"标准建设，但把"必须上架"降为软目标；设 Plan B，触发时不留返工债。

**A. 建设期必须做（否则将来无法上架，属返工债）**

| 项 | 要求 | 现状/依据 |
|---|---|---|
| 签名体系 | 发布证书 + Profile（AGC）；debug 签名只用于模拟器 | 模拟器**只吃 debug 签名**，发布签名在模拟器上不可验 → E3，须真机或 AGC 云端校验（R26） |
| 包体与 ABI | HAP/HSP 分包；双 ABI 体积分别记录；超限时按 ABI 拆分分发 | R17；基线二进制 30 MB（剥 21 MB） |
| 权限最小化 | 每条 `requestPermissions` 必须带 `reason` + `usedScene`，逐条论证 | 网络/文件/剪贴板/后台四类要单独说明 |
| 后台合规 | **不伪造** DATA_TRANSFER；只在前台或真实传输时申请长时任务 | 官方会比对"申请类型与实际业务"，不符即挂起（R08） |
| 隐私与数据 | 隐私声明、权限说明、数据收集清单；密钥不进备份；诊断脱敏 | R05 / R24 |
| 开源合规 | `THIRD_PARTY_NOTICES`：Motty Apache-2.0、rdpcore MIT、图标集、iTerm2 配色、**Viva Apache-2.0（修改文件加显著说明）**；应用内开源许可页 | R11 |
| 供应链 | SBOM + govulncheck/CodeQL/secret scan；无高危 | R23 |
| 禁止自更新 | T3 已移除 selfupdate，与市场分发一致 | 见能力矩阵 H 组 |

**B. Plan B（触发时立刻切换，不推翻已有工作）**

- 触发条件：AGC 审核因具体项被拒且无法整改（例如不允许捆绑 `.so`、包体超限、后台类型不符）→ 把"拒绝原因"记入决策台账后转 Plan B。
- 交付方式：企业/内部签名分发，或开源构建 + 开发者模式侧载。
- 代价明确：覆盖不到普通用户；发布签名、审核相关项改为 E3 且**不再阻塞里程碑**。
- 切换成本低的原因：上面 A 组里除了"签名体系"和"包体"两项，其余（权限、隐私、开源合规、供应链）在任何分发方式下都是必需的，不浪费。

### 12.2 路线 A（G1 失败时全量重写）的必然后果（决策 2）

用户已定：**G1 失败 → 走 A，C 否决**。这个选择成立的前提是把下面三件事一并接受，否则"1:1"会变成一句无法验收的口号：

**① "1:1" 的定义降级为 L2，且必须补证明**
A 属于安全口径里的 **L2（功能等价、安全实现重写）**，按 AppSec 判定 **L2 不计入 1:1**，除非同时具备：
- 威胁模型（覆盖 SSH/KEX/AEAD/known_hosts/CredSSP 等已重写面）；
- 关键路径等价性证明（known_hosts fail-closed、证书 pin、传输根校验、审批门、保险库 AEAD）；
- 一次独立渗透测试。

→ 所以 A 路线的验收目标是 **T1 行为等价 + 安全等价证明**，不是"看起来一样"。

**② oracle 必须重建，约 280–425 人日**
原 oracle 是 Viva 专属（`headless.go` 硬绑桌面三平台 + `headless_drive.py` 驱动 Viva 行协议），A 路线下全部失效。可复用与需重建分开列：

| 资产 | A 路线下的状态 |
|---|---|
| `tools/e2esshd`（纯 Go 回环 SSH/SFTP/SCP 夹具） | ✅ **可继续用**，作协议对端 |
| `tools/fakes3`、`tools/live`（VNC/RDP 容器） | ✅ 可用 |
| 82 个 `tools/e2e/*.txt`（文案点击驱动） | ⚠️ 改写为**行为规格** + ArkTS uitest（hypium）场景 |
| 828 个 Go 测试文件 / 177,285 行 | ❌ 不能在 ArkTS 跑；降级为**规格来源**与交叉参考 |
| `docs/performance-audit.md` 基线 | ❌ 设备/语言全变，作废，需重新标定 |

**③ 永久分叉，跟版成本转人工**
D1 的"改动 upstream 文件数 = 0"优势消失。缓解：按季度对齐一次上游 release notes + `docs/` 逐版本变更，人工判定是否移植。

**工期修正（与 §2 表格一致，勿混用）**
- 建设：55–70 人月；oracle 重建：280–425 人日 ≈ 13–20 人月 → **合计约 70–90 人月**。
- 6 人队：纯建设约 15–18 月；含 2–3 轮修订与验收 → **24–36 月**。
- 分期调整：在 M1 之前插入 **M0.5「oracle harness」（2–3 月）**——uitest 骨架 + 协议对端接线 + 先跑通 10 个场景。**没有 M0.5 不得进 M1**，否则后面所有"等价"都无据。

> 一句话总结这两条决策的组合效果：**"可上架"按标准建但不强求，"G1 失败就走 A"但必须连带接受 oracle 重建与安全等价证明的账单。** 两者都不改变 Phase 0 的先行顺序——先把 G1 测出来。

### 12.3 平板 1:1：真实差距与增量成本（决策 4）

**先确认用户判断中成立的部分。** 在鸿蒙上，PC 与平板是**同一份代码、同一个 HAP、同一个 `deviceTypes: ["2in1","tablet"]`**，不存在"再写一个平板版"。所以"平板基本一样、几乎不需要重写多少"这个判断是**对的**——增量是**适配层与双画像验收**，不是重写。

**真实差距只有 3 类，且都不是功能缺失：**

| 差距 | PC 范式 | 平板范式 | 归属 |
|---|---|---|---|
| 指针 | hover 悬停、右键菜单、滚轮、精确光标 | 无 hover；长按承担右键语义；双指滚动；触点精度低 | **T2 输入映射** |
| 窗口 | 自由窗口、多窗口、跨窗口移动标签 | 单窗口为主 + 分屏 / 平行视界 / 悬浮窗 | **T2 窗口映射** |
| 外壳 | 托盘 / 状态区 | 服务卡片 + 通知 | **T2 外壳映射** |

**一个显著收敛因素（支持你的判断）**：平板常配磁吸键盘 + 触控板（如 HUAWEI Smart Magnetic Keyboard）。一旦有触控板，指针 hover、滚轮、右键（双指轻点）、修饰键**全部可得**，平板与 PC 的输入差距基本消失。
→ 因此设计上应当 **按"有没有指针设备"切换交互范式，而不是按 `deviceType` 硬编码**。这一条能省掉大量分支，也让"一套 UI 服务两种形态"真正成立。

**必须提前定稿的 3–4 处交互冲突：**

| 冲突 | 说明 | 建议裁决 |
|---|---|---|
| 长按 = 文本选择 vs 长按 = 右键 | 终端里长按是选字惯用手势，平板把长按当右键 | 终端区域内长按=选择；上下文菜单改为**选择后浮动菜单 / 双指长按**；工具栏与列表区域长按=菜单 |
| hover-only 提示 | 工具栏图标 hover 显示名称、垂直标签栏 hover 展开 | 触控形态改为**常显**或轻点展开，不能依赖 hover |
| 滚轮 = 回滚 vs 双指滑动 | 终端滚动敏感性不同 | 双指滑动映射为滚轮回滚，速度曲线单独标定 |
| 跨窗口移动标签 | PC 拖到另一窗口；平板无多窗口拖拽 | 平板用分屏内移动 / 悬浮窗切换实现，功能不缺 |

这些冲突必须在 **M1 之前定稿**，否则后期改交互要连带返工验收。

**增量成本（D1 路线，在 §2 的 15–23 人月之外）：**

| 项 | 人月 |
|---|---|
| 输入归一化层（指针/触控/键盘/触控板能力检测与事件抽象） | 1.5–3 |
| 窗口与多任务适配（分屏、平行视界、悬浮窗、尺寸断点） | 1–2 |
| 布局与触控可达性（tap target、hover 提示可见化） | 1–1.5 |
| 软键盘 IME 与物理键盘双通道 | 0.5–1 |
| 第二份验收矩阵 + 触控自动化用例 | 1–1.5 |
| **合计** | **约 4–9 人月** |

A 路线下增量更小（约 3–6 人月）：UI 本来要重写，只是"一套 UI 同时支持两种输入"，不存在二次实现。

**三条设计约束（写进 M1 准入条件）：**
1. **禁止 PC-first**：任何交互从第一版就要在 2560×1600 触控画像下走通；不允许"先做 PC，平板以后适配"。
2. **运行时切换优先于 `deviceType`，也优先于"启动时检测一次"**：同一台设备可能同时有触控与指针（鸿蒙 PC 本身就是触屏 + 触控板），交互范式必须按**最近一次输入源**即时切换，而不是开屏时猜一次。
3. **双画像同时验收**：每期在 `2in1` 与 `tablet` 两个模拟器画像上各跑一遍，截图并列存档（对应 §11.3 的 E1）。

**模拟器可验证范围**：`tablet` 画像 2560×1600 @360dpi 可验单指触控、长按、双指（`devecocli` 提供 `emulator shake/power/rotate/fold/battery/sensor/geolocation` 注入）；分屏/平行视界需实测该镜像是否放开；**触控板与磁吸键盘无法在模拟器验证 → E3，需真机**。

---

## 13. D1 的实测基准（Viva 已检出，@`95802a9`）

初稿里"D1 的 6–12 人月后端"是**推断**（当时本机无 `../viva`，无法测量）。现在 Viva 已克隆到 `E:\viva`，下面换成**实测数字**。

### 13.1 Viva 不是小框架

| 项 | 实测 |
|---|---|
| Viva 规模 | **1,608 个 .go / 277,507 行**（与 Motty 的 413,844 行同一量级） |
| 许可证 | Apache-2.0（**本机 `E:\viva\LICENSE` 已核**，不再依赖线上抓取） |
| 平台后端位置 | `internal/platform/<os>/`（不是 `app/backend_*.go`，那些只是 9–10 行的 build-tag 壳） |

**各 OS 后端的生产代码行数（去掉测试）：**

| OS 后端 | 文件 | 生产行数 | 测试行数 |
|---|---|---|---|
| linux | 89 | **24,203** | 11,607 |
| windows | 65 | 13,152 | 7,174 |
| web | 24 | 5,736 | 2,068 |
| darwin | 27 | 4,194 | 3,781 |

→ **给 OHOS 新写一个后端，是 1.2 万–2.4 万行量级的新平台代码**。按平台集成类工作 1,500–2,500 行/人月估算 → **约 6–12 人月**，与架构员原判一致；因为 OHOS 是陌生 OS，实际应取**上半区**。

### 13.2 一个显著有利的发现：Viva 走 Vulkan，而 OHOS 提供 Vulkan

- Linux 后端的渲染核心是 **Vulkan**：`vulkan_linux.go`(1,431) + `vulkan_text_linux.go`(980) + `vulkan_scene_linux.go`(518) + `vulkan_frame/hotpath/probe/...`，合计 **3,364 行**。
- OHOS NDK 同时提供 Vulkan 与 EGL/GLES（见 §1.2 的 `native/` 目录）。
- 推论：**渲染核心大概率可以近乎原样复用**，真正的适配面收敛为「**surface / swapchain 创建（XComponent → OHOS NativeWindow）+ 输入 + IME + 系统集成**」。这一条既提高了 D1 的可行性，也解释了它为什么比 B 便宜。

### 13.3 可裁剪面（首版最小可用后端的范围）

Linux 后端里下面这些**首版可以不做**，合计约 7,000 行，这正好解释"上限 24k 行"与"下限 12k 行"的差距：

| 可裁剪 | 约行数 | 理由 |
|---|---|---|
| `xcb_linux.go` / `scale_x11_linux.go` / `gtk_wayland*` | ≈1,400 | OHOS 无 X11/Wayland |
| GTK 路径（`gtk_*.go` 十多个文件） | ≈3,000 | OHOS 用原生 NativeWindow，不需要 GTK |
| 无障碍 `atspi_*.go` | ≈1,800 | 首版可后置（上架不宜永久缺，见 §12.1） |
| `status_item_linux.go`（托盘） | 664 | 平板无托盘；PC 侧用服务卡片/通知替代（§12.3） |
| `secret_linux.go` | 357 | 换 HUKS/Asset Store |

### 13.4 还有一个反向证据：Viva 自带文本引擎

`text_linux.go`(391) + `vulkan_text_linux.go`(980) + `internal/uniprops`(2,272 行的 Unicode 属性表) 说明 **Viva 自己做字形整形与文本布局**，不依赖系统控件。
→ 这既意味着 D1 能逼近"像素级一致"（同一套整形管线），也意味着**它绕开了 ArkUI 的字形差异**——这正是 D1 与 B 在"1:1"上的本质区别。
→ 代价：OHOS 上的字体获取需要自己接（`fonts_linux.go`(98) + `font_register_linux.go`(94) 是参照物），属可估工作。

### 13.5 结论（更新后仍不变）

- D1 的 **6–12 人月后端估算被实测支持**，总量 **15–23 人月（含缓冲与返工）维持不变**。
- 风险结构有所改善：**渲染不是最大未知（Vulkan 可复用），最大未知变成 surface 与 IME 的 OS 侧行为**——这正好是 G1/G3 要测的东西，再印证"先测后写"。
- 反向约束：Viva 自身 277k 行、4 个后端，意味着**自维护 Viva 分支（D1-fork）不是小成本**，若上游不接纳 OHOS 后端，需把 +3–5 人月修正为 **+5–8 人月**。


---

## 14. 触控是两形态的共同需求（2026-11-10 修正，覆盖 §12.3 的"平板专属"假设）

用户指出：**鸿蒙 PC 本身也是触屏设备**。这条修正了 §12.3 的一个隐含错误——它把触控当成平板专属的 T2 差距。事实上**触控对 PC 同样是必须项**，因此：

### 14.1 直接后果：触控成本从"平板增量"变"公共成本"

§12.3 的增量表里"输入归一化层 1.5–3 人月"应**移出平板增量、计入公共建设**。于是平板真正专属的增量只剩：
- 窗口形态差异（分屏 / 平行视界 / 悬浮窗 vs 自由窗口多窗口）：1–2 人月
- 无外接键盘的场景（软键盘路径，PC 触屏也可能不接键盘）：0.5–1 人月
- 第二份验收矩阵（双画像）：1–1.5 人月
→ 平板专属增量由 **4–9 人月下修为约 2.5–4.5 人月**；触控相关的 1.5–3 人月上移为两形态共同成本。

这进一步支持"平板与 PC 基本一样、几乎不用多写"的判断。

### 14.2 但触控撞在了一个框架边界上（实测证据）

**Viva 的指针模型是纯鼠标语义**（`E:\viva\gfx\input.go:70-118`，实测）：

| 项 | 内容 |
|---|---|
| `PointerEventKind` | 只有 `PointerDown / PointerMove / PointerUp / PointerExit` 四个相位 |
| `PointerButton` | 只有 None/Primary/Secondary/Middle/Back/Forward |
| 缺少 | **没有触摸来源标识、没有多点触控、没有压力、没有 hover 之外的悬停态** |

而 Motty 侧**有 91 个文件出现 hover**（`internal/workbench`，实测），其中包含真正的 hover-only 可用性：AI 回答悬停才显示复制按钮与 token 用量（`ai_actions_test.go:13` 的用例名即是 `...ShowsCopyOnHover...`）、工具栏图标 hover 显示名称、垂直标签栏悬停展开。

**推论（重要）**：在 D1（"Motty 零改动"）下，纯触控时只有两条路让这些 hover-only 入口可达：
- 后端**合成 hover**：把触点持续当作 hover 位置（抬手后保留一小段时间）。可行、零 Motty 改动，但"点哪显哪"，体验不等于鼠标；
- 或**改 Motty** 把这些提示改为常显/长按触发。改动量不大（真正 hover-only 的入口需枚举，量级估计 10–30 处），但**破坏"upstream diff = 0"**，并带来跟版冲突成本。

### 14.3 三个选项与建议

| 选项 | 做法 | Motty 改动 | Viva 改动 | 触控体验 | 跟版成本 |
|---|---|---|---|---|---|
| A | Viva 后端合成 hover（触点=hover） | 0 | 后端内 | 打折（可用但不如鼠标） | 0 |
| B | 枚举并改造 Motty 的 hover-only 入口 | 10–30 处 | 0 | 好 | 有冲突，需每次合并 |
| **C（建议）** | **A 打底 + B 只改高频入口**（AI 复制按钮、标签展开） | 少量 | 少量（事件模型加 `Touch` 来源） | 接近原生 | 可控 |

**建议 C 的理由**：A 单独用会让"悬停才出现的关键按钮"在纯触控下变得不可发现（这是可用性缺陷，不是 1:1）；B 全量改则把跟版成本永久化。C 用最小改动覆盖高频路径，其余靠合成 hover 兜底。

**若要多指手势**（捏合缩放等）：Viva 事件模型**没有多点表示**，必须扩展（新增 touch 来源 + 多指路径），属 Viva fork 面扩大的动作。建议**首版不做**，在能力矩阵里记为 T3 并在文档写明（终端场景用双指滚动映射为滚轮即可，捏合缩放不是终端刚需）。

### 14.4 对工期与验收的影响

- D1 总量：**维持 15–23 人月**（触控公共成本 1.5–3 已在内；平板增量下修 1.5–4.5）。
- 新增验收项（两形态都要跑）：**纯触控可完成核心路径**——新建连接、输入命令、切标签、打开文件面板、执行一次 AI 复制。这条比"有没有 hover"更能反映 1:1。
- 模拟器可验：2in1 与 tablet 两个画像都支持触控注入；**触控板/磁吸键盘仍不可验（E3）**。
- 新增风险 **R34**：Viva 指针模型无 touch 来源与多点 → 纯触控下 hover-only 入口不可达；缓解见 §14.3 选项 C；验证方法为"断开指针设备后完成核心路径"的手动用例。
---

## 15. G1 实测结果（2026-11-10，鸿蒙模拟器 2in1 / API 26 / x86_64）

第一次真实执行 G1。结论**部分通过、关键部分失败**，且失败点足以改变路线判断。

### 15.1 环境（已跑通）

| 项 | 实测 |
|---|---|
| 模拟器实例 | `motty_pc`（2in1，deviceModel `PCEMU-FD00`，3120×2080 @304dpi，4 核） |
| 设备架构 | **`uname -m` = `x86_64`**、设备配置 `hw.cpu.arch: x86_64`（§11 的推断被设备确认） |
| 加速 | `Windows Hypervisor Platform accelerator is operational`（WHPX 生效） |
| 连接 | `hdc tconn 127.0.0.1:10100` → `Connected` |
| 镜像 | HarmonyOS 7.0.0(26.0.0) / 2in1，2.38 GB |
| Go | go1.27.3 windows/amd64 |
| 坑（已记） | `getprop` 在 OHOS 上**不存在**，用 `param get <key>`；虚拟设备名**不能含连字符**（`motty-pc` 失败，`motty_pc` 成功）；NDK 的 `*-ohos-clang` 是 **sh 脚本**，Windows 上要直接用 `clang.exe -target … --sysroot=… -D__MUSL__`；路径含空格会截断 cgo 的 `CC`，用 `C:\ohos-ndk` junction 规避 |

### 15.2 G1a：`go tool dist list` 无 `ohos`

实测为空 → 确认**无官方 `GOOS=ohos`**。只能走 `GOOS=linux` + NDK musl 工具链。

### 15.3 第 1 级：纯 Go 静态二进制 —— ✅ **PASS**

`CGO_ENABLED=0 GOOS=linux GOARCH=amd64` 构建（2.5 MB），`hdc file send` 后在设备上直接执行：

```
goos: linux  goarch: amd64  goversion: go1.27.3  numcpu: 4
proc status: OK (1077 bytes)      ← /proc/self/status 可读
tmpfile   : OK                    ← 沙箱外可写
sched     : OK (8 goroutines + timers)
result    : PASS
```

**意义**：Go runtime 与 OHOS 内核 ABI 兼容，goroutine/定时器/`/proc`/文件写入全部正常。**arm64 同源二进制也编译成功**（2.28 MB，仅编译未执行）。
**边界**：`hdc shell` 在应用沙箱**之外**，这一级不证明应用内可用。

### 15.4 第 2 级：c-shared 共享库 —— 构建成功，**加载失败（两种方式都失败）**

**构建 ✅**：`-buildmode=c-shared` + NDK `clang.exe` 产出 `libmottycore.so`（3.16 MB），`llvm-readelf` 显示 `ELF64 / DYN / x86_64`，`DT_NEEDED` 只有 **`libc.so`**（干净的 musl 依赖），导出 `MottyAdd / MottyProbe / MottyVersion`。

**加载方式 A（dlopen，运行时动态加载）❌**
```
dlopen : FAIL Error relocating libmottycore.so: pthread_attr_destroy:
         initial-exec TLS resolves to dynamic definition in libmottycore.so
```
这是 **musl 的已知限制**：musl 不支持 dlopen 一个带 static TLS（initial-exec）定义的库。试过 `CGO_CFLAGS=-ftls-model=global-dynamic` 重建 → **同样报错**（TLS 定义不在 cgo 生成代码里，改这个开关无效）。

**加载方式 B（链接期依赖，`DT_NEEDED`）❌**
```
Signal 11
```
即作为启动期依赖加载时，Go 运行时初始化直接 **SIGSEGV**。合理推断是 Go runtime 在 musl 进程里自建 TLS（`arch_prctl(ARCH_SET_FS)`）与 musl 自己的静态 TLS 冲突。

**这个方法学很重要**：`-buildmode=c-shared` 能"编出来"并**不**代表能"加载起来"。只看编译成功会得出完全错误的结论。

### 15.5 这对路线意味着什么（必须正视）

D1 与 B **都要求 Go 运行在应用进程内**（D1 = Viva 是 Go；B = Go 内核经 NAPI）。而 OHOS 应用的 native 库就是被 ArkTS 运行时 **dlopen** 的 —— 正好命中方式 A 的失败。

因此当前判断（**待证，不是定论**）：

| 路线 | 状态 |
|---|---|
| **D1**（Viva + OHOS 后端） | ⚠️ **同样受此阻断**（Viva 也是 Go 库），此前"15–23 人月、真 1:1"的前提被打掉 |
| **B**（Go 内核 + NAPI） | ⚠️ **受阻断** |
| **B′**（Go 作为**子进程**，ArkTS 经 pipe/socket 通信） | 🟡 **唯一可能救回 Go 内核的路线** —— 因为它回到"Go 自己当 main 进程"（第 1 级已 PASS），只需沙箱允许 fork/exec 自带二进制（原 U-04，现升级为**决定性前置**） |
| **A**（全量 ArkTS 重写） | ✅ 不受影响；用户已定为失败回落 |

### 15.6 下一步（按顺序，先便宜的）

1. **B′ 可行性（最高优先，1–2 天）**：在真 HAP 内用 native `posix_spawn` 启动一个随包分发的静态 Go 二进制，验证沙箱是否允许。**这决定 Go 内核还能不能救。**
2. **Go-as-library 的缓解尝试（时间盒 1 周，与 1 并行）**：
   - `-buildmode=c-archive` 静态链进 NAPI `.so`（TLS 定义随之进入被 dlopen 的对象，**仍需实测**，不能假设有效）；
   - 试 Go 1.26（与 `go.mod` 对齐）而非 1.27.3；
   - 链接加 `-Wl,-z,nodelete`；确认 OHOS 侧 musl 是否有 static TLS surplus 配置。
3. **arm64 同类验证**：x86_64 失败不必然等于 arm64 失败（musl 版本/TLS 布局可能不同），但**没有真机就无法执行**，只能记为 E2。
4. 若 1 失败且 2 全部失败 → **按已定决策转 A**，并把"Go 内核复活"列为一个独立研究项（不阻塞 A 的交付）。

> **要写下的一句话**：G1 的"第 1 级 PASS"证明了 Go 能在鸿蒙上跑，但"第 2 级双失败"证明了**它不能在鸿蒙应用进程里以共享库形态跑**。这两句必须一起说，单独说任何一句都是误导。
---

## 16. G1 终局：Go 在鸿蒙应用内不可用（2026-11-10 实测判定）

§15 之后补做了 B′（子进程方案）的决定性实验。结论明确：**Go 无法在鸿蒙应用沙箱内运行，无论作为共享库还是子进程。**

### 16.1 B′ 实验：沙箱内 `posix_spawn`

真 HAP（`com.motty.bprime`，API 26，2in1+tablet，NAPI C++ + 签名）在模拟器上安装并运行，三条候选路径全部失败：

| 候选 | 实测 | 说明 |
|---|---|---|
| 私有数据目录（`/data/storage/el2/base/haps/entry/files/go-probe`） | `stat: mode=0100755` → **`posix_spawn rc=13 EACCES`** | **权限位正确、目录可写、仍被拒绝** |
| native 库目录伪装成 `.so`（`/data/storage/el1/bundle/libs/x86_64/libgoprobe.so`） | `stat: mode=0100644` + `chmod: Permission denied` → `EACCES` | 安装时被 **hvigor `DoNativeStrip` 改写**（2,511,886 → 1,626,912 字节），且执行位被清掉；bundle 目录只读，改不回来 |
| 链接期依赖 / dlopen（§15） | TLS 重定位失败 / SIGSEGV | 见 §15.4 |

**关键判读**：文件是 0755、在应用自己的可写目录里、由应用自己 spawn —— 依然 `EACCES`。这不是权限位问题，是**策略层禁止应用执行随包分发的 ELF**（SELinux/seccomp 域限制）。

### 16.2 综合判定表

| 形态 | 结果 | 证据 |
|---|---|---|
| Go 静态二进制，**由 shell 用户**执行 | ✅ PASS | §15.3 |
| Go 静态二进制，**由应用** spawn | ❌ EACCES | §16.1 |
| Go `c-shared`，**dlopen** | ❌ musl initial-exec TLS | §15.4 |
| Go `c-shared`，**启动期依赖** | ❌ SIGSEGV | §15.4 |
| **NAPI C/C++ `.so` 在应用内** | ✅ **可加载可执行** | 本次探针 `libbprobe.so` 正常工作；`posix_spawn` 调用本身被正确执行并返回错误码 |

### 16.3 于是

- **D1 ❌**：Viva 是 Go，无法进应用进程。
- **B ❌**：Go 内核走 NAPI，无法进应用进程。
- **B′ ❌**：子进程也被策略禁止。
- **A ✅**：不受影响，**按用户既有决策，这就是最终路线**（G1 失败 → 全量重写）。

### 16.4 一个重要的路线改良：A′ = ArkTS UI + **C/C++ 协议库（NAPI）**

本次实验顺带证明了一件正面的事：**NAPI C/C++ `.so` 在应用内完全可用**。因此 A 不必把 SSH/加密/RDP 用 ArkTS 手写：

- UI / 状态机 / 交互：ArkTS + ArkUI
- SSH、SFTP、加密、RDP、VNC 协议：**用成熟的 C 库**（OpenHarmony 三方库框架 tpc_c_cplusplus / Lycium 已有 openssl、zlib、libssh2、openssh 的 HPKBUILD 配方），经 NAPI 暴露给 ArkTS

这直接缓解了安全工程师最担心的问题（"手写 SSH/KEX/AEAD/CredSSP = 由构造决定的安全回归"）：**安全关键路径继续跑审计过的 C 实现，而不是新写的 ArkTS**。
代价：C 依赖带来 SBOM/漏洞跟踪义务（R23 已列），以及 NAPI 边界仍需 capability 化（SEC-01 不变）。

**A′ 与 A 的差别是"协议层谁来写"，不是"要不要重写 UI"。** 建议正式采用 A′ 作为 A 的落地形态。

### 16.5 仍需诚实标注的边界

- 全部实验在 **x86_64 模拟器**上完成。真机（arm64）上"禁止应用执行随包 ELF"的策略**极可能相同**（这是安全基线，不是架构差异），但**未在真机验证** → 记 E2/E3。
- `posix_spawn` 的 EACCES 未被进一步归因到具体策略条目（SELinux denial 明细需 `audit` 或内核日志，本次未取）。
- 未穷举 B′ 的替代通道（如 through binder/服务化、`OH_Ability` 提供的进程模型、或把协议核心做成独立 ExtensionAbility 进程）——若将来要复活 Go，这些是研究入口，但**不阻塞 A**。

### 16.6 对工期与验收的影响（最终）

| 项 | 值 |
|---|---|
| 路线 | **A′**（ArkTS UI + C/C++ 协议库） |
| 建设 | 55–70 人月（UI 与状态机为主）+ oracle 重建 13–20 人月 ≈ **70–90 人月** |
| 6 人队 | 纯建设 15–18 月；含 2–3 轮修订与验收 **24–36 月** |
| 前置 | **M0.5 oracle harness（2–3 月）**，没有它不得进 M1 |
| "1:1" 口径 | **L2**：T1 行为等价 + 安全等价证明（威胁模型 + 关键路径等价性 + 渗透测试） |
| 跟版 | 永久分叉，按季度对齐 upstream release notes |
---

## 17. 路线定案：A′（2026-11-10 确认）

用户已确认 **A′**：ArkTS/ArkUI 重写视图与工作流 + C/C++ 协议库经 NAPI。

- **取代** §2 的 D1 / B / B′ 分支结论（Go 路线因 §15/§16 的实测证据全部作废）。
- 详细落地见 **[A-PRIME-ENGINEERING.md](./A-PRIME-ENGINEERING.md)**：分层、C 依赖映射（逐包）、M0.5 oracle harness、前 4 个月 sprint 计划、两个待决项。
- C 依赖的两个要点同步记入风险：**R35**（LibVNC 为 GPL-2.0，与闭源分发冲突 → 建议自写 VNC）；**R36**（C 依赖引入后 govulncheck 不覆盖，需 SBOM + CVE 比对）。
- 工期口径不变：建设 55–70 人月 + oracle 13–20 人月 ≈ **70–90 人月**；M0.5 为 M1 硬前置。
---

## 18. G5 基线已达成（2026-11-10）

M0.5 里"原版参照实现"这一步的**硬前置已解除**。

| 项 | 实测 |
|---|---|
| `go build ./...` | **exit 0**（日志为空） |
| `go build -o motty-baseline.exe ./cmd/motty` | **exit 0**，产物 **52.6 MB**（未剥离；与 `performance-audit.md` 的"30 MB、剥 21 MB"一致） |
| Go | go1.27.3（`go.mod` 要求 1.26，新工具链向下兼容，已实测可编） |
| Viva | `E:\viva` @`95802a9`，其 `go.mod` 亦为 `go 1.26` |
| 模块缓存 | 首次构建已拉齐全部依赖（modernc.org/sqlite、x/crypto、pkg/sftp 等） |

**一个需要记住的判读陷阱**：第一次构建被报 `exit code 1`，实际是 **PowerShell 把 `go` 写到 stderr 的下载进度当作错误记录**。改用 `cmd /c "... > log 2>&1"` 重跑后 `exit=0` 且日志为空。
→ 这是本次会话第二次踩同一个坑（viva 的 `git clone` 也是），已作为方法论记下：**在 PowerShell 里判断外部命令成败，不能只看 exit code，必须把 stdout/stderr 落到文件再判读**。

**对 M0.5 的意义**（对应 [A-PRIME-ENGINEERING.md](./A-PRIME-ENGINEERING.md) §3.1 ②）：
- 原版 Motty 可以在本机构建 → **轨迹 oracle 具备源头**（同一次交互在 Go 客户端与 ArkTS 客户端上分别采集，做协议级逐字节对比）。
- 下一步待验：`-tags vivahead` 无头构建 + `tools/headless_drive.py` 驱动（需 python3，本机是否可用见下方探测结果）。