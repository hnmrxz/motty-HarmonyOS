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
