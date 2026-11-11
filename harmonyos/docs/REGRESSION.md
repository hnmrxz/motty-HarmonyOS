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

