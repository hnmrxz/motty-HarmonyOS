# Phase 0 门禁 Spike 执行手册（模拟器版）

> **本版变更（2026-11-10）**：测试基线由"真机"改为 **DevEco 鸿蒙模拟器（虚拟机）**。因此 G1 的可执行 ABI 从 arm64 变为 **x86_64**（见 §A.3 的证据等级），arm64 降为"仅交叉编译验证"。
> 时间盒：G1 共 10 个工作日，三级递进，任一级失败立即停下看 §D 决策表。
> 路径均为本机实测值。

---

## 0. 环境前置（当前状态）

| 项 | 状态 | 说明 |
|---|---|---|
| 模拟器二进制 | ✅ 已装 | `C:\Program Files\Huawei\DevEco Studio\tools\emulator\Emulator.exe` |
| 虚拟化 | ✅ 就绪 | `HypervisorPresent: True`（Hyper-V 在跑，`hns`/`hvhost` 运行中）；`VMMonitorModeExtensions: False` 是"已在 hypervisor 之下"的正常表现，不是故障 |
| 华为账号 | ✅ 已登录 | `devecocli auth status` → 傲**** |
| 模拟器许可 | ✅ 已接受 | `devecocli emulator license accept`（4 份协议，全文存 `harmonyos/.emulator-license.txt`） |
| 系统镜像 | ⏳ 下载中 | `HarmonyOS 7.0.0(26.0.0)` / **2in1**（后台任务 `pwsh-afdd331a9be14b46`）+ **tablet**（`pwsh-d4589efb4c2b49b8`）。**两个都要**：平板同为 1:1 目标，见 PLAN §12.3 |
| 设备类型可用性 | ✅ | 镜像目录含 **2in1**、**tablet** 在 API 26，正好覆盖「PC + 平板」两个目标 |
| Go 工具链 | ❌ **未安装** | `winget` 可用（`C:\Users\Administrator\AppData\Local\Microsoft\WindowsApps\winget.exe`） |
| `../viva` | ❌ 不存在 | 需 `git clone https://github.com/vivaui/viva E:\viva` |
| 占用空间 | 够 | C: 132 GB 空闲 / D: 200 GB / E: 193 GB |

```powershell
# 镜像（已启动，后台任务 pwsh-afdd331a9be14b46）
devecocli emulator image download --device-type 2in1   --os-version "HarmonyOS 7.0.0(26.0.0)"
devecocli emulator image download --device-type tablet --os-version "HarmonyOS 7.0.0(26.0.0)"

# 实例
devecocli emulator create motty-pc     --device-type 2in1   --os-version "HarmonyOS 7.0.0(26.0.0)" --memory 4 --storage 8
devecocli emulator create motty-tablet --device-type tablet --os-version "HarmonyOS 7.0.0(26.0.0)" --memory 4 --storage 8

# 启动（--no-window 可无界面跑；--boot-mode snapshot 热启可加速回归）
devecocli emulator start motty-pc
devecocli device list
hdc list targets
```

---

## A. G1：Go → HarmonyOS（核心门禁，10 个工作日）

### A.1 先确认 guest ABI（5 分钟，决定后面所有命令）

```powershell
$HDC = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
& $HDC shell getprop ro.product.cpu.abi
& $HDC shell getprop ro.build.version.sdk
& $HDC shell uname -m
```

- 预期 `x86_64`、`26`。**若返回 `arm64-v8a`，则下面所有 `GOARCH` 换成 `arm64`、CC 换 `aarch64-unknown-linux-ohos-clang`。**
- 这一行输出要记进结论表——它是"模拟器上能证明什么"的边界。

### A.2 第 1 级：纯 Go 静态二进制（0.5 天）——只验内核 ABI

`CGO_ENABLED=0` 的 Go 二进制不依赖任何 libc，直接用 Linux 原始系统调用。

```powershell
go version                       # 需 Go 1.26，与 go.mod 一致
winget install --id GoLang.Go -e  # 未安装时

mkdir E:\motty-HarmonyOS\harmonyos\spike\hello -Force
cd E:\motty-HarmonyOS\harmonyos\spike\hello
# hello.go: package main; import ("fmt";"runtime"); func main(){ fmt.Println("ohos-ok", runtime.GOOS, runtime.GOARCH) }

$env:CGO_ENABLED="0"; $env:GOOS="linux"; $env:GOARCH="amd64"
go build -o hello-ohos .

$HDC = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
& $HDC file send .\hello-ohos /data/local/tmp/hello-ohos
& $HDC shell "chmod +x /data/local/tmp/hello-ohos && /data/local/tmp/hello-ohos"
```

**通过判定**：输出 `ohos-ok linux amd64`。
**边界**：`hdc shell` 在应用沙箱**之外**，这一级只证明内核 ABI 兼容，**不能**推断应用内可用。
**失败**：`hilog` 抓崩溃点（seccomp 拦 `clone3`/`futex`、`/proc` 受限）→ 走 §D 分支 B。

### A.3 第 2 级：cgo + NDK 产 `.so`（3–4 天）

```powershell
$NDK = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native"
& "$NDK\llvm\bin\x86_64-unknown-linux-ohos-clang" --version   # 模拟器主目标
& "$NDK\llvm\bin\aarch64-unknown-linux-ohos-clang" --version  # 真机目标，仅编译验证
```

Go 侧（`harmonyos\spike\core\`）：`//export MottyAdd`，`func main(){}`。

```powershell
cd E:\motty-HarmonyOS\harmonyos\spike\core
$NDK = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native"

# ① 模拟器可执行目标 x86_64
$env:CGO_ENABLED="1"; $env:GOOS="linux"; $env:GOARCH="amd64"
$env:CC="$NDK\llvm\bin\x86_64-unknown-linux-ohos-clang"
go build -buildmode=c-shared -o libmottycore-x86_64.so .
& "$NDK\llvm\bin\llvm-nm" -D .\libmottycore-x86_64.so | Select-String MottyAdd

# ② 真机目标 arm64 —— 只编译，不执行（无设备）
$env:GOARCH="arm64"
$env:CC="$NDK\llvm\bin\aarch64-unknown-linux-ohos-clang"
go build -buildmode=c-shared -o libmottycore-arm64.so .
& "$NDK\llvm\bin\llvm-nm" -D .\libmottycore-arm64.so | Select-String MottyAdd
```

**通过判定**：`x86_64` 与 `arm64` **都能编译出 `.so`** 且 `MottyAdd` 为 `T`；只有 x86_64 会在模拟器上被真实加载执行。
**若 `c-shared` 不支持**：改 `-buildmode=c-archive`，产 `.a` + `.h`，静态链进 NAPI 宿主 `.so`。不要在这里停住。

### A.4 第 3 级：NAPI 宿主 + ArkTS 调用（5 天）——端到端闭环

空 HarmonyOS 工程（Empty Ability，API 26），然后：

1. `build-profile.json5`：`compileSdkVersion: 26`，`abiFilters: ["x86_64"]`（先只做模拟器目标；arm64 后续追加）
2. `entry/src/main/module.json5`：`deviceTypes: ["2in1", "tablet"]`
3. `entry/libs/x86_64/libmottycore.so`
4. `entry/src/main/cpp/CMakeLists.txt`：`add_library(mottynapi SHARED napi_init.cpp)`，链 `libace_napi.z.so` 与上面的 `libmottycore.so`
5. `napi_init.cpp`：注册模块 `mottycore`，导出 `add(a,b)` → `MottyAdd`
6. `Index.ets`：`import { add } from 'libmottycore.so'`，显示 `add(2,3)`

```powershell
# 构建
& "C:\Program Files\Huawei\commandline-tools\command-line-tools\bin\hvigorw.bat" --mode module -p product=default assembleHap

# 安装（模拟器接受 debug 签名；发布签名另验）
devecocli device app install entry-default-signed.hap
# 或：& $HDC install -r entry-default-signed.hap
```

**通过判定（G1 完成）**：模拟器界面显示 `5`；`hilog` 无 `dlopen`/`undefined symbol`。
**已知风险点**：Go runtime `m0/g0` 与 Ark 运行时同进程共存的初始化时序；cgo 线程创建在应用沙箱内的权限；`.so` 在 `libs/<abi>/` 的加载路径；SIGILL/SIGSEGV 时先试 `-linkflags="-linkmode external"`，再试静态链 `c-archive`。

### A.5 G1 结论记录（必须填写）

| 项 | 结果 |
|---|---|
| guest ABI / SDK（`getprop`） | |
| `go tool dist list` 是否含 `ohos` | |
| 第 1 级（纯 Go 静态，在 hdc shell 内跑） | 通过 / 失败 + 日志 |
| 第 2 级 `c-shared` x86_64（**模拟器可执行**） | 通过 / 失败 |
| 第 2 级 `c-shared` arm64（**仅编译**） | 通过 / 失败 |
| 第 3 级 NAPI 闭环（x86_64 模拟器） | 通过 / 失败 |
| 双运行时共存问题 | 无 / 有（描述） |
| 结论 | **D1 可开工 / 只能 B / 两者皆不可** |

---

## B. G3：渲染基线（5 天，与 G1 并行）

**这一节在模拟器上只能证明"功能可跑"，不能证明"性能达标"** —— 模拟器 GPU 由宿主中介，帧率数字与真机无可比性。

```powershell
# 在 G1 第 3 级的工程里加一页：XComponent + @ohos.graphics.drawing
# 场景 1：5000 行 × 120 列网格连续滚动 10 秒
# 场景 2：CJK 宽字符 + 组合字符混排
# 场景 3：4K 图片按 SIXEL 方式铺进网格
```

**通过判定（模拟器口径）**：
- [ ] 三个场景都能渲染出正确画面（截图存档）
- [ ] 无崩溃、无 OOM（RSS 记录）
- [ ] 帧耗时**仅记录、不判定**（标注"模拟器，不可作真机基线"）
- [ ] 设备信息记录：`devecocli device view`（型号/分辨率/DPI，本机为 3120×2080 @304dpi 的 2in1 画像）

**真机性能门（G3-device）单列**：需 arm64 真机，`PLAN.md` 中标为"未执行"。

---

## C. 模拟器专属的验证边界（写进验收报告，不许省略）

| 能力 | 模拟器能否验证 | 说明 |
|---|---|---|
| Go 运行时/NAPI 桥（x86_64） | ✅ 可证 | 核心门禁，正是 G1 要的 |
| arm64 运行 | ❌ 仅编译 | 无设备，只能证明"能编出来" |
| UI 功能/布局/交互 | ✅ 可证 | 2in1 画像 3120×2080，窗口/鼠标/键盘齐全 |
| **平板触控**（单指/长按/双指） | ✅ 可证 | tablet 画像 2560×1600 @360dpi；`devecocli emulator` 可注入 shake/rotate/fold/sensor |
| **平板分屏 / 平行视界 / 悬浮窗** | ⚠️ 部分 | 需实测该镜像是否放开；放开则 T2 窗口映射可验，否则 E3 |
| **触控板 / 磁吸键盘** | ❌ 不可证 | 模拟器无该外设 → hover/滚轮/右键 的"指针范式"只能靠 2in1 画像验，平板侧 E3 |
| 多窗口/自由窗口 | ⚠️ 部分 | 需实测 2in1 镜像是否放开自由窗口 |
| HUKS / Asset Store | ⚠️ 存疑 | 可能软件实现，能验代码路径，**不能验安全属性** |
| 后台长时任务保活 | ⚠️ 存疑 | 模拟器策略常比真机宽松 → **假通过**风险 |
| 应用间 loopback 可达（MCP） | ✅ 可证 | 同一 guest 内装两个应用互连即可 |
| filePicker / URI 持久授权 | ✅ 可证 | |
| 剪贴板策略 / 手势限制 | ⚠️ 部分 | Windows 宿主剪贴板桥接行为可能不同 |
| USB / 串口 | ❌ 不可证 | 模拟器无对应设备节点 |
| 发布签名上架 | ❌ 不可证 | 模拟器只吃 debug 签名 |
| 性能（帧率/吞吐/启动） | ❌ 不可证 | 宿主中介，数字无意义 |
| 真机热/功耗/长时间稳定性 | ❌ 不可证 | |

---

## D. 决策表（G1 出结论后照此执行）

| G1 结果 | 决策 | 后续 |
|---|---|---|
| 第 3 级通过（x86_64 模拟器） | **走 D1**：给 Viva 写 OHOS 后端 | 进入 P0 架构准备 + M1；arm64 编译纳入 CI |
| 仅第 2 级通过 | 修桥接层（模块名/符号/abiFilters 最可能），限 5 天 | 超时视为失败 |
| 第 1 级通过、第 2 级失败 | 只能 **A**（全量 ArkTS 重写，55–70 人月） | **已决策：走 A**（见 PLAN §12.2） |
| 第 1 级失败 | **A**（D1 与 B 同时作废） | **已决策：走 A**（见 PLAN §12.2） |

> 不要因为"模拟器跑通了"就跳过 arm64：模拟器是 **x86_64**，真机是 **arm64**。上线前必须有一轮真机抽验，这条写进 M5 的 release 条件。

---

## E. 仍需用户提供/确认

1. ~~鸿蒙真机~~ → **已由模拟器替代**（PC 用 `2in1` 画像，平板用 `tablet` 画像）。
2. 是否上架应用市场（决定 R08/R17/R23 合规强度；且"仅模拟器验证"不足以支撑上架）。
3. 形态口径：PC 与平板**都要求 1:1**（已决）。因此每期验收必须在 `2in1` 与 `tablet` 两个画像上各跑一遍并并列存档；`deviceType` 只决定默认窗口形态，交互范式按"有无指针设备"切换（见 PLAN §12.3）。
