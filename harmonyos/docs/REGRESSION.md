# 回归（PC 端）

本文件说明如何一次性跑完全部场景、如何读结果、以及"什么算通过"。

## 一条命令

```powershell
# 1) 夹具与端口（SSH/SFTP 用例需要）
Get-Process sshfixture -ErrorAction SilentlyContinue | Stop-Process -Force
$hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
& $hdc -t 127.0.0.1:10100 rport tcp:2222 tcp:2223
Start-Process "harmonyos\.bin\sshfixture.exe" -ArgumentList `
  '-addr','127.0.0.1:2223',`
  '-hostkey','harmonyos\.bin\.sshfixture\hostkey',`
  '-hostkeytype','rsa' -RedirectStandardError "harmonyos\.bin\sshfixture.err" -WindowStyle Hidden

# 2) 全量跑（PC 画像）
C:\Python315\python.exe harmonyos\tools\run-all.py
```

结果落在 `harmonyos/spec/evidence/runs/full<N>/`：
- 每条用例一个子目录（含 `step-*.json`、`final.png`、`result.json`）
- `summary.json`：`total / passed / failed` 与每条用例的 `passed / seconds / error`

## 判定规则（不许放宽）

1. **只有 `result.json.passed == true` 才算通过**；跑完没崩不算通过。
2. 断言失败就是失败；**不允许**把断言改宽松来"变绿"，除非能说明是断言写错了（例如旧文案/旧语义）。
3. 每次改断言都要在提交信息里写清"旧断言为什么错"。
4. 证据等级仍是 E1（本机模拟器实测）/E2（编译静态）/E3（未验证），不许把 E2 写成 E1。

## 已知的环境前提

| 前提 | 说明 |
|---|---|
| 卸载重装**不会**清空数据 | 备份扩展会恢复应用数据；用例里用诊断面板的"重置"步骤代替 |
| `--fresh` 现在会校验卸载结果 | 卸载被跳过会直接 `EnvError`，不再静默继续 |
| 夹具要重启 | 残留夹具（旧 hostkey/会话）会表现为"点不到 sftp/entry/xxx" |
| 语言跟随系统 | 本模拟器为中文；用例断言写成"中文\|英文"两可，避免把语言状态误判成取词失败 |

## 本轮基线

见 `harmonyos/spec/evidence/runs/full21/summary.json`（Round 21 首次全量基线）。

## Round 21 首次全量回归（进行中 -> 基线）

新增 `harmonyos/tools/run-all.py`：一次跑完 `spec/scenarios/*.yaml`，每条用例单独输出目录，
最后写 `spec/evidence/runs/full<N>/summary.json`。

首轮（Round 21）**部分基线**：跑到 34/62 后停止（全量约 60–75 分钟），结果在
`spec/evidence/runs/full21/summary-partial.json`：

```
done 34 / 62    PASS 24    FAIL 9
```

失败清单（附 error 摘要）：
| 用例 | 失败点 | 初步判断 |
|---|---|---|
| `host.persist` | 断言文本 `10.9.9.9` | 地址列现在渲染成 `地址:端口`，断言用了精确文本 → **断言过时** |
| `infra.host-create-by-id` | 断言文本 `10.0.0.2` | 同上 |
| `hosts.search` | 期望 `no matching hosts` | 我们搜索无结果时**没有这条文案** → 真实缺文案 |
| `hostkey.changed` | `host-open/0` 未命中 | 上一步已进会话（视图切到终端）→ 用例缺"回列表"步骤 |
| `net.reachability` | 期望 `SSH-2.0-` | 需要夹具 banner 探测路径，待查 |
| `rdp.client-input` / `rdp.client-render` / `rdp.connect` | RDP 断言 | RDP 仍是实验态（见 RDP.md），**不算通过** |
| `rdp.server-peer` | 期望 `No hosts yet` | 空态文案已改（跟随语言）→ 断言过时 |

**注意**：这批失败里有些是"文案/选择器过时"，有些是真实缺陷（如 `hosts.search` 缺空结果文案），
必须逐条看 `result.json` 的 `error` 与 `final.png` 再下结论，不能一概当作环境问题。

## Round 23 状态：54 / 62（估算）+ 8 条已知未通过

批量跑（`full21`）当时的快照是 **44/62**，随后 Round 22–23 修复了 10 条并**单独复跑通过**：

```
host.persist / hostkey.changed / hosts.search / infra.host-create-by-id / net.reachability
terminal.resize / ui.i18n.diag / ui.i18n.diagnostics / ui.i18n.vnc / ui.rdp-experimental
=> 54/62（估算）
```

详见 `spec/evidence/runs/full21/status.json`（明确写了"批量快照 + 复跑修复"的口径，避免把两次混成一个数）。

### 仍失败的 8 条
| 类别 | 用例 | 说明 |
|---|---|---|
| RDP（实验态） | `rdp.connect`、`rdp.client-render`、`rdp.client-input`、`rdp.server-peer` | RDP 仍不可用（画面/输入未投递、服务端状态不符）。**不追求变绿**，等实现推进 |
| VNC（功能） | `vnc.adapt`、`vnc.desktopsize`、`vnc.auth-hextile`、`vnc.negative` | 期望 `canvas=80x60` / `auth=vncauth` / `authentication failed` 等状态串未出现，需查 VNC 面板流程 |

### 这一轮修的都是"断言/文案过时"，不是放宽
- 语言默认已改为跟随系统（中文），旧用例里"点一次语言按钮 = 切到中文"的假设失效 → 改为点两次；
- 信任/删除/变更对话框改成官方中文后，旧英文断言补上中文分支；
- 地址列渲染成 `地址:端口`，精确 `text` 断言改 `screenRegex`；
- RDP 实验性提示原来只有"RDP: 实验"四个字，现在补了说明（`画面与输入尚未投递` / `picture/input are not delivered yet`），
  这样"是否可用"在界面上是**明说**的，而不是靠用户猜。

## Round 24：VNC 4 条失败是**夹具参数**，不是应用缺陷

带正确参数重启夹具后，这 4 条一次性全过：

```
vnc.auth-hextile  PASS     (夹具 -vnc-auth secret)
vnc.negative      PASS     (夹具 -vnc-auth secret)
vnc.adapt         PASS     (夹具 -vnc-resize)
vnc.desktopsize   PASS     (夹具 -vnc-resize)
```

因此 Round 21–23 的"VNC 功能失败"结论是**错的**（至少这 4 条），已纠正。
为避免再次误判，`run-all.py` 现在支持用例声明 `fixture: { vncAuth, vncResize }` 并在跑之前自动重启夹具。

同时修了一个工具本身的坑：`run-all.py` 曾被 PowerShell 写入带 BOM，Python 直接 `SyntaxError`；
已去掉 BOM（`﻿`）。

## Round 25 新基线：58/62（批量）→ 59/62（含复跑修复）

`full24` 全量新鲜回归（夹具参数已自动化，每条用例走 `--fresh`）：

```
[批次快照] 58 / 62 PASS
[复跑] terminal.resize PASS（批量中受"备份恢复带回归 known_hosts"影响，已加显式重置）
=> 有效 59 / 62
```

### 仍然失败的 3 条（全部 RDP，实验态）
| 用例 | 期望 | 现状 |
|---|---|---|
| `rdp.client-render` | `rdp-render: frames=N paints=N` | 画面未投递（paints 为 0） |
| `rdp.client-input` | `serverSaw keys=N` | 输入未投递到服务端 |
| `rdp.server-peer` | `rdp-server: start rc=0 running port=13389` | 内嵌 shadow 服务端状态不符/崩溃（见 RDP.md） |

这 3 条**不代表回归**，是 RDP 功能本身没完成；`rdp.connect` 与 `rdp.client-connect` 这两条（连接/失败路径）是通过的。

### 与上一轮的对比
| 轮次 | 通过 |
|---|---|
| Round 21–23（full21） | 44/62 批次 + 10 条复跑修复 ≈ 54/62 |
| **Round 25（full24）** | **58/62 批次 + 1 条复跑修复 = 59/62** |

提升来自：夹具参数自动化（VNC 4 条）、语言默认跟随系统后的用例修正（i18n 3 条）、
信任/删除对话框中文化后的断言对齐、地址列文本断言改 `screenRegex` 等——都是"断言/环境"层面的修正，
没有为了变绿放宽任何业务断言。

---

## 面板分页约定（Round 57 起）

诊断面板已从"单页"改为**三页**：`RDP` / `调试` / `快照`（`@State diagTab`，默认 `rdp`）。

**写用例时必读**：
1. 打开诊断面板（`click id:diag/open`）后，默认在 **RDP 页**；
2. 需要 `catalog/*`、`terminal/*`、`vnc/session*`、`net/probe`、`ssh/probe*`、`diag/term-echo`、`vnc/result`、
   `net/probe-result`、`catalog/result` 的用例，**必须先切到调试页**：
   ```yaml
   - action: click
     target: id:diag/tab-debug
   ```
3. 需要 `rdp/canvas`、`rdp/canvas-info`、`rdp/ticks`、`rdp/experimental*` 的用例，切到快照页：
   ```yaml
   - action: click
     target: id:diag/tab-snap
   ```
4. 被分页隐藏的控件**不会出现在 `uitest dump` 里**——"选择器未命中"优先怀疑"没切页"，
   而不是"控件被删了"。

**为什么分页**：面板可视高度实测只有 **1324px**（`diag/panel [914,351][2206,1675]`），
单页内容约 1900px，排在后面的控件既不显示也不进 dump，用户也点不到。

**已迁移**：30 条依赖调试页控件的用例已统一插入切页步骤；新增 `diag.tabs` 用例保护"分页不被改回单页"。

---

## 全量回归 full58（73 条，分页后的构建）

```
SUMMARY passed=70/73
FAIL rdp.connect            (assert "connect failed" 未命中；见下"已知自动化问题")
FAIL ui.i18n.diagnostics    (断言跨了两页：调试页文案与 RDP 页文案不能同时断言) -> 已修
FAIL ui.rdp-experimental    (实验性说明已移到「快照」页，且提示文案已更新) -> 已修
```

### 分页带来的两类用例修正（已做）
1. **跨页断言**：`ui.i18n.diagnostics` 原先同时断言「调试」页（TCP 探测/主机密钥检查）与「RDP」页（RDP 服务启动）的文案。
   分页后必须分别在各页断言 → 重写为：切调试页断言两条 → 切回 RDP 页断言一条，末尾只保留 RDP 页断言。
2. **文案更新**：`ui.rdp-experimental` 断言的旧说明「画面与输入尚未投递」已被改为
   「画面已能解码并投递到界面」（这是在 RDP 画面真的能显示之后改的），用例同步更新，并先切到快照页。

### `rdp.connect` 的根因（Round 60 查清）
- 手工流程（开面板 → 点 `rdp/probe-closed` → 等 5s）稳定得到
  `rdp: connect failed: The connection transport layer failed.`；
- 但 `run.py --fresh` 跑这条用例时，断言阶段屏幕里**面板已经不见了**，且**没有崩溃日志**；
- 已尝试：加 `wait`（1000→2500ms）、把 `settleMs` 1800→4000、加长 probe 后等待（4→8s），均无效；
- 结论：**暂记为已知自动化问题**（不是产品缺陷，手工验证通过）。下一步用 `run.py` 的步骤日志逐帧对比
  "面板何时消失"，而不是继续猜。

### 当前基线
真实通过 **70/73**；两条用例已修（`ui.i18n.diagnostics`、`ui.rdp-experimental` 各自单独跑均 PASS），
`rdp.connect` 仍为红（已知自动化问题）。**不把它算进通过数**。

### Round 60：`rdp.connect` 根因与修复（73/73 可达成）
**根因**：该用例第二步探测 `rdp/probe-ssh`（127.0.0.1:2222）。跑批时 SSH 夹具在这个端口上，
TCP 能连上，但 RDP 握手一直等不到数据 → NAPI 回调不返回 → 结果停在 `rdp: probing ...`，
断言自然失败。手工验证"通过"只是因为当时夹具没起、端口是关闭的。

**两处修复**：
1. **产品侧**：`rdpProbe` 加 **UI 层 8 秒守卫**——超时未返回就明确显示
   `rdp: probe timeout (no RDP response within 8s) on 127.0.0.1:<port>`，
   不再无限停在 `probing ...`（FreeRDP 该构建没有可用的连接超时设置）。
2. **用例侧**：把 `connect failed` 的断言放在"探测关闭端口"之后（步骤内 expect），
   末尾断言改为 `probe timeout`（反映最后一次探测的真实结果）。

复跑：`rdp.connect` / `ui.i18n.diagnostics` / `ui.rdp-experimental` /
`rdp.client-render` / `rdp.preview` / `rdp.server-peer => 6/6 PASS`。
⇒ full58 的 3 条失败全部消除，理论上 **73/73**（需再跑一次全量确认）。

---

## 全量回归 full65（75 条，协议筛选 + 表单协议 + Esc 之后的构建）

```
SUMMARY passed=74/75
FAIL ui.i18n.diag  step 1 (wait) 失败：'New Host|新建主机' 未命中（屏幕文本为空 —— 应用还没画出来）
```
单独复跑 `ui.i18n.diag` → **PASS**。⇒ 这是**批量里的首启抖动**（应用启动慢/空窗），不是产品回归。

### 批量工具改进：只对"第 1 步失败"重跑一次
`tools/run-all.py` 增加：若某条用例**在第 1 步就失败**，先 `aa force-stop`，再整条重跑一次；
重跑通过则记为 PASS（并在日志里打 `[retry]`，结果落在 `<spec>-retry/`）。
其它步骤的失败**一律不重试** —— 避免把真实回归掩盖成"抖动"。

### 当前基线
- 全量：**74/75**（唯一失败为首步抖动，可重跑通过）
- 加入重试后，预期全量稳定在 **75/75**（下一轮验证）

---

## 全量回归 full68：**76/76 全绿**（首个全通过的全量）

```
SUMMARY passed=76/76
[47s-106s/条]  无 FAIL、无 [retry]
```
本轮构建包含：协议筛选 chips、表单协议选择、命令面板 Esc、主机 Icon 字段、
RDP 自解码/预览/输入、诊断面板三页化、FreeRDP 日志静音（修掉间歇崩溃）。

### 值得记录的结论
1. **RDP 相关 7 条全绿**：`rdp.server-peer / client-render / client-input / connect /
   preview / preview-idle / client-connect`。
2. **分页之后 30 条用例补的切页步骤全部有效**（`catalog/*`、终端、VNC、探测）。
3. **首步重试机制本轮没有被触发**（日志里没有 `[retry]`），说明 76 条都能一次跑过；
   它仍然保留作为基础设施抖动的兜底。

### 基线（可用于后续回归对照）
- 用例数：**76**
- 全量：**76/76**
- 运行时长：约 70 分钟（含 VNC 夹具多次重启）

---

## 全量回归 full72：**78/78 全绿**（第二次全通过，用例数 +2）

```
SUMMARY passed=78/78   failed=0
```
新增两条（本轮之前加入）：`host.grid-meta`、`host.lastused`、`host.icon`、`host.proto-filter` 都在其中。

### 结论
- Icon / 最近连接 / 网格元信息 三项 UI 改动**没有引入回归**；
- 批量的"首步失败重跑"机制本轮仍未触发；
- 全量跑批时长 ~70 分钟（78 条，含三次 VNC 夹具参数切换）。

### 基线（更新）
- 用例数：**78**
- 全量：**78/78**

---

## 全量回归 full75：**79/79 全绿**（第三次全通过，用例数 +1）

```
SUMMARY passed=79/79   failed=0
```
新增 `host.group-rename-delete` 在内全部通过；分组管理（重命名/删除 + 表头 ✎/🗑）**没有引入回归**。

### 基线（更新）
- 用例数：**79**
- 全量：**79/79**
- 时长：约 70 分钟

---

## 全量回归 full77：**80/80 全绿**（第四次全通过，用例数 +1）

```
SUMMARY passed=80/80   failed=0
```
新增 `command.palette-hosts` 在内全部通过；命令面板"列主机"改动**没有引入回归**。

### 基线（更新）
- 用例数：**80**
- 全量：**80/80**

### 连续全绿记录
| 轮次 | 用例数 | 结果 |
|---|---|---|
| full68 | 76 | 76/76 |
| full72 | 78 | 78/78 |
| full75 | 79 | 79/79 |
| full77 | **80** | **80/80** |

---

## 全量回归 full81：**82/82 全绿**（第五次全通过，用例数 +2）

```
SUMMARY passed=82/82   failed=0
```
新增 `forward.typed`（转发表单输入可靠）与 `forward.edit`（规则编辑）都在其中通过；
**转发面板的输入重复注入缺陷修复没有引入回归**。

### 基线（更新）
- 用例数：**82**
- 全量：**82/82**

### 连续全绿记录
| 轮次 | 用例数 | 结果 |
|---|---|---|
| full68 | 76 | 76/76 |
| full72 | 78 | 78/78 |
| full75 | 79 | 79/79 |
| full77 | 80 | 80/80 |
| full81 | **82** | **82/82** |

---

## 全量回归 full84：**83/83 全绿**（第六次全通过）

```
SUMMARY passed=83/83   failed=0
```
本轮包含 **设置持久化迁到 DB**（绕开损坏的 preferences）与 **分组排序**；
`host.group-order` / `settings.persist` / `host.group-pin` 等含重启断言的用例全部通过。

### 基线（更新）
- 用例数：**83**
- 全量：**83/83**

### 连续全绿记录
| 轮次 | 用例数 | 结果 |
|---|---|---|
| full68 | 76 | 76/76 |
| full72 | 78 | 78/78 |
| full75 | 79 | 79/79 |
| full77 | 80 | 80/80 |
| full81 | 82 | 82/82 |
| full84 | **83** | **83/83** |

---

## 全量回归 full86：**83/83 全绿**（第七次全通过）

```
SUMMARY passed=83/83   failed=0
```
本轮包含：**备份配置排除 preferences**、**设置持久化迁 DB**、**分组排序**。
所有含重启断言（`settings.persist` / `host.group-order` / `host.group-pin`）的用例通过。

### 连续全绿记录
| 轮次 | 用例数 | 结果 |
|---|---|---|
| full68 | 76 | 76/76 |
| full72 | 78 | 78/78 |
| full75 | 79 | 79/79 |
| full77 | 80 | 80/80 |
| full81 | 82 | 82/82 |
| full84 | 83 | 83/83 |
| full86 | 83 | **83/83** |

### 基线（沿用）
- 用例数：**83**；全量：**83/83**

---

## 全量回归 full89：**83/84**（1 条竞态失败，已加固用例）

```
SUMMARY passed=83/84   failed=1
FAIL forward.double-start  step 10 (click)：id:host-open/0 未命中
```
- 同一用例**单跑 PASS**（`runs/r89a`）；
- 失败现场 dump 显示：提交表单后对话框关闭，但列表仍是"还没有主机"——
  即**点击建行时"新增主机"尚未落到列表**的竞态，不是产品功能坏了。

### 处置（用例加固，而不是放宽断言）
在 `forward.double-start` 的 `shell/dialog-submit` 之后插入显式等待：
```yaml
- action: wait
  ms: 1500
  expect: { kind: screenRegex, regex: "fwddbl-host", withinMs: 12000 }
```
这样"主机出现"是**断言**出来的，而非假设出来的；加固后单跑 **PASS**（`runs/r89c`）。

### 结论
- 本轮 **没有产品回归**；full89 的 1 条失败是**用例对时序的隐含假设**；
- 下一轮需要再跑一次全量，确认 84/84。

---

## 全量回归 full90：**84/84 全绿**（第八次全通过）

```
SUMMARY passed=84/84   failed=0
```
包含 Round 88 的**终端字号设置**与 Round 89 的**用例加固**（`forward.double-start` 显式等待主机出现）。

### 结论
- Round 89 的 83/84 确认为**用例竞态**，加固后本轮 **84/84**；
- 字号设置的加减/持久化在 `settings.font-size` 中通过，其余设置类用例无回归。

### 连续全绿记录
| 轮次 | 用例数 | 结果 |
|---|---|---|
| full68 | 76 | 76/76 |
| full72 | 78 | 78/78 |
| full75 | 79 | 79/79 |
| full77 | 80 | 80/80 |
| full81 | 82 | 82/82 |
| full84 | 83 | 83/83 |
| full86 | 83 | 83/83 |
| full90 | **84** | **84/84** |

---

## 全量回归 full92：**84/85**（失败原因：用例假设"known_hosts 为空"）

```
FAIL ui.i18n.panels step 18: 期望信任对话框，未出现
```
根因不是抖动：**重装会恢复数据**，`known_hosts` 里已有夹具指纹 ⇒ 首次信任对话框不出现。

### 处置
1. 新增「清空已知主机」按钮 `known/clear`（用户可用 + 用例可确定性）；
2. `ui.i18n.panels` 连主机前先清空已知主机；
3. 新增 `knownhosts.clear` 用例覆盖清空行为。

### 规范补充
**不要假设数据库是空的**：涉及"首次"行为的用例必须显式清理对应表
（`catalog/reset-hosts` 清主机、`known/clear` 清已知主机）。

### 下一轮
再跑全量确认 86/86。

---

## 全量回归 full93：**86/86 全绿**（第九次全通过）

```
SUMMARY passed=86/86   failed=0
```
包含 Round 91 的 **RDP 会话视图**、Round 92 的 **已知主机清空** 与用例数据清理修正；
`ui.i18n.panels` 不再依赖历史 `known_hosts`。

### 连续全绿记录
| 轮次 | 用例数 | 结果 |
|---|---|---|
| full68 | 76 | 76/76 |
| full72 | 78 | 78/78 |
| full75 | 79 | 79/79 |
| full77 | 80 | 80/80 |
| full81 | 82 | 82/82 |
| full84 | 83 | 83/83 |
| full86 | 83 | 83/83 |
| full90 | 84 | 84/84 |
| full93 | **86** | **86/86** |

### 基线（更新）
- 用例数：**86**；全量：**86/86**

