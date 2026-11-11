# harmonyos/ —— A′ 开发工作区索引

> 路线：**A′（ArkTS/ArkUI + C/C++ 协议库经 NAPI）**。Go 在鸿蒙应用内不可用（已实测），详见 PLAN §15/§16。

## 文档（按阅读顺序）

| 文件 | 作用 | 状态 |
|---|---|---|
| [PLAN.md](./PLAN.md) | 总方案：路线对比 → 决策台账 → 风险登记册 → G1 实测 → A′ 定案 | 定稿（多次修订） |
| [A-PRIME-ENGINEERING.md](./A-PRIME-ENGINEERING.md) | A′ 落地：分层、C 依赖映射、M0.5 验收门、前 4 月 sprint、M0.5 实测进展 | 定稿 |
| [A-PRIME-ENGINEERING.md](./A-PRIME-ENGINEERING.md) | **工程主方案**：目录、12 个领域模块、7 端口契约、M0.5–M5 任务分解、Sprint 1 | 定稿（软件架构师交付） |
| [contracts/motty-native.d.ts](./contracts/motty-native.d.ts) | ArkTS ↔ NAPI ↔ C 契约 IDL 草案 | 草案 |
| [CAPABILITY-MATRIX.md](./CAPABILITY-MATRIX.md) | 能力矩阵 T1/T2/T3 逐项 | 待补「A′ 落点 + E1/E2/E3」两列 |
| [spec/RUNBOOK.md](./spec/RUNBOOK.md) | 模拟器环境、验证边界、证据等级 | 定稿 |

## 代码骨架（已建，待填）

```
ohos/     entry + features + libs{contract,domain,data,platform,input,i18n,testbase}
native/   port + proto-{ssh,sftp,crypto,agent,vnc,rdp} + napi + third_party + tests
spec/     schema + scenarios（82 个行为规格将在此） + capabilities.json
tools/design/   docs/
```

## 已验证的可用资产

- `.bin/motty-baseline.exe`（52.6 MB）与 `.bin/motty-head.exe`（52.9 MB）—— 原版参照实现，M0.5 oracle 的源头

## 环境速查

```
模拟器   devecocli emulator start motty_pc   （实例名不能含连字符）
hdc      C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe
设备     127.0.0.1:10100（x86_64，API 26）
NDK      C:\ohos-ndk（junction，避开路径空格截断 cgo CC）
Go       1.27.3    Viva E:\viva @95802a9    Python C:\Python315\python.exe
```

## 判读陷阱（已踩过两次）

在 PowerShell 里判断外部命令成败**不能只看 exit code** —— go/git 写 stderr 的进度信息会被当成错误记录。必须 `cmd /c "... > log 2>&1"` 落到文件再判读。
---

## Sprint 1 已落地产物（Round 1）

| 产物 | 作用 | 验证方式 |
|---|---|---|
| `spec/capabilities.json` | 能力注册表 v0.1，**83 条**（矩阵 78 + R51 补 5） | Python 校验：id 唯一、levels T1 60 / T2 8 / T3 9 / null 6 |
| `tools/design/caps-bootstrap.py` | 从 `CAPABILITY-MATRIX.md` **解析生成**注册表，保证键集合与矩阵不漂移 | 可重跑，幂等 |
| `spec/schema/scenario.schema.json` | 行为规格 v1：禁坐标、profile 必双画像、asserts 必须可判定、limits 必填 | jsonschema 校验通过 |
| `spec/scenarios/infra.host-create-by-id.yaml` | **黄金样例**：把已跑通的 host_menu_move 子集写成 spec（17 步 / 4 断言） | `spec/lint.py` 通过 |
| `spec/lint.py` | spec 门禁：schema + **6 条语义规则** + `--strict` | 负测已验证会拦（见下） |
| `spec/TRANSFER-PLAN.md` | 82 个 upstream 脚本 → 12 个批次的转译计划 | 覆盖性脚本校验：**无遗漏、无多余，12 批合计 = 82** |

### lint 的 6 条语义规则（schema 表达不了的）
1. `profile` 必须同时含 2in1 与 tablet
2. 选择器必须是 `id:`/`role:`/`label:`，**禁纯坐标**
3. `capabilities` 引用必须存在于注册表
4. **引用 T3 能力即错误**（T3 已移除，断言无意义）
5. 至少一条可判定断言（只有截图不算验收）
6. `evidence.limits` 必须有实质内容、含模拟器/真机与未覆盖项、不得含占位词

### 负测（证明门禁不是橡皮章）
构造一个 schema 合规但语义违规的 spec，lint 报出 **5 条错误**并 exit 1：profile 缺 tablet、坐标选择器、非选择器字符串、引用 T3 能力 A09。

### 已知未决（阻塞后续）
- `capabilities.json` 有 **25 条 needsReview** 待人工裁决（混合级 cell 如 "T1 / 平板 T3"，以及 6 条 level=null）
- `aPrime.where` 全部为空：必须等矩阵补上「A′ 落点 + E1/E2/E3」两列后回填，**禁止**用矩阵 B 组的"原样保留 Go 内核"填充
- spec 工具链依赖 `pyyaml` + `jsonschema`（已装：6.0.3 / 4.26.0）
---

## Round 2：spec runner 双画像跑通（2026-11-10）

| 产物 | 作用 |
|---|---|
| `spec/run.py` | spec → 真机/模拟器执行器：选择器解析→坐标解算→uitest 原语→断言→证据物 |
| `spec/RUNBOOK.md` | 运行手册：设备原语、双画像端口、首次安装对话框坑、证据物约定、**已知限制** |
| `spec/runs/smoke-2in1/`、`smoke-tablet/`、`smoke-tablet-2/` | 证据物：布局快照 + final.png + result.json |

### 实测结论
- `uitest` 7.0.0.1 的 `dumpLayout / screenCap / uiInput` 三条原语足够支撑整套 spec runner
- **双画像均通过**：2in1（3120×2080@304）与 tablet（2560×1600@360），同一份 spec 零改动
- 两个画像需**顺序运行**（本机 15.8 GB RAM，并发会互相拖慢）
- 新增环境问题检测：启动后被系统对话框遮挡时报 exit 2 并给指引，而不是让选择器"神秘找不到"

### 尚未实现（故意的，会报错而不是跳过）
动作 `swipe/longPress/rightClick/invoke`；断言 `state/screenRegex/wireLog/count/capabilityDisabled`；`testSurface` 观测面（终端文本读不到 → B2 批次在它落地前无法机器判定）。
---

## Round 3：第一个产品功能切片，双画像验收通过（2026-11-10）

| 产物 | 说明 |
|---|---|
| `ohos/app/` | ArkTS 应用骨架：主机列表 + 新建主机对话框（label/address/user/port，id 与 spec 精确对齐） |
| `spec/runs/host-create-2in1/` | **passed**（3120×2080 PC 画像） |
| `spec/runs/host-create-tablet/` | **passed**（2880×1920 平板画像） |
| `tools/design/dismiss-dialog.py` | 按文本点掉系统遮挡物（首次安装/输入法引导） |

### 这是第一个"机器判定"的产品验收
`infra.host-create-by-id` 17 步、4 断言，在两个画像上都是 `passed`：
建两台主机 → 列表出现 `alpha`、`beta`、`10.0.0.2` → 布局断言（无零宽/出屏文本）。

### 过程中修复的四个真实缺陷（都已进文档/工具）
1. **`.id()` 可用**：ArkUI 的 `.id()` 会出现在 dumpLayout 的 `id` 字段（`shell/dialog-label` 等），选择器策略成立。
2. **输入法拦截输入**：`uiInput text` 与 `inputText` 都会进拼音组合串 → 必须 `keyEvent 2054`（ENTER）提交，再回读校验。
3. **spec 的 `type` 必须带 `target`**：靠"先点后打"的焦点路径无法校验，且会丢字 → lint 已加硬规则。
4. **应用侧回写环**：`TextInput({text: state})` + `onChange` 会让提交的文本被状态回滚 → 改为不绑定 `text`。
5. **地址与端口分开渲染**：拼成 `10.0.0.2:22` 与上游呈现不一致，按文本断言会失败。

### 三道首次运行系统引导（已固化到 runner 遮挡检测 + RUNBOOK §8）
安装后"添加至桌面" → 输入法隐私授权 → 中文键盘布局向导。三者都会盖住 UI 让选择器失效。
---

## Round 4：持久化 + 可重复性（2026-11-10）

| 产物 | 说明 |
|---|---|
| `ohos/app` 持久化 | 主机数据落 `relationalStore`（`motty.db`，表 `hosts`，schema v1，**无迁移策略**） |
| `spec/scenarios/host.persist.yaml` | **新增**：新建主机 → 冷启动重启 → 数据仍在（3 断言） |
| `spec/run.py --fresh` | 运行前 `bm clean -n <bundle> -d` 清数据，保证可重复 |
| `spec/RUNBOOK.md` §9 | `--fresh` 使用规则；"两次 launch = 冷启动重启"的语义 |

### 双画像验收（本轮全部带 `--fresh`）
| spec | 2in1 | tablet |
|---|---|---|
| `infra.host-create-by-id` | **passed** | **passed** |
| `host.persist` | **passed** | **passed** |

### 明确未做（不假装）
- 数据库 schema 迁移/epoch 兼容（M5 前处理）
- 主机分组/标签/排序（B09 其余能力）
- 凭据与保险库加密（走 HUKS/Asset，M1-b）
- 持久化在能力矩阵里尚无独立条目（借用 B09），属待补条目
---

## Round 5：设备→宿主 SSH 通路打通（M0.6 第一块，2026-11-10）

| 产物 | 说明 |
|---|---|
| `tools/design/sshfixture/` | **新增** Windows 可跑的最小 SSH 对端（主机密钥/密码/公钥/exec；**拒绝 pty** 并记日志） |
| `ohos/app` TCP 探针 | `@ohos.net.socket` 连接设备 127.0.0.1:2222，读 SSH banner → Transport 层第一块真实代码 |
| `module.json5` | 新增 `ohos.permission.INTERNET`（缺它直接 `201 Permission denied`，实测） |
| `spec/scenarios/net.reachability.yaml` | 断言屏幕出现 `SSH-2.0-…`（新实现 `screenRegex` 断言） |
| `spec/RUNBOOK.md` §10 | fixture + `rport` 运行前提、能力边界表、权限要求 |

### 双画像验收
| spec | 2in1 | tablet |
|---|---|---|
| `net.reachability` | **passed** | **passed** |
| `infra.host-create-by-id` | passed（回归） | **passed** |
| `host.persist` | passed（回归） | **passed** |

### 明确边界（不夸大）
- 只证明 TCP 通路 + banner 可达；**不覆盖** SSH 握手/KEX/认证/通道/pty
- 对端是自建 fixture，**不是** upstream `tools/e2esshd`（后者需 `/bin/bash` + 真 pty，Windows 与无 WSL 环境下不可用）
- SFTP/SCP/转发/X11 仍需 Linux 对端 → B3/B5 批次的前置未解
---

## Round 6：协议层打通（libssh2 + mbedTLS 交叉编译 + NAPI + 真 SSH 会话）

| 产物 | 说明 |
|---|---|
| `native/cmake/ohos-x86_64.cmake` | OHOS 交叉编译 toolchain（直调 clang.exe，规避 sh 包装脚本） |
| `native/build-thirdparty.ps1` | 一条命令重编 mbedTLS + libssh2（x86_64） |
| `native/third_party/ohos/x86_64/lib/*.a` | mbedTLS 3.6.2 + libssh2 1.11.1（mbedTLS 后端）静态库 |
| `ohos/app/entry/src/main/cpp/ssh_napi.{cpp}` | NAPI 封装：异步 SSH 握手/密码认证/exec（TSFN 回调，不阻塞 UI） |
| `spec/scenarios/ssh.exec.yaml` | 断言远端 `echo` 的输出 `fixture-exec-ok` 出现在屏幕上 |
| `tools/design/sshfixture` | 支持 `-hostkeytype rsa|ed25519`；默认 RSA-3072（互操作原因见 RUNBOOK §11.3） |

### 双画像验收
| spec | 2in1 | tablet |
|---|---|---|
| `ssh.exec` | **passed** | **passed** |

对端侧独立证据（fixture stderr）：两次 `session from … auth=password` + `exec: "echo hello-from-ssh"`。

### 明确未做
- **arm64 未编译**（只有 x86_64 第三方库与 abiFilters）→ 真机尚不可运行
- 无主机密钥校验、无 pty、无 SFTP/SCP/转发、无会话复用
---

## Round 7：双 ABI（x86_64 + arm64-v8a）

| 产物 | 说明 |
|---|---|
| `native/cmake/ohos-arm64.cmake` | aarch64-linux-ohos toolchain |
| `native/third_party/ohos/arm64/lib/*.a` | mbedTLS + libssh2 的 AArch64 静态库（已验证 Machine: AArch64） |
| `native/build-thirdparty.ps1` | 支持 `-Arch x86_64|arm64`；修了两个脚本级坑（BOM、$root 多减一层） |
| `entry/src/main/cpp/CMakeLists.txt` | 按 hvigor 注入的 `OHOS_ARCH` 自动选第三方库子目录 |
| `entry/build-profile.json5` | `abiFilters: ["x86_64","arm64-v8a"]` |

### 打包结果
`libs/x86_64/libmottynapi.so` 745.8 KB (X86-64) ｜ `libs/arm64-v8a/libmottynapi.so` 724.9 KB (AArch64)

### 回归（双 ABI 包在模拟器上仍正常）
| spec | 2in1 | tablet |
|---|---|---|
| `ssh.exec` | **passed** | **passed** |
| `net.reachability` | **passed** | **passed** |
| `host.persist` | — | **passed** |

### 证据等级（重要）
**arm64 只有 E2（仅编译）**，没有真机 → 无执行证据。x86_64 侧是 E1（模拟器实测）。
---

## Round 8：主机密钥校验（P1 安全不变量）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | `probe(host,port,user,pass,cmd,expectedFingerprint,cb)`；**先校验、后认证**；SHA256 指纹（OpenSSH 格式） |
| `spec/scenarios/ssh.hostkey.yaml` | 三步 TOFU：未知主机只回指纹 / 匹配才认证 / 不匹配即拒 |
| `Index.ets` | `Hostkey Check` 三步自检；`SSH Test` 改为两步 TOFU |

### 三条状态语义
`unknown_host SHA256:…`（不认证）｜`verified SHA256:… ok …`｜`hostkey-mismatch expected=… actual=…`（不认证）

### 双画像验收（全 5 条）
| spec | 2in1 | tablet |
|---|---|---|
| `ssh.hostkey` | **passed** | **passed** |
| `ssh.exec` | **passed** | **passed** |
| `net.reachability` | **passed** | **passed** |
| `host.persist` | **passed** | **passed** |
| `infra.host-create-by-id` | **passed** | **passed** |

### 对端日志证据
三次握手 → **只有一条** `auth=password`、**只有一条** `exec: "echo should-run-2"`；两次拒绝路径均为握手后 `disconnect`，从未认证。

### 明确未做
known_hosts 持久化、`@cert-authority`、hostkey 算法白名单、指纹变更的用户提示 UI。
---

## Round 9：known_hosts 持久化 + 用户确认闭环

| 产物 | 说明 |
|---|---|
| `relationalStore` 表 `known_hosts` | `host / fingerprint / updated_at`，`ON_CONFLICT_REPLACE` 写入 |
| `Index.ets` | 未知主机 → **确认对话框**（显示指纹，Trust/Cancel）→ 信任才落盘并连接；已信任则不再弹框 |
| `spec/scenarios/ssh.knownhost.yaml` | 用**步骤级 expect** 断言"第 1 次弹框、Trust 后 verified、第 2 次不再弹框" |
| `spec/run.py` | **新增步骤级 `expect` 支持**（schema 早已声明、此前未实现）；修 assert dump 命名格式化 bug |

### 双画像验收（6 条 × 2 画像，均为当前构建）
| spec | 2in1 | tablet |
|---|---|---|
| `infra.host-create-by-id` | **passed** | **passed** |
| `host.persist` | **passed** | **passed** |
| `net.reachability` | **passed** | **passed** |
| `ssh.exec` | **passed** | **passed** |
| `ssh.hostkey` | **passed** | **passed** |
| `ssh.knownhost` | **passed** | **passed** |

对端日志证据：第一次连接只握手不认证；Trust 后认证并执行；**第二次连接直接认证、不再取指纹**。

### 明确未做
主机密钥变更的提示 UI、删除/重置已知主机、`@cert-authority`、hostkey 算法白名单。
---

## Round 10：从主机列表发起连接（协议层接回产品）

| 产物 | 说明 |
|---|---|
| `Index.ets` 主机条目 | 增加 `proto` 列；行内 `Connect` 按钮（`host-row/<i>`）→ 走完整 TOFU → 认证执行；每行独立状态（`host-status/<i>`） |
| 口令处理 | **只存内存**（`Map`，键 `address:port`），**不落库、不落文件**；保险库是 M1-b |
| `spec/run.py` + schema | 新增步骤级 `expect` 与 `secret`（掩码字段不回读，由"连得上"间接验证） |
| `spec/scenarios/ssh.connect-from-list.yaml` | 建主机 → 点行 → 确认指纹 → 信任 → 认证执行 → 二次点击不再弹框 |

### 双画像验收（6 条产品 spec × 2 画像，均为当前构建）
| spec | 2in1 | tablet |
|---|---|---|
| `ssh.connect-from-list` | **passed** | **passed** |
| `infra.host-create-by-id` | **passed** | **passed** |
| `host.persist` | **passed** | **passed** |
| `net.reachability` | **passed** | **passed** |
| `ssh.exec` | **passed** | **passed** |
| `ssh.hostkey` | **passed** | **passed** |

对端日志：取指纹不认证 → Trust 后认证执行 `echo hello-from-list` → 二次点击直接认证。

### 去重
删除 `ssh.knownhost.yaml`：它断言的两件事（确认框出现、二次连接不再弹框）已被
`ssh.connect-from-list` 完整覆盖，保留两份会让维护成本翻倍而没有额外证据。

### 仓库卫生（重要）
`ohos/app/build-profile.json5` 里含**明文签名口令与绝对路径** → 已 `gitignore`，
改为提交 `build-profile.example.json5` 模板。第三方源码（99 MB）与构建产物同样不入库，
由 `native/build-thirdparty.ps1`（含自动下载）重建。
---

## Round 11：终端视图最小闭环（流式输出 → 渲染）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | 新增 **流式** `exec(host,port,user,pass,cmd,expectedFp,onData,onDone)`：分块回调（两个 TSFN），不再等全部读完 |
| `Index.ets` | 行内 `Term` 按钮 → TOFU 确认 → 终端面板（`terminal/panel`，输出区 `terminal/output`），文本随流式数据追加 |
| `tools/design/sshfixture` | 新增 `term-demo` 命令：6 行、每行间隔 120ms、末行带 ANSI 颜色序列 |
| `spec/scenarios/terminal.view.yaml` | 断言 `term-line-1` / `term-line-5` / `term-line-6 green` / `[status] ok` |

### 为什么这条 spec 有意义
它区分"一次性 exec 返回"与"流式分块到达"：term-demo 每 120ms 吐一行，
断言到第 5、6 行说明多块数据都进了终端缓冲区，而不是只拿到最后一次读的结果。

### 双画像验收（7 条 × 2 画像）
| spec | 2in1 | tablet |
|---|---|---|
| `terminal.view` | **passed** | **passed** |
| `ssh.connect-from-list` | **passed** | **passed** |
| `infra.host-create-by-id` | **passed** | **passed** |
| `host.persist` | **passed** | **passed** |
| `net.reachability` | **passed** | **passed** |
| `ssh.exec` | **passed** | **passed** |
| `ssh.hostkey` | **passed** | **passed** |

### 明确不做（本版是"数据通路"，不是终端模拟器）
- **没有 VT 解析**：颜色、光标、备用屏、回滚、宽字符整形一律没有；ESC 序列原样显示
- 没有真实 shell 会话（远端命令是固定的 `term-demo`）
- 没有窗口尺寸协商、没有键盘输入、没有选择/复制
---

## Round 12：交互式终端（键盘输入 → SSH 通道 → 远端回显）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | `openShell/sendInput/closeShell`：每会话一个工作线程，**所有 libssh2 调用都在该线程**；sendInput 只入队；会话非阻塞轮询 |
| `Index.ets` | 终端面板加输入框（`terminal/input`）与 `Send`（`terminal/send`）；关面板时 `closeShell` |
| `tools/design/sshfixture` | 新增 `term-echo`：读一行回一行 |
| `spec/scenarios/terminal.interactive.yaml` | 输入 `hello-one`、`second-line` 各断言回显 |
| 顶栏 `terminal/demo` | 保留一次性流式 `exec` 路径的覆盖（`terminal.view` 改指向它） |

### 本轮修掉的三个真实缺陷
1. **参数索引错位**：`openShell` 把 `expectedFingerprint` 读成第 5 参（onData）→ 指纹恒空 → 日志里出现 `hostkey not trusted`
2. **会话阻塞**：socket 有 8s 收超时，worker 阻塞在 `channel_read` → 键盘写入被推迟到超时之后。改为 `libssh2_session_set_blocking(session, 0)` 轮询
3. **写入丢字节**：`channel_write` 遇 EAGAIN 时剩余字节直接丢弃 → 改为放回队列；另修 `g_sessions.erase` 用错 key 的泄漏
4. **输入框未清空**：发送后字段仍显示上一行，第二行变成 `hello-one second-line` → 输入框绑定状态并在发送后清空

### 双画像验收（8 条 × 2 画像）
| spec | 2in1 | tablet |
|---|---|---|
| `terminal.interactive` | **passed** | **passed** |
| `terminal.view` | **passed** | **passed** |
| `ssh.connect-from-list` | **passed** | **passed** |
| `infra.host-create-by-id` | **passed** | **passed** |
| `host.persist` | **passed** | **passed** |
| `net.reachability` | **passed** | **passed** |
| `ssh.exec` | **passed** | **passed** |
| `ssh.hostkey` | **passed** | **passed** |

### 仍然不是终端模拟器
无 VT 解析（无颜色/光标/退格/备用屏/回滚/宽字符整形）；输入按整行 + 换行发送，需点 Send；
远端是 fixture 的 `term-echo`，不是真 shell。真正的 VT 引擎是 M1 剩余最大块。
---

## Round 13：最小 VT 引擎（网格化，而非字节流）

| 产物 | 说明 |
|---|---|
| `cpp/vt_core.cpp` | 最小 VT 解析器：CUP/CUU-CUD-CUF-CUB/CHA/VPA、ED 0/1/2、EL 0/1/2、SGR 前景色与重置、CR/LF/滚动；导出 `vtReset/vtFeed/vtScreen/vtStatus` |
| `Index.ets` | 终端不再直接拼字节：`chunk → vtFeed → vtScreen` 渲染网格，另显示 `terminal/vt-status`（光标位置与着色格数） |
| `tools/design/sshfixture` | 新增 `vt-demo`：清屏 → 定位 → 颜色 → 擦行 → 跨行 → 光标回位覆盖 |
| `spec/scenarios/terminal.vt.yaml` | 5 条断言覆盖四种 VT 能力 |
| 顶栏两个诊断入口 | `terminal/demo`（原始流式 term-demo）与 `terminal/vt`（VT 子集），一个入口只覆盖一件事 |

### 四条断言各自的含义
| 断言 | 证明什么 |
|---|---|
| `cursor-here` 出现 | CUP 回到 1,1 后覆盖写入生效（旧内容被替换） |
| `vt-moved` 出现 | CUP 定位到 3,5 生效 |
| `vt-erase-me` **缺席** | EL 2 真的擦掉了整行 |
| `colors=[1-9]` | SGR 被记录（着色格数 > 0） |

### 本轮修掉的两个问题
1. **链接错误**：`RegisterVtFunctions` 声明写在匿名命名空间内 → 内部链接 → `ld.lld: undefined symbol`。移到全局作用域解决
2. **状态标签硬编码**：`runDemo` 的完成回调固定写 `vt-demo:`，导致 `terminal.view` 的 `[status] ok` 断言失效 → 改为按命令名带出，并同步更新断言

### 双画像验收（9 条 × 2 画像，均为当前构建）
`terminal.vt`、`terminal.view`、`terminal.interactive`、`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 2in1 与 tablet 全部 **passed**。

### 仍然不做的（写清楚，别当成完整终端）
备用屏、回滚缓冲、宽字符/组合字符、连字、SIXEL/Kitty/iTerm2 图片、鼠标上报、
DECSET 2026、选择与复制、真实 pty 尺寸协商。宽字符一项会直接影响 CJK 显示，
是下一阶段必须补的（当前只处理 0x20–0x7E 可打印 ASCII）。
---

## Round 14：收口（CJK 宽字符 + 证据回填 + 现状文档）

| 产物 | 说明 |
|---|---|
| `cpp/vt_core.cpp` | 支持 UTF-8（含跨 chunk 半截序列）与 **CJK 双宽单元格**；`vtStatus` 增加 `wide=` 计数 |
| `spec/scenarios/terminal.vt.yaml` | 新增 3 条断言：`中文宽字符测试`、`abc|中文|def` 对齐、`wide=[3-9]+` |
| `spec/capabilities.json` | 回填 `proof`（spec 路径）与 `evidence=E1`：**4 个能力**取得实测证据（B01/B02/B07/B09） |
| `A-PRIME-STATUS.md` | **现状收口**：E1/E2/E3 分层、82 spec 进度、四个关键结论、下一步真实顺序 |

### CJK 实测结果
终端缓冲区（`terminal/output`）实测：
```
cursor-here
    vt-movedred-text
vt-line-10
中文宽字符测试
abc|中文|def
```
`terminal/vt-status`：`cur=21,13 colors=8 wide=9 size=80x24`
→ 宽字符占 2 列且对齐正确（`abc|中文|def`），`wide=9` 与 7+2 个汉字吻合。

### 最终验收（9 spec × 2 画像，同一份最终构建）
| spec | 2in1 | tablet |
|---|---|---|
| `terminal.vt`（含 CJK） | **passed** | **passed** |
| `terminal.view` | **passed** | **passed** |
| `terminal.interactive` | **passed** | **passed** |
| `ssh.connect-from-list` | **passed** | **passed** |
| `infra.host-create-by-id` | **passed** | **passed** |
| `host.persist` | **passed** | **passed** |
| `net.reachability` | **passed** | **passed** |
| `ssh.exec` | **passed** | **passed** |
| `ssh.hostkey` | **passed** | **passed** |

### 诚恳的结论
82 个行为规格完成 **9 个（11%）**；产品功能只有"主机列表 + 连接 + 终端"一个切片；
**arm64 只有编译证据（E2），没有任何真机执行证据**。距离"1:1 完成"仍是数十人月的量，
现状与缺口逐条写在 [A-PRIME-STATUS.md](./A-PRIME-STATUS.md)。

---

## 清理：删除探针与被取代文档（2026-11-10）

用户要求"清理无关代码和文档"。删掉的是**已失效或已被取代**的东西，不是有用的证据：

| 删除 | 原因 | 证据去哪了 |
|---|---|---|
| `spike/`（bprime / hello / core） | G1 已定案（Go 不可用），探针工程不再是产品资产；且 bprime 的 build-profile 曾含明文签名口令 | PLAN §15/§16 保留了完整的实测命令与结论 |
| `spec/scenarios/smoke.runner.yaml` | 目标是 bprime 探针应用，探针删除后它必然失效（僵尸 spec） | 测试链路可用性已由 9 个产品 spec 持续证明 |
| `A-PRIME-PLAN.md` | 与 A-PRIME-ENGINEERING.md 大面积重叠 | 其唯一独有的「C 依赖映射」已并入 ENGINEERING 附录 A |
| `SPIKES.md` | G1 门禁已结束；模拟器/rport 操作知识已固化在 spec/RUNBOOK.md | RUNBOOK §10 与 PLAN §15/§16 |
| 构建产物与证据物（`.bin/`、`native/build/`、`entry/.cxx`、`entry/build`、`spec/runs/`） | 可重建，且已在 gitignore 内 | 结论写入文档，不靠提交截图表意 |

**结果**：`harmonyos/` 从 363.5 MB / 5355 文件降到约 116 MB / 少量源文件；文档从 9 篇降到 7 篇，
交叉引用全部改指仍然存在的文件。

清理后复核：`devecocli build` 成功、`spec/lint.py` 全绿、`terminal.vt` 在平板上仍 **passed**。
---

## Round 15：回滚缓冲 + 备用屏（终端可用性的关键一步）

| 产物 | 说明 |
|---|---|
| `cpp/vt_core.cpp` | 回滚缓冲（上限 2000 行，滚出即入历史，**只存文本不存属性**）；备用屏 `DECSET/DECRST 47/1047/1049`（进入时保存主屏与光标，退出恢复）；`vtStatus` 增加 `hist=` 与 `alt=`；新增 `vtScrollBack(n)` |
| `Index.ets` | 终端面板增加 `terminal/history`（历史尾巴外显）与 `VT2` 诊断入口（`terminal/vt2`） |
| `tools/design/sshfixture` | 新增 `vt-demo2`：30 行滚动 + 进备用屏写标记 + 退出 + 主屏写标记 |
| `spec/scenarios/terminal.scrollback.yaml` | 5 条断言，含回滚与备用屏各自的关键证明 |

### 关键断言设计
- `scroll-0[5-9]`：30 行进 24 行屏后，第 1–6 行已被顶出屏幕，**只可能出现在历史缓冲**里（`vtScrollBack` 尾巴）。没有回滚缓冲这条必然失败。
- `alt-marker` **缺席**：备用屏里写的内容在退出后不得残留。
- `hist=[1-9][0-9]*` 与 `alt=0`：来自 `vtStatus`，把"内部状态"变成可断言的外部观测。

### 双画像验收（10 条 × 2 画像，当前构建）
`terminal.scrollback`、`terminal.vt`、`terminal.view`、`terminal.interactive`、`ssh.connect-from-list`、
`infra.host-create-by-id`、`host.persist`、`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

### 仍未做（终端离可用还有距离）
- 回滚区只有文本，**没有颜色/宽字符属性**
- 没有滚动条交互、回滚内搜索、DECSTBM 滚动区域、resize 重排
- 没有组合字符/零宽连接/emoji 序列（宽度仍是区段近似）
- 没有真 pty：对端是"行回显"而非 shell
---

## Round 16：真 pty（pty-req + shell + window-change）

| 产物 | 说明 |
|---|---|
| `tools/design/sshfixture/pty_windows.go` | **ConPTY** 实现：真 pty 后面跑 `cmd.exe`；`ResizePseudoConsole` 支持 window-change |
| `tools/design/sshfixture/pty_other.go` | 非 Windows 平台明确报错（不提供假 pty） |
| `tools/design/sshfixture/pty_manual_test.go` | 把 ConPTY 从 SSH 链路里隔离出来的单测（本次调试的关键工具） |
| `cpp/ssh_napi.cpp` | `openChannel(...,cols,rows,usePty,...)`：`libssh2_channel_request_pty_ex` + `libssh2_channel_shell`；`resizeShell(id,cols,rows)` 走 `request_pty_size_ex`（入队到工作线程） |
| `cpp/vt_core.cpp` | **跳过 OSC 序列**（真 shell 会发 `ESC ] 0;标题 BEL`，不跳过会当文本打印） |
| `spec/run.py` | **type 注入加引号**：`hdc shell` 会把含空格的命令拆成多参数，之前只喂进第一个单词 |
| `spec/scenarios/terminal.pty.yaml` | pty 会话 + resize 的端到端断言 |

### 本轮的两个真实 bug（都不是猜出来的）
1. **ConPTY 子进程把输出写回父控制台**：先只收到 16 字节初始化序列。对照已知可用实现后发现两处差异——**交给 ConPTY 的两个句柄不能提前关闭**，且 `STARTUPINFOEXW` 要置 `STARTF_USESTDHANDLES`。修完立刻拿到真 cmd.exe banner 与提示符。
2. **`inputText` 遇空格被截断**：`hdc shell` 按空格拆参数，`echo hello-pty-ok` 只进去了 `echo`。加设备侧单引号引用后正常。

调试方法值得记：先用一个 Go 单测把 ConPTY 单独跑通（2 秒出结果），再回到端到端 spec。否则"pty 没输出"和"SSH 没转发"在 spec 里长得一模一样。

### 双画像验收（11 条 × 2 画像）
`terminal.pty`、`terminal.scrollback`、`terminal.vt`、`terminal.view`、`terminal.interactive`、
`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

对端日志证据：`pty-req term=xterm-256color size=80x24` → `shell started on pty 80x24` → `window-change -> 100x30`。

### 边界（对端是 Windows ConPTY，不是 Linux bash）
- 未覆盖 Linux bash/zsh 的 terminfo 行为、vim/less 等全屏程序
- window-change 只验证请求被发出且对端执行，未验证 shell 实际重排
- 终端仍无组合字符/emoji 宽度、无鼠标上报、无 DECSET 2026
---

## Round 17：产品形态收敛（诊断收进面板、主机行直接开会话）

前 16 轮顶栏堆了 9 个诊断按钮，那是"能验证"的产物，不是"能卖"的产品。本轮开始收敛。

| 变化 | 说明 |
|---|---|
| 顶栏 | 只剩 `Motty` / `Diagnostics`(`diag/open`) / `New Host`（+ 会话中显示 `nav/hosts`） |
| 主机行 | `Test`（`host-row/<i>`，一次探测连接）+ `Open`（`host-open/<i>`，打开 pty 会话） |
| 会话视图 | 终端内联显示（不再是浮层），带 `terminal/output`、输入、`Send`、`Resize`、`Hosts` 返回 |
| 诊断 | 全部收进 `diag/panel`：TCP probe / SSH probe / Hostkey check / term-echo / vt-demo / vt-demo2 / vt / pty shell，`net/probe-result` 显示结果 |

### spec 的变化（都是必要的，不是为了凑数）
- 诊断类 spec 多一步 `diag/open`：`net.reachability`、`ssh.exec`、`ssh.hostkey`、`terminal.view`、`terminal.vt`、`terminal.scrollback`
- `terminal.interactive` 改走 `diag/term-echo`（产品行按钮已变成 pty 会话）
- `terminal.pty` **改走产品路径** `host-open/0`，不再是诊断入口
- `terminal.view` 的完成态断言改为网格文本（`term-line-3`）：诊断面板动作后会自动关闭，状态文本不再停留在屏幕上

### 双画像验收（11 条 × 2 画像）
`terminal.pty`、`terminal.scrollback`、`terminal.vt`、`terminal.view`、`terminal.interactive`、
`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

### 明确的未做
- **多标签**：同一时刻只有一个活动会话。要并行多会话，必须把 `vt_core` 从全局单例改成实例化
  （每标签一个网格 + 各自的历史缓冲），这是下一轮的工作，本轮不假装支持。
- 分屏、会话恢复、标签重排、设置页。
- 凭据仍只在内存（保险库未做）。
---

## Round 18：VT 实例化 + 多标签会话

| 产物 | 说明 |
|---|---|
| `cpp/vt_core.cpp` | 网格从**全局单例**改为**实例注册表**：`vtNew/vtFree` 管理实例，`vtFeed/vtScreen/vtStatus/vtScrollBack` 均支持带 id；旧的"默认实例 0"接口保留，既有代码与 spec 不受影响 |
| `Index.ets` | 多标签：`tabs[]` + `activeId`，每个标签独立 `vtId` 与 `shellId`；标签栏 `session/tabbar`（`session-tab/<id>`、`session-close/<id>`、`session/count`）；`Hosts` 只是切回列表，**不再销毁会话** |
| `spec/scenarios/session.tabs.yaml` | 同一主机开两个会话、切回列表、关闭排序 |

### 为什么必须先实例化 VT
之前 `vt_core` 只有一个全局网格。若直接做多标签，第二个会话的输出会把第一个的屏幕覆盖掉——
"看起来有标签，实际只有一个终端"。所以这轮先改 C 层，再做 UI。

### 关键断言
- `tab-host #1` 与 `tab-host #2` 同时存在 → 两个会话都在
- `2 sessions` → 标签计数来自真实数组长度
- 关闭一个后 `#2` 缺席、计数回到 `1 session`
- 第二次 `Open` **不再弹信任框**（known_hosts 已落盘），证明信任持久化在多会话下依然生效

### 双画像验收（12 条 × 2 画像）
`session.tabs`、`terminal.pty`、`terminal.scrollback`、`terminal.vt`、`terminal.view`、`terminal.interactive`、
`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

### 未做
- 标签拖动/重排、分屏、会话恢复（应用重启后丢失）
- 会话数量增长时的内存与切换开销未测量
- 终端仍缺组合字符/emoji 宽度、鼠标上报、DECSET 2026、选择复制
---

## Round 19：SFTP 最小链路（列目录 + 读文件）

| 产物 | 说明 |
|---|---|
| `tools/design/sshfixture` | 新增 **SFTP 子系统**（`github.com/pkg/sftp`），根目录是临时目录，内含 `hello.txt` 与 `sub/nested.txt` |
| `cpp/ssh_napi.cpp` | `sftp(host,port,user,pass,expectedFp,op,path,cb)`，`op = list \| read`；主机密钥语义与 probe 一致（未知/不匹配**不认证**，碰不到任何文件） |
| `Index.ets` | 主机行新增 `Files`（`host-files/<i>`）→ 文件面板 `sftp/panel`：路径、条目按钮、下载、预览、状态 |
| `spec/scenarios/sftp.browse.yaml` | 列根目录 → 读文件内容 → 点进子目录 → 列子目录 |

### 一个设计决定
目录不能只把名字打出来——**要让用户能点进去**。于是列表项是按钮（`sftp/entry/<name>`）：
点目录就进入并重新列出，点文件就选中它。顺带绕开了一个真实缺陷：
`sftp/path` 输入框绑定状态时，注入后值会被回滚（与设置页那些输入框同源的问题），
靠"打字改路径"来驱动测试是不可靠的，改成点击才既可测也是正常交互。

### 关键断言
- `hello.txt` 出现在列表里（列目录通）
- 点 Download 后 `sftp-hello-marker` 出现（读内容通，且内容真的来自远端）
- 点进 `sub/` 后 `nested.txt` 出现（**path 参数真的传到了远端**，不是被忽略）
- `error opendir` 缺席

### 双画像验收（13 条 × 2 画像）
`sftp.browse`、`session.tabs`、`terminal.pty`、`terminal.scrollback`、`terminal.vt`、`terminal.view`、
`terminal.interactive`、`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、
`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

### 未做（SFTP 只到"能看"）
上传、重命名、删除、权限/时间戳展示、进度与断点续传、符号链接、二进制文件（当前按 UTF-8 文本读，上限 256 KiB）、
并发传输、SCP、本地↔远端双栏。
---

## Round 20：SFTP 写与删（上传 + 删除）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | `sftpWrite(...)`（临时文件 + `rename_ex` 原子落位）、`sftpDelete(...)`（unlink，失败回退 rmdir） |
| `Index.ets` | 文件面板增加上传名/内容/`Upload`（`sftp/upload`）与 `Delete`（`sftp/delete`）；新增独立结果行 `sftp/result` |
| `spec/scenarios/sftp.write.yaml` | 写 → 列 → 读回 → 删 的完整往返 |

### 三个实打实的坑
1. **写文件必须用临时文件 + 改名**：直接 truncate 目标文件时若中途失败，远端会留一个坏文件。
2. **结果文本会被刷新覆盖**：`refreshListing` 会把 `sftpStatus` 改成 "listed …"，删除/上传结果就看不见了。
   所以单独开一行 `sftp/result` 只由操作写、不被列目录覆盖。
3. **裸文件名断言会假通过**：上传目标输入框里本来就有 `uploaded.txt`，用 `uploaded\.txt` 匹配屏幕必然命中。
   改成匹配目录列表格式 `uploaded\.txt\|[0-9]+`——只有真的出现在远端目录里才成立。

### 双画像验收（14 条 × 2 画像）
`sftp.write`、`sftp.browse`、`session.tabs`、`terminal.pty`、`terminal.scrollback`、`terminal.vt`、
`terminal.view`、`terminal.interactive`、`ssh.connect-from-list`、`infra.host-create-by-id`、
`host.persist`、`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

> 一次瞬时失败记录：2in1 刚启动时屏幕处于锁屏，`launch` 报 `error code 10106102`；
> 同一条 spec 重跑即通过。这是环境态而非产品缺陷，已写进 RUNBOOK §22。

### 未做
上传进度/断点续传、大文件、二进制上传、目录递归上传与删除、权限/时间戳保留、并发与冲突、
本地↔远端双栏、SCP。
---

## Round 21：凭据保险库（还安全债）

此前口令只活在内存 `Map` 里，进程一退就没了。本轮把它交给**系统 Asset Store Kit**。

| 产物 | 说明 |
|---|---|
| `Index.ets` | `Vault` 封装（`asset.add/query/remove`，别名 `motty.host.<host:port>`，可访问性 `DEVICE_UNLOCKED`） |
| `submit()` | 新增主机时口令写入保险库；`reload()` 时**从保险库预热**内存缓存 |
| 启动逻辑 | **删除硬编码的 fixture 口令**——诊断入口现在也走保险库，没有主机就没有凭据 |
| `spec/run.py` | 新增 `restart` 动作（`aa force-stop` + 重新 launch），进程级重启的验证手段 |
| `spec/scenarios/vault.persist.yaml` | 建主机 → **重启进程** → 直接点 Test → 拿到命令输出 |

### 这条 spec 为什么能证明"落盘了"
内存 `Map` 在进程重启后**必然为空**。重启后没有重新输入任何口令，却仍能完成认证并拿到
`hello-from-list` 输出 → 口令只可能来自保险库。反证：保险库失效时 UI 会显示
`no credentials in memory`，这条被断言为**缺席**。

### 连带改动（都是必要的）
- `ssh.exec`、`ssh.hostkey` 两个 spec 先建一台主机（硬编码口令已删除，不建就没凭据）
- 能力注册表回填：`B03`（凭据存储）、`C01`（SFTP 浏览）、`C02`（SFTP 写）

### 双画像验收（15 条 × 2 画像）
`vault.persist`、`sftp.write`、`sftp.browse`、`session.tabs`、`terminal.pty`、`terminal.scrollback`、
`terminal.vt`、`terminal.view`、`terminal.interactive`、`ssh.connect-from-list`、`infra.host-create-by-id`、
`host.persist`、`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

### 边界（别说成"安全做完了"）
- 只覆盖"锁屏解锁后可访问"一种可访问性；锁屏/重启后的访问限制行为未测
- 未做口令轮换、失效、迁移、多用户、Asset 不可用时的降级
- 地址/端口/用户名仍在明文库（它们不是机密）；**known_hosts 与主机列表也没有加密**
- 未做 arm64 真机验证；未做渗透测试
---

## Round 22：本地端口转发（direct-tcpip）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | `forwardStart(...)` / `forwardStop(id)`：独占会话 + 本地监听 + `libssh2_channel_direct_tcpip_ex` + 双向透传 |
| `tools/design/sshfixture` | **自己实现 direct-tcpip**（Go 的 ssh 库不提供转发）：解析载荷 → `net.Dial` 目标 → 双向 `io.Copy` |
| `Index.ets` | 顶栏 `Forward`（`fwd/open`）→ 面板：监听端口/目标/Start/Stop/`Test tunnel`，事件流 `fwd/events`，隧道结果 `fwd/result` |
| `spec/scenarios/forward.local.yaml` | 起隧道 → 用本机 socket 连自己的转发端口 → 读到远端 SSH banner |

### 关键断言
`SSH-2.0-`：这个 banner **只可能由远端服务产生**。本机 socket 连的是设备自己的
`127.0.0.1:2201`，中间经 SSH 隧道到远端 `127.0.0.1:2223`——看到 banner 就说明整条链路通了，
不是本地假回显。对端日志同时出现 `direct-tcpip open -> 127.0.0.1:2223`。

### 修掉的两个真问题
1. **转发循环曾单端阻塞**：原先在本地 `recv` 上阻塞，远端数据永远读不到（banner 一直不来）。
   改为两端都非阻塞轮询（`libssh2_session_set_blocking(session, 0)` + `O_NONBLOCK`）。
2. **对端不支持 direct-tcpip**：Go `x/crypto/ssh` 不实现转发，通道请求被拒 → 客户端报
   `error direct-tcpip failed`。夹具补了通道处理才算真通。

### 双画像验收（16 条 × 2 画像）
`forward.local`、`vault.persist`、`sftp.write`、`sftp.browse`、`session.tabs`、`terminal.pty`、
`terminal.scrollback`、`terminal.vt`、`terminal.view`、`terminal.interactive`、
`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、`net.reachability`、
`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

### 未做
远程(remote)转发、动态(SOCKS)转发、多连接并发（当前串行，一次一个连接）、ACL/来源限制、
断线重连、端口冲突提示、转发规则持久化。
---

## Round 23：VNC / RFB 3.8（自研实现，先定许可证再写代码）

### 路线决策（写在代码之前）
| 选项 | 结论 |
|---|---|
| 引 LibVNC(libvncclient) | **否决**。GPL-2.0 会传染整个应用，直接堵死上架 |
| 自研 RFB 客户端 | **采用**。上游 Motty 也是自研 `internal/rfb`，行为对齐更容易 |

这条不是"以后再看"——它是本轮动手前的第一个决定。

| 产物 | 说明 |
|---|---|
| `tools/design/sshfixture/rfb_fixture.go` | 最小 RFB 3.8 服务端夹具：`None` 安全类型、`Raw` 编码、固定图案（左半红右半蓝，64×48） |
| `cpp/ssh_napi.cpp` | `vncProbe(host, port, cb)`：版本协商 → 安全类型 → SecurityResult → ClientInit/ServerInit → SetEncodings(Raw) → FBUpdateRequest → Raw 矩形解码 |
| `Index.ets` | 诊断面板加 `VNC`（`vnc/probe`）与结果行 `vnc/result` |

### 关键断言
`top-left=FF0000` 与 `right=0000FF` **取自同一帧的左半区与右半区**：解码/移位/通道顺序任一处错，
两者必然错位或相等。这比"连上了"强得多。

### 修掉的 bug
`ServerInit` 布局读错：把 shifts 当成偏移 16/17/18（实际 14/15/16），并且多读了 4 字节 nameLength
（它已包含在 24 字节里）→ 读到垃圾长度后按 8s 超时失败。对端日志表现为"客户端只发了版本就断"。

### 双画像验收（17 条 × 2 画像）
`vnc.handshake`、`forward.local`、`vault.persist`、`sftp.write`、`sftp.browse`、`session.tabs`、
`terminal.pty`、`terminal.scrollback`、`terminal.vt`、`terminal.view`、`terminal.interactive`、
`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、`net.reachability`、
`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

### 未做（VNC 远未完成）
- **VNC Auth (DES)** 未实现：只支持 `None`；遇到只给 VNC Auth 的服务器会返回明确错误，不假装成功
- 编码只支持 `Raw`：Hextile / ZRLE / CopyRect / RRE 都没有
- **不上屏**：本轮只做取色验证，没有把帧渲染到画布（XComponent 纹理待做）
- 鼠标/键盘事件、剪贴板、resize、增量脏区、多帧、断线重连
- RDP 完全未动（上游 38k 行，单独立项）
---

## Round 24：VNC 会话与输入（**上屏被图形崩溃阻塞，已回退**）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | `vncStart/vncPointer/vncKey/vncStop`：持续帧循环 + 输入事件队列（PointerEvent/KeyEvent） |
| `tools/design/sshfixture/rfb_fixture.go` | 支持 PointerEvent/KeyEvent：收到按下事件就在指针处画 8×8 绿块（让"输入到达"可断言） |
| `Index.ets` | VNC 面板：状态行 `vnc/status`、帧信息 `vnc/frame`、`Send pointer (10,10)`（`vnc/tap`） |
| `spec/scenarios/vnc.session.yaml` | 帧循环 + 指针到达远端 |

### 必须如实写下的失败
本轮本来是"VNC 上屏 + 交互"。**上屏没做成**：

- ArkTS 侧 `Canvas.putImageData(new ImageData(...))` 触发**原生崩溃**：
  `SIGSEGV` in `lib2d_graphics.z.so` → `OHOS::Rosen::Drawing::SkiaImage::Serialize()`
- 证据：`/data/log/faultlog/faultlogger/cppcrash-com.motty.harmony-*.log`（进程生命周期 7s）
- 最初误判为"首帧早于 Canvas 就绪"（加了就绪门仍崩），又试过把帧从 ArrayBuffer 改成 hex 字符串（仍崩），
  最终确认崩溃点在图形序列化，而非我们的协议/TSFN 代码

**处置**：关闭渲染（保留解码与统计），UI 明示该限制，spec 命名为 `vnc.session` 并只断言
"帧循环在跑 + 指针到了对端"。**不把"远程桌面渲染"算作完成。**

### 同时修正的一处夸大
上一轮把 VNC spec 挂到了 `D02`（跳板链）/`D03`（全局代理）——**挂错了**。
正确是 `E01`（RFB 版本）与 `E06`（指针）。且 `E02`（其它编码）、`E03`（VNC Auth）**仍是 E3**，
因为这两项根本没做。能力表已加 `partialCoverage` 字段逐条写明"部分覆盖"的具体范围。

### 双画像验收（18 条 × 2 画像）
`vnc.session`、`vnc.handshake`、`forward.local`、`vault.persist`、`sftp.write`、`sftp.browse`、
`session.tabs`、`terminal.pty`、`terminal.scrollback`、`terminal.vt`、`terminal.view`、
`terminal.interactive`、`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、
`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

### 未做
- **VNC 画面渲染**（被 Skia 崩溃阻塞；下一步要评估 Surface/XComponent 纹理路径）
- VNC Auth (DES)、Hextile/ZRLE/CopyRect、键盘事件的断言、剪贴板、缩放/滚动、RDP
---

## Round 25：VNC 上屏打通（换掉会崩的渲染通路）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | 帧回调重新开启（hex 字符串通道），解码后交给 UI 自行绘制 |
| `Index.ets` | **Canvas `fillRect` 逐像素网格**（64×48 = 3072 个矩形，缩放 5×）替代 `putImageData`；状态行加 `drawn=` |
| `spec/scenarios/vnc.session.yaml` | 加 `drawn=3072` 断言，标题改为"会话与上屏" |

### 为什么上一轮的 `putImageData` 必须放弃
`Canvas.putImageData(new ImageData(...))` 会让进程 SIGSEGV 在
`lib2d_graphics → Rosen::Drawing::SkiaImage::Serialize()`（cppcrash 已留证）。
同样的数据改用 `fillRect` 逐格绘制则**完全正常**——问题在 `ImageData` 的序列化路径，不在数据本身。

### 本轮的可视证据
运行截图（`spec/runs/vnc-session-2in1/final.png`）中可以看到：
- 画布左半红、右半蓝（与夹具图案一致）
- 指针处有 8×8 绿色方块（说明指针事件到达对端、对端重绘、新帧回到客户端并上屏）
- 状态行：`frame=91 64x48 red=1455 green=81 blue=1536`、`drawn=3072 (fillRect grid)`

我不只看"用例通过"，而是把截图取回来肉眼确认了图案与绿块位置。

### 双画像验收（18 条 × 2 画像）
`vnc.session`、`vnc.handshake`、`forward.local`、`vault.persist`、`sftp.write`、`sftp.browse`、
`session.tabs`、`terminal.pty`、`terminal.scrollback`、`terminal.vt`、`terminal.view`、
`terminal.interactive`、`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、
`net.reachability`、`ssh.exec`、`ssh.hostkey` —— 全部 **passed**。

### 性能与正确性的边界（别当成可用远程桌面）
- **每帧 3072 次 `fillRect`**：在模拟器上跑得动，但这不是渲染的正确终点，
  真实实现应走 Surface/XComponent + `OH_NativeWindow` 直接写缓冲
- 只支持 `Raw` 编码：真实 VNC 服务器的常见编码（Hextile/ZRLE/Tight）一个都没做
- 无 VNC Auth(DES)：只给 VNC Auth 的服务器连不上（会明确报错）
- 键盘事件未断言；剪贴板、缩放、滚动、断线重连未做
---

## Round 26：VNC Auth(DES) 与 Hextile 编码

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | VNC Auth：口令按位反序成 DES key，加密 16 字节挑战（**用 mbedTLS 的 DES，不自己搓**）；Hextile(5) 解码（Background/Foreground/AnySubrects/SubrectsColoured，含 Raw 瓦片）；状态行加 `auth=vncauth\|none` 与 `enc=hextile\|raw` |
| `tools/design/sshfixture/rfb_fixture.go` | `-vnc-auth <pw>` 只提供 VNC Auth（`crypto/des` 校验响应）；按客户端 SetEncodings 自动改用 Hextile 发送 |
| `spec/scenarios/vnc.auth-hextile.yaml` | 认证 + Hextile + 指针 → 绿块回归 |

### 修掉的两个真问题
1. **C++ 补丁静默未生效**：我改了"安全类型选择"，但锚点文本与文件实际内容不符，替换没发生，
   编译后仍跑旧逻辑（错误信息还是老的）。**教训：批量文本替换必须回读校验**，这次靠
   "状态行显示的是旧错误文案"才暴露。
2. **Go 变量遮蔽**：夹具里 `useHextile := false` 在 switch 分支内遮蔽了外层变量，
   导致"客户端请求了 Hextile"的结论从未生效，服务器一直发 Raw。

### 夹具两种模式（证据分别记录，不混在一起）
| 模式 | 启动参数 | 用于 |
|---|---|---|
| None | 无 | 18 条标准 spec |
| VNC Auth | `-vnc-auth secret` | `vnc.auth-hextile` |

### 双画像验收（19 条 × 2 画像 = 38 次）
标准矩阵 18 条（None 模式）全绿；`vnc.auth-hextile` 单独在 auth 模式下双画像通过。
对端日志实证：`client chose security type 2` → `vnc auth ok`；`SetEncodings count=2 hextile=true`。

### 仍未做
- 编码：CopyRect / RRE / ZRLE / Tight 一个都没有
- RFB 3.3 / 3.7（只实现 3.8）
- 错误口令的负向用例（需夹具以另一口令启动）
- 键盘事件断言、剪贴板、缩放滚动、VeNCrypt/TLS、真实 VNC 服务器、RDP
---

## Round 27：换用成熟开源组件（libvterm 接入 + LibVNC 就位 + GPLv3 决定）

### 一、许可证决定（用户确认）
仓库原 Apache-2.0，LibVNC 是 **GPL-2.0-or-later**（官方 FAQ：链接即衍生作品）。
Apache-2.0 与 **GPLv3** 兼容、与 GPLv2 不兼容 → 所以按 **GPL-3.0-or-later 组合分发**。
记录在 [LICENSING.md](./LICENSING.md)，含义务清单与第三方台账。**这是单向门**，已明确写清。

### 二、终端换成 libvterm（MIT）
手写"最小 VT"换掉，改用 libvterm（Neovim 在用）：
- 源码 9 个 .c，仅 stdlib 依赖；`.inc` 表随仓库提供（**不需要 Perl**——本机没有）
- 交叉编译为静态库：x86_64 105.6 KB / arm64 81.2 KB
- NAPI 接口（vtNew/vtFeed/vtScreen/vtStatus/vtScrollBack）保持不变，spec 不用改

接入时踩到两个 libvterm 语义坑：
1. **`settermprop` 回调返回 1 = "已处理"** → libvterm 会跳过自己的备用屏切换，
   导致主屏被 `\x1b[2J` 清空。必须返回 0。
2. **备用屏要在 screen 层显式启用**：`vterm_screen_enable_altscreen(vts, 1)`，
   否则 1049 只发通知、不真的切缓冲。

### 三、LibVNC client 就位（尚未替换运行时）
- 交叉编译成功：libvncclient.a 148.5 KB(x86_64) / 144.7 KB(arm64)
- 已加 `native/build-libvnc.ps1`（GPL 要求可复现构建）
- CMakeLists 已链接 `libvncclient.a`；**运行时仍走自研 RFB**，下一轮再替换并验证

### 四、双画像验收（20 条 × 2 画像 = 40 次）
None 模式 18 条 + VNC Auth 模式 2 条（`vnc.auth-hextile`、`vnc.negative`），
2in1 与 tablet 全部 **passed**。

### 五、操作提醒（本轮踩到）
切换模拟器后 **`hdc rport` 需要重建**：这轮忘记给平板补 `tcp:5901`，
导致两条 VNC 用例失败——不是产品缺陷，补上 rport 后即通过。
---

## Round 28：LibVNC 运行时替换 —— **尝试失败，已回退**

### 做了什么
按"用成熟组件"的方向，把自研 RFB 换成 LibVNC client（后端子线程 + 帧/输入/状态）。
新增 `vnc_libvnc.cpp` / `vnc_backend.h`，并把 `vncProbe` 与 `vnc.handshake` 一起删掉（被会话取代）。

### 结果：失败，且已回退
三类失败依次出现，每一类都能定位：
1. **收不到帧**：我把 `MallocFrameBuffer` 覆盖成返回 TRUE 的空实现，
   把 LibVNC 默认的帧缓冲分配顶掉了 → 客户端只发 FBUpdateRequest，永远拿不到更新。
2. **UI 线程冻结（appfreeze）**：`rfbInitClient` 是同步网络 I/O，直接在 JS 线程调用会卡死；
   设备上留下 `appfreeze-com.motty.harmony-*.log`。
3. **改后台线程后仍空白**：界面没有内容（dump 全是空节点），未能在本轮内定位。

**处置**：回退到已验证的自研 RFB（`git checkout` 恢复 `ssh_napi.cpp`/`Index.ets`/`vnc.handshake.yaml`），
删除 `vnc_libvnc.cpp`/`vnc_backend.h`，CMakeLists **不再链接** `libvncclient.a`，
避免"库在包里但没人用"的假象。

### 保留的成果（这些是真实有效的）
- `native/build-libvnc.ps1` + 两个 ABI 的 `libvncclient.a`（148.5/144.7 KB）——**构建可用**
- 许可证路线与台账（`LICENSING.md`）
- 回退后的状态**重新验证通过**：`vnc.session`、`vnc.auth-hextile`、`vnc.negative`、`vnc.handshake`
  在 2in1 上分别用 None/auth 模式跑通

### 这轮的教训（写进 RUNBOOK）
- **不要覆盖你不理解的 LibVNC 回调**：`MallocFrameBuffer` 覆盖即等于接管缓冲分配。
- **第三方同步 API 一律不能放在 JS 线程**：本工程从第 12 轮就立了这条规矩，这次仍然踩了。
- **替换核心组件的回合要单独留时间**：本轮把"接入 + 全量回归 + 文档"压在一轮里，
  失败后只能回退而不可能既回退又完成验证。

### 下一步
LibVNC 接入需要**单独一轮**，并且先用设备日志确认帧缓冲与回调时序；在那之前，
VNC 能力继续由自研 RFB 提供（Raw + Hextile + None/VNC Auth + 上屏 + 指针 + 键盘）。
---

## Round 29：SOCKS5 动态转发（补完 D01 的一部分）

### 为什么不是 RDP
FreeRDP 是 Apache-2.0、无许可障碍，但它依赖 OpenSSL；**本机没有 Perl**，而 OpenSSL 的构建脚本是 Perl，
NDK sysroot 里也没有 libcrypto。因此 FreeRDP 不是"一轮能落地"的东西，我把它降级为待办，
本轮改为交付**确定能验证**的部分。

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | 转发支持 `mode = local \| socks5 \| http`；SOCKS5 无认证握手 + CONNECT(IPv4/域名) 解析；HTTP CONNECT 解析；目标从客户端请求里取得后走 `direct-tcpip` |
| `Index.ets` | 转发面板增加模式选择（`fwd/mode-local` / `fwd/mode-socks5` / `fwd/mode-http`、`fwd/mode` 显示），`Test tunnel` 按模式做对应握手 |
| `spec/scenarios/forward.socks5.yaml` | 起 SOCKS5 → 本机 socket 走 CONNECT → 隧道内读到远端 SSH banner |

### 关键断言
`SSH-2.0-`：**只有远端 SSH 服务会产生这个 banner**。`05 00` / `05 00 00 01` 只能说明握手成功，
banner 才能证明"隧道真的在转发数据"。对端日志同时出现 `direct-tcpip open -> 127.0.0.1:2223`。
事件流里的 `proxy target 127.0.0.1:2223` 则证明目标地址确实来自客户端请求，而不是配置里写死的。

### 清理
`vnc.handshake` 已删除：它依赖的 probe 入口已并入会话，断言口径（`fb=...`）不再存在；
其覆盖（握手 + ServerInit + Raw 取色）已被 `vnc.session`（帧/颜色/指针）完整包含。
UI 里的 `VNC probe` 按钮一并移除，避免"叫 probe 实际开会话"的误导。

### 双画像验收（20 条 × 2 画像 = 40 次）
None 模式 18 条 + auth 模式 2 条（`vnc.auth-hextile`、`vnc.negative`），2in1 与 tablet 全部 **passed**。

> 一次瞬时失败记录：`sftp.browse` 在 2in1 上出现"聚焦后选择器消失"（对话框尚未渲染完就聚焦），
> 重跑即通过；属测试时序而非产品缺陷。

### 仍未做
远程转发、SOCKS5 用户名口令认证、UDP ASSOCIATE、HTTP CONNECT 的断言用例、并发连接、RDP。
---

## Round 30：HTTP CONNECT 用例补齐 + RDP 可行性定论（不做无效尝试）

### 一、RDP：这条路暂时走不通，原因已定位到源码层
想用 FreeRDP（Apache-2.0）替掉上游 38k 行自研 RDP。按官方文档试了 **mbedTLS 后端**（我们已有 mbedTLS）：

| 步骤 | 结果 |
|---|---|
| 3.9.0 配 `-DWITH_OPENSSL=OFF -DWITH_MBEDTLS=ON` | 失败：`Could NOT find OpenSSL` |
| 读 CMakeLists | `OPENSSL_FEATURE_TYPE "REQUIRED"`，mbedTLS 只是 OPTIONAL —— **3.9.0 不支持无 OpenSSL**；master 同样 |
| 打补丁（OpenSSL→OPTIONAL）后配置 | **成功**（找到 mbedTLS 三个静态库） |
| 编译 | **失败**：①`libfreerdp/crypto/tls.h` 等**无条件 include `<openssl/*>`**；②`winpr/libwinpr/crypto/cipher.c` 的 mbedTLS 分支自身有编译错误（`undeclared identifier 'i'`） |

结论：mbedTLS 后端是社区实验分支，靠 CMake 开关无法生效，改它等于维护一个 FreeRDP fork。
**可行路径只有先编 OpenSSL**，而本机缺 Perl/​make（便携版 Strawberry Perl 可同时提供两者）。
详见 [RDP-FEASIBILITY.md](./RDP-FEASIBILITY.md)。

附带解决：FreeRDP 配置还卡 `Could NOT find ZLIB`，需显式给 `-DZLIB_LIBRARY=<sysroot>/libz.so`。

### 二、本轮真正交付的：HTTP CONNECT 用例补齐
第 29 轮实现了 `mode=http` 却没断言（只有 SOCKS5 有用例）。本轮补 `forward.http`：
- `200 Connection Established`（握手成功）
- 隧道内 `SSH-2.0-`（**数据真的通了**）
- `proxy target 127.0.0.1:2223`（目标来自客户端请求）

两条断言缺一不可：只有 200 无法证明转发，只有 banner 无法证明 HTTP 语义。

### 三、双画像
`forward.http` 在 2in1 与 tablet 均 **passed**（其余 20 条沿用本轮前一次全量结果，未改代码路径）。

### 四、下一步（顺序已明确）
1. **OpenSSL 里程碑**（便携 Perl + gmake + 双 ABI 静态库）——独立一轮，先验证 `libcrypto.a` 产物
2. 再开 **FreeRDP 最小配置**（`-DWITH_OPENSSL=ON`，关 SDL/X11/声音/打印）
3. 最后才是 RDP 客户端接入（帧/输入/通道）
---

## Round 31：OpenSSL 交叉编译完成（RDP 的前置里程碑）

### 产物（E2：编译/链接证据，非运行验证）
| 架构 | libcrypto.a | libssl.a | 架构核验 |
|---|---|---|---|
| x86_64 | 7.13 MB | 1.16 MB | `EM_X86_64` ✅ |
| arm64 | 7.41 MB | 1.11 MB | `EM_AARCH64` ✅ |

**链接验证**：用一个只调用 `OpenSSL_version_num()` 的探针源，分别对两个架构链接成 `.so`
（x86_64 3671 KB / arm64 成功），说明头文件与静态库可用。探针产物已删除，不入库。

### 这一路必须解决的六个坑（全部固化进 `native/build-openssl.ps1`）
1. **本机没有 Perl** → 便携版 Strawberry Perl（解压即用，同时提供 `perl` 与 `gmake`）
2. **`Configurations/unix-checker.pm` 直接 die**：Windows Perl 产出反斜杠路径 →
   打补丁跳过该检查（这是构建脚本的一步，不是改上游行为）
3. **汇编生成(perlasm)在 Windows 下跑不通** → `no-asm`（功能不受影响，仅性能）
4. **`rm -f` 在 sh 下把反斜杠路径吃掉**（`crypto\aes\aes_cbc.c` 变成 `cryptoaesaes_cbc.c`）→
   强制 `SHELL=cmd.exe`，并提供 `rm.bat` 兜底
5. **直接编 `libcrypto.a` 会缺生成的头文件**（`opensslv.h`）→ 先 `build_generated`
6. **`install_sw` 在 sh 下失败** → 手工拷贝 `libcrypto.a`/`libssl.a` 与 `include/openssl`

### 这是 RDP 的前置，不是 RDP
能力表里 RDP 仍是 **E3**。下一步才是 FreeRDP 配置（`-DWITH_OPENSSL=ON -DOPENSSL_ROOT_DIR=<prefix>`），
再之后才是客户端接入。顺序写死在 [RDP-FEASIBILITY.md](./RDP-FEASIBILITY.md)，避免又"一轮内既编译又接入"。

### 许可
OpenSSL 是 **Apache-2.0**，与 FreeRDP 一致，不引入新的 GPL 义务（整包已是 GPLv3 组合分发）。
---

## Round 32：FreeRDP 静态库产出并链接验证（仍不是 RDP）

| 里程碑 | 状态 | 证据 |
|---|---|---|
| FreeRDP 配置（OpenSSL 后端） | **完成** | 关 SDL/X11/声音/打印/JSON/KRB5/PCSC，`configure exit=0` |
| FreeRDP 静态库（x86_64） | **完成** | `libfreerdp3.a` 5.36 MB、`libfreerdp-client3.a` 1.45 MB、`libwinpr3.a` 2.60 MB |
| 链接验证（x86_64） | **完成** | 探针 + `pthread_cancel` 桩链接成 **8.2 MB `.so`**，`EM_X86_64` |

### 新踩的三个坑（固化进 `native/build-freerdp.ps1`）
1. **`WITH_ABSOLUTE_PLUGIN_LOAD_PATHS=OFF` 必须关**：否则 `FREERDP_INSTALL_PREFIX` 里的
   `E:\…\ohos\…` 反斜杠成为非法转义 `\o` → `expected '{' after '\o' escape sequence`
2. **只构建库目标**：示例 `sfreerdp` 链接缺 `pthread_cancel`（musl 未实现）→ 全量构建必失败
3. **winpr 头文件分三处**：源码 `include/`、`winpr/include/`、**构建目录生成的**
   `wtypes.h / build-config.h / buildflags.h`——少一份就找不到头

### 诚实边界
- **RDP 仍是 E3**：这只是"库能编、能链"，客户端接入（连接/能力协商/位图/输入/通道）一样没做
- arm64 的 FreeRDP 库尚未跑完（脚本已支持）
- 应用侧最终必须提供 `pthread_cancel` 桩，这是 musl 的缺口，不是 FreeRDP 的 bug

### 为什么这轮算"真进展"
它把 RDP 从"完全不知道能不能做"推进到"依赖链已就位、只剩接入"。这类前置如果跳到接入阶段再补，
就会像第 28 轮那样在最后一步回退。
---

## Round 33：RDP 客户端接入（仅连接路径）+ arm64 FreeRDP

### 交付
| 项 | 说明 |
|---|---|
| `cpp/rdp_napi.cpp` | `rdpProbe(host,port,user,password,cb)`：**工作线程**里创建 FreeRDP 上下文、填设置、尝试连接、把失败原因如实回传；含 `pthread_cancel` 桩（musl 缺口） |
| `Index.ets` | 诊断面板加 `RDP :3389`（无监听）与 `RDP :2222`（SSH）两个探测按钮 + `rdp/result` |
| `spec/scenarios/rdp.connect.yaml` | 两个非法对端都必须 `connect failed`，且不得出现 `connected 127.0.0.1` |
| arm64 FreeRDP | 静态库补齐（libfreerdp3 4.77 MB 等），双 ABI 均可链 |

### 本轮修掉的四个问题（都是"能编但跑不对"的类型）
1. **默认开 ThinLTO**：FreeRDP Release 默认 `CMAKE_INTERPROCEDURAL_OPTIMIZATION=ON`，生成的 `.a` 是 bitcode，
   与应用 lld 链接时报 `loop not vectorized: the optimizer was unable...` **直接失败** → 必须显式关掉
2. **`freerdp_client_context_new(nullptr)` 返回空**：那是"客户端入口点"版本，本工程只链 libfreerdp；
   改用 `freerdp_new()` + `freerdp_context_new()` 才拿到上下文
3. **`freerdp_get_last_error` 收的是 `rdpContext*`**，不是 `freerdp*`（3.x API）
4. **`rdp/result` 被插进了 VNC 面板**：锚点撞车（第 29 轮同类错误），已移到诊断面板

### 诚实边界（必须一起读）
- **RDP 仍是 E3**：这条只验证"能起、能失败、能报错、不崩溃"
- **没有**与真实 RDP 服务器成功连接、TLS/证书 pin、NLA/CredSSP、能力协商、位图、输入、通道
- 两个对端都是非 RDP 服务（3389 无监听、2222 是 SSH）——所以断言的是**失败语义**，不是功能

### 双画像
`rdp.connect` 在 2in1 与 tablet 均 **passed**。
---

## Round 34：known_hosts 管理（查看/删除信任）+ RDP 环境结论

### 一、RDP 被环境卡住（如实记录，不是代码问题）
宿主检查结果：
- `TermService` **Stopped**（StartType=Manual）
- `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections = 1`（远程桌面被禁用）
- 3389 **未监听**

启用需要管理员授权与系统设置变更，且真实 RDP 还要凭据 —— 本轮不做未经授权的系统改动。
所以 RDP 的真实链路验证**被环境阻塞**，我没有把它写成"已实现"。

### 二、本轮交付：known_hosts 管理
| 产物 | 说明 |
|---|---|
| `Index.ets` | 顶栏 `Known`（`known/open`）→ 面板列出条目（`known/count`、`known/del/<host>`、`known/empty`、`known/close`） |
| 数据 | 删除走 `relationalStore.delete`，删除后立即刷新列表 |
| `spec/scenarios/knownhosts.manage.yaml` | 信任 → 列出 1 条 → 删除 → 计数 0 → **再连必须重新弹信任框** |

### 为什么最后一步才是关键
只断言"列表变空"只证明 UI 删了，**不证明信任状态真的失效**。
再连一次必须重新出现 `Unknown host key` 且对话框里显示 `SHA256:` 指纹，才说明 known_hosts 真的被删。

### 双画像
`knownhosts.manage` 在 2in1 与 tablet 均 **passed**。

### 小坑
YAML 里 `- 断言用 "trusted entries: N" 计数…` 这种带冒号的未加引号条目会被解析成 map，
lint 直接报 `is not of type 'string'`——已改成不带冒号的写法。
---

## Round 35：主机密钥变更告警（B02 的另一半）

### 交付
| 产物 | 说明 |
|---|---|
| `Index.ets` | 检测 `hostkey-mismatch` → 弹**变更告警**（`hostkey/changed`），同时显示 `hostkey/old` 与 `hostkey/new`；`hostkey/cancel-changed`（默认拒绝）、`hostkey/update`（显式接受后更新 known_hosts 并重试） |
| `spec/run.py` | 新增 `shell` 动作：在**宿主**上跑命令（用于中途轮换夹具 host key），输出写临时文件而非管道 |
| `spec/scenarios/hostkey.changed.yaml` | 信任钥匙 A → 换钥匙 B → 再连必须告警且默认拒绝 |

### 为什么必须与"未知主机"分开
`Unknown host key` 是首次连接；`HOST KEY HAS CHANGED` 是**同一主机换了钥匙**——这是 MITM 的典型信号。
两者混在一起会让用户习惯性点"信任"。

### 本轮修掉的三个问题
1. **runner 挂死 10 分钟**：`shell` 动作用管道捕获输出，而命令里的 `Start-Process -RedirectXxx`
   让子进程继承句柄、管道永远等不到 EOF → 改为写临时文件
2. **新旧指纹显示成同一个**：正则取的是结果串里**第一个** `SHA256:`（那是 `expected=`），
   必须显式匹配 `actual=(SHA256:…)`
3. **拒绝文案看不见**：原先只写进 `probeText`（只在诊断面板里渲染），改为同时写主机行状态

### 双画像
`hostkey.changed` 在 2in1 与 tablet 均 **passed**。

### 能力表
`B02` 的 partialCoverage 更新为：信任确认 + 持久化/删除 + **变更告警与默认拒绝**已测；
接受新钥后重连、`@cert-authority`、导入导出仍未做。

### 未做
接受新钥匙后的自动重连路径（需另一条用例）、算法降级告警、告警跨会话复现。
---

## Round 36：转发规则持久化（落库 + 重启恢复）

| 产物 | 说明 |
|---|---|
| `Index.ets` | 新表 `forwards`（id/host_key/mode/listen_port/target_host/target_port）；面板加 `fwd/save`（保存当前表单）、`fwd/rule-count`、规则列表（`fwd/rule/<id>` 一键启动、`fwd/rule-del/<id>` 删除、`fwd/rule-empty`） |
| 启动 | `initStore` 建表；启动时与打开面板时都 `reloadRules()` |
| `spec/scenarios/forward.persist.yaml` | 保存 1 条 → **进程级重启** → 规则仍在 → 计数 1 |

### 修掉的一个解析错误
规则展示串是 `id|mode|listen->host:port`，但"一键启动"最初把 `parts[1]` 当成 `listen->…`（实际是 mode），
会导致启动参数错位。已改为按 `parts[2]` 解析并在两端做边界判断。

### 双画像
`forward.persist` 在 2in1 与 tablet 均 **passed**。

### 未做
一键启动后的隧道连通性（由 `forward.socks5` / `forward.local` 覆盖，这里不重复断言）、规则编辑、
多主机规则、开机自启、规则与 known_hosts 的一致性校验。
---

## Round 37：主机编辑与删除

| 产物 | 说明 |
|---|---|
| `Index.ets` | 行内 `Edit`（`host-edit/<i>`，表单预填、提交走 `update`，id 不变）与 `Del`（`host-del/<i>`，二次确认 `hostdel/dialog`）；删除时**同时清 known_hosts 与保险库口令** |
| `spec/scenarios/host.manage.yaml` | 新建 → 改名 → 信任一次 → 删除先取消（不删）→ 再确认删除 → 列表空 |

### 本轮最关键的一个 ArkUI 坑
编辑后数据库确实更新了（hilog 可见 `host updated … rows=1`），但**界面仍显示旧标题**：
`ForEach(this.hosts, …)` 的 key 只用了 `h.id`，id 未变 → ArkUI 复用旧渲染结果，文本不刷新。
把 key 改为 `id|label|address|port`（纳入可变字段）后立即正常。
这类"数据对了但界面不动"的问题，只靠逻辑日志会被骗过去。

### 双画像
`host.manage` 在 2in1 与 tablet 均 **passed**。

### 未做
删除后"重建同主机是否重新要求信任"的第二条用例、编辑时改端口/地址的迁移、批量删除、撤销、导入导出。
---

## Round 38：主机搜索 + 删除后重建必须重新信任

| 产物 | 说明 |
|---|---|
| `Index.ets` | 列表加搜索框 `hosts/search`（按标签/地址过滤）与空态 `hosts/no-match`；**渲染仍遍历全量、内层 `if` 过滤**，保证 `host-row/<i>` 下标仍对应未过滤数组 |
| `spec/scenarios/hosts.search.yaml` | 两台主机 → 搜 `alpha` 只留一台 → 搜无匹配串出空态 |
| `spec/scenarios/host.recreate-trust.yaml` | 信任 → 删除主机 → 重建同地址 → **必须重新弹信任框** |

### 两个实现细节（都是踩过才改的）
1. **不能用"重建过滤数组 + ForEach"**：ArkUI 的 ForEach 体内**不允许写 `const` 语句**
   （报 `Only UI component syntax can be written here`），而且重建数组会让 `host-row/<i>`
   的下标随搜索漂移。最终采用"遍历全量 + 内层 if 隐藏"。
2. **元组类型在 ArkTS 里推断不稳**：`Array<[HostItem, number]>` 在 ForEach 里报类型不匹配，
   改用接口对象（最终连接口也不需要了，因为方案换成了内层 if）。

### 为什么"重建后仍要信任"这条重要
上一轮只证明"库里的行删了"，这条证明**删除对后续连接真的生效**：
若 known_hosts 没清，第二次点 Test 会直接 `verified` 而不弹框，断言必然失败。

### 双画像
`hosts.search` 与 `host.recreate-trust` 在 2in1 与 tablet 均 **passed**。

### 未做
按端口/协议过滤、排序、搜索历史；删除后"重建时不填口令"的凭据清理用例；多主机同地址不同端口。
---

## Round 39：凭据清理的负向验证（删除主机必须清掉保险库口令）

| 产物 | 说明 |
|---|---|
| `Index.ets` | 新增主机时**口令为空则不写保险库、也不塞内存**——否则"空口令"会被当成有效凭据，掩盖"保险库是否有残留"这一关键差异 |
| `spec/scenarios/cred.cleared.yaml` | 建主机(带口令) → 删主机 → 重启 → 重建同地址(**不填口令**) → 再重启 → 点 Test 必须提示 `no credentials in memory` |

### 为什么需要两次 restart
- 只"删主机"看不出保险库有没有清；
- 只重启一次会被内存缓存干扰；
- **两次重启 + 空口令重建**才能让"保险库是否残留"变成可判定差异：
  残留 → 预热到旧口令 → 会尝试认证（出现 `verified`）；清理干净 → 直接提示没有凭据。

### 双画像
`cred.cleared` 在 2in1 与 tablet 均 **passed**。

### 未做
直接查询 Asset 确认条目不存在（当前用行为推断）、口令轮换、多用户隔离、Asset 不可用时的降级路径。
---

## Round 40：回滚区交互（向上看历史、向下回实时）

| 产物 | 说明 |
|---|---|
| `cpp/vt_core.cpp` | 新增 `vtView(id, scroll)`：把**历史 + 当前屏**拼起来再按 `scroll`（回退行数）截取一屏。单纯返回历史尾部是不够的——用户往上滚看到的是"历史尾部 + 当前屏" |
| `Index.ets` | 会话面板加 `▲`（`terminal/scroll-up`，+5 行）与 `▼`（`terminal/scroll-down`，-5 行）；状态显示 `scroll=N`；**有新数据到达时若停留在回滚区则保持偏移**，不被拉回实时 |
| `spec/scenarios/terminal.scrollview.yaml` | vt-demo2 造 30 行 → 上滚断言 `scroll=5` 且历史行可见 → 下滚回实时 |

### 关键设计点
- 滚动不是"改个数字"：必须重算视图文本（`vtView`），否则界面上什么都不会变
- 停在回滚区时新数据不能把视图拽回底部——这是"看历史"与"看直播"的区别
- 断言同时看两件事：`scroll=N`（状态）与 `scroll-2x` 可见（内容），只断言其一都不够

### 双画像
`terminal.scrollview` 在 2in1 与 tablet 均 **passed**。

### 未做
滚动条拖拽、滚到顶/底边界提示、回滚区搜索、选区复制、鼠标滚轮与触控惯性。
---

## Round 41：终端选区复制（写入系统剪贴板）

| 产物 | 说明 |
|---|---|
| `Index.ets` | 会话面板加 `Sel all`（`terminal/selall`，选中当前视图含回滚偏移）与 `Copy`（`terminal/copy`，写系统剪贴板）；显示 `terminal/sel` / `terminal/clip` |
| `spec/scenarios/terminal.copy.yaml` | 造 30 行 → 全选 → 断言 `selected: N chars` → 复制 → 断言 `copied N chars` 与 `clipboard:` |

### 本轮踩的两个坑
1. **`getPrimaryText()` 返回 undefined 后取 `.length` → TypeError 直接把进程杀掉**（jscrash 记录可见）。
   现在所有返回值都做空值防护，并对 `onClick` 的 async 调用加 `.catch`。
2. **写入成功但回读为空**：模拟器上 `setData` 之后 `getData` 可能短暂返回空。
   处理方式：重试 5 次；仍读不到就显示 `(readback unavailable)`，**明确区别于"写失败"**。
   断言因此改为"`copied N chars`（N>0）+ 不存在 `copy failed`"，而不是硬要求回读长度一致。

### 双画像
`terminal.copy` 在 2in1 与 tablet 均 **passed**。

### 未做
鼠标/触控**拖拽局部选区**（当前是"全选当前视图"）、跨屏选区、富文本多格式、剪贴板历史、
粘贴到其他应用的实际验证。
---

## Round 42：终端按键直发（Ctrl-C）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | 新增 `sendRaw(id, text)`：**原样**写入通道，不追加换行（`sendInput` 会给每行补换行，控制字符走那条路会变成"^C + 回车"两件事） |
| `Index.ets` | 会话面板加 `^C`（`terminal/ctrl-c`）→ `sendRaw(id, "\u0003")` |
| `spec/scenarios/terminal.key.yaml` | 真实 pty 会话里发 Ctrl-C，断言 UI 状态 `sent ^C` 与终端回显 `^C` |

### 为什么"原样"是关键
`sendInput` 的语义是"提交一行"（自动补换行）。把它用于控制字符会造成语义错位：
`^C\n` 与 `^C` 在 shell 里是两件事（前者可能被当成"中断 + 空命令提交"）。
因此专门加了 `sendRaw`，并在 spec 里同时断言 UI 与终端内容。

### 双画像
`terminal.key` 在 2in1 与 tablet 均 **passed**。

### 未做
方向键/功能键的转义序列映射、修饰键组合、Alt/Shift 语义、真实 Linux shell 的作业控制、
鼠标上报、滚轮/触控滚动（原先计划在此轮，但触控需要先给 runner 加 `swipe` 动作，留到下轮）。
---

## Round 43：触控拖动滚动回滚区（含 runner 新增 swipe）

| 产物 | 说明 |
|---|---|
| `spec/run.py` | 新增 `swipe` 动作（`uitest uiInput swipe`，支持 `dx/dy/durationMs/settleMs`）；此前它是 `NotImplementedError` 占位 |
| `Index.ets` | 终端输出区 `onTouch`：手指上滑回看历史、下滑回实时；每 18vp 走一行（避免过于灵敏） |
| `spec/scenarios/terminal.touchscroll.yaml` | 上滑断言 `scroll>0`，下滑断言回到 `scroll=0` |

### 顺序上的一个原则
这条功能必须**先有 swipe 原语**才能验证。若先写功能再补测试手段，就只能产出 E3（未验证）——
这也是我把它排在本轮而不是上一轮的原因。

### 断言为什么这样设计
只断言"scroll 变大"不够：一个只会增不会减的实现也能过。
必须再断言下滑后回到 `scroll=0`，才证明"方向"是对的。

### 双画像
`terminal.touchscroll` 在 2in1 与 tablet 均 **passed**。

### 未做
鼠标滚轮（未接 `AxisEvent`）、惯性滑动、拖到边界回弹、双指手势、方向键转义映射。
---

## Round 44：方向键（VT 序列编码）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | `sendKey(id, name)`：`up/down/left/right/home/end/tab/esc/backspace` → CSI `A/B/C/D`、`H/F`、`\t`、`\x1b`、`\x7f` |
| `Index.ets` | 会话面板加 `↑ ↓ ← →`（`terminal/up|down|left|right`），状态显示 `sent <name>` |
| `tools/design/sshfixture` | `term-echo` 收到**以 ESC 开头**的数据时改为以十六进制回显（`recv 1b5b41`），让"字节是否原样到达"可判定 |
| `spec/scenarios/terminal.arrow.yaml` | 按 ↑ 断言 `recv 1b5b41`，按 → 断言 `recv 1b5b43` |

### 为什么不用真实 shell 断言"↑ 调出上一条命令"
那依赖 shell 行编辑器实现，在 cmd.exe 上还依赖 VT 输入模式，容易变成环境相关的不稳定用例。
这里断言的是**"我们发出的字节序列正确且到达对端"**——这一层是确定的、可判定的。

### 限定范围（写在代码注释里）
只实现**普通光标模式**（CSI 序列）；应用光标模式（DECCKM 的 `SS3 Ox`）未实现，
因为需要从 libvterm 读到当前 DECCKM 状态。没有假装支持。

### 双画像
`terminal.arrow` 在 2in1 与 tablet 均 **passed**。

### 小坑
状态行只保留最后一次按键，`sent up` 在按 → 之后被覆盖 → 断言改为 `sent right`。
---

## Round 45：SFTP 重命名与新建目录

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | `sftpRename(...,from,to,cb)`（`libssh2_sftp_rename_ex`）、`sftpMkdir(...,path,cb)`（`libssh2_sftp_mkdir`，0755） |
| `Index.ets` | 文件面板加 `Rename`（`sftp/rename`，目标固定 `renamed.txt`）与 `Mkdir`（`sftp/mkdir`，目录固定 `newdir`），成功后刷新列表 |
| `spec/scenarios/sftp.manage.yaml` | 选中 `hello.txt` → 重命名 → 断言 `rename: renamed` 且列表出现 `renamed.txt` → 新建目录 → 断言 `mkdir: created dir` 且列表出现 `newdir` |

### 本轮的过程教训（值得记）
前两次补丁都"打印成功但没落地"：锚点字符串与实际代码不一致（`private deleteSftp()` 实际叫 `deleteFile(cred, fp)`，
按钮块的收尾缩进也不同）。**replace 之后必须逐项断言目标字符串真的存在**，否则会写出一堆
"日志说改了、代码没变"的假象——这次是靠 `changed: True / sftp/rename -> False` 的对照才发现的。

### 双画像
`sftp.manage` 在 2in1 与 tablet 均 **passed**。

### 未做
递归目录操作、覆盖已存在目标、权限位与符号链接、批量重命名、目录层级进入/返回、书签。
---

## Round 46：SFTP 目录层级导航

| 产物 | 说明 |
|---|---|
| `Index.ets` | 新增 `Up`（`sftp/up`）与 `goUp/enterEntry/joinPath`；目录条目（带尾斜杠）点击进入子目录，文件条目点击仅为选中 |
| `spec/scenarios/sftp.navigate.yaml` | 建目录 → 点击 `newdir/` 进入（断言 `listed newdir`）→ `Up` 返回（断言 `listed .` 且能看到 `hello.txt`） |

### 本轮抓到的一个隐蔽 bug
插入 Up 按钮前，检查脚本用 `"sftp/up" in line` 判断"是否已存在"——
结果被 **`sftp/upload-name` / `sftp/upload`** 前缀误匹配，导致"已存在"永远为真、按钮从未插入，
而构建与安装都成功（因为代码没变）。改成精确匹配 `id('sftp/up')` 后才真正插入。
这与第 45 轮同源：**"看起来改了"必须用精确断言验证**。

### 另一个平台差异
平板屏幕更矮：`listed newdir (0 entries)` 这类长状态行在平板可能不在可视区，
断言改为稳定前缀 `listed newdir` + 父目录 `hello.txt`（严格断言，未放宽）。

### 双画像
`sftp.navigate` 在 2in1 与 tablet 均 **passed**。

### 未做
多级深路径、路径手输跳转校验、面包屑、书签、符号链接目录。
---

## Round 47：VNC 剪贴板（ServerCutText / ClientCutText）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | 帧循环从"读 4 字节且类型必须是 0"改为**按消息类型分发**；新增 `ServerCutText(3)` 处理、`vncCutText(id,text)`（ClientCutText 6）、`vncClipboard(id)`；`VncSession.clipboard` |
| `Index.ets` | VNC 面板加 `Read clip`（`vnc/clip-read`）与 `Send clip`（`vnc/clip-send`，内容 `app-clip`），显示 `vnc/clip` |
| 夹具 | 握手后主动发 `ServerCutText("fixture-clip")`；收到 `ClientCutText` 回 `ServerCutText("got:<text>")` |
| `spec/scenarios/vnc.clipboard.yaml` | 连上后断言 `clip: fixture-clip`；发送后断言 `clip: got:app-clip` |

### 这不是"加个按钮"，是修一个结构性问题
旧帧循环断言"服务端第一条消息必须是 FramebufferUpdate(0)"，
只要服务端发一条 `ServerCutText` 就会被判成 `unexpected message 3` 并**断开连接**。
改成按类型分发后，非更新类消息不再中断会话。剪贴板只是第一个受益的消息类型（Bell、DesktopSize 同理）。

### 两个小坑
1. `OH_LOG_Print` 需要额外链接 libhilog，直接编译期链接失败 → 诊断日志改用 `fprintf(stderr)`（OHOS 上会进 hilog）
2. 夹具注释里的中文在 PowerShell 写入时被破坏、吞掉了换行，导致 `func sendServerCutText` 粘到注释行上（语法错误）→ 按行重建该段

### 双画像
`vnc.clipboard` 在 2in1 与 tablet 均 **passed**。

### 未做
Latin-1 以外的编码转换细节、超长文本分片、自动双向同步（当前手动读/发）、DesktopSize 与 resize、其他编码。
---

## Round 48：DesktopSize 伪编码（服务端改分辨率）

| 产物 | 说明 |
|---|---|
| `cpp/ssh_napi.cpp` | `w/h` 由 `const` 改为可变；`SetEncodings` 增加 **DesktopSize(-223)**；收到该伪矩形时更新会话尺寸、**重分配像素缓冲**、丢弃本帧剩余矩形并重新请求 |
| 夹具 | 第 3 次 `FramebufferUpdateRequest` 后先发 DesktopSize 矩形，再把绘制尺寸切到 80x60（`rfbWidth/rfbHeight` 改为可变） |
| `spec/scenarios/vnc.desktopsize.yaml` | 断言最终 `80x60` **且 `drawn=4800`**（80×60 像素数） |

### 为什么断言"像素数"而不只断言尺寸文字
只断言 `80x60` 可能只是状态文字更新了，缓冲仍是旧尺寸——那样解码会越界或错位。
`drawn=4800` 是 80×60 的像素总数，说明**缓冲与解码都按新尺寸走**。

### 两个实现坑
1. `w/h` 原来是 `const`，帧循环里写死——不改就永远按初始尺寸解析
2. 夹具的 `rfbWidth/rfbHeight` 原来是 `const`（`AppendUint16` 直接吃常量），改成变量后需要显式 `uint16(...)` 转换

### 双画像
`vnc.desktopsize` 在 2in1 与 tablet 均 **passed**。

### 未做
UI 对非 320×240 的缩放自适应（Canvas 固定尺寸）、ExtendedDesktopSize 变体、多显示器、Tight/ZRLE/Cursor 编码。
---

## Round 49：VNC 画布自适应

| 产物 | 说明 |
|---|---|
| `Index.ets` | 新增 `updateCanvasSize(w,h)`（长边 ≤640、保持比例）；画布 `width/height` 绑定状态；绘制换算改用实际画布尺寸；新增 `vnc/canvas-size` 显示 |
| `spec/scenarios/vnc.adapt.yaml` | 远端切到 80x60 后断言 `canvas=80x60` 且 `drawn=4800`，并断言 `canvas=320x240` **不存在** |

### 为什么断言 `canvas=320x240` 必须缺席
写死尺寸的旧实现里，`canvas=320x240` 永远成立，"存在 Canvas 组件"也永远成立。
只有"尺寸跟着远端变"才是这条用例要证的东西。

### 又一次"锚点没命中"
第一次只把 `updateCanvasSize` 方法加进去，两个调用点（帧回调、status 回调）都没插入——
因为锚点缩进/内容与真实代码不一致，而**构建与安装都成功**（方法未被调用，编译当然过）。
靠 dump 里 `canvas=320x240` 才暴露出来。修法：直接用真实代码片段做锚点，并打印调用点计数确认。

### 双画像
`vnc.adapt` 在 2in1 与 tablet 均 **passed**。

### 未做
缩放后的**坐标反算精度**（指针事件仍按 1:1 像素坐标发送，缩放时点击位置会偏）、
ExtendedDesktopSize、Tight/ZRLE/Cursor 编码、双指缩放。
---

## Round 50：收口（全量回归未完成，如实记录）

### 一、本轮完成
| 项 | 说明 |
|---|---|
| `tools/sweep.ps1` | 按用例需要自动切换夹具模式（VNC Auth / None）、重启夹具、重建 rport，逐条回归并输出矩阵 JSON |
| `spec/run.py` | **dumpLayout 重试 3 次**：设备侧会间歇报 `Wait for subscribe uitest.broadcast.command.reply timeout`，此时 dump 文件为空，旧实现直接以"选择器未命中"这种误导性错误失败 |
| `COMPLETION-REPORT.md` | 完成度与差距清单（能力矩阵、P0/P1/P2 缺口、证据形态） |
| `RUNBOOK.md` | 新增 §30 VNC 消息分发/DesktopSize/画布自适应、§31 SFTP 导航、§32 测试原语（shell/swipe）、§33 全量回归 |

### 二、全量回归：**没有完成**（不写成通过）
- 计划 39 条 × 2 画像；实际：平板跑了 8 条（每条最多 2 次尝试），**通过 3 条**
- 失败集中在**第 1 步 `shell/add-host` 未命中**，与功能无关：本机 `uitest dumpLayout` 出现间歇性
  `Wait for subscribe uitest.broadcast.command.reply timeout`（实测连续 3 次 dump 中有 1 次返回空文件）
- 已做缓解：runner 对 dump 增加 3 次重试（本轮提交）
- 结果落在 `spec/runs/matrix-tablet-partial.json`，**没有**伪造通过率

### 三、为什么这不影响既有 E1 结论
每条功能在**其实现的当轮**都做过双画像验证（41 条用例、逐条通过记录见各 Round 条目）。
本轮是"再回归一遍"的额外保险，失败原因是测试基础设施抖动，不是被测功能回退。
但按诚实原则：**本轮没有新增可引用的通过证据**，也不把旧结果冒充本轮结果。

### 四、目标状态
**未完成**。剩余缺口（RDP 完整链路、AI 能力、i18n、上架材料、arm64 真机、SBOM/渗透测试）见
[COMPLETION-REPORT.md](./COMPLETION-REPORT.md)。
---

## Round 50 补记：夹具 DesktopSize 改为按需开启（修一个跨用例干扰）

Round 48 为了让 `vnc.desktopsize` 能验证尺寸变化，让夹具"第 3 次请求后自动切到 80x60"——
结果**干扰了 `vnc.session`**：它断言初值 `64x48`，但尺寸已被改成 80x60。

修法：夹具新增 `-vnc-resize`（默认关闭），只有这两条用例带该参数：
`vnc.desktopsize`、`vnc.adapt`。`tools/sweep.ps1` 已加对应映射。

复验（平板，复位后）：
- `vnc.session`、`vnc.clipboard`（默认夹具）**PASS**
- `vnc.desktopsize`、`vnc.adapt`（`-vnc-resize`）**PASS**
- `sftp.browse` **PASS**

这条也说明：**共享夹具的行为变更必须按需开关**，否则会让无关用例悄悄失败。
---

## 收官决定（用户裁定）：保持未完成，另开目标继续

用户选择 **B**：不把目标标记为完成，后续另开目标继续 RDP / AI / i18n / arm64。
因此本仓库当前状态是"**本期交付完成、目标未达成**"，缺口与顺序见
[COMPLETION-REPORT.md](./COMPLETION-REPORT.md) §4。

接手建议（按依赖顺序）：
1. **RDP**：先造一个可连端点（宿主开启远程桌面，或写最小 RDP 服务端夹具），再接入 FreeRDP；
   依赖链已就绪，缺的是"能验证的对端"
2. **AI 能力**：定义最小可验收切片（例如"对当前会话发一条指令 → 返回结构化结果"），先做通路
3. **i18n / 上架材料**：文案抽取 + 签名证书 + 隐私声明
4. **arm64 真机**：把 39 条用例在真机上跑一遍（脚本与矩阵格式已就绪）
---

## Round 51：i18n 中英双语 + AI 通路最小切片（恢复目标后第一轮）

### 一、i18n（用例 `ui.i18n`，双画像通过）
| 产物 | 说明 |
|---|---|
| `ets/common/strings.ets` | 中英两套文案表（39 键，点分命名空间），`get(lang,key)`；**缺键回退为键名**，让缺失在界面上可见而不是静默显示英文 |
| `Index.ets` | `lang` 状态 + `ui/lang` 切换按钮；顶栏（Known/Forward/Diagnostics/New Host）与主机区（标题/空态/行内 5 个按钮）改为取词 |
| spec | 默认英文 → 切中文（`新建主机`/`还没有主机`）→ 切回英文；并**反向断言键名不出现**（`top.newHost`/`host.empty`），等价于"用到的键都存在" |

**未做**：第三种语言、资源限定符目录方案、系统语言自动跟随、复数与日期本地化、其余面板文案。

### 二、AI 通路（用例 `ai.request`，双画像通过）
| 产物 | 说明 |
|---|---|
| `tools/design/sshfixture/ai_fixture.go` | 本地 AI stub 端点：`POST /v1/ai {"prompt"}` → `{"answer":"stub: N chars"}`；`GET /v1/health`；缺 prompt 返回 400 |
| 夹具参数 | 新增 `-ai-addr`（默认 `127.0.0.1:2297`） |
| `Index.ets` | `ai/ask` 按钮：截取终端尾部 200 字符 → HTTP POST（5s 超时）→ `ai/answer` 显示；覆盖 200/非 200/异常三条分支 |
| spec | 造 10 行输出 → 点 AI → 断言 `ai: stub: N chars`（N>0），并反向断言 `ai: request failed` / `ai: http ` / `ai: (empty context)` 都不出现 |

**诚实边界**：这证明的是**通路**（请求构造、超时、错误分支、结果渲染），**不是**模型质量。
stub 回答里的字符数是可判定信号：若发的是空 body，端点返回 400，界面会出现 `ai: http 400` → 用例失败。

### 三、能力号纠正（又一次"用错编号"）
最初把 i18n 标成 `F01`、AI 标成 `G01`，查表后发现：
- `F01` 实际是「Ask（当前终端为上下文）」→ AI 用 F01 **正确**
- `G01` 是「加密 .mottybak 导出导入」→ 与 AI 无关
- i18n 的正确编号是 **`H08`（3 语言 × 约 2,580 叶串）**

已纠正并回填。**教训重复了三次**：能力号必须先查表再写，不能凭印象。

### 四、双画像
`ui.i18n` 与 `ai.request` 在 2in1 与 tablet 均 **passed**。E1 能力数：14 → **16**。
---

## Round 52：SBOM 生成/校验 + 上架就绪度

| 产物 | 说明 |
|---|---|
| `tools/gen-sbom.py` | 从**实际产物**生成 CycloneDX 风格最小 SBOM（13 组件 / 29 份产物，含 arch/size/sha256）；`--check` 做两项机器判定 |
| `SBOM.json` | 生成结果（勿手改，脚本会覆盖） |
| `spec/lint.py` | 新增 `check_sbom()` 并入 errors：**漏登记三方库或清单过期时 lint 直接失败** |
| `STORE-READINESS.md` | 权限最小化说明、隐私声明底稿、签名指引、合规清单、上架前硬性阻塞 |

### 两项机器判定的负向验证（证明校验不是摆设）
1. 放一个 `libunregistered.a` → `gen-sbom.py --check` **exit=1**；删除后 exit=0
2. 放一个 `libtemp-check.a` → `spec/lint.py` **exit=1**；删除后 exit=0

### 上架前 4 项硬性阻塞（不在代码仓库内可完成）
1. **AI 端点默认值**是自测桩 `127.0.0.1:2297`，正式版必须改为显式配置 + 首次使用确认（隐私）
2. **release 签名证书**：需 AGC 证书 + Profile（你的华为账号）
3. **arm64 真机回归**：现有 E1 证据全部来自 x86_64 模拟器
4. **RDP 实验特性标注**：仅连接路径，上架需说明或补齐

### 又一次"改完没落地"
第一次给 `lint.py` 加 `problems += check_sbom()` 时，锚点 `problems = []` 在文件里根本不存在——
替换是空操作，但脚本仍打印"已接入"。**是负向验证（期望失败却通过）把这个问题揪出来的**。

### 状态
lint 通过（41 用例 + SBOM 校验）。E1 能力 16。
---

## Round 53：arm64 真机验证脚本与指引（E2 就绪）

| 产物 | 说明 |
|---|---|
| `spec/run.py` | 新增 `--profile device`（真机画像）：接受任意声明模拟器画像的用例，结果单独落盘，**不混淆"模拟器通过"与"真机通过"** |
| `tools/verify-arm64.ps1` | 装 HAP → 建 rport(2222/5901/2297) → 起夹具 → 逐条跑 → 出 `matrix-device.json`；判据 41/41 全通过才 exit 0 |
| `ARM64-REAL-DEVICE.md` | 六类差异、前置条件、完整命令、验收判据、真机风险点排序、记录模板 |

### 守卫的负向验证（都能判定）
| 情况 | 期望 | 实测 |
|---|---|---|
| 设备不在 `hdc list targets` | exit 3 | **3** ✅ |
| 序列号是模拟器 `127.0.0.1:1010x` | exit 4 | **4** ✅ |
| 缺 HAP | exit 5 | 逻辑同源（未构造） |
| 安装失败（真机缺 UDID Profile） | exit 6 | 逻辑同源（未构造） |

### E2 证据（本轮实测）
- `arm64-v8a/libmottynapi.so` 9803 KB，`llvm-readobj` 确认 **EM_AARCH64**
- HAP 内同时含 `libs/arm64-v8a/` 与 `libs/x86_64/` 两份 `.so`
- strip 前 9.8 MB → strip 后 7.3 MB

### 诚实边界
**真机未执行**。所以能力表里相关条目 evidence 保持 **E2**，没有改成 E1。
`sweep` 里 `--profile device` 的 smoke 是在模拟器上跑的，只验证"开关机制可用"，不作为真机证据。
---

## Round 54：RDP 对端选定方案 C —— FreeRDP server 组件已可为 OHOS 编译

### 一、为什么不用"开宿主远程桌面"
那需要管理员授权并修改宿主安全设置（`TermService` + `fDenyTSConnections`），且真实 RDP 还需要凭据。
未经授权不动宿主——所以选 **方案 C**：复用 FreeRDP 的服务端实现（Apache-2.0），
只补一个"虚拟屏幕"capture 子系统。协议协商/位图编码/输入通道全部由 FreeRDP 完成，
与我们客户端用的是**同一套协议栈**，因此是真实协议互通而不是自说自话。

### 二、已完成（E2，实测）
| 项 | 结果 |
|---|---|
| `-DWITH_SERVER=ON -DWITH_SHADOW=OFF` 配置 | **x86_64 与 arm64 均成功** |
| `libfreerdp-server3.a` | x86_64 **850 KB**、arm64 **950 KB** |
| 链接探针 | 引用 `shadow_server_new/shadow_server_start` + `rdpShadowServer`，与 freerdp/winpr/ssl/crypto 一起链成 **10 KB `.so`**，`EM_X86_64` |
| `native/build-freerdp.ps1` | 已改为同时构建 `freerdp-server` 目标（可复现） |

### 三、关键发现（决定了工作量）
**不需要 FreeRDP 源码树内部头**：安装后的 `freerdp/server/shadow.h` 里已含
`RDP_SHADOW_ENTRY_POINTS`、`rdpShadowSubsystem` 全部字段与 `shadow_capture_*` API。
因此自定义子系统可以只用公开头实现（约 300–600 行 C）。

### 四、SBOM 闸门再次生效
新库一落地，`gen-sbom.py --check` 立刻失败（未登记 `libfreerdp-server3.a`），
登记后 14 组件 / 31 份产物通过。**这说明上一轮的机器判定确实在起作用**，不是摆设。

### 五、下一步（Round 55）
实现 `vss_new/free/init/uninit/start/stop/enum_monitors` 六件套 + 帧生产线程，
`shadow_subsystem_set_entry` 注册后 `shadow_server_start`；
验收：App 内起服务端 → `rdpProbe` 连 `127.0.0.1:<port>` → 断言 `connected`。

### 六、诚实边界
服务端是"用来验证自己"的组件，不等于与真实 Windows RDP 互通；
客户端仍只有连接路径（无画面/输入/通道）。
---

## Round 55：RDP 服务端（自定义 capture 子系统）——编译通过，init 仍失败（未达成）

### 一、已落地（E2）
| 项 | 说明 |
|---|---|
| `cpp/rdp_server.cpp` | 自定义 shadow 子系统：`vss_new/free/init/uninit/start/stop/enum_monitors` + 帧生产线程（640×480 BGRA 图案，10fps）+ 认证回调 |
| NAPI | `rdpServerStart(port,user,password,configDir)` / `rdpServerStop()` / `rdpServerStatus()` |
| UI | 诊断面板 `rdp/srv-start`、`rdp/srv-stop`、`rdp/srv-status`，状态行 `rdp/srv-state` |
| 构建 | 需两处**构建期补丁**（已写进 `build-freerdp.ps1` 说明）：X11 子系统改可选、`freerdp-shadow-subsystem-impl` 目标缺少时不链接/不安装 |
| 依赖 | 新增链接 `libfreerdp-shadow3.a`、`librdtk0.a`、`libwinpr-tools3.a`（makecert） |
| SBOM | 已登记 shadow/rdtk/winpr-tools，16 组件 / 36 份产物，`--check` 通过 |

### 二、未达成：`shadow_server_init` 失败
`rdp/srv-state` 显示 `stopped err=shadow_server_init failed`。已排除/已修的：
1. ~~`g_server->subsystem` 在 init 前为空~~ → 凭据改用文件级静态量（顺序错，曾导致 SIGSEGV，已修）
2. ~~控制流错误导致 init 失败后仍解引用 `g_server`~~ → 重写分支（曾 SIGSEGV，已修）
3. **ConfigPath 为空** → 传入 `cacheDir`（`freerdp_settings_get_config_path()` 在 OHOS 返回空）

仍在排查（`shadow_server_init` 的失败点只有 6 处）：`shadow_server_init_certificate`（makecert 自签证书）
或 `shadow_subsystem_init`。**下一步手段**：FreeRDP 的 WLog 默认写 stderr，而 OHOS 上 stderr 不进 hilog；
本轮已加 `freopen(cacheDir/motty-rdp-server.log)`，但日志文件未出现在预期路径，需先解决日志落盘，
否则只能靠读源码逐个排除（效率很低）。

### 三、诚实边界
- 服务端**没有跑起来**，因此 `rdp.server-peer` 用例当前是**失败**状态，不是通过
- 客户端仍只有连接路径（无画面/输入/通道）
- 上轮文档里"链接探针引用了 `shadow_server_new`"的说法**不准确**：那个探针实际只取了常量地址，
  没有真正引用服务端符号；真正需要 `-DWITH_SHADOW=ON` 才能解析符号——本轮已更正

### 四、下一步（Round 56）
1. 解决日志落盘（先确认 `cacheDir` 是否真的传进 native；把 configDir 显示在 `rdp/srv-state` 里）
2. 逐项排除 `shadow_server_init` 失败点（优先证书生成：makecert + OpenSSL 在 OHOS 上是否可用）
3. 服务端起来后再跑 `rdp.server-peer`，届时才能谈"客户端连上真实对端"
---

## Round 56：RDP 服务端终于跑起来了（手动验证），但用例仍有"版本不一致"问题

### 一、修掉的两个**返回值约定**错误（这是关键）
FreeRDP 的 `shadow_server_init` 与 `shadow_server_start` **成功都返回 0、失败返回 <0**（不是布尔）。
我先写成 `!shadow_server_init(...)`，后改成 `== 0` 判失败——**两次都把成功当失败**。
正确写法：`>= 0` / `< 0`。

### 二、手动验证：服务端确实起来了
在设备上按"force-stop → aa start → 点诊断 → 点 srv-start"操作，状态行显示：
```
rdp-server: start rc=0 running port=13389 frames=0
```
且 `/proc/net/tcp` 中 `344D`（=13389）状态为 `0A`（**LISTEN**）。这是**手动证据**，不是用例证据。

另外修掉的真问题：
1. **端口 3389 是特权端口** → 改 **13389**
2. `ConfigPath` 为空（OHOS 无 XDG 配置目录）→ 传 `cacheDir`；证书已成功生成（`shadow/shadow.crt` 1010 B、`shadow.key` 1705 B）
3. 凭据顺序（曾 SIGSEGV）、init 失败后解引用（曾 SIGSEGV）
4. 自检体系：`stage[cert=ok key=ok listener=ok subsystem=ok vssInit=1]`、`start[screen=ok capture=ok]` 全部落进状态行，不需要日志文件

### 三、未解决：用例抓到的仍是旧版行为
同一个 HAP、同一设备：
- **手动点击**：新行为（`rc=0 running`）
- **用 `run.py` 跑用例**：旧行为（`stopped err=shadow_server_init failed`，这是**旧二进制的文案格式**）
已尝试：`--fresh`/不加 `--fresh`、`uninstall + install`、清 `.hvigor` 全量重建、`settleMs` 4000 + 首屏等待。
仍未消除。**下一步**：在状态行里输出 native 库的构建指纹（如 `__DATE__ __TIME__`），
用例与手动各跑一次，直接比对"跑的是不是同一份 .so"，而不是继续猜。

### 四、诚实边界
- `frames=0`：capture 线程尚未产出帧（`server->surface` 可能为空），**画面/位图未验证**
- 客户端仍只有连接路径
- **`rdp.server-peer` 用例当前仍是失败状态**，不能算 E1

### 五、为什么这轮值得记
两个"把成功当失败"的返回值错误，各花了很久才定位——根因是**没有读 FreeRDP 的返回值约定就照直觉写**。
自检体系（把每个阶段的结果塞进状态行）是这轮唯一真正有效的排障手段。
---

## Round 57：定位到"版本回滚"根因的一半

### 一、确认的真问题
1. **`bm clean -n <bundle> -d` 在本机表现为"把应用回滚到先前安装的版本"**。
   这解释了 Round 55–56 的怪现象：手动启动是新二进制、`run.py` 跑用例却抓到旧行为
   （旧二进制文案格式 `stopped err=shadow_server_init failed`，没有新加的 `built=` 字段）。
2. 因此 `--fresh` 之后**必须重装 HAP**：`spec/run.py` 已改为"force-stop → bm clean -d → 重装 → 继续"，
   HAP 路径默认 `harmonyos/ohos/app/entry/build/default/outputs/default/entry-default-signed.hap`，
   可用环境变量 `MOTTY_HAP` 覆盖；找不到时**打印警告**而不是静默继续。
3. 新增用例级开关 `app.skipFresh: true`（schema 已允许）：
   对"清数据会破坏环境"的用例（如 RDP 服务端自检）改为不清数据。
   已用于 `rdp.server-peer`。

### 二、native 构建指纹（本轮新增的排障手段）
状态行现在输出 `built=<__DATE__ __TIME__>`，以及 `loops=`（采集线程循环次数）、
`surface=ok|null`（是否拿到 shadow 表面）。实测：
- **手动启动 + 点击**：`start rc=0 running port=13389 frames=0 loops=0 surface=null built=Nov 11 2026 08:04:23`
  → 服务端确实在跑（`/proc/net/tcp` 的 `344D` 为 LISTEN），但**采集线程没被调用**（`loops=0`）
- 说明 FreeRDP 的 shadow **不会调用 `ep.Start`**，采集线程需要我们自己拉起

### 三、尝试后回退的改动
按上面结论"start 成功后自己起采集线程"改了一版，但引入崩溃（`std::terminate`，`libc++_shared` 栈），
**已回退**——不留未验证的改动在主干上。

### 四、仍未解决
即使加了"清理后重装"，`run.py --fresh` 抓到的仍是旧二进制（无 `built=` 字段）；
而手动启动是新的。**下一步**：
1. 让 runner 在 launch 后把 `built=` 抓下来打印（人眼立刻能比对，不用等断言失败）
2. 检查 `/data/storage/el1/bundle/libs/x86_64/libmottynapi.so` 的 mtime 是否随 install 更新
3. 若确认 install 不刷新该路径，则需要 uninstall + install（手动路径有效）

### 五、状态
`rdp.server-peer` **仍失败**，不算 E1。服务端"能启动"目前只有**手动证据**。
---

## Round 58：RDP 服务端"能启动"有了**脚本化机器判定**证据

### 一、根因清单（这轮才补齐）
| 现象 | 真因 | 处置 |
|---|---|---|
| 用例抓到旧行为、手动是新行为 | `bm clean -d` 会让应用回滚到先前版本 | `--fresh` 改为 **uninstall(hdc) + install** |
| `bm uninstall` 无效 | hdc shell 下静默失败（权限） | 改用 `hdc uninstall` |
| 改了 C++ 但设备行为不变 | **`devecocli build` 会跳过打包**（HAP 时间停在旧值） | 全清 `.hvigor` + `entry/build` 后重建，并**核对 HAP 时间** |
| 采集线程从没跑过 | FreeRDP shadow **不调用 `ep.Start`**（实测 `loops=0`） | 待修（见下） |

### 二、脚本化机器判定：通过
`tools/rdp-peer-check.ps1` + `rdp-peer-check-dump.py`（按 id 点击、断言状态行、返回退出码）：
```
state: rdp-server: start rc=0 running port=13389 frames=0 loops=0 surface=null built=Nov 11 2026 08:11:10
PASS  服务端处于 running
PASS  端口匹配
PASS  二进制含构建指纹
exit=0
```
同时 `/proc/net/tcp` 中 `344D`(=13389) 为 LISTEN。
**为什么单独写脚本**：runner 的 `--fresh` 路径在本机仍会跑旧二进制（未彻底定位），
而这条序列稳定拿到新二进制。脚本有退出码，属于机器判定，不是人眼判断。

### 三、仍未达成
- `frames=0 loops=0 surface=null`：**采集线程没跑**，因此没有画面
- 上一轮尝试"start 后自己起线程"引入过 `std::terminate` 崩溃 → 已回退。
  下一轮要安全地做：线程生命周期与 `shadow_server_stop/free` 严格配对（先 join 再 free）
- 客户端仍只有连接路径

### 四、诚实边界
`rdp.server-peer`（spec）**仍失败**；本轮通过的只是"服务端能启动"这条脚本化检查。
不把脚本通过说成"RDP 完整链路可用"。
---

## Round 59：采集线程之谜（定位到"ep.Start 被调用但函数体没走到线程创建"）

### 一、修掉的真 bug：重复启动导致崩溃
上一版我"start 成功后自己起采集线程"，与 shadow 内部的 `ep.Start` 撞车：
对 **已 joinable** 的 `std::thread` 赋值会抛 `std::system_error` → `std::terminate`。
崩溃栈已符号化确认：
```
std::__n1::thread::operator=[abi:v15004](std::thread&&)   thread:256
(anonymous namespace)::vss_start(...)                      rdp_server.cpp:194
shadow_server_thread                                       shadow_server.c
```
→ 说明 **FreeRDP 确实会调用 `ep.Start`**（在 `shadow_server_thread` 里）。
处置：删掉我们自己的重复启动；`vss_start` 改为**幂等**（已 joinable 直接返回 0），并 try/catch 兜底。

### 二、仍未解决：`loops=0 surface=null frames=0`
状态行实测：`vssStart=1 startRc=-2 tIn=0 tOut=0`
- `vssStart=1`：`ep.Start` 被调用了一次
- `startRc=-2`（初值）：**函数体没有执行到 `std::thread` 赋值那一行**
- `tIn=0`：线程函数一次都没进入

也就是说进到 `vss_start` 后、在 try 之前就返回了。可能原因（下一轮按序排除）：
1. `base == nullptr` → 我们的空指针分支提前 return -1（但 `ep.Init` 同一指针是好的，需打印指针值确认）
2. `sub->worker.joinable()` 为真（对象的 worker 处于奇怪状态，需打印 joinable 结果）
3. 我们的 `reinterpret_cast<VssSubsystem*>(base)` 与 `ep.New` 分配的布局不一致
   （`rdpShadowSubsystem` 必须是 `VssSubsystem` 的第一个成员——当前是，但要验证 `sizeof`/offset）

### 三、当前可引用的证据（与上一轮相同，未退化）
`tools/rdp-peer-check.ps1` 通过：
```
state: rdp-server: start rc=0 running port=13389 frames=0 loops=0 surface=null built=Nov 11 2026 08:16:07
PASS 服务端处于 running / PASS 端口匹配 / PASS 二进制含构建指纹 → exit=0
```
**服务端能监听、能接受连接**这件事是脚本化机器判定通过的；**画面/位图**仍未验证。

### 四、诚实边界
`rdp.server-peer`（spec）仍失败；RDP 客户端仍只有连接路径；
"服务端能启动"≠"RDP 可用"。
---

## Round 60：采集线程的两步定位（卡在 paintSurface；读 surface 有竞态）

### 一、修掉的
`vss_start` 里创建 `std::thread` 会**卡住不返回**（实测 stage 停在 5、无异常）。
处置：`vss_start` 只确认就绪并 return 0；采集线程改到 `shadow_server_start` 成功之后创建（**全进程唯一位置**）。

### 二、实测现象（非确定性）
| 观察 | 含义 |
|---|---|
| `stage=6` | `vss_start` 正常返回（不再卡住） |
| 有时 `loops=1 surface=ok lock=1 paint=0` | 线程跑了一轮，拿到 surface、进了临界区，**卡在 `paintSurface`** |
| 有时 `loops=0 surface=null` | 线程根本没跑（同代码、不同次启动） |

`paintSurface` 只有 640×480 的双层循环 + 写 `surface->data`。卡在这里最可能是
**`surface->width/height/scanline` 是脏值**（例如 width 极大导致"看起来像死循环"），
或 `surface->data` 指向尚未就绪的缓冲。已加 `sw/sh/stride/dnull` 计数准备取证，
但同一构建下行为在"跑一轮"与"完全不跑"之间跳，说明**我们自己的线程去读 shadow 的内部表面本身是竞态**。

### 三、结论与下一步（换思路，不再硬试）
不应该由我们线程直接写 `server->surface`。下一轮改为：
1. 用 shadow 自己的机制：`SHADOW_MSG_IN_REFRESH_REQUEST` / `subsystem->MsgPipe`（子系统消息循环），
   在 shadow 期望的时机交付帧，而不是自己起线程抢锁
2. 或者实现真正的 `shadow_capture` 语义（内部 API），让 shadow 主动拉帧
3. 若都不行，就明确记录"RDP 服务端只到握手、无画面"，把 RDP 结论收敛为：客户端连接路径已验证、服务端仅监听验证

### 四、诚实边界
- `frames=0`：**没有画面**
- `rdp.server-peer`（spec）仍失败
- 脚本化检查仍通过（`rc=0 running port=13389`、端口匹配、构建指纹），这是"能监听"的证据，不是"能出图"
---

## Round 61：i18n 覆盖到 SFTP 面板（用例 `ui.i18n.panels` 双画像通过）

| 产物 | 说明 |
|---|---|
| `ets/common/strings.ets` | 新增 10 个面板键（`sftp.preview/path`、`fwd.mode/listen/target/start/stop/test`、`vnc.stop`、`term.history`） |
| `Index.ets` | 14 处按钮改取词：SFTP（下载/上传/删除/重命名/新建目录/上级/列出）、转发保存规则、VNC 读/发剪贴板、三个面板的关闭、表单保存/添加 |
| `spec/scenarios/ui.i18n.panels.yaml` | 切中文 → 建主机信任 → 打开文件面板 → 断言 `下载`/`上传`/`新建目录`/`上级` 出现，并**反向断言 `Mkdir`/`Download` 与键名不出现** |

### 为什么反向断言是关键
"中文出现在屏幕上"可能只是因为面板没渲染到那一行；只有**英文原词与键名都不出现**，
才说明这些按钮确实走了取词表。

### 双画像
- tablet：**PASS**
- 2in1：**PASS**（首次失败是系统"是否将应用自动添加至桌面？"对话框遮挡，点"不添加"后通过——属环境问题，runner 已能识别并报为环境错误而不是用例失败）

### 边界
转发/VNC/诊断面板未逐一覆盖；第三种语言、系统语言跟随、复数与日期本地化未做。
---

## Round 62：RDP 服务端收敛 —— "能监听"双画像通过；**采集帧放弃**（有据）

### 一、这轮把上轮的"卡住"彻底解释清楚了
| 观察 | 真相 |
|---|---|
| `paint=0` 看似卡死 | 状态行是**点击瞬间的快照**，不是实时值；之前的判读全被这一点误导 |
| 8x8 探针能完成、整屏不完成 | 也受上面快照影响；加行计数后出现 `tsp=0`（线程函数从未进入） |
| `tsp=0`、`loops=0`、`cap=1` | **线程创建成功但从未被调度**（同一 HAP、同一设备，时好时坏） |

结论：**在 shadow 的上下文里创建 `std::thread` 不可靠**；再加上整屏绘制偶发不返回，
继续硬试的收益已经低于成本。因此本版本**主动禁用采集线程**：
服务端只监听、不产帧——这比"看起来有画面但其实没发出去"诚实。

### 二、用例收敛（不再假装连上）
`rdp.server-peer` 改为只断言**服务端真的在监听**：
```
rdp-server: start rc=0 running port=13389 ... built=...
```
删掉了原先"客户端 connected"的断言——因为服务端不产帧、完整协商未打通，
把没做到的事写成通过是不可接受的。

### 三、双画像
- 2in1：**PASS**
- tablet：**PASS**

### 四、E04 能力现状（如实）
仅连接路径（含失败语义）+ 服务端"能监听"实测；
**未达成**：服务端产帧、成功连接真实 RDP、TLS/证书 pin、NLA/CredSSP、能力协商、位图、输入、通道。

### 五、留给后续的可行方向
1. 不用 `std::thread`：把帧生产放进 shadow 的 `MsgPipe` 消息循环（子系统自己的线程）
2. 或者放弃内嵌服务端，改为"真实 Windows RDP 服务端 + 授权开启宿主远程桌面"
3. 客户端位图解码本身也还没做——即使服务端出帧，客户端也还显示不了
---

## Round 63：补两条"已实现但没覆盖"的用例（`terminal.resize`、`vnc.key`）

### 一、新增用例（双画像均通过）
| 用例 | 断言重点 | 为什么不只断言状态 |
|---|---|---|
| `terminal.resize` | 点 Resize → `resize->100x30`，**再发一条命令看到回显** | 只断言状态行只证明"调用了"，发命令看回显才证明 resize 没把会话弄坏 |
| `vnc.key` | 点"Send key a" → 画面统计里 `magenta>0` | 只有对端收到按键并回传新帧，客户端统计才会出现洋红（与指针的绿色区分） |

### 二、顺手修掉一个真实的布局 bug
`vnc/key` 在 2in1 上**根本渲染不出来**。dump 显示 `vnc/tap` 的 x 坐标跑到 2473（面板右边到 2225）——
根因是那一行 Row 里第一个 `Text('canvas=...')` 带了 `.width('100%')`，把后面的按钮全挤出了面板。
去掉 100% 宽度并把指针/按键按钮移到画布上方之后，2in1 与 tablet 都能正常渲染与点击。

这个 bug 在 tablet 上没暴露（屏幕更宽），是**双画像**才抓到的——也算给"为什么必须双画像"又添了一个实例。

### 三、状态
用例 43 → **45**；E1 能力 16；B09/E02 的 partialCoverage 已更新。