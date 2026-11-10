# 能力矩阵：Motty 全功能在鸿蒙上的落地等级

等级定义（详见 [PLAN.md](./PLAN.md) §0.5）：

| 级 | 含义 | 要求 |
|---|---|---|
| **T1** | 行为等价，机器可判定 | 必须 100% 通过；有 e2e/单测对照 |
| **T2** | 实现等价但载体改变 | 必须 100% 声明 + 有负测；用户可见差异要写文档 |
| **T3** | 不可复刻 | 100% 移除且 UI 无入口 + 文档口径 |

> 本表为 **G4 签字草案**。状态列：`已有API` = 本机 SDK 已核实存在对应 `.d.ts`；`未验证` = 需真机/官方正文。

> **修订 2026-11-10（模拟器基线）**：每条结论还需标注**证据等级**（定义见 [PLAN.md](./PLAN.md) §11.3）：
> **E1** 模拟器实测 ｜ **E2** 仅编译/静态 ｜ **E3** 未验证。
> 其中 **T2 的"密钥 → HUKS/Asset Store"与"后台保活"两项，模拟器最高只能到 E1（代码路径）而无法到真机语义**——模拟器可能软件实现 HUKS、后台策略通常更宽松，属高风险假通过点，必须在报告中写明"不代表真机"。同样，**发布签名上架、USB/串口、真机性能**在模拟器上是永远 E3。
>
> **形态口径（已决策 2026-11-10）**：PC 与平板**都要求 1:1**——T1 两形态共用全量标准，T2 按形态映射（指针↔触控、自由窗口↔分屏/悬浮窗、托盘↔服务卡片）。表内「平板 T2」= 载体不同但**功能不缺**；`T3` 只保留平台真无对应机制者（现有 8 项，与形态无关）。触控板与磁吸键盘无法在模拟器验证（E3）。

---

## A. 终端

| 能力 | 原版位置 | 鸿蒙方案 | 级 | 依赖 | 验收用例 |
|---|---|---|---|---|---|
| 真 PTY 会话 | `internal/term`、`internal/localshell` | 远程 PTY 走 SSH channel（T1）；**本地 PTY 见 B 组 T3** | T1 / 本地 T3 | G1 | `terminal_protocols` |
| 256 色 / 真彩色 | `internal/term` | Go 内核不变，配色数据随 HAP | T1 | G1 | 截图对照 |
| 备用屏 / 5000 行回滚 | `internal/term/terminal.go` | 内核不变；回滚区内存预算 16 MiB/标签页重标定 | T1 | G3 | `terminal_flood`、`terminal_drag_scroll` |
| 宽字符 / 组合字符 / 连字 | `internal/term` + Viva 文本整形 | D1：Viva 自带整形；B：ArkUI `@ohos.graphics.text` + 自绘网格 | T1（字形允许 T2 容差） | G3 | CJK 混排截图 |
| 鼠标上报 / 滚轮 | `term` 键鼠事件 | PC 自由窗口鼠标事件；平板触控模拟 | T1 / 平板 T2 | G3 | `terminal_drag_scroll` |
| IME 输入 / preedit | Viva IME 接口 | `@ohos.inputMethod` + `InputMethodExtensionAbility`（已有 API） | T1 | G3 | `preedit` |
| DECSET 2026 同步刷新 | `internal/term` | 内核不变，渲染端对齐 vsync | T1 | G3 | 全屏重绘无撕裂 |
| kitty 键盘协议 | `internal/term/keyboard.go` | 内核不变（仅需替换 `viva/gfx` 键码，≈50 行） | T1 | P0 | 按键矩阵单测 |
| `win32-input-mode` | `internal/term/win32input.go` | 只服务 Windows console | **T3 删除** | — | UI 无入口 |
| 标签重排 / 水平垂直分屏 | `internal/workbench` | PC：自由窗口 + 分屏；平板：单窗口 + 分屏 | T1 / 平板 T2 | G3 | `layout_*` |
| 跨窗口移动标签 | `workbench` | PC：多窗口拖拽；平板：分屏内移动 / 悬浮窗切换（功能不缺） | T1（两形态） | G3 | 手动 |
| 垂直标签 / 垂直聚合 | `workbench` | 纯 UI 逻辑，可 1:1 重做 | T1 | — | 截图 |
| 可停靠工具栏 | `workbench` | 鼠标拖拽；平板改长按菜单 | PC T1 / 平板 T2 | — | 手动 |
| 200+ 配色 / Xresources 导入 | `internal/workbench/schemes` | 数据文件随 HAP；导入改为 filePicker | T1 / 导入 T2 | — | `schemes_*` |
| 内置编辑器（语法着色/查找替换/正则） | `workbench` 编辑器 | 纯图元 + 键盘，无 OS 依赖 | T1 | — | `editor_*` |
| 历史搜索 / OSC 8 链接 / 超链接 | `term` | 打开外部链接走 want（需确认，见 SEC-02） | T1 / 打开 T2 | — | 手动 |
| Kitty / iTerm2 / SIXEL 图片 | `term/image.go` | 内核不变；上屏走 GPU 纹理 | T1 | G3 | 图片 e2e |
| 广播输入 / 会话录制 | `workbench` | 纯逻辑 | T1 | — | 手动 |
| 行内命令建议 / 补全 | `internal/completion` | 纯逻辑（22 文件 / 5,587 行） | T1 | — | `completion_*` |

## B. 主机与认证

| 能力 | 原版位置 | 鸿蒙方案 | 级 | 依赖 | 验收 |
|---|---|---|---|---|---|
| SSH 协议栈（KEX/AEAD/算法协商） | `internal/sshconn`（纯 Go `x/crypto/ssh`） | **原样保留**，无需 libssh2/OpenSSL | T1 | G1 | `host_test` |
| 主机密钥校验 + 自有 `known_hosts` | `sshconn/hostkey.go` | 原样；文件进沙箱目录 | T1 | R04 | `host_test` |
| 主机证书 / `@cert-authority` | `sshconn` | 原样 | T1 | G1 | `host_cert` |
| agent 认证 + agent 转发 | `sshconn` | 原样（纯 Socket 转发，不依赖本地 agent 进程） | T1 | G1 | `agent_forward` |
| 私钥文件 / OpenSSH 证书自动配对 | `sshconn`、`keyidentity` | 原样；私钥经 filePicker 或导入 | T1 | R11 | `credentials` |
| PuTTY `.ppk` v2/v3（含 Argon2id） | `internal/ppk` | 原样（有参数上限与测试） | T1 | — | `ppk` |
| 密码 / keyboard-interactive 多问题 | `workbench` 对话框 | 原样逻辑，UI 重做 | T1 | — | `credentials` |
| TOTP/HOTP + 保险库自动填充 | `internal/vault`、`autofill` | 原样；密钥存 HUKS | T1 | R05 | `autofill_*` |
| 主机分组 / 标签 / 搜索 | `workbench` | 纯逻辑 | T1 | — | `host_*` |
| 从 OpenSSH config / PuTTY / Xshell / MobaXterm / WindTerm / Electerm / Netcatty 导入 | `internal/sessionimport`、`sshconfig` | 原样；**导入入口必须确认**（SEC-02） | T1 / 入口 T2 | R07 | `import_*` |
| 保险库 AES-256-GCM | `internal/vault` | 原样；数据密钥进 Asset Store | T1 / 载体 T2 | R05 | `vault_*` |
| 系统密钥存储 | Viva `app.*Secret` | **HUKS / Asset Store**（已有 API） | T2 | R05 | 拒绝时不回退 |
| **本地 PTY shell** | `internal/localshell`（2,807 行）+ `creack/pty` | 沙箱无 `/dev/ptmx`、禁 exec | **T3**（未验证，若开放则回 T1） | R16 | UI 无入口 |

## C. 文件

| 能力 | 原版位置 | 鸿蒙方案 | 级 | 依赖 | 验收 |
|---|---|---|---|---|---|
| SFTP 浏览 / 多选 / 权限 / 书签 | `internal/sftpclient` | 原样协议层；UI 重做 | T1 | G1 | `sftp_*` |
| 递归上传下载 / 队列 / 续传 / 取消重试 | `sftpclient` | 原样（原子 partial + 校验前缀 + rename） | T1 | G1 | `sftp_*` |
| SCP 回退（无 SFTP 子系统） | `internal/scpclient` | 原样 | T1 | G1 | `scp_e2e` |
| 远端文件选择 | OS 文件对话框 | **filePicker + `persistPermission`** | T2 | R11 | 重启后授权仍在 |
| 本地↔远端拖放 | OS 拖放 | PC：系统拖放；平板：系统触控拖拽或 filePicker 替代 | T1 / 平板 T2 | — | 手动 |
| 终端目录跟随 / 文件面板跟随 | `docs/terminal-folder-sync.md` | 原样逻辑；路径改沙箱 | T1 | R04 | 手动 |
| 传输根越界防护 | `agent_transfers.go:57-125` | 原样 + URI 规范化复核 | T1 | R11 | 目录外访问失败 |

## D. 转发与跳板

| 能力 | 原版位置 | 鸿蒙方案 | 级 | 依赖 | 验收 |
|---|---|---|---|---|---|
| 本地 / 远程 / SOCKS5 / HTTP CONNECT | `internal/portforward` | 原样；只绑 loopback（`127.0.0.1`） | T1 | `@ohos.net.socket` 已有 API | `local_proxy`、`proxy_start_stop` |
| 跳板链（每跳独立验钥/认证） | `sshconn` | 原样 | T1 | G1 | `jump_*` |
| 全局出站 SOCKS5/HTTP 代理 | `internal/systemproxy` | 原样；**系统代理功能无意义 → 只保留显式配置** | T1 / 系统代理 T3 | — | 手动 |
| `ProxyCommand` 子进程 | `sshconn/proxycommand.go:109-133` | 沙箱禁 exec | **T3 删除**（UI 拒绝并提示） | R16 | 配置含 ProxyCommand 必拒 |
| **X11 转发** | `internal/x11fwd`（1,040 行） | 需本机 X server + Xauthority | **T3 删除** | — | UI 无入口 |
| 容器 / 系统代理集成 | `workbench` | 鸿蒙无对应语义 | **T3** | — | — |

## E. 远程桌面

| 能力 | 原版位置 | 鸿蒙方案 | 级 | 依赖 | 验收 |
|---|---|---|---|---|---|
| VNC：RFB 3.3/3.7/3.8 | `internal/rfb` | 原样协议层；帧上屏走 XComponent GPU 纹理 | T1 | G3 | `vnc_e2e` |
| VNC 编码 Raw/CopyRect/RRE/Hextile/ZRLE | `rfb` | 原样 | T1 | G1 | `vnc_e2e` |
| VNC 认证 None / VNC Auth | `rfb` | 原样 | T1 | G1 | `vnc_e2e` |
| RDP：TLS / NLA / 证书 pin / 文件拖放 | `internal/rdpcore`（38,410 行，**单独立项**） | 原样；**MinVersion ≥1.2**（现 1.0）、保留 pin 与"变更即断" | T1 | R12 | `rdp_e2e`、`rdp_files_e2e` |
| VNC/RDP 经 SSH loopback 隧道 | 原样 | 原样 | T1 | — | `tools/live` |
| 桌面尺寸变化 / 指针 / 剪贴板文本 | 原样 | 原样；剪贴板受 OS 策略约束 | T1 / T2 | — | 手动 |

## F. AI 与 MCP

| 能力 | 原版位置 | 鸿蒙方案 | 级 | 依赖 | 验收 |
|---|---|---|---|---|---|
| Ask（当前终端为上下文） | `internal/ai`（22,600 行） | 原样；网络走 `@ohos.net.socket` | T1 | G1 | `ai_*` |
| Agent（执行命令，经风险分级 + 审批门） | `ai/gate` | 原样；**审批 UI 重做，判定留 Go** | T1 | P0 | `ai_agent_*` |
| 脱敏（私钥/赋值/URL 内嵌凭据/令牌格式） | `ai` Redact | 原样；尽力而为性质不变 | T1 | — | 单测 |
| token 预算 / 上下文裁剪 | `ai` | 原样 | T1 | — | 单测 |
| 模型 Key 存保险库 | `vault` | HUKS/Asset Store | T2 | R05 | 拒绝不回退 |
| HTTP MCP（bearer token，observe/ask） | `ai/mcp/server.go` | 原样；**默认关闭**；loopback 跨应用可达性未验证 | T1 / 默认关 T2 | R14 | `mcp_e2e.py` |
| stdio MCP（`motty mcp-serve`） | `cmd/motty/mcp_serve.go` | 需要子进程 stdin/stdout 管道 → **鸿蒙不可行** | **T3**（HTTP MCP 可替代） | R16 | — |
| MCP token 存储 | `ai.db`（明文 0600） | **Asset Store** | T2 | R14 | 导出/诊断无 token |
| "风险分级审批" | `ai/risk/risk.go:1-11`（自述**不是**安全边界） | 原样，**口径改为"防误操作提醒"**；allow-all 二次确认 + 审计 | T1 / 口径 T2 | R29 | 审计日志 |

## G. 数据

| 能力 | 原版位置 | 鸿蒙方案 | 级 | 依赖 | 验收 |
|---|---|---|---|---|---|
| 加密 `.mottybak` 导出导入 | `internal/backup`（Argon2id + AES-GCM） | 原样；导出经 filePicker | T1 / 载体 T2 | R11 | 双向 round-trip |
| WebDAV / S3 / Gist / Gitee 同步 | `cloudsync` | 原样；HTTPS 策略保留（HTTP 需显式勾选） | T1 | G1 | `cloudsync_*` |
| 同步合并（HLC + 90 天墓碑） | `cloudsync` | 原样 | T1 | — | `cloudsync_*` |
| `meta.format` epoch 23 | `tools/README.md:112-118` | **不得抬 epoch**；单向不可回退 | T1 | R18 | 跨端双向 round-trip |
| 数据目录 / portable 模式 | `datadir.go:5-16` | 映射沙箱 `filesDir`；**portable 删除** | T2 / portable T3 | R04 | 冷启动可写 |
| 应用数据是否进华为云备份 | — | **未验证**；若进备份则必须确保密钥不在数据目录 | T2 | R05 | 备份产物审计 |
| 会话恢复（重启恢复不自动重连） | `workspace` | 原样 | T1 | — | `workspace_*` |

## H. 平台 / 外壳 / 发行

| 能力 | 原版位置 | 鸿蒙方案 | 级 | 依赖 | 验收 |
|---|---|---|---|---|---|
| 窗口 / 自由窗口 / 多窗口 | Viva app | PC `@ohos.window` 自由窗口；平板 分屏 / 平行视界 / 悬浮窗 | T1 / 平板 T2 | G3 | 双画像手动 |
| 剪贴板（OSC 52 写） | `remote_clipboard.go:22-28`（默认 allow） | **默认改 ask**；读需用户手势（未验证） | T2 | R13 | 默认策略负测 |
| 系统通知 / 状态 | `main.go:201 hasStatusArea` | 通知 + 服务卡片；托盘无契约 | T2 / 托盘 T3 | — | 手动 |
| 后台长连接保活 | 无 | 官方长时任务无 SSH 类型；**不伪造**，退后台降级并提示 | T2（降级） | R08 | 8h soak |
| 自更新（minisign 验签） | `internal/selfupdate`（2,867 行） | 市场分发禁自装 → 只保留"检查更新"提示 | **T3** | — | UI 无自装入口 |
| **串口 / serial** | `internal/serial`（1,117 行） | 无 `/dev/ttyUSB*`；USB Kit 可否替代**未验证** | **T3**（未验证） | — | UI 无入口 |
| zmodem / xymodem | `internal/zmodem` | 纯协议（1,751 行），随终端可用 | T1 | G1 | `zmodem_*` |
| i18n（3 语言 × 约 2,580 叶串） | `internal/i18n` | 由 Go 结构体生成 ArkTS 资源 | T1 | R28 | key 集合 1:1 |
| 应用图标 / 品牌资源 | `assets`（3.7MB）、`workbench/icons`（0.52MB） | 直接复用（体积非风险） | T1 | — | 目视 |
| 打包 | Viva `go run ./cmd/viva package` | **hvigor 打 HAP/HSP，双 ABI** | T2 | R17 | 双 ABI 可装 |
| 上架 | — | 待定 | — | 需用户决策 | — |

---

## 汇总

| 级 | 数量（约） | 说明 |
|---|---|---|
| T1 | 约 45 项 | 保留 Go 内核即可原样通过，是 D1/B 路线的价值主体 |
| T2 | 约 12 项 | 载体改变，必须声明 + 负测 |
| T3 | **8 项** | `win32-input-mode`、本地 PTY、X11 转发、ProxyCommand、stdio MCP、selfupdate、serial、portable。｜托盘与跨窗口拖拽已移入 T2（平板有等效入口） |

> T3 共 8 项，全部是"攻击面收窄"或"平台无对应机制"，安全上可接受，但**产品口径必须逐条写明**——这正是"1:1"在鸿蒙上唯一的诚实表述方式。
