# E1 待验清单（模拟器恢复后跑）

> 模拟器重启后无法启动（`hdc list targets` 为空，`-wipe-data` 无效，需要 DevEco GUI 重新启动）。
> 以下用例已写好、已过 `lint` 与 `check-ids` 静态检查，但只有 **E2**。

## 一条命令

```powershell
python harmonyos\tools\run-all.py --only vault,settings.tab,jump,knownhosts,logs,settings.scrollback
```

| 用例 | 覆盖 |
|---|---|
| `vault.add` | 密钥链新增凭据（对话框 → 保存 → 结果显示） |
| `settings.tab-numbers` | 标签编号开关生效 |
| `settings.tab-side` | 侧栏标签（顶部标签栏消失） |
| `settings.scrollback` | 回滚行数按钮 + 重启保持 |
| `jump.page` | 跳板路由说明页（不再是死链） |
| `knownhosts.export` | 已知主机导出/导入链路 |
| `logs.proto-filter` | 日志协议筛选 chips |
| `logs.export` | 日志导出 JSON（此前已单跑通过，回归确认） |

## 通过后要做的收尾
1. 跑一次 `--quick`（12 条）确认没有连带回归；
2. 更新 `docs/REGRESSION.md` 基线（用例数 99 → 全绿数）；
3. 更新 `README.md` 的用例数/能力表；
4. 视情况跑一次全量（约 80 分钟）。

## 模拟器起不来的**根因**（Round 120 定位）

```
Get-Service vmcompute  -> Stopped
Start-Service vmcompute -> 无法打开计算机"."上的 vmcompute 服务
```
`Hyper-V 主机计算服务 (vmcompute)` 处于停止状态，且当前会话**没有权限启动它**
（`Get-WindowsOptionalFeature` 也报 "requires elevation"）。
Emulator.exe 只是外壳，真正跑虚拟机的 qemu 需要该服务 ⇒ 进程在但虚拟机没起来。

### 需要用户做的（任选其一）
1. **以管理员身份打开 DevEco Studio**，从 Device Manager 启动 `motty_pc`；
2. 或在**管理员 PowerShell** 里：`Start-Service vmcompute`，然后再启动模拟器；
3. 若仍失败，检查「启用或关闭 Windows 功能」里 *Hyper-V* / *Windows 虚拟机监控程序平台* 是否被关闭（重启后有时被系统关闭）。

### 待补 E1 的用例（共 9 条）
`vault.add`、`settings.tab-numbers`、`settings.tab-side`、`settings.scrollback`、
`settings.display-toggles`、`settings.startup-view`、`jump.page`、`knownhosts.export`、`logs.proto-filter`
（`logs.export` 此前已 E1，回归时一并确认）

一条命令：
```powershell
python harmonyos\tools\run-all.py --only vault,settings.tab,settings.scrollback,settings.display,settings.startup,jump,knownhosts,logs
```

## 新增待验（Round 129~133）

| 用例 | 覆盖 |
|---|---|
| `ui.toolbar` | 顶栏：新会话 / 刷新 / 排序切换 / 粘贴 / 本地终端 / AI / 通知 + 提示行 |
| `host.menu` | 主机行 ⋯ 菜单：复制地址提示、详情面板 |
| （视觉）hover 显隐 | 主机行操作区 `opacity 0.3 → 1`（悬停时完全显示）—— 属视觉行为，**无自动断言**，需人工目视 |

一条命令（含上面全部）：
```powershell
python harmonyos\tools\run-all.py --only vault,settings.tab,settings.scrollback,settings.display,settings.startup,settings.reset,jump,knownhosts,logs,workspace,ui.toolbar,host.menu
```

## Round 167 新增

| 用例 | 覆盖 |
|---|---|
| `logs.filters-combo` | 日志主机 chip + SSH 协议 + 关键词三重 AND 过滤（计数 0 / N） |

