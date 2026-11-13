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

