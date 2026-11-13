# Motty 鸿蒙复刻（PC 优先）

[Motty](https://github.com/t8y2/motty)（Go 桌面 SSH / SFTP / VNC / RDP / AI 客户端，Apache-2.0）的
**HarmonyOS PC（2in1）复刻**。本仓库所有新工作都在 `harmonyos/` 下。

> 当前阶段：**只做 PC 端**，平板特性暂停；目标是把 UI 与可实现功能尽量 1:1 对齐上游。

> ⚠️ 模拟器重启后暂无法启动；`docs/E1-BACKLOG.md` 列出了待补 E1 的用例与一条命令。

## 现状（机器判定，非自述）

| 能力 | 状态 | 证据 |
|---|---|---|
| 主机管理（增删改、分组、标签、颜色、**图标**、**最近连接**、协议筛选、批量删除、网格/列表） | ✅ | `host.*` 系列用例 |
| 分组管理（折叠、固定、**重命名**、**删除**、**上移/下移排序 + 持久化**） | ✅ | `host.group-*` |
| 终端（PTY、VT 解析、滚回、选区复制、改尺寸、方向键） | ✅ | `terminal.*`（13 条） |
| SFTP（列举、读写、删除、重命名、建目录、中文名、缺失文件） | ✅ | `sftp.*`（8 条） |
| 端口转发（local / SOCKS5 / HTTP，规则持久化、启停、**编辑**） | ✅ | `forward.*`（8 条） |
| VNC（RFB 3.8、None/DES、Raw+Hextile、指针/键盘、剪贴板、DesktopSize、自适应） | ✅ | `vnc.*`（7 条） |
| RDP（协商+TLS、**自解码位图**、**BMP 预览 + 自动刷新**、**输入回传**、内嵌 shadow 服务端） | ⚠️ 可用但**不等于真实 Windows 桌面** | `rdp.*`（7 条） |
| 命令面板（模糊过滤、↑↓、回车、Esc、悬停高亮、**主机直达**） | ✅ | `command.*`（4 条） |
| 设置（中英双语、默认视图/排序、语言切换；**经 DB 持久化**） | ✅ | `settings.*`、`ui.i18n*` |
| 调试面板（RDP / 调试 / 快照 三页） | ✅ | `diag.tabs`、`ui.*` |
| AI 通路（本地 stub） | ✅ 仅通路 | `ai.request` |

**用例总数：105**；最近一次全量：**83/83 全绿**（连续 7 次全量全通过，见
[docs/REGRESSION.md](docs/REGRESSION.md)）。

## 架构

```
ohos/app/entry/src/main/ets/pages/Index.ets     ← PC 外壳（单文件 ArkUI，约 5k 行）
ohos/app/entry/src/main/cpp/                    ← 协议库（经 NAPI 暴露）
        vt_engine.*, ssh_*, sftp_*, vnc_*, rdp_client.*, rdp_server.*, rdp_napi.cpp
ohos/app/entry/src/main/cpp/third_party/        ← libssh2 / libvncserver / FreeRDP 等
spec/                                           ← YAML 用例 + 运行器 + 证据
tools/                                          ← 批量回归、SBOM、arm64 脚本
docs/                                           ← 回归/UI 对齐/RDP/发布文档
```

**路线 A′**：UI 用 ArkTS/ArkUI 复刻上游的 Wails 前端交互，协议栈用 C/C++ 原生库，
通过 NAPI 调用。ArkTS 侧不直接做协议解析。

## 快速开始

前置：DevEco Studio（含 HarmonyOS SDK）、`hdc`、Python 3、一台 PC/2in1 设备或 `motty_pc` 模拟器。

```powershell
# 1) 构建（在 harmonyos\ohos\app 下）
devecocli build

# 2) 安装到模拟器（127.0.0.1:10100）
hdc -t 127.0.0.1:10100 install -r entry\build\default\outputs\default\entry-default-signed.hap

# 3) 起 SSH/VNC 夹具（用例前置）
harmonyos\.bin\sshfixture.exe -addr 127.0.0.1:2223 -hostkey harmonyos\.bin\.sshfixture\hostkey -hostkeytype rsa
hdc -t 127.0.0.1:10100 rport tcp:2222 tcp:2223
hdc -t 127.0.0.1:10100 rport tcp:5901 tcp:5901

# 4) 跑一条用例
python harmonyos\spec\run.py harmonyos\spec\scenarios\terminal.vt.yaml `
  --serial 127.0.0.1:10100 --profile 2in1 --fresh --out harmonyos\spec\evidence\runs\manual-1

# 5) 定向回归（推荐，5~15 分钟）
# 定向：只跑某前缀（支持逗号分隔）
python harmonyos\tools\run-all.py --only host,forward
# 冒烟：12 条，约 12 分钟
python harmonyos\tools\run-all.py --quick
# 全量（里程碑才用，约 80 分钟）
$env:MOTTY_RUN_ID="full-$(Get-Date -Format yyyyMMdd)"
python harmonyos\tools\run-all.py

# 6) 静态检查（无需设备）
python harmonyos\spec\lint.py
python harmonyos\tools\check-ids.py     # spec 的 target id 是否都存在（无需设备）
python harmonyos\tools\gen-sbom.py --check
```

## 用例约定（写用例前必读）

- 用例里**不要**依赖固定列表下标（主机项进入命令面板后索引会变）；
- 面板分页：ids 在调试页的要先 `click id:diag/tab-debug`，快照页的 `diag/tab-snap`；
- `bindMenu` 弹层不进 `uitest dump`：需要自动化点击的菜单一律**自绘**（例：`groupmenu/*`）；
- 输入框用**非受控**写法（`onChange` 单向写状态 + `placeholder`），否则 IME 注入会被
  `text:` 回填叠加成"旧值+新值"；
- 点开输入框后先 `key 2070`（Esc）收起输入法，再做后续按钮点击；
- 每个数据隔离的用例开头先 `catalog/reset-hosts`；
- 更完整的踩坑清单见 [docs/REGRESSION.md](docs/REGRESSION.md) 与 [docs/RUNBOOK.md](docs/RUNBOOK.md)。

## 已知限制（诚实清单）

1. **RDP 画面**：解码与预览链路（自解码 → BMP → `Image`）在模拟器上验证通过，
   但对端是**进程内 shadow 服务端绘制的测试图案**，**不代表真实 Windows 桌面的像素对齐**；
   与真实 RDP 服务器的端到端像素对比尚未做。
2. **preferences 曾损坏**：设备上出现过 `preferences/motty-ui.broken`（写入不落盘）。
   现已把关键设置迁到 DB `ui_state`，并在备份配置里排除 `preferences`；
   但"损坏文件在应用侧无法删除"这一点没有根治，只被绕开。
3. **arm64 真机**：脚本与材料齐全，**未在真机执行**（当前只有 x86_64 模拟器证据）。
4. **平板形态**：按本轮目标**暂停**，相关用例保留但不在主线要求。
5. **AI**：只验证通路（本地 stub），不含模型质量与真实供应商。
6. 上架合规（隐私声明、签名、审核）未完成。

## 证据等级

| 等级 | 含义 |
|---|---|
| **E1** | 在模拟器上真跑并机器判定通过（用例 + 截图/dump） |
| **E2** | 只做编译/静态/配置验证 |
| **E3** | 未执行或不可复现 |

全量结果在 `harmonyos/spec/evidence/runs/<run-id>/summary.json`；每次提交都带证据目录。

> 交付状态与唯一阻塞：见 [docs/DELIVERY-STATUS.md](docs/DELIVERY-STATUS.md)。

## 文档地图

| 文档 | 内容 |
|---|---|
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | 构建/测试/夹具/踩坑大全（接手先读） |
| [docs/REGRESSION.md](docs/REGRESSION.md) | 用例约定、分页规则、全量历史与基线 |
| [docs/UI-PARITY.md](docs/UI-PARITY.md) | 逐轮 UI 对齐记录与字段对照（含每轮教训） |
| [docs/RDP.md](docs/RDP.md) | RDP 全过程：崩溃根因、自解码、预览、输入 |
| [docs/RELEASE.md](docs/RELEASE.md) | 上架材料与 arm64 验证指引 |
| [docs/MAINTENANCE-PLAN.md](docs/MAINTENANCE-PLAN.md) | 维护与清理计划 |

## 许可

上游 Apache-2.0。本项目因链接 LibVNC（GPL）/ FreeRDP（Apache-2.0）等，整体分发方式见
[LICENSING.md](LICENSING.md)；第三方组件清单见 [SBOM.json](SBOM.json)。
