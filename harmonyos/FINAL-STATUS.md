# Motty 鸿蒙复刻 — 交接总览（Round 88）

> 一页看完：**做到了什么、没做到什么、接下来怎么继续、踩过哪些坑**。
> 所有结论都标了证据级别：**E1** = 模拟器双画像实测 ｜ **E2** = 编译/静态 ｜ **E3** = 未验证。

## 1. 一句话结论

终端、SFTP、端口转发、VNC、i18n、AI 通路、SBOM 与上架材料**都有双画像机器判定**；
**RDP 只到"能协商 + 能解码一帧"，画面内容与输入仍未打通**；**arm64 只有编译证据，真机没跑过**。

## 2. 数字

| 指标 | 值 |
|---|---|
| 用例（机器判定） | **56 条**（`spec/scenarios/*.yaml`，`spec/lint.py` 全绿） |
| E1 能力 | **16 条**（`spec/capabilities.json`） |
| 回归/冒烟矩阵 | round82 **8/8**、round85 **2/2**、round87 **4/4**（均双画像） |
| SBOM | 16 组件 / 36 份产物（`--check` 通过） |
| 模拟器 | `motty_pc`（2in1, :10100）、`motty_tablet`（tablet, :10101），x86_64 / API 26 |

## 3. 完成情况（按目标五项）

### ① i18n 中英双语与切换 —— **E1 完成（覆盖面已收口）**
- 取词表 60+ 键，覆盖：顶栏、主机区、**SFTP / 转发 / VNC / 诊断**四块面板
- 用例 5 条：`ui.i18n`、`ui.i18n.panels`、`ui.i18n.diag`、`ui.i18n.vnc`、`ui.i18n.diagnostics`
- 每条都带**反向断言**：英文原文 + 键名都必须缺席（防止"中文在屏上"其实是没渲染到那一行）
- 未做：第三种语言、跟随系统语言、复数与日期本地化

### ② AI 最小可验收切片 —— **E1 完成（只验证通路）**
- 本地 stub 端点（`tools/design/sshfixture/ai_fixture.go`，`POST /v1/ai`）+ 界面 `ai/ask`
- 用例 `ai.request` 双画像通过
- **不证明**：模型质量、真实服务、鉴权、流式、多轮 —— 全部未做

### ③ SBOM 与上架材料 —— **E2 完成（材料齐，合规未做）**
- `SBOM.json`（16 组件 / 36 产物，含 sha256）+ `tools/gen-sbom.py --check`，已接入 `spec/lint.py`
- `STORE-READINESS.md`：权限（仅 `ohos.permission.INTERNET`）、隐私声明草稿、签名指引、4 个硬阻塞
- 附录 A：RDP **实验性**标注（有 `ui.rdp-experimental` 用例守着）
- 未做：release 证书、隐私政策 URL、渗透测试

### ④ RDP 客户端完整链路 —— **部分（关键链路通，画面/输入未通）**
| 环节 | 状态 | 证据 |
|---|---|---|
| 内嵌服务端（FreeRDP shadow）**能监听、能出帧** | ✅ | `tools/rdp-selfcheck.py` + 脚本化判定 |
| 客户端 **协商 + TLS + connected** | ✅ E1 | `rdp.client-connect` |
| 客户端 **收到并解码桌面更新**（1024×768=786432） | ✅ E1 | `rdp.client-render` |
| **画面内容正确** | ❌ E3 | 停在 shadow 的 lobby 白屏 `#FFFFFF` |
| 输入回传 / NLA / 真实 Windows 互通 | ❌ E3 | 未做 |
| 界面诚实告知 | ✅ E1 | `ui.rdp-experimental` |

### ⑤ arm64 真机验证指引与脚本 —— **E2（脚本与指引就绪，真机未跑）**
- `tools/verify-arm64.ps1`（4 个守卫含负向验证：缺设备 3、模拟器序列号 4、缺 HAP 5、安装失败 6）
- `ARM64-REAL-DEVICE.md`：步骤、41 项验收、风险清单、记录模板、**附录 B 先跑 RDP 自检**
- 三方库 arm64 静态库齐（libssh2/mbedTLS/OpenSSL/FreeRDP/libvterm/libvnc*）

## 4. 接手者的最短路径

```powershell
# 1) 环境自检
python harmonyos\spec\lint.py
python harmonyos\tools\gen-sbom.py --check

# 2) 一条命令看 RDP 现状（真机/模拟器都行）
python harmonyos\tools\rdp-selfcheck.py --serial <序列号> --profile device --fresh

# 3) 真机 41 项
powershell harmonyos\tools\verify-arm64.ps1 -Serial <真机序列号>
```

**RDP 画面这块的三条路**（Round 89 已把"为什么卡住"用证据钉死，这里是可选方向）：
1. **打补丁改 FreeRDP**：`rdpShadowClient` 的 `inLobby` 字段是**不透明结构**（`shadow.h` 只有前置声明），
   公共 API 改不了。要离开 lobby 只能改 `shadow_client_post_connect` 后重编
2. 放弃 shadow，自己实现最小 RDP 服务端（完全控制画面，工作量最大但最可控）
3. 用真实 Windows 服务端验证客户端（需要你有可开启远程桌面的机器）

## 5. 踩过的坑（都写进 RUNBOOK 了）

| 坑 | 后果 | 现在怎么做 |
|---|---|---|
| `bm clean -d` | 应用**回滚到旧版本** | `--fresh` 用 `hdc uninstall` + `hdc install` |
| `devecocli build` 跳过打包 | 跑到旧二进制 | 删 `.hvigor` + `entry/build`，**核对 HAP 时间戳** |
| 状态行是**点击瞬间快照** | 误判"卡死" | 先点刷新按钮再读 |
| `type` 是**光标处插入** | `uploaded.txt中文文件.txt`、`22022221` | 输入框默认值留空；测试不依赖键入 |
| `Row` 里 `Text.width('100%')` | 后面按钮被挤出面板**不渲染** | 去掉 100%；面板套 `Scroll`；按钮拆行 |
| NAPI 返回裸 `ArrayBuffer` | ArkTS 读出来全是 0 | 返回 **`Uint8Array`** |
| `ClientNew` 返回 0 | `freerdp_client_context_new` 返回 NULL | 返 **TRUE**；`ContextSize` 必须非 0（否则 SIGFPE） |
| `gdi_init` 之后挂 `BitmapUpdate` | 回调**永不触发** | 用 `EndPaint` + 读 `gdi->primary_buffer` |
| PowerShell here-string 拼中文 | 追加内容**静默为空**（INDEX 丢过 4 个轮次） | 中文文档用 Python 写 |

## 6. 明确不声称的

- ❌ 不说"RDP 可用"：只是**能连接、能解码一帧**，画面内容仍是 lobby 白屏
- ❌ 不说"支持 arm64"：只有编译证据，真机 41 项**一行没跑**
- ❌ 不说"可上架"：缺 release 证书、隐私政策 URL、渗透测试
- ❌ 不说"全量回归通过"：只有定向回归 8 条 + 认证模式 2 条 + 冒烟 4 条
