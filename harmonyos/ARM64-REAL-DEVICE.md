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
- SBOM/许可/上架材料：见 `SBOM.json`、`LICENSING.md`、`STORE-READINESS.md`
