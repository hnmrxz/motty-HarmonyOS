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

