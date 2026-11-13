# UI 二级页面/设置项 差距审计（Round 112）

> 方法：以**上游 i18n 键**为准（`internal/i18n/english.go`），逐项对照我们 `Index.ets` 里的页面与控件 id。
> 结论只写可核对的事实，不写"应该差不多"。

## 1. 一级导航

| 上游 `Nav*` | 中文 | 我们的状态 |
|---|---|---|
| `NavHosts` | 主机 | ✅ `nav/hosts` |
| `NavWorkspaces` | 工作区 | ⚠️ 最小版（会话标签概览，非上游 pane deck） |
| `NavKeychain` | 密钥链 | ✅ `nav/keys` |
| **`NavProxies`** | **跳板路由** | ❌ **死链**（`nav/jump` 点击无反应） |
| `NavSnippets` | 快捷命令 | ✅ `nav/snippets` |
| `NavPortForwarding` | 端口转发 | ✅ `fwd/open`（弹层，非独立页） |
| `NavKnownHosts` | 已知主机 | ✅ `known/open`（弹层） |
| `NavSettings` | 设置 | ⚠️ **只有 12 个控件**（见 §2） |
| `NavDebug` | 调试 | ✅ `diag/open`（三页弹层，上游无此页，属我们的诊断补充） |
| `NavSearch` | 搜索/命令面板 | ✅ `top/search` |

我们多出三项（上游无对应一级项）：**会话日志**、**笔记**、**本地终端**。

## 2. 设置面板：**114 个上游键 vs 我们 12 个控件**

上游设置按区分为（括号内为键数）：
`Terminal 16 / Connection 10 / Startup 10 / Other 10 / Toolbar 8 / Local 7 / Tab 6 / Tabs 6 /
Vault 6 / Text 5 / Restore 5 / Language 4 / Appearance 4 / Network 4 / Interface 3 /
Output 2 / Share 2 / Shortcuts 1`

我们已有的控件：
`lang-zh|lang-en`、`view-list|view-grid`、`sort-manual|name|ip`、`font-dec|font-value|font-inc`（终端字号）

**缺的整块**（按"能否真做"排序）：
| 区块 | 上游键数 | 可行性 | 说明 |
|---|---|---|---|
| 标签（方向/编号/自动隐藏/快捷键） | 12 | **真做**（中成本） | 标签栏改造，可验证 |
| 外观（跟随系统/深/浅） | 4 | 真做（**高成本**） | 需要全量主题化，当前写死深色 |
| 界面字号（小/标准/大） | 5 | 真做（中成本） | 需要 UI 尺寸缩放体系 |
| 关闭/恢复行为（恢复会话、启动打开什么） | 15 | 真做（中成本） | 涉及启动流程 |
| 终端（Option、字体、光标、滚回行数） | 16 | 部分真做 | 我们已有字号；其余需 C++ 侧支持 |
| 连接（超时、保活、重连） | 10 | 部分真做 | 超时可做；保活需 SSH 侧 |
| 本地终端（默认 shell、代理） | 7 | 不做 | 模拟器上没有本地 shell 概念 |
| Vault / Share / Shortcuts | 9 | 真做（低-中） | 分享/快捷键说明可从简 |
| 网络代理 | 4 | **不做** | 无系统代理集成 |

## 3. 二级弹窗/页面清单（我们 vs 上游）

| 功能 | 我们的实现 | 备注 |
|---|---|---|
| 新建/编辑主机 | `host-form/dialog` | 字段：label/address/user/port/proto/group/tags/color/icon/password |
| 主机详情 | `hostdetail/panel` | 只读 + 打开/编辑/删除 |
| 删除主机确认 | `host-del` → 确认 | ✅ |
| 分组重命名/删除 | `grouprename/dialog`、`groupdel/dialog` | ✅ |
| 已知主机 | `known/panel`（含清空） | 缺"导入/已知主机导出" |
| 端口转发 | `fwd/panel`（含编辑/清空） | 上游是独立页，我们是弹层 |
| 密钥链 | `vaultPage` | 只读列表 + 删除；**缺"新增凭据/编辑"** |
| 快捷命令 | `snippetsPage` | CRUD 有；缺"发送到会话"以外的分组管理细节 |
| 笔记 | `notesPage` | CRUD 有 |
| 会话日志 | `logsPage`（搜索/导出/清空） | 缺"按主机/协议筛选" |
| 诊断 | `diagPanelV2` 三页 | 我们独有 |
| 工作区 | `workspacePage` 最小版 | 缺 pane 分屏 |
| **跳板路由** | ❌ 无 | 死链 |
| SFTP 面板 | `filesPanel` | 有上传/下载/删除/改名/建目录 |

## 4. 结论与优先队列（按"用户可见 + 可实现"排序）

1. **P0 设置：标签区块**（方向/编号/自动隐藏）— 真做，可验证，12 个键一次补齐
2. **P0 密钥链：新增/编辑凭据** — 上游有，我们只有只读+删除
3. **P1 跳板路由**：先给**明确说明页**（不做假配置），等 SSH 侧支持再实现
4. **P1 外观主题（浅色）**：成本最高，放到最后；若不做，需在设置里显式标注"仅深色"
5. **P1 界面字号**：与已有终端字号并列，属"能用就好"的类型
6. **P2 会话日志筛选（按主机/协议）** — 便宜
7. **P2 已知主机导入/导出**

## 5. 验收方式（省时）
- 每个 P0/P1 项：**1 条新用例 + 定向 `--only` 回归**（不跑全量）
- 设置项：断言"值 + 重启保持"（DB 持久化已有基建）
- 页面：断言关键 id + 关键文本，不逐个像素比对

---

## 本轮已补（Round 112，E2 构建通过，待模拟器回归 E1）

| 项 | 实现 | 用例 |
|---|---|---|
| 密钥链「新增凭据」 | `vault/add-open` + `vaultadd/dialog`（addr/port/user/pw + save/cancel），保存后写 Asset Store + 内存凭据，结果行 `vault/result` | `vault.add` |
| 设置「标签编号」 | `settings/tab-numbers` 开关，标签栏标题前缀序号，DB 持久化（`tabNumbers` 走 `savePrefs`） | `settings.tab-numbers` |

> 说明：本轮模拟器未就绪（冷启动），这两项只有 **E2（编译+lint）**；
> 下一轮模拟器起来后按 `--only vault` / `--only settings.tab` 定向跑，拿到 E1 再更新本文档。

## Round 113 追加（E2，构建通过）

| 项 | 实现 | 用例 |
|---|---|---|
| 跳板路由页 | `jumpPage()`：说明 libssh2 无 transport、指向端口转发替代；`jump/fwd-open`、`jump/back` | `jump.page` |
| 已知主机导出/导入 | `known/export-file`、`known/import-file`，JSON `motty-known-hosts`，结果行 `known/result` | `knownhosts.export` |

> 仍为 **E2**：模拟器未连接。下轮设备就绪后按 `--only jump` / `--only knownhosts` 拿 E1。

### 剩余设置缺口（按建议顺序）
1. 关闭前确认、标签方向（顶部/侧栏）——真做，中成本
2. 界面字号（小/标准/大）——需要尺寸缩放体系
3. 外观浅色主题——成本最高，最后做；不做则在设置里显式标注
4. 会话日志按主机/协议筛选——便宜

## Round 114 追加（E2）

| 项 | 实现 | 用例 |
|---|---|---|
| 会话日志按协议筛选 | `logs/proto-all|ssh|rdp|vnc` chips + `logs/proto-count`；`logsFiltered()` 同时按协议与关键词过滤（AND） | `logs.proto-filter` |

## Round 115 追加（E2）

| 项 | 实现 | 用例 |
|---|---|---|
| 设置「侧栏标签」 | `settings/tab-side` 开关；开启后顶部 `tabBar` 隐藏，左侧渲染 `session/tabstrip`（`session-tabv/<id>`、`session-closev/<id>`）；DB 持久化 `tabSide` | `settings.tab-side` |

## Round 116 追加（E2）

| 项 | 实现 | 用例 |
|---|---|---|
| 设置「回滚行数」 | `settings/scrollback` 按钮（+10，0~100 循环）+ `settings/scrollback-value` 显示；`termScrollback` 传给 `vtScrollBack`；DB 持久化 | `settings.scrollback` |
| 工具 | `run-all.py --only` 支持**逗号分隔多前缀**（如 `--only vault,settings.tab,logs`），一次跑多条定向回归 | — |

### 阻塞（重要）
电脑重启后模拟器**无法启动**：`Emulator.exe` 有进程但 `hdc list targets` 一直为空，
`-wipe-data` 重试也无效。已确认不是 hdc 端口问题（`tconn` 失败）。
⇒ 需要从 DevEco Studio GUI 里重新启动模拟器（或重建镜像）；在此之前所有新增只有 E2。

## Round 118 追加（E2）

| 项 | 实现 | 用例 |
|---|---|---|
| 设置「显示最近连接」 | `settings/show-lastused` 开关；关闭时列表行不再渲染最近连接文本 | 并入 `settings.display-toggles` |
| 设置「显示会话计数」 | `settings/show-tabcount` 开关；关闭时顶部 `session/count` 不渲染 | `settings.display-toggles` |

## Round 119 追加（E2）

| 项 | 实现 | 用例 |
|---|---|---|
| 设置「启动打开什么」 | `settings/start-hosts|logs|workspace` 三个按钮；`startupView` 存 DB；启动时 `applyStartupView()` 落到 `pcNav`（日志分支顺带 `reloadLogs()`） | `settings.startup-view` |

## Round 134 追加（E2）

| 项 | 实现 | 用例 |
|---|---|---|
| 设置「界面字号」三档 | `settings/scale-small|regular|large`；`uiScaleKey` 存 DB；`fs(n)` 只缩放文字尺寸（0.9/1.0/1.15），先用于侧栏导航、主机名、各页标题、设置标题 | `settings.ui-scale` |

## Round 139 追加（E2，无需设备）

| 项 | 实现 | 用例 |
|---|---|---|
| 本地终端页 | `localTerminalPage()`：如实说明 HarmonyOS 沙箱不能 fork/exec 本地 shell，给「打开调试页」「回到主机」两个入口（`localterm/explain`、`localterm/workaround`、`localterm/diag`、`localterm/back`） | `page.local-terminal` |
| 页标题统一 | 新增 `pageTitle(text,id)`，统一 `fs(16)/Bold/#E8EAED`；已用于 会话日志/工作区/跳板路由/密钥链 | — |

## Round 141 追加（E2）

| 项 | 实现 |
|---|---|
| 死按钮审计 | 扫描全部 `@State *Open/Dialog`：无「只置位不渲染」的残留（`aiOpen` 已于 Round 140 补面板） |
| 标题统一 | 快捷命令 `snippet/title`、笔记 `note/title` 接入 `pageTitle`；主机页标题 `hosts/title` 接入 `fs()` |
| 页内边距统一 | 二级页面统一 `left/right 22, top 10, height 100%` |

## Round 144 追加（E2）：设置面板**分区重构**

原面板把「终端字号」塞进「默认视图」列、把字号/启动/显示开关全挤在一行，视觉与信息架构都乱。

新结构（560 宽，统一 `settingsSection` 分区标题 + `settingsOpt` 选项按钮）：

| 分区 | 内容（id 全部保留） |
|---|---|
| 语言 | `settings/lang-zh|lang-en` |
| 外观 | `settings/scale-small|regular|large` |
| 主机列表 | `settings/view-list|view-grid`、`sort-manual|name|ip`、`show-lastused`、`show-tabcount`、`tab-numbers`、`tab-side` |
| 终端 | `settings/font-dec|font-value|font-inc`、`settings/scrollback` |
| 启动时打开 | `settings/start-hosts|start-logs|start-workspace` |
| 关于 | 版本说明（RDP 文案更新为「可连接/可解码/会话预览+输入投递（实验性）」） |

`check-ids` 同步增强：识别通过 `@Builder` 参数传入的 id（如 `settingsOpt(label, 'settings/x', ...)`）。

## Round 145 追加（E2）：主机表单 i18n + 分区

- 表单 6 个中文 placeholder 全部双语化（显示名/主机名或 IP/登录账户/密码提示/标签示例/分组提示）
- 表单加入两个分区标题：**基础**（名称/地址/凭据）、**外观与归类**（分组/图标/协议/标签/颜色）

## Round 146 追加（E2）：按钮样式收敛

- 新增三个统一 builder：`btnPrimary`（主 `#2F6F4F`）、`btnSecondary`（次 `#23262B`）、`btnDanger`（危险 `#3A2226`），统一 `height 30 / fontSize 12`
- 已把 `hostMoreMenu`（打开/编辑/删除）、`tabRenameDialog`、`vaultAddDialog` 的 7 个按钮改为使用它们（id/文案不变）
- `check-ids` 增强：识别通过 `btnPrimary/btnSecondary/btnDanger/settingsOpt` 参数传入的 id

## 样式约定（后续开发照此执行）

| 类别 | 约定 |
|---|---|
| 页标题 | `this.pageTitle(text, id)`：`fs(16) / Bold / #E8EAED` |
| 分区标题 | `fs(11~12) / #8A8F98`（设置用 `settingsSection`，表单用 11 号 `#6B7078`） |
| 主操作按钮 | `btnPrimary(label, id, onTap)`：`#2F6F4F` / 白字 / h30 / fs12 |
| 次操作按钮 | `btnSecondary(...)`：`#23262B` / `#C7CBD1` |
| 危险操作 | `btnDanger(...)`：`#3A2226` / `#E08A8A` |
| 菜单项 | `menuItem(...)` / `menuItemDanger(...)`：宽 100% / h30 / fs13 |
| 选项按钮（设置） | `settingsOpt(label, id, active, onTap)`：激活 `#2F6F4F`，否则 `#23262B` |
| 页面容器 | 二级页面统一 `padding(left 22, right 22, top 10)`、`width/height 100%` |
| 文案 | 一律 `lang === 'zh' ? … : …` 或 `t('key')`；**不允许**只写中文或只写英文 |
| 弹层关闭 | 统一 `this.t('common.close')`；保存统一 `this.t('common.save')` |
| 图标按钮 | 只用于"工具栏/行内快捷"，必须 `id` + `onClick`（`check-actions.py` 会拦） |

> 自动化门禁：`check-all.ps1` = build + lint + check-ids + check-paging + check-actions。

## Round 149 追加（E2）：弹层宽度收敛成 4 档

| 档位 | 宽度 | 用于 |
|---|---|---|
| 菜单 | 200 / 220 | `hostmenu`、`viewmenu`、`groupmenu` |
| 小 | 420 | 重命名/删除确认、`hostdetail`、`tabrename`、`vaultadd` |
| 中 | 520 | `settings`、`palette`、`note`、`ai`、`hostkey`、`snippet`、`knowndel`、`vaultdel` |
| 大 | 620 | `host-form`、`known` |
| 超大 | 680 | `sftp`、`fwd`、`diag`、`vnc` |

本轮调整 10 处（460→420、400→420、480→420、560→520、700→680），使同一类弹层宽度一致。

## Round 150 追加（E2）：终端工具条按钮尺寸统一

终端视图工具条 11 个按钮（`terminal/send|resize|scroll-up|scroll-down|selall|copy|ctrl-c|up|down|left|right`）
之前没有显式高度，随默认样式漂移；现统一 `height 30 / fontSize 11`，与面板按钮档一致。

### 当前按钮高度档（规范）
| 场景 | 高度 |
|---|---|
| 行内/工具条 | 26（主机行）、30（终端工具条、面板） |
| 主操作（页头/提交） | 32 / 38 |
| 图标按钮 | 16 / 24 |

## Round 151 追加（E2）：深色/浅色主题（骨架）

- 新增 `th(dark)`：把 11 个基准色（应用底/顶栏/侧栏/面板/次级面/按钮面/输入面/四级文字）在浅色模式下映射为浅色
- 全文件把这些色字面量改为 `this.th('#xxxxxx')`（约 350 处），**彩色强调色（绿/蓝/红/紫）不随主题变化**
- 设置「外观」分区新增 `settings/theme-dark|light`，`themeMode` 存 DB
- 用例 `settings.theme`：切浅色 → 重启 → 仍有深/浅两个按钮

### 已知边界（诚实）
浅色下**对比度未逐屏校验**（无设备截图），个别面板（白底面板 `Color.White`）与浅色背景可能重复；需设备上目视一轮再微调。

## Round 152 追加（E2）：主题覆盖到面板底色与边线

- `backgroundColor(Color.White)` 5 处 → `this.th('#1C1F24')`（浅色下为白，深色下为深面，不再"白板"）
- `#EFEFEF`（标签栏底）→ `th('#1E2127')`；`#F0F0F0`（关闭按钮面）→ `th('#23262B')`
- 边线 `#22252A`、`#1E2126` 纳入 `th()`（浅色下映射为浅灰）
- 终端工具条遗留的 `#E6E6E6`/`#1A1A1A`（浅色按钮）**保持不随主题**：它们在深色下本就是浅色按钮（历史样式），
  这一块要不要跟着主题走需要设备截图确认后再改，避免把可读性弄坏。

## Round 154 追加（E2）：新增 `check-theme.py`（灰色是否都走 `th()`）→ 门禁七项

- 规则：所有**近灰**颜色（RGB 最大差 ≤ 12）必须包在 `this.th('…')` 里；彩色强调色不检查
- 白名单（有意固定，等设备目视）：终端深色底 `#000000/#1E1E1E/#D4D4D4/#333333`、固定对比 `#888888/#FAFAFA`、
  历史浅底按钮 `#E6E6E6/#1A1A1A`、浅色文字 `#12141A`、次级 `#999999/#666666/#DDDDDD`、
  以及 `th()` 自身返回的浅色值
- 本轮把 `#17191D`（侧栏标签条）、`#22262C`（悬停行）、`#9AA0A6`（侧栏次要文字）、
  `#2F343B`、`#3A3F46`、`#0B0D10` 全部纳入 `th()`；结果 **non-themed gray colors: 0**

门禁顺序：build → lint → check-ids → check-paging → **check-theme** → check-contrast → check-actions

## Round 159~160 追加（E2）：有范围的状态补"当前值 + 范围 + 边界禁用"

| 状态 | 范围 | 交互 |
|---|---|---|
| 终端字号 `termFontSize` | 10–24 | `font-dec`/`font-inc`，边界禁用并置灰，值旁标注 `(10–24)` |
| 回滚行数 `termScrollback` | 0–100 | `scrollback-dec`/`scrollback`（+），边界禁用，值旁标注 `(0–100)`；不再"循环归零" |

## Round 162 追加（E2）：无凭据时不再静默

SFTP 面板 / 会话相关的 `creds.get(fixtureKey)` 分支原本在**未连接主机**时静默 return。
现在统一先判空并提示「请先连接一台主机 / connect a host first」（13 处入口），提示 4 秒自动消失。

## Round 163 追加（E2）：端口转发表单校验

- 新增 `forwardFormError()`：监听端口 / 目标端口必须是 **1–65535** 的整数、目标主机不能为空
- `startForward()` 与 `saveRule()` 先校验：不合格时把错误写进 `fwd/events` 或 `fwd/result`，不再带着无效参数去连接/入库
- **未加用例**：输入框是非受控的，自动化无法「清空已有内容」，构造非法值不稳定；列为 E2 代码级保证

## Round 164 追加（E2）

| 项 | 实现 |
|---|---|
| 日志上限提示 | `reloadLogs()` 最多取 200 条，并置 `logsCapped`；计数处追加「（仅最近 200 条）/ (latest 200 only)」 |
| SFTP 路径校验 | `requireSftpPath()`：路径为空时把提示写进 `sftp/status`（「请先填写远端路径」），已接入 `refreshListing()` 与 `goUp()` |

## Round 165 追加（E2）：会话标签「未读」指示

- `TabInfo` 增加可选 `unread`；`markUnread(tabId)` 在**非活动标签**收到输出时置位，`clearUnread()` 在切换标签时清除
- 标签栏在未读且非活动时显示琥珀色圆点 `session-unread/<id>`（放在标签按钮**前面**，避免按钮坐标抖动 —— 这是本工程踩过的坑）
- 覆盖范围：目前只挂在演示 vt 输出回调（`kind=vt/vt2/demo`）上；真实 SSH shell 的流式输出走另一条路径，尚未接

## Round 166 追加（E2）：未读指示接入**真实 shell 流**

- `openShell(...)` 的 chunk 回调：非活动标签时 `markUnread(tabId)`
- `exec(...)` 演示回调和另一处 vt 回调同样补上 else 分支
- 现在 `this.markUnread(` 共 3 处调用（真实 shell + 演示 vt + 演示 exec），覆盖全部输出路径

## Round 168 追加（E2）：会话**分屏**（左侧当前会话 + 右侧另一个标签）

- 新状态：`splitOn` / `splitId` / `splitText`
- `toggleSplit()`：切到「另一个标签」并排；**不足两个会话时提示**「至少需要两个会话才能分屏」
- 分屏 pane：`split/title`（被分屏的会话名）、`split/body`（该会话 vt 视图，随 `refreshTab()` 同步）、`split/close`
- 标签栏新增按钮 `session/split`（激活时变绿并显示「取消分屏」）
- 布局只在 `splitOn` 时插入 `Row{ 终端 | splitPane }`；关闭时 DOM 结构与原来完全一致，避免坐标抖动

### 已知边界（诚实）
- 并排渲染**未实测**（设备不可用）：需要两个会话都有输出才能目视确认
- 右侧 pane 是**只读快照**（不能输入）；上游分屏两侧都可输入 —— 这是与上游的已知差异
- 用例 `split.view` 只覆盖「单会话点分屏 → 提示」这一分支

## Round 169 追加（E2）：分屏右侧改为**可输入**

- 新增 `splitInput` 与 `sendSplitInput()`：把文本通过 `sendInput(splitShellId, …)` 发给右侧会话，发送后立即 `refreshSplit()`
- 分屏 pane 底部新增输入行：`split/input` + `split/send`
- 与上游差异已消除（此前右侧只读）；仍待设备确认实际输入效果

> 过程记录：首次插入时把 Row 放到了 `Column` 之外（`.width('44%')` 落在块尾），ArkTS 报
> `arkts-no-implicit-return-types` / `arkts-no-any-unknown`（Index.ets:5922）。已修正嵌套并用 `check-all` 复核通过。

## Round 170 追加（E2）：分屏体验补全

| 项 | 实现 |
|---|---|
| 右侧切换会话 | `split/prev`（‹）/`split/next`（›）→ `cycleSplit(±1)`，环绕并跳过当前活动标签 |
| 关闭保护 | `closeTab()` 关闭的正是分屏会话时，自动退出分屏并提示「分屏已关闭（会话被关闭）」 |

