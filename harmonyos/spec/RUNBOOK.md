# spec runner 运行手册（实测有效）

> 全部命令与坑位来自 2026-11-10 在 x86_64 模拟器上的真实执行，不是推演。
> 退出码语义：**0 通过 / 1 断言或步骤失败 / 2 环境错误**。环境错误不算通过，也不算产品失败。

## 1. 设备侧原语（鸿蒙自带 uitest 7.0.0.1）

| 用途 | 命令 |
|---|---|
| 起测试进程 | `hdc shell uitest start-daemon` |
| 抓布局 | `hdc shell "uitest dumpLayout -p /data/local/tmp/x.json"` |
| 截图 | `hdc shell "uitest screenCap -p /data/local/tmp/x.png"` |
| 点击 | `hdc shell "uitest uiInput click <x> <y>"` |
| 输入文本（当前焦点） | `hdc shell "uitest uiInput text <text>"` |
| 按键 | `hdc shell "uitest uiInput keyEvent <Back/Home/Power/keyID>"` |

`dumpLayout` 输出的每个节点含 `accessibilityId / bounds=[x1,y1][x2,y2] / text / type / clickable`。
**这就是 spec 能用选择器而不写坐标的原因**：坐标由 runner 在运行时按 bounds 中心解算。

## 2. 两个画像的实例与端口

| 画像 | 实例名 | hdc 端口 | 屏幕档案 | 分辨率 |
|---|---|---|---|---|
| 2in1（PC） | `motty_pc` | 10100 | MateBook Pro | 3120×2080 @304dpi |
| tablet（平板） | `motty_tablet` | 10101 | MatePad Pro 13 | 2560×1600 @360dpi |

```powershell
$E = "C:\Program Files\Huawei\DevEco Studio\tools\emulator\Emulator.exe"
& $E -start motty_tablet -noWindow -hdcPort 10101
& $E -stop  motty_tablet
# 实例名不能含连字符（motty-pc 会失败）
```

**务必顺序运行两个画像，不要并发。** 本机 15.8 GB RAM，一个实例稳定占用后只剩约 3–5 GB 可用；并发会互相拖慢甚至启动失败。停掉一个再起另一个，双画像证据仍然成立（不要求同时）。

```powershell
hdc tconn 127.0.0.1:10101        # 首次需要 tconn
hdc list targets                 # 确认出现
hdc -t 127.0.0.1:10101 shell "uname -m"   # 预期 x86_64
```

启动后约 50 秒设备才出现在 `hdc list targets`。

## 3. 首次安装的系统对话框（必踩，已固化检测）

装完应用第一次 `aa start` 可能弹出系统对话框（实测为 **"是否将应用自动添加至桌面？"**），它**盖住应用 UI**，此时所有选择器都找不到——极容易被误判成 spec 写错。

处置：先点掉再跑；runner 现在会在 launch 后检测并直接报 **环境错误**（exit 2）并给出该提示，而不是让你去猜。

```powershell
# 从 dumpLayout 找到"不添加"文本节点的 bounds 中心，然后点它
hdc -t <serial> shell "uitest uiInput click <x> <y>"
```

## 4. 运行

```powershell
# 2in1
python harmonyos\spec\run.py harmonyos\spec\scenarios\<id>.yaml ^
  --serial 127.0.0.1:10100 --profile 2in1

# tablet
python harmonyos\spec\run.py harmonyos\spec\scenarios\<id>.yaml ^
  --serial 127.0.0.1:10101 --profile tablet
```

应用信息来自 spec 的 `app` 块（`bundleName` / `ability` / `settleMs`）；缺 `app` 而 spec 里有 `launch` 步骤时**报环境错误**，不会静默跳过。

## 5. 证据物约定

每次运行写入一个独立目录（默认 `spec/runs/<id>-<profile>-<epoch>/`）：

| 文件 | 内容 |
|---|---|
| `step-NN.json` | 该步 click/type 解析选择器时的布局快照 |
| `assert-NN.json` | 该断言最后一次判定的布局 |
| `launch.json` | 启动后的布局（用于遮挡检测） |
| `final.png` | 结束时的屏幕截图 |
| `final-layout.json` | 结束时的布局 |
| `result.json` | 逐步结果 + 断言结果 + `passed` + `limits` |

`passed` 的判定：**所有步骤成功 且 所有断言成功 且 至少一条断言**。跑完不等于通过。

## 6. 已知限制（不许当通过看）

- `layout` 断言是**保守版**：只检查"带文本节点宽度>0 且落在屏幕内"，不是真正的重叠/裁剪检测。它不能替代人工目检。
- 当前只实现了动作 `launch / click / type / key / wait`；`swipe / longPress / rightClick / setVariable / invoke` 会**报错**而不是跳过。
- 断言只实现 `text / absent / layout`；其余种类（`state / screenRegex / wireLog / count / capabilityDisabled`）**报错**。
- 尚未接 `testSurface`（P7 观测面）：终端里的文本读不到，B2 批次在它落地前无法机器判定。
- 模拟器上的帧率/耗时数字不可作为性能证据（宿主 GPU 中介），见 [RUNBOOK.md](./RUNBOOK.md) §C。

## 7. 已验证的双画像结果

harness 自检 spec（`smoke.runner`，目标曾是 `spike/bprime` 探针应用）已随探针工程一并删除——
它证明的是测试链路可用，不是产品行为，长期留在仓库里只会增加维护面。

产品 spec 的证据请以 `spec/scenarios/` 下的 9 个文件为准，其运行结果见
[A-PRIME-STATUS.md](../A-PRIME-STATUS.md) §2 与 `INDEX.md` 的逐轮记录。

---

## 8. 首次运行的三道系统引导（必须一次性做完，否则 spec 会"莫名找不到控件"）

全新设备/新实例上，第一次跑 spec 会连续撞上三个系统流程。它们的共同特征是**盖住应用 UI**，
让所有选择器失效，看起来像 spec 写错。runner 已把它们的特征文本加入遮挡检测（命中即报环境错误 exit 2）。

| # | 触发时机 | 现象 | 处置 |
|---|---|---|---|
| 1 | 安装后首次 `aa start` | "是否将应用自动添加至桌面？" | 点「不添加」 |
| 2 | 输入框首次获得焦点 | 输入法隐私授权单（小艺输入法 / 本应用需要联网…） | 点「同意」 |
| 3 | 输入框首次获得焦点（授权后） | "请选择中文键盘布局 … 下一步" | 点「下一步」直到消失 |

```powershell
# 用工具按文本点掉，不要手敲坐标
python harmonyos\tools\design\dismiss-dialog.py --serial <serial> --list        # 看看有什么
python harmonyos\tools\design\dismiss-dialog.py --serial <serial> --text 不添加
python harmonyos\tools\design\dismiss-dialog.py --serial <serial> --text 同意
python harmonyos\tools\design\dismiss-dialog.py --serial <serial> --text 下一步  # 可能需要连点
```

### 输入文本为什么这么麻烦（实测记录）

| 尝试 | 结果 |
|---|---|
| `uitest uiInput text <text>` | 字符进入输入法组合串（`pinyinTextInput` + `candidateView`），**应用输入框始终为空** |
| `uitest uiInput inputText <x> <y> <text>` | 同样进组合串；且对话框/输入法一弹出布局会变，旧坐标可能落到相邻字段（曾把两个值串成 `10.0.0.110.0.0.2`） |
| `inputText` + `keyEvent 2054`（ENTER 提交组合） | **可行**：提交后应用输入框拿到文本 |
| 但 spec 里 `type` 不写 `target`（靠"先点后打"） | 仍会丢，且无法回读校验 → 已在 lint 里禁止 |

最终 runner 的做法：**聚焦 → 等输入法稳定 → 重新取坐标 → inputText → ENTER 提交 → 回读校验 → 失败重试（最多 3 次）**。
spec 里 `type` 必须写 `target`，这条由 `lint.py` 强制。

### 应用侧也要配合
`TextInput({ text: this.state })` 与 `.onChange` 回落形成回写环，会让输入法提交的文本被状态回滚。
本项目输入框改为**不绑定 `text`**（只留 placeholder + onChange），避免这个陷阱。
---

## 9. 可重复性：`--fresh`

```powershell
python harmonyos\spec\run.py <spec> --serial <serial> --profile <profile> --fresh
```

`--fresh` 会在运行前执行 `bm clean -n <bundle> -d` 清空应用数据，让断言不依赖上一次运行遗留的库内容。
**凡是断言"列表里有什么/有几个"的 spec，都必须加 `--fresh`**，否则第二次跑就不是同一个初始状态了。
断言"存在性"的 spec 不加也能过，但同样建议加——可重复性优先。

同时：`launch` 动作会先 `aa force-stop` 再 `aa start`，所以**在 spec 里写两次 `launch` 就等于一次冷启动重启**，
`host.persist` 正是靠这个验证持久化的。
---

## 10. 设备 → 宿主的 SSH 对端（B1 批次的地基）

### 10.1 为什么不用 upstream 的 `tools/e2esshd`

`tools/e2esshd` 需要 `/bin/bash` 与真 pty（`creack/pty`），**Windows 宿主上起不来**，本机也没有 WSL/Docker。
所以本轮新增 `harmonyos/tools/design/sshfixture`：纯 Go、不需要 pty 的最小对端。

**能力边界（必须照实说，不许用它冒充 e2esshd）**

| 项 | sshfixture | e2esshd |
|---|---|---|
| 主机密钥（持久文件） | ✅ | ✅ |
| 密码认证 | ✅ 任意用户 / `secret` | ✅ |
| 公钥认证 | ✅ 启动时生成 ed25519（口令 `key-secret`） | ✅ |
| exec 命令 | ✅ 固定输出 `fixture-exec-ok` | ✅ |
| pty / shell | ❌ **明确拒绝并记日志** | ✅ 真 pty |
| SFTP / SCP / 转发 / X11 | ❌ | ✅ |

拒绝 pty 是刻意的：pty 相关 spec 会**响亮失败**，而不是悄悄通过一个假 pty。

### 10.2 启动与转发

```powershell
# 1) 宿主起对端（持久主机密钥，便于做 known_hosts 变更测试）
harmonyos\.bin\sshfixture.exe -addr 127.0.0.1:2223 -hostkey harmonyos\.bin\.sshfixture\hostkey

# 2) 设备反代：设备 tcp:2222 → 宿主 tcp:2223
hdc -t <serial> rport tcp:2222 tcp:2223
hdc -t <serial> fport ls           # 应看到 [Reverse]

# 3) 跑 spec
python harmonyos\spec\run.py harmonyos\spec\scenarios\net.reachability.yaml `
  --serial <serial> --profile <2in1|tablet> --fresh
```

**rport 是每设备/每实例的**：换模拟器实例或重启实例后必须重新建立，`fport ls` 里没了就是没了。

### 10.3 应用侧必须声明 INTERNET 权限

不加 `ohos.permission.INTERNET` 时，`socket.connect` 直接返回 **`201 Permission denied`**（实测）。
已写入 `entry/src/main/module.json5` 的 `requestPermissions`。
→ 这条也是上架清单的一项（[PLAN.md](../PLAN.md) §12.1 权限最小化）：SSH/SFTP/转发/远程桌面都需要它。

### 10.4 本节的边界

`net.reachability` 只证明"设备能连到宿主、能收到 `SSH-2.0-…` banner"。
它**不覆盖**握手、KEX、认证、通道、pty——那些要么等 sshfixture 扩展，要么等 Linux 对端。
---

## 11. 协议层：libssh2 + mbedTLS（A′ 的真实协议栈）

### 11.1 第三方库怎么编出来的

```powershell
pwsh -File harmonyos\native\build-thirdparty.ps1        # x86_64（模拟器）
```

产物：`harmonyos/native/third_party/ohos/x86_64/lib/{libssh2,libmbedtls,libmbedx509,libmbedcrypto,libeverest,libp256m}.a`

**关键决策与坑**

| 决策/坑 | 说明 |
|---|---|
| 不用 OpenSSL | 其构建依赖 **Perl**（生成汇编），本机没有；mbedTLS 纯 C + CMake，交叉成本低 |
| 必须用官方 release 包 | GitHub 的 `archive/refs/tags` 归档**缺 `framework` 子模块**，CMake 直接报错；要下 `releases/download/mbedtls-3.6.2/mbedtls-3.6.2.tar.bz2` |
| 手写 toolchain 文件 | NDK 的 `*-ohos-clang` 是 **sh 脚本**（170–250 字节），Windows 不能执行 → 直接调 `clang.exe` + `-target` + `--sysroot` |
| libssh2 找 mbedTLS | 它的 `FindMbedTLS.cmake` 不认 pkg-config，必须显式传 `MBEDTLS_INCLUDE_DIR` 与 `MBEDCRYPTO_LIBRARY` |
| 静态链接 | `libssh2.a` + mbedTLS 全部静态进 NAPI `.so`，避免多带 `.so`、避免运行时找不到依赖 |

### 11.2 NAPI 封装的两个硬约束

1. **`nm_modname` 必须等于 `.so` 文件名主干**：`libmottynapi.so` → `nm_modname = "mottynapi"`。
   写成别的（例如 `mottyssh`）时 ArkTS `import` 会拿到空模块，且**不报错**，非常隐蔽。
2. **不能阻塞 UI 线程**：SSH 握手在 `std::thread` 里做，结果经 `napi_create_threadsafe_function` 回 JS。

编译期两个小坑（都踩过）：
- `napi_get_value_string_utf8(env, v, nullptr, 0, &len)` 在 OHOS 头里是 `char*`/`char16_t*` 重载，`nullptr` 二义 → 必须 `static_cast<char*>(nullptr)`
- 工程默认 C++11 时 `std::string::data()` 返回 `const char*` → 用 `&dst[0]`；CMake 里已设 C++17

### 11.3 互操作发现：主机密钥类型决定握手成败

首轮实测：`ssh: error handshake: Unable to exchange encryption keys`。
原因不是密码学强度，而是**算法集不重叠**：fixture 用 ed25519 主机密钥，而 libssh2 的 **mbedTLS 后端**算法覆盖远窄于 OpenSSL 构建。

修法：fixture 改用 **RSA-3072** 主机密钥（`-hostkeytype rsa`，默认值）。
→ 记录：**换密码学后端会缩小算法集，联调前先对齐主机密钥类型与 KEX 列表。**

### 11.4 rport 端口冲突

`hdc ... rport tcp:2222 tcp:2223` 若该端口已有转发规则，会报 **`TCP Port listen failed at 2222`**（旧规则仍在，通常还能用）。
要么复用现有规则，要么换端口；用 `hdc -t <serial> fport ls` 查当前规则。

### 11.5 应用侧链路

`ArkTS → import mottynapi('libmottynapi.so') → probe(host, port, user, password, cmd, cb) → libssh2 → 对端`

对端日志是被独立验证的（不是只看 UI）：
```
session from 127.0.0.1:64531 user=tester auth=password
exec: "echo hello-from-ssh"
```

### 11.6 本节未做（不许当已完成）

- **arm64 未编译**：目前只有 `x86_64` 的第三方库与 `abiFilters`。真机（Kirin）还跑不了，需补 `ohos-arm64.cmake` 并重跑脚本。
- 无主机密钥校验回调（M1-b 必做，见 PLAN §7.4 P1）
- 无 pty、无 SFTP/SCP/转发、无会话复用
---

## 12. 双 ABI（x86_64 + arm64-v8a）

### 12.1 为什么必须做
模拟器是 x86_64，真机（Kirin）是 arm64。只编 x86_64 的第三方库，**真机根本装不上**。
这一步不属于"优化"，属于"能不能上线"。

### 12.2 一条命令编两套

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File harmonyos\native\build-thirdparty.ps1 -Arch x86_64
powershell -NoProfile -ExecutionPolicy Bypass -File harmonyos\native\build-thirdparty.ps1 -Arch arm64
```

产物分别在 `third_party/ohos/{x86_64,arm64}/lib/`，已验证 `libssh2.a` 的 ELF Machine 分别为
`Advanced Micro Devices X86-64` 与 `AArch64`。

**两个脚本级坑（已修）**
1. Windows PowerShell 5.1 读**无 BOM 的 .ps1** 会按 ANSI 解析，中文注释导致 `Unexpected token ')'` → 脚本存为 **UTF-8 with BOM**。
2. `$root = Split-Path -Parent $PSScriptRoot` 会把 `harmonyos/native` 多减一层 → 应为 `$root = $PSScriptRoot`。

### 12.3 CMake 侧按 ABI 选库
hvigor 为每个 ABI 各跑一次 CMake，并注入 `OHOS_ARCH`（实测值 `x86_64` / `arm64-v8a`）。
所以 `CMakeLists.txt` 里：

```cmake
if(DEFINED OHOS_ARCH AND OHOS_ARCH STREQUAL "arm64-v8a")
  set(OHOS_SSH_ARCH arm64)
else()
  set(OHOS_SSH_ARCH x86_64)
endif()
set(OHOS_SSH_PREFIX ${OHOS_SSH_ROOT}/${OHOS_SSH_ARCH})
```

`build-profile.json5` 里 `abiFilters: ["x86_64", "arm64-v8a"]`，arguments 传 `-DOHOS_SSH_ROOT=<.../third_party/ohos>`。

### 12.4 打包结果（实测）
HAP 内同时含：
```
libs/x86_64/libmottynapi.so      745.8 KB   Machine: X86-64
libs/arm64-v8a/libmottynapi.so   724.9 KB   Machine: AArch64
```
安装到 x86_64 模拟器运行正常（系统按 ABI 自动选）。

### 12.5 仍然只是 E2
**arm64 产物只证明"编译通过"**，没有真机 → **没有执行证据**。
按证据等级（[PLAN.md](../PLAN.md) §11.3），arm64 目前是 **E2（仅编译/静态）**，不是 E1。
许可证与体积：双 ABI 各自约 720–750 KB 的 NAPI 库 + 1.2 MB libc++_shared，包体影响已记录在 R17。
---

## 13. 主机密钥校验（PLAN §7.4 P1）与它的验证方法

### 13.1 实现语义（fail-closed）

NAPI 的签名已改为 7 参：

```
probe(host, port, user, password, command, expectedFingerprint, callback)
```

`expectedFingerprint` 的三种取值决定行为，**顺序固定为"先校验、后认证"**：

| 输入 | 行为 | 返回 |
|---|---|---|
| `""`（未知主机） | 完成握手 → 取 SHA256 指纹 → **立即断开，不认证** | `unknown_host SHA256:…` |
| 正确指纹 | 校验通过 → 认证 → exec | `verified SHA256:… ok <输出>` |
| 错误指纹 | **立即失败，不认证**，且无任何"仍要信任"参数 | `hostkey-mismatch expected=… actual=…` |

指纹格式沿用 OpenSSH：`SHA256:` + base64(32 字节哈希，去掉 `=` 填充)，来源是 `libssh2_hostkey_hash(session, LIBHOSTKEY_HASH_SHA256)`。

**后果（有意为之）**：没有已知指纹就**不能**执行任何命令。上游"先连上去再说"的路径在本实现里不存在。
因此应用里的 "SSH Test" 改成了两步：先取指纹，再用该指纹连。真实产品中第二步必须由用户确认后才发生。

### 13.2 对端日志就是证据（比截图强）

跑 `ssh.hostkey` 后，fixture 的 stderr 呈现教科书式分布：**三次握手，只有一次认证**。

```
15:03:40 handshake failed: ssh: disconnect, reason 11: "bye"   ← 第 1 次：未知主机，只取指纹就断开
15:03:40 session from 127.0.0.1:57616 user=tester auth=password
15:03:40 exec: "echo should-run-2"                            ← 第 2 次：指纹匹配，才认证并执行
15:03:40 handshake failed: ssh: disconnect, reason 11: "bye"   ← 第 3 次：指纹不符，握手后断开
```

判读要点：
- 只有**一条** `session from … auth=password` → 两次拒绝路径**确实没有认证**
- 只有**一条** `exec` 且命令是 `should-run-2` → `should-not-run-1` / `must-not-run-3` 从未在远端出现
- 两次 `disconnect … "bye"` 是我们在校验失败后主动断开（库收到的是 disconnect，不是 EOF）

### 13.3 这个改动的"回归破坏"是预期行为

改完之后 `ssh.exec` 第一次回归**失败**了，因为旧按钮传空指纹 → 返回 `unknown_host` 而不再执行。
这不是 bug，而是"没有已知指纹就不许执行"生效的证明。已把调用方改成两步 TOFU，回归恢复绿色。

### 13.4 仍未做

- **known_hosts 持久化**（本轮只做校验与拒绝；存盘 = M1-b）
- `@cert-authority` / 主机证书路径
- hostkey 算法白名单（当前依赖 libssh2 协商；服务器可给多种类型）
- 指纹变更的**用户提示 UI**（现在只是自检文本）
---

## 14. known_hosts 持久化 + 用户确认闭环

### 14.1 三种状态与 UI

| 情况 | 行为 |
|---|---|
| 无记录 | 取指纹 → 弹 **"Unknown host key"** 确认框（显示指纹，按钮 `Trust` / `Cancel`），**用户点 Trust 才写入并连接** |
| 有记录且匹配 | 直接连，**不再弹框** |
| 有记录但不匹配 | 报 `hostkey-mismatch`，**界面上没有 Trust 按钮**（P1） |

存储：`relationalStore` 表 `known_hosts(host TEXT PRIMARY KEY, fingerprint TEXT, updated_at INTEGER)`，
写入用 `ON_CONFLICT_REPLACE`。主机键为 `host:port`。

### 14.2 怎么证明"持久化真的生效"

spec `ssh.knownhost` 的关键不是"能连上"，而是**第二次点击不再弹框**：
- 步骤级 `expect`：第 1 次点击后断言屏幕出现 `Unknown host key`
- 点 `Trust` 后断言出现 `verified SHA256:`
- 第 3 次点击（第 2 次连接）后断言屏幕**不再出现** `Unknown host key`

对端日志逐条对应：
```
handshake failed: ssh: disconnect, reason 11: "bye"   ← 取指纹，不认证
session from … auth=password                          ← Trust 之后才认证
exec: "echo hello-from-ssh"
session from … auth=password                          ← 第二次点击：直接认证，不再取指纹
exec: "echo hello-from-ssh"
```

### 14.3 顺带补齐的 runner 能力：步骤级 `expect`

schema 早就声明了 `steps[].expect`，但之前 runner 没实现——而"先断言弹框、再点确认"必须中途断言。
现已实现：每步执行成功后立即判定，失败即中止该 spec，并在 `result.steps[i].expect` 里留证。

修复过程中还发现一个格式化 bug：`dump_layout(f'assert-{idx:02d}')` 在 `idx` 是字符串标签时会抛
`Unknown format code 'd' for object of type 'str'` → 改为 `f'assert-{idx}'`。

### 14.4 仍未做

- **主机密钥变更的用户提示 UI**（协议层已拒绝，UI 只显示错误文本）
- 删除/重置已知主机、`@cert-authority`、hostkey 算法白名单
- 主机列表条目还没有凭据/协议字段，因此本轮用"连接固定 fixture 主机"的按钮承载流程
---

## 15. spec 的两个新能力（Round 10）

### 15.1 步骤级 `expect`
```yaml
- action: click
  target: id:host-row/0
- action: wait
  ms: 2500
  expect:
    kind: screenRegex
    regex: "Unknown host key"
    withinMs: 12000
```
每步执行成功后立即判定；失败即中止该 spec，并在 `result.steps[i].expect` 留证。
用于"先断言弹框、再点确认"这类必须中途验证的流程。

### 15.2 `secret: true`
口令字段被掩码，回读拿不到原文，因此：
```yaml
- action: type
  target: id:shell/dialog-password
  text: secret
  secret: true
```
注入后**不做回读校验**，真正的验证交给后续连接结果（连得上 = 口令对）。
不要给普通字段加这个标记——那等于放弃校验。

### 15.3 一条 spec 的取舍原则
`ssh.knownhost` 已删除：它断言的两件事被 `ssh.connect-from-list` 完整覆盖。
**保留两份不会增加证据，只会增加维护成本与漂移风险。**
---

## 16. 流式 exec（终端数据通路）

### 16.1 签名
```
exec(host, port, user, password, command, expectedFingerprint, onData, onDone)
```
- `onData(chunk)`：每读到一块就回调一次（两个 TSFN 分别承载 data 与 done）
- `onDone(status)`：`ok` 或 `error …` / `unknown_host …` / `hostkey-mismatch …`
- 主机密钥语义与 `probe` 完全一致：未知/不匹配**不认证**，因此不会有任何数据回调

### 16.2 当前渲染的上限（别当成终端模拟器）
应用侧只是把 chunk 追加到一个字符串并显示在 `terminal/output` 里：
- **没有 VT 解析**：ANSI 颜色、光标移动、备用屏、回滚、宽字符对齐都不支持
- 没有真实 shell、没有窗口尺寸协商、没有键盘输入
- 验证点是"多块数据都到了"，不是"渲染正确"

真正的终端模拟器（VT 解析 + 网格 + 5000 行回滚 + 图片/连字）是 M1 剩余的最大一块，
计划以 libvterm 为骨架 + 自有扩展（见 A-PRIME-ENGINEERING.md 的待决项 D1）。

### 16.3 fixture 的 term-demo
`term-demo` 输出 6 行、每行间隔 120ms、末行 `\x1b[32m…\x1b[0m`：
用来同时验证"流式分块"和"ANSI 序列原样透传"（因为还没有 VT 解析）。
---

## 17. 交互式会话 API（openShell / sendInput / closeShell）

```
openShell(host, port, user, password, expectedFingerprint, onData, onDone) -> sessionId (0 = 失败)
sendInput(sessionId, text) -> 1/0
closeShell(sessionId) -> 1/0
```

### 17.1 线程模型（这是它能工作的关键）
- 每个会话一个工作线程，**所有 libssh2 调用都在该线程内**（读/写/关闭），因为 libssh2 会话不是线程安全的
- `sendInput` 只把字节追加到 mutex 保护的队列，不触碰 libssh2
- `closeShell` 只置标志位，由工作线程收尾
- 会话建立后必须 `libssh2_session_set_blocking(session, 0)`：否则 `channel_read` 会阻塞到 socket 收超时（本工程 8s），**键盘输入的写入要等到超时后才发出**（实测踩过）

### 17.2 写入必须能回退
`channel_write` 返回 `EAGAIN`（或只写出一部分）时，剩余字节要放回队列，否则会**静默丢字节**。

### 17.3 对端要求
fixture 的 `term-echo`：读一行、回 `echo: <line>`。真实产品里这里会是 pty + shell，
但当前对端不支持 pty（Windows 无 `/bin/bash`），所以交互语义用"行回显"近似验证。

### 17.4 UI 侧的一个坑
终端输入框若不绑定状态，`Send` 后字段仍显示旧内容，下一行会拼成 `old new`。
必须绑定并清空——这与设置页那些输入框"刻意不绑定"的取舍相反，原因是这里需要**程序化清空**。
---

## 18. 最小 VT 引擎的边界（vt_core.cpp）

### 18.1 支持
`CUP(H/f)` · `CUU/CUD/CUF/CUB(A/B/C/D)` · `CHA(G)` · `VPA(d)` ·
`ED(J) 0/1/2` · `EL(K) 0/1/2` · `SGR(m)` 前景色 30–37 与 0/39 重置 · CR/LF/换行滚动 · 退格

### 18.2 不支持（会静默忽略，不破坏网格）
备用屏、回滚缓冲、**宽字符与组合字符**、连字、SIXEL/Kitty/iTerm2 图片、
鼠标上报、DECSET 2026（同步刷新）、选择/复制、真实 pty 尺寸协商。

### 18.3 一个必须记住的限制
当前 `put()` 只处理 `0x20–0x7E` 可打印 ASCII。**CJK 文本不会显示**——
这是"最小 VT"与"可用终端"之间的硬差距，宽字符需要 wcwidth 表 + 双宽单元格，
属下一阶段工作，不能因为 spec 全绿就以为终端能用了。

### 18.4 观测面
`vtScreen()` 返回去掉行尾空格的网格文本（供 UI 渲染与 spec 断言）；
`vtStatus()` 返回 `cur=<行>,<列> colors=<着色格数> size=<列>x<行>`（供断言光标与颜色属性）。
`terminal/vt-status` 就是把它显示出来——没有这个观测面，光标与颜色无法被机器判定。
---

## 19. 回滚缓冲与备用屏（vt_core）

### 19.1 回滚
- 行被 `scroll()` 顶出时进入 `history`，上限 **2000 行（FIFO）**
- **只存文本行，不存颜色/宽字符属性**：要"回滚区也能着色"必须存 Cell 行，属后续工作
- 备用屏内的滚动**不进主屏历史**（与真实终端一致）
- `vtScrollBack(n)` 返回最近 n 行；UI 用 `terminal/history` 外显，否则"滚出屏幕的内容"无法被 spec 断言

### 19.2 备用屏
`DECSET/DECRST`（CSI `?Pm h/l`）的 **47 / 1047 / 1049** 都映射到备用屏切换：
- 进入时保存主屏 cells 与光标
- **统一清屏**（1049 本来就清；47/1047 严格说不清屏，这里为了行为可预测做了统一，属于已知偏差）
- 退出恢复主屏与光标；`vtStatus` 的 `alt=0/1` 暴露当前状态

### 19.3 断言这两件事的正确姿势
- 回滚：造出超过屏幕行数的输出，然后断言**已滚出的行**出现在 `terminal/history` 里
- 备用屏：进入后写标记 → 退出 → 断言该标记**不出现**在主屏上
两条都必须经过 `vtStatus`/`vtScrollBack` 这类观测面，否则 UI 上看不出来。
---

## 20. 真 pty（ConPTY 对端）

### 20.1 客户端（产品代码）
```
openChannel(host, port, user, password, expectedFp, cols, rows, usePty, onData, onDone) -> id
resizeShell(id, cols, rows) -> 1/0
```
`usePty=true` 时：`libssh2_channel_request_pty_ex(channel, "xterm-256color", ...)` → `libssh2_channel_shell`。
**必须先申请 pty 再开 shell**，否则远端拿到默认 80x24，与真实窗口不符。

`resizeShell` 只入队，真正的 `libssh2_channel_request_pty_size_ex` 在会话工作线程里执行——
libssh2 会话非线程安全，这条约束在 §17.1 已经踩过一次。

### 20.2 对端（夹具，Windows ConPTY）
`pty_windows.go` 用 `CreatePseudoConsole` + `CreateProcessW(EXTENDED_STARTUPINFO_PRESENT)` 起 `cmd.exe`。

**两个必须照做的细节（都是实测踩出来的）**
1. 交给 ConPTY 的 `ptyIn` / `ptyOut` 句柄**不能在 CreateProcess 后关闭**。
   提前关掉会让子进程退回父控制台：我们从管道只读到 16 字节初始化序列
   （`\x1b[?9001h\x1b[?1004h`），而 cmd 的 banner 直接印在调用方控制台上。
2. `STARTUPINFOEXW.StartupInfo.Flags` 要置 `STARTF_USESTDHANDLES`，`Cb` 要等于 `sizeof(STARTUPINFOEXW)`。

### 20.3 调试方法（比读日志快）
`pty_manual_test.go` 把 ConPTY 从 SSH 链路里隔离出来：
`go test -run TestPtyManual -v -count=1 -timeout 90s .`
注意 pty 的 `Read` 是阻塞的，测试里必须用 goroutine + select 超时，否则测试会永久挂住。

### 20.4 真 shell 会发 OSC
`cmd.exe` 通过 ConPTY 会发 `ESC ] 0;标题 BEL`。VT 引擎必须**整段跳过 OSC**（直到 BEL 或 `ESC \`），
否则标题会被当成文本打印进网格。已在 `vt_core.cpp` 的 `Osc/OscEsc` 状态里处理。

### 20.5 RUNBOOK 里最容易被忽略的一条
`uitest uiInput inputText <x> <y> <text>` 的 text 若含空格，**必须加引号**：
`hdc shell` 会把命令按空格拆参数，`uitest` 只吃到第一个单词（实测 `echo hello-pty-ok` 变成 `echo`）。
`spec/run.py` 已统一用单引号引用并转义内部单引号。
---

## 21. SFTP（当前只做 list / read）

### 21.1 客户端
```
sftp(host, port, user, password, expectedFingerprint, op, path, cb)   // op = "list" | "read"
```
- 主机密钥校验与 `probe` 完全同源：未知/不匹配**不认证**，因此一个字节都读不到
- `list` 返回每行 `name|size`，目录名带尾斜杠
- `read` 按 UTF-8 文本返回，**上限 256 KiB**，超出截断并追加 `[truncated]`
- 回调走 TSFN，不阻塞 UI

### 21.2 对端
夹具用 `github.com/pkg/sftp` 起 SFTP 子系统，根为临时目录（含 `hello.txt`、`sub/nested.txt`）。
启动日志会打印 `sftp root: ...`；若这行缺失说明 `prepareSftpRoot()` 没跑到，
客户端会看到 `subsystem "sftp" refused`。

### 21.3 一个必须记住的 UI 陷阱
把路径输入框**绑定状态**再用注入文本去改它，是**不可靠**的：注入提交后值会被回滚
（与设置页输入框同源的问题）。所以目录导航做成"点击条目进入"（`sftp/entry/<name>`）——
既可测，也才是正常交互。凡是要靠"打字改变量"来驱动流程的地方，都应改成显式控件。
---

## 22. 操作坑位（每一条都真实踩过）

### 22.1 模拟器刚启动时可能锁屏
`launch` 步骤会报：
```
error code 10106102: The device screen is locked during the application launch
The current mode is developer mode, and the screen cannot be unlocked automatically
```
这是环境态，不是产品问题。**重跑即可**；批量跑时最好在第一条 spec 前先做一次唤醒/重试。
不要把这类瞬时失败当成"用例通过"或"产品失败"记进结论。

### 22.2 上传要避免中途失败留下坏文件
`sftpWrite` 先写 `path + ".motty-tmp"`，成功后 `libssh2_sftp_rename_ex`（带 OVERWRITE）落位。
失败则 `unlink` 临时文件。注意 libssh2 1.11 里没有 `libssh2_sftp_rename`，要用 `_ex` 版本并传长度。

### 22.3 操作结果别和"刷新状态"共用一行
列目录会把状态行改成 "listed …"，删除/上传的结果就被覆盖了。UI 里必须有**只由操作写**的独立结果行
（本工程是 `sftp/result`），否则 spec 无法断言、用户也看不到。

### 22.4 断言别用"裸文件名"
上传目标输入框里本来就有 `uploaded.txt`，用裸文件名匹配屏幕会**假通过**。
要匹配目录列表的格式（`uploaded\.txt\|[0-9]+`）——只有它真的出现在远端目录里才成立。
---

## 23. 凭据保险库（Asset Store Kit）与 restart 动作

### 23.1 为什么用 Asset 而不是自己搓加密
口令属于系统该管的机密。`@kit.AssetStoreKit` 由系统保管、可绑定锁屏状态访问，
比自己拿 HUKS + AES 拼一套更不容易写错。别名：`motty.host.<address:port>`。
**只存口令**；地址/端口/用户名仍在 relationalStore（非机密）。

注意枚举名：可访问性是 `asset.Accessibility.DEVICE_UNLOCKED` / `DEVICE_FIRST_UNLOCKED` /
`DEVICE_POWERED_ON`——**没有 `UNLOCKED`**（写错会在编译期报 `Property 'UNLOCKED' does not exist`）。

### 23.2 怎么验证"真的落盘了"
新增 runner 动作 `restart`：`aa force-stop <bundle>` + 重新 launch（进程级重启）。
重启后**不重新输入口令**直接发起连接，还能拿到远端输出 → 口令只可能来自保险库。
反证：保险库失效时 UI 显示 `no credentials in memory`，spec 把它断言为**缺席**。
只验证"界面上显示已保存"是没有意义的。

### 23.3 连带影响（踩过的）
删掉硬编码的 fixture 口令后，凡是用诊断入口的 spec 都必须**先建主机**，
否则会走"没有凭据"分支。`ssh.exec`、`ssh.hostkey` 已补上建主机步骤。
---

## 24. 端口转发（本地 forward）

### 24.1 客户端
```
forwardStart(host, port, user, password, expectedFp, listenPort, targetHost, targetPort, onEvent) -> id
forwardStop(id)
```
- 一个转发任务**独占一条 SSH 会话** + 一个本地监听 socket，串行处理连接
- 事件流：`listening on 127.0.0.1:<p> -> <target>`、`accepted local connection`、
  `forwarded N bytes`、`stopped`、`error …`
- 主机密钥语义与 probe 一致：未信任不会建立通道

### 24.2 两个必须遵守的实现约束
1. **两端都必须非阻塞**。若在本地 `recv` 上阻塞，远端数据永远读不到——实测表现是
   "隧道起来了、连上了、但一个字节都收不到"。需要 `libssh2_session_set_blocking(session, 0)`
   + 本地 socket `O_NONBLOCK`，然后双向轮询。
2. **对端要真的支持 direct-tcpip**。Go 的 `x/crypto/ssh` 不实现转发，通道请求会被拒，
   客户端只会看到 `error direct-tcpip failed`。夹具里自己解析载荷 + `net.Dial` + 双向 `io.Copy`。

### 24.3 怎么验证"隧道真的通"
不要只看"监听听起来了"。用本机 socket 连自己的转发端口，读回**只有远端才可能产生的数据**
（本工程用远端 SSH 的 banner `SSH-2.0-`）。同时看对端日志是否出现 `direct-tcpip open`。

### 24.4 当前限制
同时只处理一个连接；没有 ACL/来源限制；只有本地转发；无断线重连与规则持久化。
---

## 25. VNC / RFB（自研）

### 25.1 为什么不引 LibVNC
LibVNC 是 **GPL-2.0**：链进应用会把整个产品拖进 GPL，直接堵死上架。上游 Motty 的 VNC 是
自研 `internal/rfb`，所以我们自研并让行为对齐。

### 25.2 当前覆盖
`vncProbe(host, port, cb)` 返回一行状态：
`fb=WxH name=… bytes=N top-left=RRGGBB center=RRGGBB right=RRGGBB`
- 版本：3.8
- 安全类型：只接受 `None(1)`；只提供 VNC Auth 的服务器会返回明确错误
- 编码：只请求 `Raw(0)`
- 只取一帧、只取三个采样点，**不上屏**

### 25.3 `ServerInit` 的真实布局（踩过）
24 字节，**nameLength 已包含在内**：
```
width(0,1) height(2,3)
PIXEL_FORMAT(4..19): bpp(4) depth(5) bigendian(6) truecolor(7)
                     rmax(8,9) gmax(10,11) bmax(12,13)
                     rshift(14) gshift(15) bshift(16) pad(17..19)
nameLength(20..23)   ← 不要再额外读 4 字节
```
把 shifts 当成 16/17/18、或多读一次 nameLength，会导致按垃圾长度读名字然后超时，
对端日志表现为"客户端只发版本就断开"。

### 25.4 夹具
`-vnc 127.0.0.1:5901` 起最小 RFB 服务，图案固定：左半红、右半蓝、64×48。
设备侧需要 `hdc rport tcp:5901 tcp:5901`。
---

## 26. VNC 上屏为什么被关掉（重要）

### 26.1 现象
ArkTS 里对 `Canvas` 执行 `putImageData(new ImageData(w, h, rgba), 0, 0)` 会让**整个进程崩溃**：

```
Reason:Signal:SIGSEGV(SEGV_MAPERR)
#00 ld-musl-x86_64.so.1
#01 lib2d_graphics.z.so(OHOS::Rosen::Drawing::SkiaImage::Serialize())
Process life time: 7s
```
证据文件：`/data/log/faultlog/faultlogger/cppcrash-com.motty.harmony-*.log`
（用 `hdc file recv` 取回即可，不要靠猜）。

### 26.2 排除过的假设（避免重复踩）
| 假设 | 结果 |
|---|---|
| 首帧早于 Canvas 就绪 | 加 `onReady` 门后**仍崩** |
| `ImageData` 参数顺序 | ArkTS 是 `(width, height, data)`，改正后**仍崩** |
| ArrayBuffer 传给 TSFN 的方式 | 改成 hex 字符串传帧，**仍崩** |

结论：崩溃点在**图形序列化**，不在协议层与 TSFN。因此本轮关闭渲染，
**保留解码与统计**，UI 上明写"rendering disabled"，spec 只断言协议与输入。

### 26.3 当前状态与下一步
- 帧循环、像素解码、RGB 统计、指针/键盘事件发送**都是通的**（对端日志可见 `PointerEvent x=.. y=.. mask=1`）
- 画面**没有上屏**：这是本工程的已知残缺，不是"没测"
- 下一步应评估 Surface/XComponent 纹理路径（拿 `OH_NativeWindow` + `OH_NativeVSync`，
  把 RGBA 直接写进缓冲区），而不是继续在 Canvas 上试 `putImageData`

### 26.4 断言口径
不要用"画面显示了"这类主观判断。本工程用 `green=N` 计数：初始图案只有红/蓝，
收到指针事件后对端画绿块，客户端统计到 `green>0` 才是"输入真的到了对端并且新帧回来了"。
---

## 26. VNC 渲染：`putImageData` 会崩，`fillRect` 可用

### 26.1 崩溃的是什么
```
Canvas.putImageData(new ImageData(w, h, rgba), 0, 0)
  -> SIGSEGV in lib2d_graphics.z.so
     OHOS::Rosen::Drawing::SkiaImage::Serialize()
```
证据：`/data/log/faultlog/faultlogger/cppcrash-com.motty.harmony-*.log`（`hdc file recv` 取回）。

排除过的假设：Canvas 就绪门、`ImageData(width, height, data)` 参数顺序、ArrayBuffer→hex 传帧方式
——**都仍崩**，说明问题在 `ImageData` 的序列化路径。

### 26.2 可用的是什么
同一份像素数据，用 Canvas 的 `fillRect` 逐格绘制**完全正常**：
每帧 64×48 = **3072 个矩形**，缩放 5× 铺到 320×240 画布。
状态行 `drawn=3072` 是可断言的外部观测。

实测截图（`spec/runs/vnc-session-2in1/final.png`）确认：左红右蓝 + 指针处绿块。

### 26.3 这不是终点
- 3072 次 `fillRect`/帧只是"能上屏"，不是可用的渲染管线；
  正确路线是 **Surface/XComponent + `OH_NativeWindow`** 直接写 RGBA 缓冲
- 只在 x86_64 模拟器验证，arm64 真机未测；帧率/带宽未测

### 26.4 断言口径
不要用"画面看起来对了"当判据。本工程用三个机器判据：
`drawn=3072`（渲染路径真的执行了）、`green>0`（输入真的到对端且新帧回来了）、
`red>0`（图案本身解码正确）。截图只作人工复核，不作为唯一证据。
---

## 27. VNC Auth(DES) 与 Hextile

### 27.1 VNC Auth 的两个坑
1. **不是说"发口令"**：服务器发 16 字节挑战，客户端把口令转成 DES key（**每字节位反序**，
   不足 8 字节补 0），再用 DES-ECB 分两段加密挑战，回 16 字节响应。
2. **别自己搓 DES**：mbedTLS 已经链进来了，`mbedtls_des_setkey_enc` + `mbedtls_des_crypt_ecb`
   直接用。先确认静态库里有符号（`llvm-nm libmbedcrypto.a | grep mbedtls_des`），
   否则链接期才发现就晚了。

### 27.2 Hextile 解码要点
16×16 瓦片，先读 1 字节 subencoding：
`1=Raw 瓦片`、`2=BackgroundSpecified`、`4=ForegroundSpecified`、`8=AnySubrects`、`16=SubrectsColoured`。
subrect 用两字节 `(x<<4|y)` 与 `((w-1)<<4|(h-1))` 表示。
漏掉任一标志位都会导致后续字节错位、画面花屏。

### 27.3 夹具的两种模式
`-vnc-auth <pw>` 时只提供 VNC Auth(2)（用 Go 的 `crypto/des` 校验）；不带该参数则只提供 None(1)。
**标准 spec 用 None 模式，认证 spec 用 auth 模式**——两种模式的证据分别记录，不要混为一次运行。

### 27.4 两个本轮的教训
- **批量文本替换必须回读校验**：C++ 补丁因锚点不匹配静默未生效，编译通过但跑的是旧逻辑；
  这次是靠"状态行里还是旧错误文案"才发现的。
- **Go 的 `:=` 会遮蔽外层变量**：夹具里 `useHextile := false` 写进 switch 分支后，
  外层的判断永远不生效，服务器一直发 Raw，客户端自然看不到 `enc=hextile`。
---

## 28. 第三方组件：构建与接入

### 28.1 libvterm（MIT，终端网格）
源码：`third_party/src/libvterm`（`git clone --depth 1 https://github.com/neovim/libvterm`）。
**不需要 Perl**：`.inc` 表已随仓库提供（这点很关键，本机没有 Perl）。
编译（每个 .c 一个对象，然后 llvm-ar）：
```
clang -target x86_64-linux-ohos --sysroot=C:/ohos-ndk/sysroot -D__MUSL__ -O2 -fPIC -std=c99 \
      -I<src>/include -I<src>/src -c src/*.c
llvm-ar rcs libvterm.a *.o
```
接入要点（两个都会踩）：
1. `vterm_screen_set_callbacks` 里 **settermprop 必须返回 0**：返回 1 表示"已处理"，
   libvterm 会跳过自己的备用屏切换，主屏随后被 `\x1b[2J` 清空。
2. **`vterm_screen_enable_altscreen(vts, 1)`**：不启用的话 1047/1049 只发通知不切缓冲。
3. 单元格颜色在 `VTermScreenCell.fg/bg`（不在 attrs 里），判断默认色用
   `VTERM_COLOR_IS_DEFAULT_FG(&cell.fg)`；宽字符 `cell.width == 2` 且右侧格 width=0。

### 28.2 LibVNC client（GPL-2.0-or-later，按 v3 用于组合分发）
构建：`native/build-libvnc.ps1`（GPL 义务：构建必须可复现）。
关闭 TLS/JPEG/PNG/SASL/LZO/ZSTD，保留 zlib → 初期只多出 VNC Auth。
装到 `third_party/ohos/<arch>/lib/libvncclient.a` 后由 CMakeLists 链接。

### 28.3 模拟器切换后必做
`hdc rport` **不会跨模拟器实例保留**。切到另一台后要重新建立：
```
hdc -t <serial> rport tcp:2222 tcp:2223   # SSH 夹具
hdc -t <serial> rport tcp:5901 tcp:5901   # VNC 夹具
```
漏了第二条会让 VNC 用例以"握手失败"报错——是环境问题，不是产品缺陷。