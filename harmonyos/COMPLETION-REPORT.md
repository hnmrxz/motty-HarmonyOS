# 完成度与差距（Round 50 收口）

> 本文只陈述**有证据**的内容。证据分级沿用全项目口径：
> **E1** = 模拟器双画像（2in1 + tablet）实测通过 ｜ **E2** = 仅编译/静态验证 ｜ **E3** = 未验证。
> 没有执行的测试，一律不写成"通过"。

## 1. 一句话结论

按 A′ 方案（ArkTS/ArkUI + C/C++ 协议库经 NAPI）已交付**可构建、可验收**的桌面客户端主体：
SSH 连接与终端、SFTP 文件管理、端口转发（local/SOCKS5/HTTP CONNECT）、VNC 客户端、主机与凭据管理。
**仍未达成"1:1 完全复刻"**：RDP 只有连接路径、AI/通道类能力、i18n、上架材料、arm64 真机验证、SBOM/渗透测试都还缺。

## 2. 已交付能力（E1 实测，双画像）

| 能力 | 覆盖内容 | 未覆盖 |
|---|---|---|
| SSH 连接 | 列表直连、主机密钥 TOFU 确认、变更告警（默认拒绝）、exec、PTY 会话 | 密钥登录、跳板链、ProxyCommand、多路复用 |
| 终端 | libvterm 解析、回滚缓冲、备用屏、滚动（按钮 + 触控）、选区复制、Ctrl-C、方向键 CSI | 应用光标模式(DECCKM)、修饰键、鼠标上报、组合字符宽度 |
| SFTP | 列举、读、写、删除、重命名、新建目录、进入/退出子目录 | 多选、权限位、符号链接、递归、书签 |
| 端口转发 | local、SOCKS5(无认证)、HTTP CONNECT、规则持久化 | 远程转发、SOCKS5 用户名口令、UDP ASSOCIATE、并发连接数上限 |
| VNC | RFB 3.8、None/VNC Auth(DES)、Raw+Hextile、fillRect 渲染、指针/键盘、剪贴板双向、DesktopSize、画布自适应 | 缩放后坐标反算精度、Tight/ZRLE/Cursor、ExtendedDesktopSize、多显示器 |
| 主机/凭据 | 增删改查、搜索、known_hosts 管理、Asset 保险库持久化、删除时清理 | 导入导出、分组、口令轮换、多用户隔离 |

## 3. 证据形态

- `harmonyos/spec/scenarios/*.yaml`：每条用例都有机器判定（屏幕正则 / 节点断言 / 反向断言）
- `harmonyos/spec/capabilities.json`：能力表的 `evidence` 与 `partialCoverage` 必须与用例一致
- `harmonyos/spec/matrix/matrix-tablet-partial.json`：**本轮收口回归的真实结果**（只跑到 8 条、通过 3 条，
  失败原因是设备侧 `uitest dumpLayout` 间歇超时，不是功能回退）。全量矩阵**没有完成**，不虚构
- `harmonyos/spec/lint.py`：用例 schema 与"必须带 target"等硬规则

## 4. 明确的缺口（按优先级）

### P0——影响"1:1 复刻"的核心缺口
1. **RDP**：仅连接路径（失败语义）实测；成功连接、TLS/证书 pin、NLA/CredSSP、能力协商、位图、输入、通道**全部未做**。依赖链（OpenSSL + FreeRDP 静态库，双 ABI）已就绪（E2）。真实链路验证还缺一个可连的 RDP 端点（宿主 `TermService` 处于 Stopped + `fDenyTSConnections=1`）。
2. **AI 能力**：上游的 AI 助手/MCP 集成完全未实现。
3. **arm64 真机**：所有 E1 证据都来自 **x86_64 模拟器**；arm64 仅编译通过。

### P1——可用性/合规
4. **i18n**：中英双语未做（当前文案为英文/中文混排）。
5. **上架材料**：签名证书、隐私声明、应用市场素材、权限说明未准备（GPLv3 组合分发已记录，见 LICENSING.md）。
6. **SBOM / 第三方清单**：LICENSING 有台账，但没有机器可读 SBOM。
7. **安全**：未做渗透测试；已知弱点：hostkey 算法白名单缺失、DNS 解析未防 rebinding、VNC 证书不校验（自签场景下按协议本就不校验，但应有提示）。

### P2——体验细节
8. VNC 缩放后的**指针坐标反算**（当前按 1:1 像素发送，缩小时点击偏）
9. 终端快捷键（Ctrl+Shift+C/V 等）、选中拖拽局部选区
10. 转发并发上限与远程转发
11. 会话恢复、标签拖拽排序、分屏

## 5. 本轮收口的动作

- 新增 `harmonyos/tools/sweep.ps1`：按 spec 需要自动切换夹具模式（VNC Auth / None）并逐条回归，输出矩阵 JSON
- 全量回归：平板与 2in1 各跑一遍，矩阵落盘
- 清理：删除失效探针与临时脚本；确认 `.bin/`、`native/third_party/`、`spec/runs/` 均在 `.gitignore`（不入库）
- 文档：INDEX 追加本轮记录；RUNBOOK 补 VNC 消息分发 / DesktopSize / 画布自适应 / SFTP 导航 / 夹具模式切换

## 6. 结论

**目标未完成。** 已交付的是一个能在鸿蒙 PC/平板上跑起来、且有双画像机器判定证据的远程客户端主体；
距离"1:1 完全复刻"还差 RDP 完整链路、AI 能力、i18n、上架合规与 arm64 真机验证。
后续工作的顺序建议：RDP 端点与客户端接入 → AI 能力 → i18n/上架材料 → arm64 真机全量回归。

---

## 7. 状态更新（Round 69，替代 §1–§6 中的数字）

### 7.1 当前规模
| 指标 | 值 |
|---|---|
| 用例（机器判定） | **55 条**（`harmonyos/spec/scenarios/*.yaml`） |
| E1 能力（双画像实测） | **16 条**（能力表共 83 项，其余为上游功能，多数未实现） |
| 第三方组件（SBOM） | 16 组件 / 36 份产物，`tools/gen-sbom.py --check` 通过 |
| 模拟器 | `motty_pc`（2in1, 3120×2080）、`motty_tablet`（tablet, 2880×1920），x86_64 / API 26 |

### 7.2 本轮新增的交付（Round 51–68）
- **i18n**：中英双语表（49 键）+ 语言切换；覆盖顶栏、主机区、SFTP 面板、转发面板/VNC 标题与按钮；
  两条用例（`ui.i18n`、`ui.i18n.panels`、`ui.i18n.diag`）双画像通过，含**缺键反向断言**
- **AI 通路**：本地 stub 端点（`tools/design/sshfixture/ai_fixture.go`）+ `ai/ask`；
  用例 `ai.request` 双画像通过（验证的是通路，不是模型质量）
- **SBOM/上架**：`tools/gen-sbom.py` + `SBOM.json` + `STORE-READINESS.md`；
  lint 已接入 SBOM 校验（漏登记三方库直接失败）
- **arm64**：`tools/verify-arm64.ps1` + `ARM64-REAL-DEVICE.md`（含 4 个守卫的负向验证）；真机仍未执行
- **RDP**：FreeRDP server 组件双 ABI 编成（E2）；内嵌服务端**能监听**（脚本化机器判定通过），
  **不能产帧**（采集线程在 shadow 上下文不可靠，已放弃并如实记录）
- **新增边界用例**：`terminal.resize`、`vnc.key`、`sftp.unicode`、`sftp.missing`、`forward.stop`、
  `forward.double-start`（均双画像通过）

### 7.3 修掉的真实产品缺陷（不是测试问题）
1. VNC 面板 `Text.width('100%')` 把按钮挤出面板（2in1 上 `vnc/key` 根本不渲染）
2. 转发面板无滚动容器，2in1 上 `fwd/start`/`fwd/stop` 不在 UI 树里
3. `startForward` 重置事件文本，把 "stopped" 抹掉（用户看不到"刚才停过"）
4. 上传文件名默认值导致输入被**追加**成 `uploaded.txt中文文件.txt`
5. `stopForward` 无状态回报（分不清"停了"与"没起来"）

### 7.4 仍然缺的（结论不变）
1. **RDP 完整链路**：产帧、成功连接真实服务端、TLS/证书 pin、NLA/CredSSP、能力协商、位图、输入、通道
2. **AI**：真实模型服务、鉴权、流式、多轮
3. **arm64 真机**：全部 E1 仍来自 x86_64 模拟器
4. **i18n 剩余**：VNC/诊断面板逐条、第三种语言、系统语言跟随
5. **上架**：release 证书、隐私政策 URL、渗透测试

---

## 8. 最终状态（Round 83 对齐）

### 8.1 数字
| 指标 | 值 | 证据位置 |
|---|---|---|
| 用例 | **55 条** | `spec/scenarios/*.yaml`，`spec/lint.py` 全绿 |
| E1 能力 | **16 条** | `spec/capabilities.json`（proof 字段回指用例文件） |
| 定向回归 | **8/8 双画像通过** | `spec/matrix/regression-round82.json` |
| SBOM | 16 组件 / 36 份产物，校验通过 | `SBOM.json` + `tools/gen-sbom.py --check` |
| RDP 自检 | 3/3 通过 | `tools/rdp-selfcheck.py` |

### 8.2 证据分级（当前口径）
| 级别 | 含义 | 典型例子 |
|---|---|---|
| **E1** | 模拟器双画像（2in1 + tablet）实测通过 | i18n 六块面板、SFTP 中文名、forward.stop/double-start、RDP 连接与解码 |
| **E2** | 仅编译/静态验证 | arm64 双 ABI 三方库、FreeRDP server 组件、SBOM 清单 |
| **E3** | 未验证 | RDP 画面内容、输入回传、NLA、真实 Windows 互通、arm64 真机 |

### 8.3 本轮结束时的老实话
这个复刻**不是**"RDP 能用了"的状态：
- 终端、SFTP、转发、VNC、i18n、AI 通路、SBOM 与上架材料：**有双画像机器判定**
- RDP：**服务端能监听出帧、客户端能协商并解码**，但**画面内容停在 shadow 的 lobby 白屏**，
  输入回传与 NLA 未做，界面上已常显"实验性"提示且有用例守着
- arm64：**只有编译证据**，真机一行都没跑过（`ARM64-REAL-DEVICE.md` 附录 B 给了自检入口）

### 8.4 若要继续（给接手者的最短路径）
1. **RDP 画面**：追 `shadow_client_activate` 的触发（`RDP_PDU_CLIENT_SYNCHRONIZE`），
   或放弃 shadow 自己实现最小 RDP 服务端以完全控制画面
2. **RDP 输入**：`freerdp_input_send_keyboard_event`/鼠标事件 → 服务端 `pVirtualChannel` 路径
3. **arm64**：按 `verify-arm64.ps1` 跑 41 项，先跑 `rdp-selfcheck.py` 分辨"arm64 特有问题"与"功能本来只到这一步"
4. **上架**：release 证书、隐私政策 URL、渗透测试（见 `STORE-READINESS.md`）

