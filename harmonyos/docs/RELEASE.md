# 发布与真机验证（上架材料 + arm64）
本文件由 `docs/RELEASE.md` 与 `docs/RELEASE.md` 合并而成。

上架硬阻塞：AI 端点默认值、release 证书、arm64 真机、RDP 实验性声明。arm64 真机验证脚本：`tools/verify-arm64.ps1`（守卫 3/4/5/6），RDP 自检：`tools/rdp-selfcheck.py`。

---

<!-- 来源：harmonyos/docs/RELEASE.md（Round 92 合并） -->
# 上架就绪度（Store Readiness）

> 结论先说：**当前不具备直接上架条件**。下面的"已完成"是文档与工程基础，"缺口"是需要账号/证书/设备的硬性事项。
> 本文与 `LICENSING.md`、`SBOM.json` 一起，构成上架材料的最小集合。

## 1. 应用信息（待填/待确认）

| 项 | 值 | 状态 |
|---|---|---|
| 包名 | `com.motty.harmony` | 已定 |
| 版本 | `0.1.0`（versionCode 1000000） | 见 `AppScope/app.json5` |
| 应用名（中/英） | Motty | 已定 |
| 分类 | 工具 / 效率 | 待选 |
| 支持设备 | 2in1（PC）、tablet | 与双画像一致 |
| 分发许可 | **GPL-3.0-or-later**（组合分发） | 见 `LICENSING.md` |

## 2. 权限说明（应用市场必须逐条给理由）

| 权限 | 用途（对外表述） | 触发时机 |
|---|---|---|
| `ohos.permission.INTERNET` | 连接用户指定的 SSH / SFTP / VNC / RDP 服务器，以及用户配置的 AI 端点 | 仅在用户主动发起连接时使用 |

**没有**申请的权限（也是卖点，写进商店描述）：不需要通讯录、位置、相机、麦克风、相册、设备标识；
不申请 `ohos.permission.GET_NETWORK_INFO`（不探测网络类型）。

> 若后续加入"局域网自动发现/扫码连接"，需要补 `GET_NETWORK_INFO` 与相机权限，届时必须更新本节与隐私声明。

## 3. 隐私声明（可直接用作商店文案的底稿）

**我们收集什么**：不收集。应用不含任何统计、埋点、崩溃上报 SDK。

**数据存在哪里**：
1. 主机配置（地址/端口/用户名）存在应用私有数据库（`relationalStore`），仅本机可读。
2. 密码存在系统**资产保险库**（Asset Store Kit，别名 `motty.host.<host:port>`，`DEVICE_UNLOCKED` 级别）。
3. 主机密钥指纹存在应用私有数据库，用于识别"服务器换钥"。

**什么会离开设备**：
- 用户输入的终端/SFTP 内容 → **只发往用户自己配置的那台服务器**。
- VNC/RDP 画面与输入 → 同上。
- **AI 功能**：把用户当前终端尾部约 200 字符作为提示词，发往**用户在设置里填写的端点**。
  默认端点是 `http://127.0.0.1:2297/v1/ai`（本机桩，仅用于自测）；正式分发前必须改为
  明确告知的第三方地址，并在首次使用 AI 时显示确认提示。**这是上架前必须解决的一项。**

**用户如何删除**：删除主机条目会同时删除其保险库口令与 known_hosts 记录（已有用例 `cred.cleared`、
`host.recreate-trust` 证明）；卸载应用会清空全部本地数据。

## 4. 签名与打包

| 步骤 | 说明 |
|---|---|
| 调试签名 | 已在用（DevEco 自动生成），但**不能用于上架** |
| 发布签名 | 需要 AGC 应用证书（.cer）+ Profile（.p7b），在 DevEco `Signing Configs` 里指向 release 配置 |
| 混淆/加固 | 未做；ArkTS 侧可开启混淆，native 侧建议 strip 符号（当前未 strip） |
| 产物 | `entry-default-signed.hap`（当前为 debug 签名） |

> 我无法代你申请证书：这需要你的华为开发者账号与实名信息。

## 5. 合规材料清单

| 材料 | 状态 |
|---|---|
| 第三方清单（SBOM） | **已有**：`harmonyos/SBOM.json`（13 组件 / 29 份产物，含 sha256），由 `tools/gen-sbom.py` 生成并可 `--check` 校验 |
| 开源许可声明 | **已有**：`harmonyos/LICENSING.md`（GPLv3 组合分发 + 各组件许可） |
| GPL 源码提供义务 | 仓库公开（`hnmrxz/motty-HarmonyOS`），满足"提供对应源码"；上架描述里需给出仓库链接 |
| 隐私政策页面 | **缺**（商店要求可访问的 URL；内容可用本文 §3） |
| 用户协议 | **缺** |
| 未成年人保护/敏感词合规 | 不适用（工具类、无 UGC） |
| 安全评估/渗透测试报告 | **缺**（含 SSH/VNC/RDP 客户端，建议上架前做一次） |

## 6. 上架前必须解决的工程项（按优先级）

1. **AI 端点默认值**：`127.0.0.1:2297` 是自测桩，正式版必须改为显式配置 + 首次使用二次确认（隐私）
2. **debug 证书换 release**（需账号）
3. **arm64 真机回归**：当前全部 E1 证据来自 x86_64 模拟器，PC/平板真机（arm64）必须跑一遍
4. **崩溃与内存**：RDP 仅连接路径（客户端栈已链入），若上架需明确"RDP 为实验特性"或先补齐
5. **SBOM 进 CI**：`python harmonyos/tools/gen-sbom.py --check` 作为提交前检查（防止漏登记三方库）

## 7. 一句话总结

**文档与物料基础已就绪**（SBOM 可校验、许可清晰、权限最小化、隐私边界明确），
**但签名证书、隐私政策 URL、arm64 真机验证、AI 端点合规这四项是硬性阻塞**，不属于能在代码仓库里完成的工作。

---

## 附录 A：RDP 功能的"实验性"标注（Round 77 落地）

为避免上架后被当作"可用功能"，诊断面板里已加**常显**提示（中英双语，`rdp/experimental`）：

- 英文：`RDP is experimental: connect works, picture/input are not delivered yet.`
- 中文：`RDP 为实验性功能：可连接，但画面与输入尚未打通。`

实测证据（模拟器 tablet，dump 已确认该文案渲染）：

```
NOTE: RDP is experimental: connect works, picture/input are not delivered yet.
```

配套事实（详见 INDEX Round 70–77）：
- 客户端与服务端**能完成协商并 connected**（`rdp.client-connect` 双画像通过）
- 服务端**能监听并出帧**（脚本化判定）
- 客户端**能收到并解码桌面更新**（`rdp.client-render` 双画像通过，1024×768）
- **但内容停在 shadow 的 lobby 白屏**，画面与输入仍未打通

上架建议：
1. 若必须保留 RDP 入口，保留该提示并把它写进应用描述与隐私声明
2. 若市场审核对"功能不完整"零容忍，则在发布构建里隐藏 RDP 入口（诊断面板整体可关）

---

<!-- 来源：harmonyos/docs/RELEASE.md（Round 92 合并） -->
# arm64 真机验证指引

> 结论先说：**这一步无法在代码仓库里完成**，它需要一台 arm64 的鸿蒙 PC 或平板，以及可用的签名配置。
> 本文提供"拿到设备后照着做"的完整步骤与验收判据；`tools/verify-arm64.ps1` 是它的自动化版本。
>
> 当前状态：所有 E1 证据来自 **x86_64 模拟器**（2in1 / tablet 两个画像）。arm64 仅有 **E2**（双 ABI 静态库编译+链接通过）。

## 1. 为什么必须做真机验证

模拟器与真机的差异**不是"应该一样"**：

| 差异点 | 风险 |
|---|---|
| CPU 架构（arm64 vs x86_64） | 三方差分包、NEON 与对齐、`char` 符号性、浮点 |
| 系统服务实现 | Asset Store Kit 在真机上的别名/权限行为、pasteboard 行为 |
| 图形栈 | `Canvas.fillRect` 大量绘制在真机 GPU 路径下的表现（VNC 用例一次画 4800 个矩形） |
| 网络 | 真实 Wi-Fi/蜂窝下的超时、DNS、MTU |
| 输入 | 触屏手势（本项目的滚动靠 `onTouch` 位移换算） |
| 生命周期 | 真机的后台冻结与内存回收比模拟器激进 |

## 2. 前置条件

1. **设备**：HarmonyOS NEXT 的 arm64 PC 或平板，开启开发者模式与 USB 调试
2. **签名**：真机安装需要 **release 或 debug 证书 + 包含该设备 UDID 的 Profile**
   - 模拟器用的自动签名**不能**装真机
   - 在 DevEco `File → Project Structure → Signing Configs` 里配置
3. **hdc 可达**：`hdc list targets` 能看到设备序列号
4. **宿主（跑脚本的机器）**：能起夹具（`harmonyos\.bin\sshfixture.exe`）并能 `hdc rport`

## 3. 步骤

```powershell
# 1) 确认设备
hdc list targets
# 期望输出形如：<serial>     （不是 127.0.0.1:10100/10101 这两个模拟器）

# 2) 构建（arm64-v8a 已在 build-profile.json5 的 abiFilters 里）
cd harmonyos\ohos\app
devecocli build
# 产物：entry\build\default\outputs\default\entry-default-signed.hap

# 3) 安装
hdc -t <serial> install -r entry\build\default\outputs\default\entry-default-signed.hap

# 4) 建端口转发（设备→宿主；模拟器切换后也会丢，需重建）
hdc -t <serial> rport tcp:2222 tcp:2223     # SSH/SFTP
hdc -t <serial> rport tcp:5901 tcp:5901     # VNC
hdc -t <serial> rport tcp:2297 tcp:2297     # AI stub

# 5) 起夹具
harmonyos\.bin\sshfixture.exe -addr 127.0.0.1:2223 `
  -hostkey harmonyos\.bin\.sshfixture\hostkey -hostkeytype rsa

# 6) 跑全量（脚本会自动切换夹具模式并记录矩阵）
pwsh -File harmonyos\tools\verify-arm64.ps1 -Serial <serial>
# 结果：harmonyos\spec\matrix\matrix-device.json
```

## 4. 验收判据（机器判定）

| 判据 | 阈值 |
|---|---|
| 用例总数 | 41 条全部执行 |
| 通过率 | **41/41**。任何一条失败都必须给出原因，不允许"跳过" |
| 证据产物 | 每条用例目录下有 `result.json`、`final.png`、`final.json` |
| 矩阵 | `spec/matrix/matrix-device.json` 中 `passed` 全为 true |

**不满足上述任一条 = arm64 未验证通过**，能力表里对应条目的 `evidence` 必须保持 E2，不能改成 E1。

## 5. 已知的真机风险点（按概率排序）

1. **VNC 绘制**：4800 个 `fillRect`/帧在真机可能出现掉帧；若崩溃看 `faultlog/faultlogger` 的 cppcrash
2. **Asset Store Kit**：`DEVICE_UNLOCKED` 可访问性在真机的锁屏态行为；`cred.cleared` 用例会暴露
3. **剪贴板**：真机 `getData()` 回读可能非空（模拟器上曾返回空），此时用例断言仍应通过（我们只断言 `copied N chars`）
4. **触控滚动**：`onTouch` 位移换算的灵敏度在真机触摸屏上可能与 `uitest swipe` 不一致
5. **hdc rport 生命周期**：长时间空闲后可能失效，脚本每条用例前重建

## 6. 记录模板（跑完请填）

```
设备型号：
系统版本：
CPU/ABI：arm64-v8a
签名方式：debug / release
执行时间：
用例总数 / 通过数：
失败用例与原因：
矩阵文件：spec/matrix/matrix-device.json
```

## 7. 我这边已经做完的部分

- `spec/run.py` 新增 `--profile device`（真机画像）：接受任意声明了模拟器画像的用例，结果单独落盘，**不混淆模拟器与真机证据**
- `tools/verify-arm64.ps1`：检测设备、建 rport、起夹具、逐条跑、出矩阵；设备不存在时**明确报错退出**（不假装通过）
- SBOM/许可/上架材料：见 `SBOM.json`、`LICENSING.md`、`docs/RELEASE.md`

---

## 附录 B：真机上先跑 RDP 现状自检（Round 79 新增）

在真机上**先跑这一条**，能立刻分辨"是 arm64 特有的问题"还是"功能本来就只到这一步"：

```powershell
C:\Python315\python.exe harmonyos\tools\rdp-selfcheck.py --serial <真机序列号> --profile device --fresh
```

它会依次跑三条机器判定用例并汇总：

| 用例 | 验证什么 |
|---|---|
| `rdp.client-connect` | 客户端与服务端完成协商并 connected |
| `rdp.client-render` | 客户端收到并解码桌面更新（尺寸/像素数） |
| `ui.rdp-experimental` | 界面诚实标注 RDP 为实验性 |

退出码：`0` 全通过 / `1` 有失败 / `2` 环境或参数问题。

**边界**：这三条只证明"能连接 / 能解码 / 界面诚实"。
**画面内容正确与输入回传仍属 E3**，脚本输出里也会打印这句提醒，避免被当成"RDP 可用"。
