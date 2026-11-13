# 交付状态（Round 125）

## 一句话
PC 端主功能已齐：主机/分组/终端/SFTP/端口转发/VNC/RDP/命令面板/设置/日志/密钥链/已知主机/调试/工作区，
**105 条机器判定用例**；最近一次完整全量 **91/91**（更早 15 次连续全绿）。

## 当前唯一硬阻塞：模拟器无法启动
- 根因：`Hyper-V 主机计算服务 (vmcompute)` 为 `Manual/Stopped`，当前会话**无权限**启动
  （`Start-Service vmcompute` → 无法打开服务；`Get-WindowsOptionalFeature` → requires elevation）
- 表现：`Emulator.exe` 有进程，qemu 不启动，`hdc list targets` 为空
- 需要：**管理员身份**打开 DevEco Studio 启动 `motty_pc`，或管理员 PowerShell `Start-Service vmcompute`
- 已确认 hypervisor 存在（`systeminfo`: "A hypervisor has been detected"），所以只需要提权启动服务

## 待补 E1（13 条，设备恢复后一条命令）
```
--only vault,settings.tab,settings.scrollback,settings.display,settings.startup,settings.reset,
       jump,knownhosts,logs,workspace
```
覆盖：密钥链新增凭据、标签编号/侧栏标签、回滚行数、显示开关、启动视图、恢复默认、
跳板说明页、已知主机导入导出、日志协议/主机筛选、工作区重命名/关闭其他。

## 已交付但只有 E2 的规则
设备不可用期间新增的功能一律标注 **E2（编译+lint+check-ids）**，
`docs/E1-BACKLOG.md` 维护待验清单，**不把 E2 写成 E1**。

## 未完成（按成本）
| 项 | 说明 |
|---|---|
| 浅色主题 | 需全量颜色主题化，成本最高 |
| pane 分屏（上游 workspace deck） | 需布局引擎改造 |
| RDP 常驻会话 + 真键鼠映射 | 需把 render worker 改常驻并暴露 SendInput |
| ProxyJump 跳板 | libssh2 无可插拔 transport，需自建 socket 抽象 |
| arm64 真机 / 上架合规 | 需设备/证书/账号 |
| 平板形态 | 按目标暂停 |

## 验证入口
- `build`：在 `harmonyos/ohos/app` 下 `devecocli build`
- `spec/lint.py`：用例 schema 与步骤合法性
- `tools/check-ids.py`：spec 指向的控件 id 是否都存在
- `tools/run-all.py --quick` / `--only` / 全量

## Round 126：代码整洁 + 静态校验增强

- 删除**未使用的旧 `diagPanel()`**（117 行死代码，曾导致 40+ 个重复 id）
- 修掉 2 处并排重复 `.id(...)`（`hostdel/dialog`、`hostkey/changed`）
- 侧栏 RDP 徽标改名 `rdp/experimental-badge`，避免与诊断面板 `rdp/experimental` 同名（用例解析会命中错的节点）
- `tools/check-ids.py` 现在同时检查：①spec target 缺失 ②静态 id 重复（退出码 2）
  当前：`defined 372 / dynamic 47 / dup 0 / 缺失 0`

## Round 127：新增分页静态检查

`tools/check-paging.py`：诊断面板是分页的（RDP 默认页 / 调试页 / 快照页），
用例若没先点 `diag/tab-debug|snap|rdp` 就点该页控件，运行时必然"选择器未命中"。
当前 105 条用例：**0 违规**。

| 静态校验 | 作用 |
|---|---|
| `spec/lint.py` | schema/步骤合法性 |
| `tools/check-ids.py` | spec target 是否存在 + **静态 id 不重复** |
| `tools/check-paging.py` | 分页规则（先切页） |

## Round 131：一条命令跑完静态门禁

```powershell
powershell harmonyos\tools\check-all.ps1
```
依次执行 **build → spec/lint → check-ids → check-paging**，任一失败立即非零退出。
当前结果：`build SUCCESSFUL` / `lint 全部通过` / `dup: 0 缺失 0` / `paging 0 违规`。

## Round 143：静态门禁扩到五项

`check-all.ps1` 现在依次执行：**build → lint → check-ids → check-paging → check-actions**
- `check-actions.py`：带 `id` 的 Button/Image 若附近没有 `onClick/onChange/onSubmit/onHover/bindMenu`，判为"死控件"
- 当前结果：`dead controls: 0`（本轮据此修掉了 `view/order` 死图标）

