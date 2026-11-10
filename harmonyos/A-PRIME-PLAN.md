# A′ 执行方案：ArkTS UI + C/C++ 协议库（经 NAPI）

> 决策已确认（2026-11-10）：路线 **A′**。本文是它的落地形态：分层、C 依赖映射、M0.5 oracle harness、第一阶段可执行计划。
> 前置结论见 [PLAN.md](./PLAN.md) §15/§16：Go 在鸿蒙应用内**不可用**（c-shared 双失败、子进程 EACCES），而 **NAPI C/C++ `.so` 可用**（已实测）。

---

## 1. A′ 是什么，不是什么

**是**：把 Motty 的**视图与工作流**用 ArkTS/ArkUI 重写，把**协议与密码学**换成经审计的 C 库，两者由 NAPI 连接。

**不是**：不是"把 Go 翻译成 ArkTS"。协议层不手写。

```
┌──────────────────────────────────────────────────────────────┐
│ ArkTS / ArkUI        UI、标签/分屏、终端网格渲染、对话框、i18n   │
├──────────────────────────────────────────────────────────────┤
│ 领域层（ArkTS）       会话状态机、命令面板、审批门、风险分级       │
│                      策略判定（allow/ask/block）必须在此层显式实现 │
├──────────────────────────────────────────────────────────────┤
│ NAPI 能力层（C++）    按会话句柄授权的窄接口；无通用 exec/eval     │
├──────────────────────────────────────────────────────────────┤
│ 协议库（C/C++）       libssh2 / OpenSSL / libargon2 / FreeRDP …  │
├──────────────────────────────────────────────────────────────┤
│ 平台适配（ArkTS Kit） socket、huks、asset、filePicker、pasteboard│
│                      inputMethod、backgroundTask、window        │
└──────────────────────────────────────────────────────────────┘
```

**为什么这样分**：安全评审的核心担忧是"手写 SSH/KEX/AEAD/CredSSP = 由构造决定的安全回归"。A′ 让这些继续跑审计过的 C 实现，把"重写"限制在 UI 与状态机（这些本来就没有密码学正确性问题）。

---

## 2. C 依赖映射表

从 Motty 的 Go 包出发，逐条给出 A′ 的落点。**"工作量"仅指 A′ 下新增的胶水/适配，不含 C 库本身。**

### 2.1 直采成熟 C 库

| Motty 包 | 行数 | A′ 落点 | 许可 | 注意 |
|---|---|---|---|---|
| `internal/sshconn` | 10,384 | **libssh2**（会话/认证/kbdint/direct-tcpip） | BSD-3 | 跳板链需自己串多会话；`@cert-authority`、OpenSSH 用户证书支持弱于 OpenSSH，需补 hostkey 回调解析；agent 转发用 `libssh2_agent_*` |
| `internal/sftpclient` | 8,136 | **libssh2 SFTP** | BSD-3 | 原子重命名/续传/权限需在 ArkTS 侧编排（逻辑可照搬 Go 版语义）；无并发管道时性能受限 |
| `internal/scpclient` | 1,537 | SCP over libssh2 exec channel | BSD-3 | 无 SFTP 子系统的回退路径，协议简单 |
| `internal/rfb` | 3,981 | **LibVNC / libvncclient** | GPL-2.0 ⚠️ | **许可风险**：GPL 与闭源分发冲突。备选：自己实现 RFB（Hextile/ZRLE/Raw 只 ~1.5k 行 C），或找 BSD 许可的 `libvncserver/LibVNC` 之外的实现 |
| `internal/rdpcore` | 38,410 | **FreeRDP** | Apache-2.0 | 比 Motty 的 MIT fork 更完整（NLA/CredSSP）；但 API 复杂，需要一层薄封装；证书 pin 用 `freerdp` 的 verify 回调 |
| `internal/vault` / `backup` / `ppk` | ~5,000 | **OpenSSL**（AES-256-GCM、HMAC）+ **libargon2**（Argon2id） | Apache-2.0 / CC0 | 保险库格式要与原版**字节兼容**才能导入 `.mottybak`/`.ppk` → 必须写兼容性夹具 |
| `internal/otp`、`hostkey`、`knownhosts` | ~3,000 | OpenSSL（HMAC-SHA1/256、指纹） | Apache-2.0 | known_hosts 文件格式要逐字节兼容（含 `@cert-authority` 行） |
| `internal/portforward` | 1,824 | libssh2 direct-tcpip + ArkTS `@ohos.net.socket` | BSD-3 | SOCKS5/HTTP CONNECT 是纯逻辑，ArkTS 可写；只绑 loopback |
| `internal/zmodem`/`xymodem` | 1,751 | 纯逻辑，ArkTS 重写 | — | 1.7k 行、协议简单、无密码学 |
| `internal/i18n` | 12,249 | 由 Go 结构体**机械生成** ArkTS 资源 | — | 约 2,580 叶串 × 3 语言；生成脚本一次投入 |

### 2.2 用鸿蒙 Kit 替代（不引入 C）

| Motty 包 | A′ 落点 | 说明 |
|---|---|---|
| `modernc.org/sqlite` + `configstore` | **ArkTS `@ohos.data.relationalStore`** | 免去 C sqlite；注意 schema 迁移与 epoch 23 兼容 |
| `internal/workbench` 状态持久化 | `@ohos.data.preferences` | 轻量键值，不写 C |
| 密钥存储（Viva `app.*Secret`） | **HUKS / Asset Store** | §PLAN 12.1；拒绝时不回退文件 |
| 文件对话框 / URI | `@ohos.file.picker` + `persistPermission` | |
| 剪贴板 | `@ohos.pasteboard` | OSC52 默认 ask（R13） |
| 后台长时任务 | `@ohos.resourceschedule.backgroundTaskManager` | 不伪造类型（R08） |
| 窗口/分屏/悬浮窗 | `@ohos.window` + `supportWindowMode` | 双形态 1:1（PLAN §12.3） |
| `internal/ai` 网络层 | ArkTS `@ohos.net.http` / `webSocket` | 脱敏、token 预算、审批门在 ArkTS 重实现，必须有等价夹具 |
| MCP server | ArkTS `@ohos.net.socket`（loopback + bearer） | Host/Origin/常量时间比较三条不变量必须保留 |

### 2.3 必须重写的（无 C 库可替）

| 模块 | 行数 | 说明 | 风险 |
|---|---|---|---|
| 终端模拟器 `internal/term` | 11,207 | libvterm 只覆盖基础 VT；Motty 的 **kitty 键盘协议、iTerm2/Kitty/SIXEL 图片、DECSET 2026、连字网格** 都超出 libvterm | **最高风险项**：这是"终端产品力"的核心，建议以 libvterm 为骨架 + 自有扩展，预留最多工时 |
| `internal/workbench` | 131,012 | 全部 ArkTS 重写 | 已知主导工期 |
| `internal/sessionlog`/`completion`/`fuzzy`/`monitor` 等 | ~15,000 | 纯逻辑，ArkTS 重写 | 低 |

### 2.4 许可与合规（新增阻断项）

- **LibVNC 是 GPL-2.0**：若上架要求闭源分发，**不能用**。→ 决议：VNC 自己用 C 实现（Raw/CopyRect/RRE/Hextile/ZRLE ≈1.5–2k 行），或改用 zlib/libssh2 已有依赖拼装。
- FreeRDP Apache-2.0、libssh2 BSD-3、OpenSSL Apache-2.0、libargon2 CC0 —— 均可闭源分发，需进 `THIRD_PARTY_NOTICES` 与 SBOM。
- 引入 C 依赖后，**govulncheck 不覆盖 C**，需改用 SBOM + CVE 比对（R23 升级）。

---

## 3. M0.5：oracle harness（2–3 月，M1 的硬前置）

**目的**：把"1:1"从口号变成机器判定。**没有 M0.5 不得进 M1。**

### 3.1 四个部件

**① 协议对端（沿用，不改）**
`tools/e2esshd`（纯 Go，仓库内已有）、`tools/fakes3`、`tools/live`（VNC/RDP 容器）。
→ 在 **Windows 宿主机**跑（Go 工具链已装），作为 ArkTS 客户端的对端。**这部分资产 100% 可复用**。

**② 原版参照实现（新增，现在才可能）**
本机已有 Go 1.27.3 + `E:\viva`，因此**可以构建原版 Motty** 作为参照：
- 采集**线上轨迹**：同一会话在 Go 客户端与 ArkTS 客户端上分别跑，记录 SSH/SFTP 帧序列与关键状态（屏幕网格快照、文件列表、转发端口行为）。
- 用途：协议层 T1 的**逐字节等价**证据（比"看起来对"强得多）。
- 约束：原版只是 oracle，**不进入交付物**；构建环境与产物不入库。

**③ 行为规格（从 82 个 e2e 转出）**
`tools/e2e/*.txt`（82 个）当前是按**本地化文案点击**的文本脚本 → 转换为机器可读规格：

```yaml
# spec/terminal-protocols.yaml（示意）
id: terminal_protocols
preconditions: [e2esshd running, host fixture loaded]
steps:
  - {action: launch, target: 2in1}
  - {action: connect, host: fixture-1}
  - {action: send, text: "printf '\\e[6n'"}
assert: {screen_regex: "\\[1;1R", timeout_ms: 5000}
evidence: {png: true, tree_dump: true, limits: "simulator, x86_64"}
```

产出：`spec/*.yaml` + 一个把 spec 编译成 **Hypium/uitest** 用例的 runner。**每个 spec 必须带 `evidence.limits`**（沿用项目原生证据范式：PNG + 命令结果表 + Limits）。

**④ Capability 注册表（T2/T3 的执行机制）**
机器可读文件 `capabilities.json`，每条能力声明 `{id, level: T1|T2|T3, evidence: E1|E2|E3, fallback, user_facing_text}`。
- UI 用它决定是否渲染入口（**避免"隐藏按钮"和"NAPI 仍可执行"的漂移**）；
- 测试用它断言"T3 项无 UI 入口"；
- 报告用它自动生成"本次覆盖了哪些 E1"。

### 3.2 M0.5 验收门（可直接判定）

| 门 | 判定 |
|---|---|
| M0.5-a | 原版 Motty 在 Windows 上构建并跑通 ≥10 个 headless e2e；记录**已知失败清单**（HEAD 上 `localshell`、`remotetools` 本就失败，R20） |
| M0.5-b | `tools/e2esshd` 对端在宿主机起停可控；ArkTS 侧能建立一条真实 SSH 会话（哪怕只 `echo`） |
| M0.5-c | 82 个 e2e 全部转成 `spec/*.yaml`，字段完整；至少 **10 个** 能在模拟器上跑通并产出 PNG + 断言日志 |
| M0.5-d | 轨迹对比工具能对"同一次交互"输出 Go 侧与 ArkTS 侧的差异报告（含帧序列 diff） |
| M0.5-e | `capabilities.json` 覆盖能力矩阵全部条目，且 CI 能断言 T3 项零 UI 入口 |

> M0.5 的产物是**测试基础设施**，不是产品功能。它让后面 24–36 个月的每一期都有据可依。

---

## 4. 第一阶段可执行计划（M0.5 + P0，前 4 个月）

### Sprint 1（第 1–2 周）环境与骨架
- [ ] 复用 `harmonyos/spike/bprime` 的 HAP 骨架（NAPI + 签名 + 双 ABI 配置已验证）
- [ ] 仓库结构：`ohos/`（ArkTS app）+ `native/`（C/C++ 库与 NAPI）+ `spec/`（行为规格）+ `capabilities.json`
- [ ] CI：hvigor 构建 + 模拟器 2in1/tablet 双画像冒烟
- 验收：空壳应用在 2in1 与 tablet 上都能装、能跑、能出 PNG

### Sprint 2–3（第 3–8 周）C 库交叉编译流水线
- [ ] 用 OpenHarmony 三方库框架（Lycium / tpc_c_cplusplus 的 HPKBUILD 模式）编出 `openssl`、`zlib`、`libssh2`、`libargon2`，目标 `x86_64` + `arm64-v8a`
- [ ] NAPI 薄封装：`ssh_open/ssh_auth/ssh_exec/ssh_sftp_*`，**全部按会话句柄授权**（SEC-01）
- 验收：ArkTS 用封装库对 `tools/e2esshd` 完成一次带公钥认证的 SSH 会话 + 一次 SFTP 列目录
- 风险：交叉编译链（NDK 15.0.4 + musl）与 Lycium 脚本语义（openssh 移植文档已记录同类坑）

### Sprint 4–5（第 9–16 周）oracle harness 主体
- [ ] 原版 Motty 构建 + 轨迹采集器
- [ ] spec 转译与 Hypium runner（先覆盖 10 个场景）
- [ ] `capabilities.json` + CI 断言
- 验收：M0.5-a ~ M0.5-e 全部通过

### Sprint 6（第 17 周）评审门
- [ ] 三份对账：轨差异报告、能力矩阵签字、C 依赖 SBOM 与许可结论（**LibVNC GPL 决议**）
- [ ] 依据实测重估 M1–M5 工期

---

## 5. 需要立即决策的两个遗留问题

1. **VNC 用什么**（唯一有许可硬冲突的项）
   - a) 自写 C（Raw/CopyRect/RRE/Hextile/ZRLE ≈1.5–2k 行，BSD 自有许可）——**推荐**，可控且无 GPL 污染
   - b) 用 LibVNC 并接受 GPL（仅当确定开源分发）
   - c) 首版不支持 VNC，进 T3（与"1:1"冲突，不建议）
2. **终端模拟器底座**（最大工期风险）
   - a) libvterm 骨架 + 自写 kitty/SIXEL/iTerm2/连字扩展
   - b) 直接 ArkTS 重写 VT 解析器（可移植 Go 版算法与 fuzz 语料思路，但不能复用代码）
   - 建议先做 2 周 spike：用 libvterm 渲染 5000 行 + 图片场景，判定扩展成本

---

## 6. 与既有文档的关系

- 路线与风险：[PLAN.md](./PLAN.md)（§16 是本文的前提）
- 能力矩阵与 T1/T2/T3 条目：[CAPABILITY-MATRIX.md](./CAPABILITY-MATRIX.md)
- 模拟器环境与验证边界：[SPIKES.md](./SPIKES.md)
- 本文取代 PLAN §2 的 D1/B 分支结论：**Go 路线全部作废，A′ 为最终路线。**

---

## 7. M0.5 实测进展（2026-11-10，本机 Windows）

M0.5 从"计划"变成"已验证的路"。以下是实跑结果，可直接作为 M0.5-a/M0.5-c 的起点证据。

### 7.1 已完成

| 项 | 结果 |
|---|---|
| 原版构建 | `go build ./...` exit 0；`motty-baseline.exe` **52.6 MB** |
| 无头构建 | `go build -tags vivahead -o motty-head.exe ./cmd/motty` exit 0，**52.9 MB** |
| 无头驱动 | `python tools/headless_drive.py <home> <script>` 正常工作，应用启动行 `ok ready 1400x900 scale=2 windows=1 active=1` |
| **一个 e2e 跑通** | 改编后的脚本 **exit=0**：`alpha`(10.0.0.1)、`beta`(10.0.0.2) 两台主机建成，`texts` 输出可见 |
| 截图证据 | `shot` 产出 PNG（约 290 KB/张），符合项目原生证据范式 |
| Python | `C:\Python315\python.exe`（3.15） |

### 7.2 原版 e2e 脚本**不能直接用**——三类可移植性缺陷

实测 `tools/e2e/host_menu_move_e2e.txt`，6 个失败逐项归因（这是 M0.5-c 的真实工作量来源）：

| 缺陷 | 现象 | 修法 |
|---|---|---|
| **POSIX 路径** | `shot /tmp/host-menu-alpha.png` → `The system cannot find the path specified` | 换成 Windows 截图目录（可批量替换） |
| **UTF-8 BOM** | `error unknown command "\ufeff#"` | 用无 BOM 写入（PowerShell 5.1 的 `Out-File -Encoding utf8` 会加 BOM，须用 `[IO.File]::WriteAllText` + `UTF8Encoding($false)`） |
| **依赖 TAB 焦点顺序** | `type 10.0.0.1` → `error app: no focused text field` | **改用稳定 id**：`click id:shell/dialog-address` 后 `type` |

改写后（`click id:shell/add-host` → `click id:shell/dialog-label` → `type` → `click id:shell/dialog-address` → `type` → `click id:shell/dialog-submit`）**一次通过**。

→ 结论：**82 个脚本的移植是机械工作，不是重写**。但"按文案点击 + 依赖 TAB 顺序"的写法必须改成"稳定 id + 显式断言"，这与 CLAUDE 的任务卡（R28）完全吻合。

### 7.3 控件 id 可直接从 `tree` 取得（省掉猜的时间）

`tree` 命令输出带 `role/id/label/state/坐标`，例如：

```
role=textfield id=shell/dialog-label   label="Label"   state=focused,focusable
role=textfield id=shell/dialog-address label="Address" state=focusable
role=button    id=shell/dialog-submit  label="Add Host" state=focusable
role=combobox  id=host-auth-ui/dialog-auth label="Authentication" value="Automatic"
role=button    id=shell/dialog-cancel  label="Cancel"
```

→ 给 M0.5-c 的转译器定了实现路径：**用 `tree` 抓一次真实界面，自动把文案脚本映射成 id 脚本**，再人工校核断言。这把 82 个脚本的转译从"逐个手改"变成"半自动"。

### 7.4 M0.5-a 的状态

- [x] 原版可构建、可无头运行
- [x] driver 协议可用、截图可用
- [x] 至少 1 个场景端到端通过（非 10 个，故 M0.5-a 记为**部分达成**）
- [ ] ≥10 个场景通过（下一步）
- [ ] 已知失败清单（HEAD 上 `localshell`、`remotetools` 本就失败，R20）需在跑 `go test` 时记录