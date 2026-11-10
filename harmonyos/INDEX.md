# harmonyos/ —— A′ 开发工作区索引

> 路线：**A′（ArkTS/ArkUI + C/C++ 协议库经 NAPI）**。Go 在鸿蒙应用内不可用（已实测），详见 PLAN §15/§16。

## 文档（按阅读顺序）

| 文件 | 作用 | 状态 |
|---|---|---|
| [PLAN.md](./PLAN.md) | 总方案：路线对比 → 决策台账 → 风险登记册 → G1 实测 → A′ 定案 | 定稿（多次修订） |
| [A-PRIME-PLAN.md](./A-PRIME-PLAN.md) | A′ 落地：分层、C 依赖映射、M0.5 验收门、前 4 月 sprint、M0.5 实测进展 | 定稿 |
| [A-PRIME-ENGINEERING.md](./A-PRIME-ENGINEERING.md) | **工程主方案**：目录、12 个领域模块、7 端口契约、M0.5–M5 任务分解、Sprint 1 | 定稿（软件架构师交付） |
| [contracts/motty-native.d.ts](./contracts/motty-native.d.ts) | ArkTS ↔ NAPI ↔ C 契约 IDL 草案 | 草案 |
| [CAPABILITY-MATRIX.md](./CAPABILITY-MATRIX.md) | 能力矩阵 T1/T2/T3 逐项 | 待补「A′ 落点 + E1/E2/E3」两列 |
| [SPIKES.md](./SPIKES.md) | 模拟器环境、验证边界、证据等级 | 定稿 |

## 代码骨架（已建，待填）

```
ohos/     entry + features + libs{contract,domain,data,platform,input,i18n,testbase}
native/   port + proto-{ssh,sftp,crypto,agent,vnc,rdp} + napi + third_party + tests
spec/     schema + scenarios（82 个行为规格将在此） + capabilities.json
tools/design/   docs/
```

## 已验证的可用资产

- `spike/bprime/` —— **可复用的 NAPI HAP 骨架**：CMake + NAPI、`abiFilters: ["x86_64"]`、debug 签名、装机、hilog 采集全链路已跑通
- `spike/hello/` + `spike/core/` —— Go 三态探针（静态二进制 / c-shared / dlopen loader），是 G1 判定的原始证据
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
| `spec/scenarios/smoke.runner.yaml` | harness 自检 spec（目标为 `spike/bprime`），双画像均 **passed** |
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