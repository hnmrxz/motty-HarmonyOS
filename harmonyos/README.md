# Motty 鸿蒙复刻（A′：ArkTS/ArkUI + C/C++ 经 NAPI）

Motty（Go 桌面 SSH/SFTP/VNC/RDP/AI 客户端，Apache-2.0）的鸿蒙 PC/平板复刻。
本仓库所有新工作都在 `harmonyos/` 下。

## 一分钟了解现状

| 能力 | 状态 |
|---|---|
| 终端（PTY + VT 解析 + 滚回 + 选区 + 改尺寸） | ✅ **E1** 双画像 |
| SFTP（列举/读写/删除/重命名/新建目录/中文名/缺失文件） | ✅ **E1** 双画像 |
| 端口转发（local/SOCKS5/HTTP + 规则持久化 + 停启） | ✅ **E1** 双画像 |
| VNC（RFB 3.8、None/DES 认证、Raw+Hextile、指针/键盘、剪贴板、DesktopSize） | ✅ **E1** 双画像 |
| i18n 中英双语（六块界面 + 语言切换） | ✅ **E1** 双画像 |
| AI 通路（本地 stub 端点 + `ai/ask`） | ✅ **E1**（只验证通路，不含模型质量） |
| SBOM / 上架材料 / arm64 脚本与指引 | ✅ **E2**（材料齐，合规与真机未做） |
| RDP | ⚠️ **部分**：协商+TLS+connected+解码桌面更新 ✅；**画面内容与输入 ❌ E3** |
| arm64 真机 41 项 | ❌ **未执行** |

数字：**56 条机器判定用例**、**16 项 E1 能力**、SBOM 16 组件/36 产物、四份回归矩阵全双画像。

## 文档地图（4 份一级 + 历史归档）

| 文档 | 内容 |
|---|---|
| **[docs/RUNBOOK.md](docs/RUNBOOK.md)** | 构建/测试/夹具/踩过的坑（§1–§36），**接手先读这份** |
| **[docs/RDP.md](docs/RDP.md)** | RDP 可行性、服务端路线、当前卡点与证据 |
| **[docs/RELEASE.md](docs/RELEASE.md)** | 上架材料（权限/隐私/签名/阻塞） + arm64 真机验证 |
| **[docs/history/](docs/history/)** | `INDEX.md`（91 轮逐轮记录）、`FINAL-STATUS.md`、`COMPLETION-REPORT.md` |
| [docs/MAINTENANCE-PLAN.md](docs/MAINTENANCE-PLAN.md) | 维护计划与清理/压缩方案 |

## 常用命令

```powershell
# 一致性检查（无需设备）
python harmonyos\spec\lint.py
python harmonyos\tools\gen-sbom.py --check

# 跑一条用例（模拟器 2in1 / tablet）
python harmonyos\spec\run.py harmonyos\spec\scenarios\terminal.vt.yaml --serial 127.0.0.1:10100 --profile 2in1 --fresh

# RDP 现状一条命令（模拟器或真机）
python harmonyos\tools\rdp-selfcheck.py --serial <序列号> --profile device --fresh

# arm64 真机 41 项
powershell harmonyos\tools\verify-arm64.ps1 -Serial <真机序列号>
```

## 证据在哪

- 用例结果与截图：`harmonyos/spec/evidence/`（`result/*/result.json` + `shots/*/*.jpg`，已入库）
- 回归矩阵：`harmonyos/spec/matrix/*.json`
- 能力表：`harmonyos/spec/capabilities.json`（E1 条目均回指用例文件）

## 许可

上游 Apache-2.0；本项目因使用 LibVNC（GPL）与 FreeRDP（Apache-2.0）而整体以兼容方式分发，
详见 [LICENSING.md](LICENSING.md)。
