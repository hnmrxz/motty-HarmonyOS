# A′ 工程化落地方案（目录 / 模块 / 契约 / 任务分解）

> 输入：路线 A′ 已定案（[PLAN.md](./PLAN.md) §17、[A-PRIME-PLAN.md](./A-PRIME-PLAN.md)）。
> 本文**不评估路线**，只回答"怎么把它变成可排期、可验收的工程"。
> 纪律：**不改上游任何文件**（`E:\motty-HarmonyOS` 除本文档所在 `harmonyos/` 外 diff 必须为 0）；本文不含构建执行结果。
> 数据来源全部为本次实测核对（见 §8 数据核实表）。

---

## 0. 读本文前必须知道的四件事

现有文档里有四处结论在 A′ 下会误导执行，先钉住（**等级不变，证据路径变**）：

### 0.1 能力矩阵的 T1 论证依据失效，但 T1 等级不变

[CAPABILITY-MATRIX.md](./CAPABILITY-MATRIX.md) 大量 T1 条目的"鸿蒙方案"写的是**原样保留 Go 内核**（B 组尤其明显："SSH 协议栈 **原样保留**，无需 libssh2/OpenSSL"）。A′ 下 Go 内核不存在，这些条目**必须重写落点**，但 T1/T2/T3 的分级判定不受影响（T1 = 行为等价，仍必须做到）。

→ 工程动作：给矩阵加两列 **「A′ 落点」+「证据等级 E1/E2/E3」**（任务 `T0.5.6`）。**不重开分级评审**，只补落点与证据。

### 0.2 M0.5-b 存在依赖倒置，必须拆成 b′ / b

原口径："M0.5-b：ArkTS 侧能建立一条真实 SSH 会话"。但 ArkTS 的 SSH 能力是 **M0.6（native 能力层）**的产物。M0.5 若等它，oracle harness 就永远开不了工。

→ 拆为：
- **M0.5-b′**（W1–W2）：用 `spike/bprime` 级别的**一次性探针**证明"ArkTS → NAPI → 对端 socket 可达"（不需要 SSH 语义）。
- **M0.6-b**（W8–W10）：真实 libssh2 会话（公钥认证 + exec + SFTP 列目录）。

### 0.3 "协议层逐字节等价"对 SSH 不成立，L2 必须换三级等价

A-PRIME-PLAN §3.1② 写"逐字节等价证据"。这对**文件/密码学格式**成立，对**协议会话**不成立：KEX 含双方随机数、算法集顺序由实现偏好决定。照此写验收，永远过不了。

→ 三级等价证据（§4.1）：**字节级**（vault/ppk/otp/backup/known_hosts/schemes）× **帧级归一化**（SSH/SFTP/转发）× **行为级**（UI spec）。

### 0.4 i18n 规模被低估约 2.7 倍

文档写"947 串"。实测：`internal/i18n` **943 个顶层分组字段**，但 `english.go` / `chinese.go` 各 **2,509 条叶串**，`traditional.go` **2,787 条**（由 `tools/zhtw/gen.py` 生成）。

→ 生成器任务按 **~2.5k 叶串 × 3 语言**估工，不要按 947 估（任务 `T1.16`）。

---

## 1. 工程目录结构

原则：**新增目录、零上游编辑**；`ohos/` 与 `native/` 各自可独立构建；`spec/` 与 `capabilities.json` 是**跨语言单一真源**。

```
E:\motty-HarmonyOS\                 ← 上游 Go 仓库（只读；CI 断言 diff=0）
├─ internal\ cmd\ tools\ docs\ ...  ← 绝不修改
├─ harmonyos\                       ← 既有规划文档（本文在此）
│  ├─ contracts\
│  │  └─ motty-native.d.ts          ← ArkTS↔NAPI 契约真源（草案，随实现演进）
│  └─ A-PRIME-ENGINEERING.md
│
├─ ohos\                            ← 【新增】HarmonyOS 工程根（hvigor）
│  ├─ build-profile.json5           产品：pc(2in1) / tablet / 共用 default；abiFilters 双 ABI
│  ├─ oh-package.json5
│  ├─ AppScope\
│  ├─ entry\                        HAP：Ability、窗口形态、路由、冷启动
│  ├─ features\                     UI 能力（初版 HAR，达阈值再改 HSP，见 D5）
│  │  ├─ terminal\  hosts\  files\  desktop\  ai\  notes\  settings\
│  ├─ libs\                         纯逻辑/契约（无 Ability、无 UI、可单测）
│  │  ├─ contract\                  端口与 DTO（无实现）
│  │  ├─ domain\                    会话状态机、审批门、风险分级、命令面板、广播
│  │  ├─ data\                      relationalStore / preferences / sessionlog / cloudsync
│  │  ├─ platform\                  Kit 适配：huks/asset/picker/pasteboard/ime/bgtask/window/net
│  │  ├─ input\                     指针↔触控归一化、hover 合成、手势判定
│  │  ├─ i18n\                      生成产物（由 tools/design/i18n-gen 出）
│  │  └─ testbase\                  test_surface 观测面（release 构建期剔除）
│  └─ test\                         ohosTest（Hypium + @ohos.UiTest）
│
├─ native\                          ← 【新增】C/C++ 与 NAPI
│  ├─ third_party\                  配方(HPKBUILD/cmake)+patch+锁 commit+许可清单
│  │  └─ recipes\{zlib,openssl,libssh2,argon2,freerdp}
│  ├─ port\                         OHOS/musl 适配：唯一允许出现 dlfcn/__MUSL__/符号可见性技巧处
│  ├─ proto-ssh\  proto-sftp\  proto-crypto\  proto-agent\  proto-vnc\  proto-rdp\
│  ├─ napi\                         模块注册、handle 表、能力位、TSFN 调度、错误映射
│  │  └─ caps\{session,fs,vault,desktop,agent}.cpp
│  ├─ tests\                        ctest：一致性向量、handle 负测、fuzz 语料
│  └─ CMakeLists.txt                产物：libmotty_napi.so（双 ABI）
│
├─ spec\                            ← 【新增】行为规格（82 个 e2e 的机器可读形态）
│  ├─ schema\spec.schema.json
│  ├─ terminal\  hosts\  files\  desktop\  ai\  data\ ...
│  └─ generated\                    runner 由 spec 生成的 uitest 用例（不入库可直接丢弃）
│
├─ capabilities.json                ← 【新增】能力注册表单一真源（T1/T2/T3+证据+回退+文案）
├─ tools\design\                    ← 【新增】宿主侧工具（不碰 upstream tools/）
│  ├─ i18n-gen\                      Go 结构体 → ArkTS 资源
│  ├─ caps-gen\                      capabilities.json → ArkTS 常量 + CI 断言
│  ├─ spec-lint\                     spec 校验（必填字段/断言强度）
│  ├─ trace-collect\                 原版轨迹采集（Go oracle）
│  └─ trace-diff\                    归一化比对
└─ docs\                            ← 【新增】
   ├─ adr\  threat-model\  sbom\  acceptance\  evidence\
```

**CI 断言（W1 就要生效，防止"悄悄改了上游"）：**

| 断言 | 命令 | 失败即阻断 |
|---|---|---|
| 上游零改动 | `git diff --stat -- internal cmd tools docs go.mod go.sum` 为空 | 是 |
| 契约单一真源 | `ohos/libs/contract/src/main/ets/motty-native.d.ts` 与 `harmonyos/contracts/motty-native.d.ts` 一致 | 是 |
| 能力表一致 | `capabilities.json` 键集合 = `caps-gen --emit` 产物键集合 | 是 |
| T3 零入口 | `caps-gen --assert t3`：T3 项在 ArkTS 中无路由/按钮引用 | 是 |
| 单一出口 | `.exec(` 仅出现在 `libs/domain/gate.ts` | 是 |
| release 无测试面 | release HAP 中无 `test_surface` 符号/字符串 | 是 |

---

## 2. 模块与包划分

### 2.1 分层与依赖方向（硬规则）

```
features/*  ──►  libs/domain  ──►  libs/contract  ◄──  libs/data
    │                 │                  ▲
    │                 └──► libs/platform ┘        （只经接口，不直接 import Kit）
    │
    └──► libs/input, libs/i18n（叶子，无反向依赖）

native/napi ──► native/proto-*  ──► native/third_party
      ▲
      └── libs/contract 的 .d.ts 是唯一可见面；native 不得知道 UI、不得持有策略
```

可 CI 断言的四条：
1. `features/*` 之间**不得互相 import**（跨模块协作走 `libs/domain` 的 mediator/事件）。
2. `libs/platform` 之外**不得出现** `@kit.*` / `@ohos.*` 的 Kit import。
3. `native/proto-*` **不得** include `native/napi/*`；`native/napi` 不得直接调 `third_party`（只经 `proto-*`）。
4. native **不得**打开文件系统、不得 exec、不得新增监听（唯一例外：MCP 在 ArkTS 侧、绑 127.0.0.1）。

### 2.2 领域模块表（实测规模，prod 行不含测试）

| # | 模块 | 上游对应（prod 行） | 载体 | 里程碑 |
|---|---|---|---|---|
| M-TERM | 终端引擎 + 输入 | `term` 6,868；`workbench/terminal*` 6,179；`completion` 3,063；`highlight` 411 | ArkTS（+可选 C 底座） | M1 |
| M-SESS | 会话与认证 | `sshconn` 4,799；`keyidentity` 434；`ppk` 567；`knownhosts` 305；`otp` 469 | C(libssh2) + ArkTS 状态机 | M1 |
| M-HOST | 主机目录与导入 | `workbench/host*` 6,163；`sshconfig` 1,500；`sessionimport` 1,102 | ArkTS | M1–M2 |
| M-FS | 文件与编辑器 | `sftpclient` 4,102；`scpclient` 962；`workbench/sftp*` 13,905；`workbench/file*` 3,593 | C(libssh2 SFTP) + ArkTS | M2 |
| M-XFER | 传输与转发 | `portforward` 692；`workbench/{transfer,forward,local_proxy}` ~4,300；`zmodem` 1,173；`xymodem` 748 | ArkTS + C(通道) | M2 |
| M-SHELL | 工作台外壳 | `workspace` 2,061；`workbench/{workspace,tab,toolbar,session,window,chrome,paint}*` ~16,000；`i18n` 12,043 | ArkTS | M1–M2 |
| M-DESK | 远程桌面 | `rdpcore` 24,065；`rfb` 1,537；`desktop` 1,614；`workbench/desktop*` 2,302 | C(RFB 自写 / FreeRDP) | M3 |
| M-AI | AI 与 MCP | `ai` 14,083；`workbench/ai*` 12,809 | ArkTS + `net.http/webSocket` | M4 |
| M-DATA | 数据与保险库 | `vault` 966；`backup` 173；`configstore` 1,114；`sessionlog` 1,421；`cloudsync/s3/gist/webdav` 1,120；`autofill` 261 | C(OpenSSL+argon2) + ArkTS(relationalStore) | M1(vault)/M4(同步) |
| M-NOTE | 笔记 | `workbench/notes*` 6,878 | ArkTS | M2 |
| M-MON | 监控与诊断 | `remotestats` 1,619；`monitoring` 408；`workbench/monitor*` 3,839；`diag` 145；`crashlog` 174 | ArkTS | M2–M3 |
| M-MISC | telnet / 串口(T3) | `telnet` 387；`serial` 815（T3 不实现） | ArkTS | M2 / — |

合计约 **231,065 行 prod**（`internal/**` 非测试总量），与 PLAN 的 55–70 人月口径同源。

### 2.3 团队泳道（6 人）

| 泳道 | 人数 | 主要产出 | M0.6→M1 关键交付 |
|---|---|---|---|
| L-A 原生协议 | 2 | `native/**`、C 交叉编译、NAPI 能力层 | 首个 SSH/SFTP/Vault 通道 |
| L-B 终端与输入 | 1.5 | M-TERM、`libs/input`、渲染层 | 终端引擎选型门 + 首屏 |
| L-C 工作台与领域 | 1.5 | M-SHELL、M-HOST、`libs/domain`、`libs/data` | 会话状态机 + 标签分屏 |
| L-D Harness 与合规 | 1 | `spec/`、`capabilities.json`、`tools/design`、CI、SBOM | 82 spec + 轨迹 diff |

M3（桌面）为**单独立项**（R21），届时从 L-B 拆出 1.5 人专做，其余泳道保持。

---

## 3. 端口 / 接口契约（ArkTS ↔ NAPI ↔ C）

完整 IDL 草案见 `harmonyos/contracts/motty-native.d.ts`。本节给**约定**与**每个端口的语义边界**。

### 3.1 七个端口（对应 PLAN §3.2 的五个 + A′ 新增两个）

| 端口 | 载体 | 跨 NAPI | 职责 |
|---|---|---|---|
| P0 `Platform` | ArkTS | 否 | 数据目录、文件 URI、密钥、剪贴板、后台、通知、窗口 |
| P1 `Transport`（会话） | C(libssh2) | 是 | 连接/KEX/认证/kbdint/hostkey/通道/direct-tcpip/远程转发 |
| P2 `RemoteFs` | C(libssh2 SFTP) | 是 | 远端文件系统原语（哑管道，不编排） |
| P3 `Vault` | C(OpenSSL+argon2) | 是 | 保险库文件格式与加解密（字节兼容） |
| P4 `DesktopSession` | C(RFB/FreeRDP) | 是 | 帧、输入、剪贴板、尺寸 |
| P5 `TerminalEngine` | ArkTS(默认) 或 C | 可选 | 字节流↔网格、键鼠编码、选中/搜索/链接 |
| P6 `ApprovalGate` | ArkTS | 否 | 唯一工具出口；风险分级；审计 |
| P7 `TestSurface` | ArkTS(debug) | 否 | 机器可读观测面（供 spec 断言） |

### 3.2 NAPI 通用约定（全部端口一致）

**(a) 句柄与能力（SEC-01 落地形态）**

```ts
type Handle = number;          // 1..0x7fffffff，绝不复用

const CAP_SHELL   = 0x0001;    // 打开交互 shell
const CAP_EXEC    = 0x0002;    // 非交互命令
const CAP_SFTP    = 0x0004;    // 打开文件子系统
const CAP_FORWARD = 0x0008;    // direct-tcpip / 远程转发
const CAP_DESKTOP = 0x0010;
const CAP_VAULT   = 0x0020;
const CAP_AGENT   = 0x0040;    // 应用内 agent 应答（D3 定后启用）
```

规则（每条都有负测）：
1. 句柄只能由 `*_open` 生成；父句柄必须已 `phase=ready`（session）或已解锁（vault）。
2. 每次调用校验：**存在 → 未撤销 → 世代(gen)匹配 → 操作位 ∈ 能力集**。
3. 撤销时机：`*_close`、连接丢失、Ability 销毁、锁屏策略命中、`onCleanup`。
4. **世代号**单调递增，旧句柄即使号段归零也不复活（防 ABA）。
5. 拒绝统一 `E_HANDLE` / `E_STALE` / `E_CAP`，**不带**内部指针、路径、对端地址。
6. 固定负测集：`0`、随机大数、已关闭、他会话句柄、能力位缺失、旧世代、跨 Ability 句柄。

**(b) 线程与事件**

```
每 session：1 个 native worker（libssh2 session 非线程安全，必须独占）
回 JS：napi_create_threadsafe_function（NDK 已确认可用），每模块 1 个 TSFN
事件：{ h, seq, kind, payload }     seq 按句柄单调
丢弃策略：只允许 progress 类事件合并；**终端数据、错误、状态迁移永不丢**
背压：native 队列 > 4 MiB → 暂停 socket 读 + 只发一次 E_BACKPRESSURE；降到 1 MiB 恢复
JS 侧：句柄必须在 onCleanup/finalizer 释放，否则 worker 泄漏（有泄漏负测）
```

**(c) 数据编码**

- 字节一律 `ArrayBuffer`（ArkTS 侧不转 string）。
- 结构体字段名固定、只增不改；每类载荷带 `v: 1`。
- 列表分页（`readdir` 200/页）；>10k 项目录不得阻塞 UI。
- 时长统一 ms；时间戳统一毫秒 epoch（与 configstore 的 HLC 分开，不做混用）。

**(d) 错误模型**

```ts
interface MottyError extends Error {
  code: 'E_HANDLE'|'E_STALE'|'E_CAP'|'E_CLOSED'|'E_AUTH'|'E_HOSTKEY'|'E_IO'
      |'E_TIMEOUT'|'E_FORMAT'|'E_LIMIT'|'E_UNSUPPORTED'|'E_BACKPRESSURE'
      |'E_NOTFOUND'|'E_EXISTS'|'E_DENIED'|'E_KDF';
  errno?: number;   // 原始 errno，仅日志
  op?: string;      // 出错操作名，仅日志
}
```
Promise reject 携带 `code`；UI 只依赖 `code` 与 `capabilities.json` 的用户文案，**不得**解析 message。

**(e) 禁止项（编译期/评审双重拦截）**

- 无 `exec(cmd)`、无 `eval`、无任意路径读写、无全局 env 读取、无符号执行。
- 无"传入任意 .so 路径加载"的能力（`port/` 之外禁止 `dlopen`）。
- native 不新增监听端口；不读 `SSH_AUTH_SOCK`（不存在，见 §7 R44）。

### 3.3 P1 Transport（会话）

```ts
ssh_open(o: SessionOptions): Promise<Handle>
SessionOptions {
  endpoint: {host:string; port:number; user:string};
  jumps?: Endpoint[];                      // 外层→内层，每跳独立验钥/认证
  knownHostsPath: string;                  // 由 ArkTS 数据层决定（沙箱路径）
  auth: {methods:number; identityFiles:string[]; storedKeys:string[]; agent:boolean};
  keepAlive?: {intervalMs:number; timeoutMs:number};
  timeouts?: {connectMs:number; bannerMs:number; kexMs:number; authMs:number};
  algorithms?: {kex?:string[]; cipher?:string[]; mac?:string[]; hostKey?:string[]};
}
```

事件（native → ArkTS，**ArkTS 决策后才继续**）：

| kind | 触发 | ArkTS 必须回 |
|---|---|---|
| `phase` | connecting/banner/kex/auth/ready/closed | 否（仅渲染） |
| `hostkey` | 首次见钥 / 变更 | `ssh_answer(h,{kind:'hostkey',decision:'accept'\|'keyed-accept'\|'abort'})` |
| `question` | 密码 / kbdint 多问题 / 私钥口令 | `ssh_answer(h,{kind:'question',answers:string[]})` |
| `negotiated` | KEX 完成 | 否（**必须写入轨迹**，供等价比对） |
| `banner` / `system` / `ready` / `error` / `closed` | — | 否 |

不变式：
- **P1 主机密钥变更无"仍要信任"**：`decision` 枚举里**没有** force 分支；`known[]` 非空时 `accept` 也不被接受（只能 abort）。
- 认证顺序、方法选择、重试次数由 ArkTS 状态机决定（可测、可审），native 只执行"再试一次"这一动作。
- `system` 探测不得写入用户 shell（照搬上游"不打扰"语义）。

方法：`ssh_answer`、`ssh_exec`(CAP_EXEC)、`ssh_shell`(CAP_SHELL)→`ChannelHandle`、`chan_write/resize/signal/eof/close`、`direct_tcpip`(CAP_FORWARD)、`remote_forward`/`cancel_remote_forward`、`sftp_open`(CAP_SFTP)、`ssh_status`、`ssh_close`。

### 3.4 P2 RemoteFs（SFTP / SCP 回退）

```ts
sftp_open(h: Handle, o:{mode:'sftp'|'scp'; root?:string}): Promise<FsHandle>
fs_readdir(fs, {path, start, limit}): Promise<DirPage>
  DirPage {v:1; entries: Entry[]; more: boolean}
  Entry {name; kind:'file'|'dir'|'link'|'other'; size; mode; mtimeMs; uid; gid; linkTarget?}
fs_stat / fs_lstat / fs_realpath / fs_mkdir / fs_rmdir / fs_remove
fs_rename(fs,{from,to,replace}) / fs_posix_rename(fs,{from,to})
fs_chmod / fs_symlink / fs_readlink / fs_utimes
fs_open(fs,{path,flags:'r'|'w'|'a'|'rw',mode}): Promise<FileHandle>
fs_read(fh,{offset,length}): Promise<ArrayBuffer>     // ≤512 KiB/次
fs_write(fh,{offset,data:ArrayBuffer}): Promise<number>
fs_fstat / fs_fsync / fs_truncate / fs_fclose / fs_fs_close
```

**职责切分（重要，决定可测性）**：
- native 只做**原语**与**非阻塞流水线**（libssh2 用 `libssh2_session_set_blocking(0)` + `EAGAIN` 重试实现窗口化请求，避免单请求往返）。
- **原子替换、续传、冲突、校验前缀、进度聚合全部在 ArkTS**（`M-XFER`）——这些是可被 Hypium 单测的纯逻辑，留在 C 里既难测又难审。
- 上传落盘：`<name>.motty-partial-<rand>` → `fsync` → `posix_rename`；语义逐条对齐上游（见 `internal/sftpclient/worker.go`）。

### 3.5 P3 Vault（含"密钥只进 HUKS/Asset"的精确口径）

```ts
vault_open(path: string): Promise<Handle>
vault_header(h): Promise<{v:number; kdf?:{name,time,memoryKiB,threads,salt:ArrayBuffer}; hasWrapped:boolean}>
vault_unlock_passphrase(h, pass: ArrayBuffer): Promise<void>       // argon2id → KEK → unwrap 数据密钥
vault_unlock_keystore(h, secret: ArrayBuffer): Promise<void>       // 从 Asset 取出的 32B 数据密钥
vault_secret_for_storage(h): Promise<ArrayBuffer>                  // 首次解锁后交给 Asset 保存
vault_list(h): Promise<{name,stamp,deleted}[]>
vault_apply(h, changes:{name,value?,delete?}[]): Promise<void>     // 原子
vault_rotate_passphrase(h, next: ArrayBuffer): Promise<void>
vault_lock(h) / vault_close(h)                                     // 内存清零（explicit_bzero）
```

**字节兼容基线（实测常量，必须逐字节 round-trip）**：
`version=1`；`kdf{name,time,memory_kib,threads,salt}`；`wrapped_key`；`records[{id,data}]`；AAD `"motty vault data key"`；记录 ID 上下文 `"motty vault record id\x00"`；上限 `maxFileSize=8 MiB`、`maxRecords=4096`（含墓碑至 8192）。

**密钥口径（把 R05 讲清楚，避免实现走偏）**：

| 允许 | 禁止 |
|---|---|
| vault 文件内的 `wrapped_key`（口令派生 KEK 包裹的 32B 数据密钥）——**格式的一部分，跨端导入必需** | `FileKeystore`：把 32B 明文 hex 写在 vault 旁 |
| 数据密钥存 **Asset/HUKS**（`IS_PERSISTENT=false`，可访问性"首次解锁后"） | `FallbackKeystore`：系统密钥库不可用就落文件 |
| Asset 拒绝（模拟器/无 TEE/用户未认证）→ **每次要求口令**，纯内存会话 | 任何形式的静默降级落盘 |

**必须承认的边界**：Asset/HUKS 的写入 API 接收明文，所以"32B 密钥从 native 传到 ArkTS 再进 Asset"这一段在同一进程内不可避免。收益在**静态存储**（TEE 绑定、随应用卸载清除、不进云备份），不在进程内隔离。写进威胁模型，不要包装成更强的东西。

### 3.6 P4 DesktopSession

```ts
vnc_open(o:{host,port,auth:{kind:'none'|'vnc',password?:string}, tunnel?:{session:Handle,dstHost,dstPort}}): Promise<Handle>
rdp_open(o:{host,port,user,domain?,password?,tlsMin:'1.2'|'1.3',certPinSha256:string}): Promise<Handle>
desk_input(h, e: PointerInput|KeyInput|ClipboardInput): void
desk_expect_size(h,{w,h,dpr}): void
desk_close(h)
// 事件
frame {x,y,w,h,encoding:'rgba',data:ArrayBuffer}(dirty rect)
bell | clipboardText | sizeChanged | certPrompt | closed | error
```

- **RFB 自写（D 决议 a）**：Raw/CopyRect/RRE/Hextile/ZRLE，先做 Raw+Hextile（覆盖绝大多数真实服务器），ZRLE 后置。
- **RDP**：FreeRDP 薄封装，`VerifyCertificate` 回调 → 事件 → ArkTS 决策，**拒绝即断**；TLS 下限硬编码 ≥1.2（上游是 1.0，R12）。
- 帧只在**脏矩形**上跨界，禁止整屏拷贝（R42）。

### 3.7 P5 TerminalEngine（保留两个底座，先立门再定）

```ts
interface TerminalEngine {
  feed(bytes: ArrayBuffer): void;
  snapshot(): {v:1; dirtyRows:number[]; rows:RowData[]; cursor:{x,y,style,visible}; modes:Modes};
  resize(cols:number, rows:number): void;
  scroll(lines:number): boolean;
  select(a:Point,b:Point,mode:'char'|'word'|'line'|'block'): void;
  search(q:string,o:{regex?:boolean;caseSensitive?:boolean}): Match[];
  keyToBytes(k:KeyEvent): ArrayBuffer | null;     // kitty / xterm 编码
  mouseToBytes(e:MouseEvent): ArrayBuffer | null;
  setReply(fn:(b:ArrayBuffer)=>void): void;       // DSR/DA/OSC 应答
  setSyncHold(fn:(hold:boolean)=>void): void;     // DECSET 2026
  setClipboardWrite(fn:(w:ClipboardWrite)=>void): void;
}
```

两个候选（**2 周 spike 定，任务 `T1.1`，门在 M1 前**）：

| 选项 | 优点 | 代价 | 触发放弃的条件 |
|---|---|---|---|
| (a) C: libvterm 骨架 + 自写扩展 | 解析离开 JS 线程；VT 基础部分成熟 | kitty 键盘/图像/DECSET2026/reflow 仍要自写；多一套 C++ 与测试 | 扩展工作量 > 自写总量 60%，或 4 周内跑不通图像与 reflow |
| (b) ArkTS 自写（默认倾向） | 一种语言、Hypium 可单测、与 UI 语义同源；语料/fuzz 思路可沿用 | JS 堆压力；必须重导 VT 语义 | 2in1 画像上 5000 行滚屏 <60fps 且优化无效 |

**决策指标（客观）**：2in1 画像 5000 行回滚滚动 ≥60fps、CJK+组合字符正确、4K SIXEL 图不抖、内存 ≤16 MiB/标签页（PLAN 的 G3 口径）。

### 3.8 P6 ApprovalGate（AI 唯一出口）

- AI 网络、provider、脱敏、token 预算全在 ArkTS（`@ohos.net.http` / `webSocket`）。
- **唯一出口**：`gate.run(toolCall)`。静态断言：`.exec(` 仅出现在 `libs/domain/gate.ts`。
- 防御性接线（**不是**安全边界，要写明）：native 的 `ssh_exec` 要求一个 `grantId`，由 gate 通过 `session.grant_exec(h,{ttlMs})` 申请，一次性、带过期、native 记录审计。同进程内它不提升安全，只让"绕过 gate 的调用"在测试里立刻失败。
- 风险分级口径：**"防误操作提醒"**，不是安全控制（R29）；allow-all 需二次确认 + 审计入 `sessionlog`。
- MCP：`@ohos.net.socket` 绑 `127.0.0.1`、bearer 定长比较、Host/Origin 校验、**默认关闭**、默认 `observe`、非法值 → `observe`。

### 3.9 P7 TestSurface（让 82 个 spec 可机器判定）

ArkUI 的 uitest **读不到 Canvas/XComponent 里画的终端文本**——这是 harness 的硬约束，不是偏好。因此必须有应用侧观测面：

```ts
testSurface.dump(): Promise<{
  screens: {cols;rows;lines:string[];cursor;modes;viewOffset}[];
  tree: {id;role;label;value?;state;rect}[];
  layout: {overflowing:[]; overlapping:[]};
  caps: {t3Visible:string[]};       // 必须为空
}>;
```

- 仅 debug 构建存在（`-DMOTTY_TEST_SURFACE=0` + ArkTS 条件编译），release 断言零符号。
- 它是 `spec` 断言语义（`waitfor`/`texts`/`layout`/`expect state id:`）的落点。

---

## 4. 等价性证据体系（L2 的工程实现）

### 4.1 三级等价（不同对象用不同强度，别混用）

| 级 | 对象 | 判定 | 工具 |
|---|---|---|---|
| **E-bytes** 字节级 | vault / ppk / otp / `.mottybak` / known_hosts / 配色 schemes / xresources | 与上游夹具**逐字节** round-trip；双向（桌面写→鸿蒙读→鸿蒙写→桌面读） | `native/tests/vectors` + `tools/design/trace-diff --bytes` |
| **E-frames** 帧级归一化 | SSH / SFTP / 转发 / VNC | ① `negotiated` 算法集合相等；② 通道事件序列（open/data/eof/close/exit-status）相等；③ 有序数据流 `sha256` 相等。**KEX 随机数与算法偏好顺序不入比较** | `trace-collect`（Go）+ native wire log + `trace-diff` |
| **E-behavior** 行为级 | UI/交互 | `spec/*.yaml` 断言 + 双画像 PNG + `testSurface.dump` | spec runner + Hypium |

> 写成这样才可证伪："SSH 逐字节等价"是伪命题；"协商集 + 通道事件序列 + 数据流哈希等价"是真命题。

### 4.2 八条安全不变量的重建表（PLAN §7.4 在 A′ 下必须重做）

| # | 不变量 | 原位置 | A′ 新位置 | 证明 |
|---|---|---|---|---|
| P1 | 主机密钥变更**无**"仍要信任" | `sshconn/hostkey.go:97-145` | native 只发 `hostkey` 事件；ArkTS `HostKeyPolicy` 枚举无 force | 负测 + `host_key_change` spec |
| P2 | AI 工具调用只经 `gate.Run` | `ai/gate/gate.go:1-7,160` | `libs/domain/gate.ts` + native `grantId` | 静态断言 + 负测 `E_CAP` |
| P3 | MCP 默认 `observe`，未知→`observe` | `workbench/ai_state.go:119` | `libs/domain/mcp-mode.ts` 闭集 | 单测：非法值映射 |
| P4 | 传输根 + realpath + 逐段 Lstat 拒符号链接 | `workbench/agent_transfers.go:57-125` | `libs/platform/fileRoot.ts`（唯一本地 IO 入口） | 负测：目录外/链接逃逸必失败 |
| P5 | 保险库 AES-256-GCM + HMAC id + 原子写；系统库拒权不降级 | `vault/vault.go:783-818,734-759`；`keystore.go:54-83` | native `proto-crypto/vault` + `libs/platform/assetKeystore.ts`（无 Fallback） | S-G2 扫描 + 注入失败测试 |
| P6 | 输入边界 `maxOSC 4096` / 图像 64 MiB / 剪贴板只写 | `term/terminal.go:5-14` | 引擎常量 + 超限计数遥测 | 单测 + 超限 spec |
| P7 | RDP 证书 TOFU pin，拒绝即断 | `rdpcore/client.go:626-645` | FreeRDP verify 回调 → 决策；TLS≥1.2 硬编码 | 负测 + 抓包 |
| P8 | 常量时间比较 + loopback + Host/Origin | `ai/mcp/server.go:174-187,235-249,335-342` | ArkTS MCP server | 单测 + 非 loopback 绑定失败 |

### 4.3 capabilities.json（唯一的"能做到什么程度"真源）

```json
{
  "schema": 1,
  "entries": [
    {
      "id": "terminal.protocols",
      "level": "T1",
      "aPrime": { "where": "ohos/features/terminal + libs/domain", "evidence": "E-behavior" },
      "evidence": "E1",
      "proof": ["spec/terminal/terminal_protocols.yaml"],
      "fallback": null,
      "userText": null
    },
    {
      "id": "shell.agentForward",
      "level": "T1",
      "aPrime": { "where": "native/proto-agent", "evidence": "E-frames" },
      "evidence": "E3",
      "proof": [],
      "fallback": "shell.agentForward.unavailable",
      "userText": "本机没有 ssh-agent，转发使用应用内密钥并逐次确认"
    }
  ]
}
```

三条 CI 断言：① 键集合 = 矩阵全集（**含矩阵漏项，见 R51**）；② `level=T3` ⇒ ArkTS 无入口引用；③ `evidence` ∈ {E1,E2,E3} 且 E3 项必须在验收报告里出现。

### 4.4 轨迹采集与 diff

- **Go 侧**：`tools/design/trace-collect`（新工具，不改 upstream）以 `vivahead` 构建跑同一脚本，输出 `{negociated, channel-events, data-sha256, sftp-ops, screen-snapshots}`。
- **ArkTS 侧**：同一 spec + native wire log + `testSurface.dump`。
- **diff**：归一化（去时间戳/去随机 nonce/排序等价操作）→ 三条断言（§4.1 E-frames）。
- **复用资产**：`tools/e2esshd`（独立 go.mod）支持 pty/SFTP/SCP-only/证书/agent 转发/远程转发/X11/资源监视，且 `E2E_*` 开关齐全 —— 对端不需要新写。
- **网络通则（本次核实）**：设备 → 宿主用 `hdc rport tcp:2222 tcp:2222`（`rport remotenode localnode`："把远端流量转回宿主"）。M0.5 必须先把这条固化进脚本。

---

## 5. 里程碑与任务分解（M0.5 → M5）

周次按"6 人队、纯建设"给相对刻度；绝对日期不写（PLAN §4 的立场）。

### 5.1 依赖图

```
            ┌──────────── W1–W2  Sprint 1（骨架 + 契约 + 首个 NAPI 探针）────────────┐
            ▼                                                                     ▼
   M0.5 harness (W1–W10)  ──┐                                        M0.6 native (W3–W12)
   spec/caps/trace/oracle   │                                          C 流水线→NAPI→SSH/SFTP
                            ├────────────────► M1 门（W16 起需要两者都绿）
   M0.6 门 (W10) ───────────┘
            │
            ▼
   M1 终端+SSH (W11–W28)  → 门：10 spec 等价 + 双画像 + 触控核心路径 + 性能重标定
            │
            ▼
   M2 文件+编辑器+传输 (W25–W38)   ─┬─► M3 桌面 (W33–W48，单独立项)
            │                        │
            ▼                        ▼
   M4 AI+MCP+同步 (W41–W54)  ──► M5 打包合规 (W47–W60) → 真机抽验 → 交付
```

### 5.2 M0.5：oracle harness（W1–W10）— 产物是测试基础设施，不是功能

| ID | 任务 | 泳道 | 依赖 | 验收判定 | 证据 |
|---|---|---|---|---|---|
| T0.5.1 | 目录骨架 + 零改动 CI + 契约/能力表断言 | L-D | — | 6 条 CI 断言全绿；上游 `git diff` 空 | CI 日志 |
| T0.5.2 | `spec/schema` v1 + runner 骨架（yaml→uitest 用例生成） | L-D | T0.5.1 | 3 个样例 spec 生成并通过 lint | schema + 3 yaml |
| T0.5.3 | 82 脚本转译（半自动：`tree` 抓取→id 映射→人工核断言），分批 10/20/30/22 | L-D | T0.5.2 | 82 个 yaml 字段完整；`spec-lint` 零告警 | `spec/**` + 报告 |
| T0.5.4 | 原版轨迹采集器（Go 侧） | L-D | 原版可构建 | 同脚本两次运行 diff 为空（除时间戳） | trace 目录 |
| T0.5.5 | 轨迹 diff 工具（三级等价中的 E-frames） | L-D | T0.5.4 | 人为注入一处理论差异能被报出 | diff 报告 |
| T0.5.6 | `capabilities.json` v1 + 矩阵补「A′ 落点/证据」两列 + 补漏项 | L-D | T0.5.1 | 条目数 = 矩阵行数 + 漏项（R51）；T3 零入口断言生效 | 能力表 |
| T0.5.7 | 原版 ≥10 个 headless e2e 通过 + 已知失败清单（R20） | L-D | 原版可构建 | 10 场景 exit=0；失败清单落档 | 截图 + 日志 |
| T0.5.8 | 对端起停 + `hdc rport` 通则脚本化 | L-D | — | 设备内 `curl 127.0.0.1:<port>` 打到宿主 | 脚本 + 输出 |
| T0.5.9 | 双画像冒烟（2in1 + tablet 装包/启动/截图/关键词断言） | L-D | M0.6 骨架 | 两画像各出 PNG + hilog 无 dlopen 错误 | PNG ×2 |

**M0.5 门（原 a–e，修订后）**：
- a：原版 ≥10 e2e 通过 + 已知失败清单 ✅
- b′：ArkTS→NAPI→socket 探针通（**不要求 SSH**）
- c：82 spec 完整；≥10 个在模拟器上跑通并出 PNG + 断言日志
- d：同一次交互的 Go/ArkTS 差异报告（E-frames）可产出
- e：`capabilities.json` 覆盖全集且 T3 零入口

### 5.3 M0.6：native 能力层（W3–W12，与 M0.5 并行）

| ID | 任务 | 泳道 | 依赖 | 验收判定 |
|---|---|---|---|---|
| T0.6.1 | C 交叉编译流水线：zlib → openssl → libssh2 → argon2，双 ABI（x86_64 + aarch64-linux-ohos），锁 commit + patch 集 | L-A | — | 两 ABI 均产出 `.so`；`llvm-readelf` 依赖清单干净；许可清单入库 |
| T0.6.2 | NAPI 骨架：模块注册、handle 表、能力位、世代号、错误映射、TSFN、`onCleanup` | L-A | — | 6 类句柄负测全部返回约定错误码；无泄漏（10k 次开关 RSS 平稳） |
| T0.6.3 | libssh2 会话封装：连接/KEX/算法白名单/公钥+口令+kbdint/hostkey 回调/keepalive | L-A | T0.6.1,T0.6.2 | 对 `e2esshd` 完成公钥认证并 `ready`；`negotiated` 事件可读 |
| T0.6.4 | SFTP 子通道 + 分页 readdir + 非阻塞窗口流水线 | L-A | T0.6.3 | 列 10k 项目录 <2 s；单文件 100 MB 下载吞吐达目标（M1 重标定） |
| T0.6.5 | 跳板链（每跳独立验钥/认证） | L-A | T0.6.3 | 两跳链 e2e 通过；任一跳拒绝即整体失败 |
| T0.6.6 | Vault 格式（Argon2id + AES-256-GCM + 常量域） | L-A | T0.6.1 | 与上游 `.mottybak`/vault 夹具**字节级** round-trip |
| T0.6.7 | native wire log 埋点（供 E-frames） | L-A | T0.6.3 | 日志可被 `trace-diff` 消费 |

**M0.6 门**：ArkTS 对 `e2esshd` 完成 **公钥认证 + exec + SFTP 列目录**；负测全绿；S-G1 的句柄部分先行通过。
> 这一步之后 ArkTS 才第一次"真的能连 SSH"——M0.5-b′ 与它的区别就在这里。

### 5.4 M1：终端 + SSH（W11–W28）

| ID | 任务 | 泳道 | 依赖 | 验收 |
|---|---|---|---|---|
| T1.1 | **终端引擎 spike（2 周）**：libvterm vs ArkTS 自写，按 §3.7 指标判定 | L-B | M0.6 门 | 决策记录 ADR-002 + 两方案各一 demo（5000 行 + 4K 图 + CJK） |
| T1.2 | 引擎实现：网格/回滚/备用屏/reflow/宽字符/组合/连字网格 | L-B | T1.1 | 单测覆盖上游 `term` 关键用例等价；`terminal_flood` spec 通过 |
| T1.3 | 键鼠编码（kitty 协议、xterm 鼠标、`win32-input-mode` **删除**） | L-B | T1.2 | 按键矩阵单测；T3 零入口断言 |
| T1.4 | 图像：Kitty / iTerm2 / SIXEL + 上限（64 MiB、OSC 4096） | L-B | T1.2 | 图片 spec + 超限截断计数 |
| T1.5 | 选择/搜索/OSC8 链接/DECSET 2026 同步刷新 | L-B | T1.2 | spec + 无撕裂截图 |
| T1.6 | 渲染层：Canvas 与 XComponent 两案对比，脏行更新 + 帧预算 | L-B | T1.2 | 2in1 画像 60fps；内存 ≤16 MiB/页 |
| T1.7 | 输入归一化：指针/触控/hover 合成 + **高频 hover-only 入口改造**（方案 C） | L-B | T1.6 | 断开指针设备后完成核心路径（触控 spec） |
| T1.8 | IME preedit（`InputMethodExtensionAbility`） | L-B | T1.6 | `preedit` spec |
| T1.9 | 会话状态机：phase 编排、认证方法策略、hostkey 策略、跳板链 | L-C | M0.6 门 | `host_test`/`credentials`/`host_cert`/`jump_*` 等价 |
| T1.10 | 凭据：stored keys、`.ppk` v2/v3、OpenSSH 证书自动配对、TOTP/自动填充 | L-C | T1.9 | `ppk`/`autofill_*` 等价；字节级 ppk 向量 |
| T1.11 | known_hosts 兼容（含 `@cert-authority`） | L-C | T1.9 | 文件字节级等价 + 变更即断负测 |
| T1.12 | 端口转发：local/remote/SOCKS5/HTTP CONNECT，**只绑 loopback** | L-C | T1.9 | `local_proxy`/`proxy_start_stop` 等价 |
| T1.13 | **应用内 agent 桥**（D3 定后）：用 vault 密钥应答 `auth-agent@openssh.com`，逐次审批 | L-A | T1.10 | 与上游"外部 agent"语义差异写入能力表；转发 spec |
| T1.14 | 标签 / 分屏 / 窗口：PC 自由窗口、平板分屏·平行视界·悬浮窗 | L-C | T1.6 | `layout_*` + 双画像手动清单 |
| T1.15 | 主题/字体/配色（200+ schemes + Xresources 导入） | L-C | T1.6 | 导入结果字节级等价 |
| T1.16 | i18n 生成器（**2.5k 叶串 × 3 语言**）+ 稳定 test id 规范 | L-D | T0.5.1 | 键集合 diff=0；`har` 键 = Go 结构体键 |

**M1 门**：10 个指定 e2e 等价（`terminal_protocols`/`terminal_flood`/`terminal_drag_scroll`/`clipboard_osc52`/`preedit`/`host_test`/`credentials`/`ppk`/`host_cert`/`agent_forward`）+ 双画像 + 触控核心路径 + 4 项性能本机重标定（R19）。

### 5.5 M2：文件 + 编辑器 + 传输（W25–W38）

| ID | 任务 | 泳道 | 验收 |
|---|---|---|---|
| T2.1 | SFTP 面板：列表/多选/权限/书签/排序/筛选 | L-C | `sftp_*` 等价 |
| T2.2 | 传输引擎：队列、断点续传、staging+rename、大小/时间校验、取消重试 | L-C | `transfer_*` 等价 + 断网续传 |
| T2.3 | SCP 回退（无 SFTP 子系统） | L-A | `scp_e2e` |
| T2.4 | 本地文件访问：picker + `persistPermission` + 传输根守卫（P4） | L-C | 目录外访问必失败；重启后授权仍在 |
| T2.5 | 内置编辑器：语法着色/查找替换/正则/大文件策略 | L-B | `editor_*` 等价 |
| T2.6 | 目录跟随 / 文件面板跟随 | L-C | 手动 + spec |
| T2.7 | zmodem / xymodem（纯逻辑） | L-C | `zmodem_*` 互操作 |
| T2.8 | 会话录制与日志检索 | L-C | 录制回放 + 检索 spec |
| T2.9 | 笔记（6,878 行） | L-B | 手动 + 关键 spec |

**M2 门**：`sftp_*`/`scp_e2e`/`transfer_*`/`zmodem_*` 等价；传输根负测；断网续传证据。

### 5.6 M3：远程桌面（W33–W48，单独立项）

| ID | 任务 | 泳道 | 验收 |
|---|---|---|---|
| T3.1 | RFB 客户端自写 C：3.3/3.7/3.8、None/VNC Auth、Raw/CopyRect/RRE/Hextile（ZRLE 后置） | 桌面组 | 对 `tools/live` 真服务器连通 |
| T3.2 | 帧上屏：脏矩形 → `ImageBitmap`/XComponent，双缓冲 | 桌面组 | 1080p 30fps 无撕裂；4K 记录实测 |
| T3.3 | 桌面输入/剪贴板/尺寸/重连 | 桌面组 | `vnc_e2e` |
| T3.4 | FreeRDP 交叉编译 + 薄封装（NLA/TLS1.2+/pin/文件拖放） | 桌面组 | `rdp_e2e`、`rdp_files_e2e`；证书变更即断 |
| T3.5 | VNC/RDP 经 SSH 隧道 | 桌面组 | 隧道 e2e |

**M3 门**：`vnc_e2e`/`rdp_e2e`/`rdp_files_e2e` + 失败路径（证书变更/认证失败）；许可结论（无 GPL）入库。

### 5.7 M4：AI + MCP + 同步（W41–W54）

| ID | 任务 | 泳道 | 验收 |
|---|---|---|---|
| T4.1 | provider 接入 + 流式回答 | L-C | `ai_*` 等价 |
| T4.2 | 脱敏（私钥/赋值/URL 凭据/令牌）+ token 预算 | L-C | 单测向量（照搬上游用例） |
| T4.3 | `gate.ts` + 审批 UI + 审计（P2/R29 口径） | L-C | `ai_agent_*` + 静态断言单一出口 |
| T4.4 | MCP HTTP server（默认关、loopback、bearer 定长比较、Host/Origin） | L-C | `mcp_e2e.py` + 负测 |
| T4.5 | configstore → `relationalStore`（**epoch 23 不抬**，迁移与 `TooNew` 语义） | L-C | 双向 round-trip：桌面写→鸿蒙读→鸿蒙写→桌面读 |
| T4.6 | 云同步：WebDAV/S3/Gist/Gitee + HLC 合并 + 90 天墓碑 | L-C | `cloudsync_*` + 冲突夹具 |
| T4.7 | `.mottybak` 双向 round-trip（字节级） | L-A | 字节级 + epoch 兼容 |
| T4.8 | 会话日志/远程统计面板 | L-C | `monitor_*` 等价 |

### 5.8 M5：打包与合规（W47–W60）

| ID | 任务 | 验收 |
|---|---|---|
| T5.1 | 双 ABI 构建 + 体积预算（HAP/HSP 分包策略随 D5） | 两 ABI 体积各自记录；超预算即回退方案 |
| T5.2 | 发布签名 + 真机安装 | 真机安装成功；签名材料不入 VCS（见 §7 R-SIGN） |
| T5.3 | 权限最小化 + 隐私声明 + 开源许可页 + NOTICE + SBOM | S-G4；许可页覆盖 libssh2/OpenSSL/argon2/FreeRDP |
| T5.4 | 威胁模型签字 + 渗透测试 | S-G0；渗透报告无高危；P1–P8 逐条复测 |
| T5.5 | 等价性总报告（T1/T2/T3 × E1/E2/E3） | 每条能力有证据或明确 E3 声明 |
| T5.6 | 上架材料（若 D7 决定上架） | 审核清单 |

**M5 门**：S-G0…S-G4 全绿 + 真机抽验（arm64 至少一轮核心路径）+ 双 ABI 体积与 `.mottybak`/epoch 双向 round-trip。

---

## 6. 首个 Sprint 具体清单（W1–W2，6 人 × 10 工作日）

| # | 任务 | 泳道 | 人日 | 依赖 | 完成判定 |
|---|---|---|---|---|---|
| 1 | 目录骨架 + `.gitignore` + 6 条 CI 断言 | L-D | 1 | — | CI 在空壳上跑绿；上游 diff=0 |
| 2 | hvigor 壳工程：`entry` + 5 个 HAR + pc/tablet 两产品 + 双 ABI 配置 | L-C | 2 | — | `assembleHap` 成功；两画像可装 |
| 3 | NAPI 骨架：handle 表 + 能力位 + 世代号 + echo 能力 + 6 类负测 | L-A | 3 | 1 | 负测全绿；`hilog` 无 dlopen 错 |
| 4 | C 流水线 bootstrap：zlib + openssl 双 ABI（锁 commit + patch 目录） | L-A | 4 | 1 | 两 ABI 产 `.so`；依赖清单干净 |
| 5 | `capabilities.json` schema + v0 全量条目骨架（含 T3 零入口断言） | L-D | 2 | 1 | `caps-gen --assert t3` 生效 |
| 6 | `spec` schema v1 + spec-lint + runner 骨架 | L-D | 3 | 1 | 3 个样例 spec 通过 lint |
| 7 | 5 个 e2e → YAML，其中 2 个在模拟器上跑通 | L-D | 4 | 6,2 | 2 个 spec 出 PNG + 断言日志 |
| 8 | `testSurface` 最小实现（screens/tree/layout dump） | L-B | 3 | 2 | `dump()` 能读出终端文本与控件树 |
| 9 | 终端引擎 spike 立项：语料抽取（上游测试语料/fuzz 种子/协议序列） | L-B | 2 | — | 语料清单 + 两方案对比表 |
| 10 | ADR-001 目录与分层、ADR-002 终端底座候选、ADR-003 句柄与线程、ADR-004 本地 IO 单写者 | L-C | 1 | — | 4 份 ADR 合入 |
| 11 | 威胁模型 v0：STRIDE + P1–P8 重建表草案 | L-C | 2 | 10 | 与 §4.2 对齐，评审一次 |
| 12 | 签名与密钥配置净化：占位 + CI 注入；双画像冒烟脚本 | L-D | 1 | 2 | 仓库内无口令；CI 注入后能签 |
| 13 | `e2esshd` 起停 + `hdc rport` 通则脚本 | L-D | 0.5 | — | 设备内可达宿主端口 |
| 14 | i18n 生成器 spike：en 2,509 叶串 → ArkTS `string.json` | L-D | 2 | 1 | 键集合 diff=0（仅 en） |
| 15 | Sprint 门：双画像装包 + 5 分钟演示脚本 + 证据归档 | 全员 | 1 | 全部 | 演示脚本可重复；证据落 `docs/evidence` |

> 合计约 32 人日 / 60 人日容量 → **留 45% 缓冲**给交叉编译与 hvigor 的未知（这是首个 sprint 最容易被低估的地方）。

---

## 7. 风险与未决项

### 7.1 新增风险（接 R01–R36）

| ID | 风险 | 触发 | 影响 | 缓解 | 验证 |
|---|---|---|---|---|---|
| **R37** | 终端引擎重写是最大工期单点（上游 6,868 行 + 扩展语义） | 低估 kitty/图像/reflow | M1 整体滑期 | 2 周 spike 立门（T1.1）；先做 VT+回滚+键鼠，图像后置 | 门指标 §3.7 |
| **R38** | FreeRDP 在 musl/OHOS 交叉编译（依赖多、线程模型、可能需要 patch） | 依赖树不可控 | M3 阻塞 | M3 单独立项；先做 RFB（自写、无依赖） | CMake 配置日志 + 运行 |
| **R39** | libssh2 与上游语义差距：`@cert-authority`、OpenSSH 用户证书、kbdint 顺序、posix-rename、远程转发细节 | 直接照搬调用 | T1 条目走不成 | M0.6 就做"语义对照清单"，逐条标注"等价/近似/缺失" | `host_cert`/`jump_*` spec |
| **R40** | NAPI 线程与背压：大帧抖动、ArrayBuffer 生命周期、TSFN 队列堆积 | 高频进度事件 | UI 卡顿/内存涨 | 合并 progress、4 MiB 高水位、终端数据零丢弃 | 10k 次开关 RSS/延迟分布 |
| **R41** | 模拟器 HUKS/Asset 只到 E1（可能软件实现） | 把 E1 当安全结论 | 虚假通过 | 能力表标注证据等级；真机阶段必须复测 | T5.4 渗透 |
| **R42** | 桌面帧拷贝带宽（4K@30fps ≈ 1 GB/s） | 整屏 RGBA 拷贝 | 掉帧/发热 | 只传脏矩形 + 双缓冲 + 编码探测 | 4K 实测记录 |
| **R43** | uitest 读不到 Canvas 文本 | 无观测面 | 82 spec 无法机器判定 | `testSurface`（P7）为 M0.5 硬依赖 | spec 通过率 |
| **R44** | **无 ssh-agent**：上游 agent 认证/转发依赖外部 agent（`SSH_AUTH_SOCK`/Windows 管道），鸿蒙两者皆无 | 直接移植 | T1 的 agent 两项走不通 | D3：应用内 agent 桥（用 vault 密钥应答 + 逐次审批）；不做则降级并写文案 | `agent_forward` spec + 能力表口径 |
| **R45** | i18n 规模低估 2.7 倍（2.5k 叶串 × 3 语言） | 按 947 估工 | 资源与测试 id 延迟 | 生成器机械化（T1.16）；先 en/zh，zh-TW 复用 `gen.py` 逻辑 | 键集合 diff=0 |
| **R46** | 包体：双 ABI + OpenSSL + FreeRDP + 代码库 | 未分包 | 上架/下载扇区风险 | D5：HAP/HSP 分包阈值；openssl 裁剪（仅所需算法） | T5.1 体积表 |
| **R47** | 真机缺位：arm64 与策略层结论只到 E2/E3 | 只用模拟器 | 上线即翻车 | M5 强制真机一轮；arm64 编译进 CI 全程绿 | 真机抽验报告 |
| **R48** | 永久分叉：upstream 语义持续演进 | 无跟版机制 | 等价性漂移 | 季度对齐 upstream release notes；spec 作为契约 | 季度对比报告 |
| **R49** | ArkTS 语言限制（无 `any`/动态属性/受限结构）造成移植摩擦 | 直译 Go 结构 | 返工 | `libs/contract` 先定 DTO；禁止 `Record<string,any>` | lint 规则 |
| **R50** | C 依赖无 `govulncheck` 覆盖 | 沿用旧 CI | 供应链盲区 | SBOM + CVE 比对流水；固定 commit；patch 集可审计 | S-G4 |
| **R51** | **能力矩阵漏项**：`telnet`(387)、`notes`(6,878)、`cmdhistory`(853)、`aiproviderimport`(1,682)、`remotestats`(1,619) 未成行 | 按矩阵排期 | 交付后才发现没做 | T0.5.6 由包树反向补齐条目 | 条目数 = 包树派生集 |
| **R-SIGN** | 签名材料与口令管理（`spike/bprime/build-profile.json5` 曾以明文口令形式存在，当前未入 git） | CI 注入不当 | 凭据泄露 | 仓库只存占位；CI 从 secret 注入；`git secrets`/gitleaks 扫描 | CI 扫描 + 历史审计 |

### 7.2 未决项（需要人或时间给答案）

| # | 未决 | 选项 | 建议 | 期限 | 影响面 |
|---|---|---|---|---|---|
| D1 | 终端底座 | (a) libvterm+扩展 / (b) ArkTS 自写 | 先 spike 再定（§3.7） | W11 前 | M1 工期、R37 |
| D2 | 渲染载体 | ArkUI Canvas / XComponent+原生 | 随 D1；Canvas 优先（少一层 native） | W12 前 | T1.6 帧预算 |
| D3 | 应用内 agent | 做 / 不做（降级 + 文案） | **做**（否则 T1 两项走不通，且它有真实用户价值：无外部 agent 也能转发） | M1 设计前 | T1.13、能力表口径 |
| D4 | RDP 范围 | 进 M3 / 后置 | 进 M3 但独立验收；先 VNC | M3 启动前 | 24,065 prod 行、R38 |
| D5 | HAR→HSP 拆分时机 | 体积/构建时间阈值触发 | 先 HAR，触发后迁 HSP | M2 | R46、构建时长 |
| D6 | 本地文件 IO 归属 | ArkTS 单写者（分块跨界）/ native 直写（allowlist 目录） | **ArkTS 单写者**（P4 单点可审）；吞吐不达标再开 native 快路 | M2 | 吞吐 vs 可审性 |
| D7 | 上架与否 | 上架 / 不上架 | 预留条件、不设为必经门（PLAN §12.1） | M5 前 | 合规强度、渗透范围 |
| D8 | 后台保活文案 | 降级提示措辞 | "退后台会断开，回到前台自动重连" | M1 | R08、上架风险 |
| D9 | VNC 编码集 | 是否含 Tight/ZRLE | Raw+Hextile 优先，ZRLE 次之，Tight 不做 | M3 | 兼容面 |
| D10 | 多指手势 | 做 / 记 T3 | 记 T3（双指滚动映射滚轮） | M1 | 能力表 |

---

## 8. 数据核实表（本文引用数字的来源）

| 项 | 实测值 | 方式 |
|---|---|---|
| `internal/**` prod 行 | 231,065 | 非 `_test.go` 计数 |
| workbench | 131,012 行 / 399 文件 | 同上（与 PLAN §3.1 一致） |
| term / sshconn / sftpclient | 6,868 / 4,799 / 4,102 | 同上 |
| rdpcore / ai / i18n | 24,065 / 14,083 / 12,043 | 同上 |
| i18n 叶串 | en 2,509、zh 2,509、zh-TW 2,787；顶层分组 943 | `english.go`/`chinese.go`/`traditional.go` 赋值行计数 |
| e2e 脚本 | 82 个 `.txt` | `tools/e2e` |
| e2e DSL 动作 | click/type/key/rightclick/settle/waitfor/shot/texts/layout/tree/expect | `tools/headless_drive.py` 文档串（控制面在 `viva/headless`） |
| e2esshd 能力 | pty / SFTP / SCP-only / 证书 / agent 转发 / 远程转发 / X11 / stats，含 `E2E_*` 开关 | `tools/e2esshd/README.md` |
| vault 格式常量 | version=1、`wrapped_key`、AAD `motty vault data key`、id 上下文 `motty vault record id\0`、8 MiB / 4096 条 | `internal/vault/vault.go` |
| `FileKeystore` / `FallbackKeystore` 会落文件 | 是（hex 32B 明文） | `internal/vault/keystore.go` |
| agent 依赖外部进程 | 是（`SSH_AUTH_SOCK` / `\\.\pipe\openssh-ssh-agent`） | `sshconn/agentdial.go`、`agentfwd.go` |
| NDK | clang 15.0.4；`x86_64-unknown-linux-ohos-clang` 与 `aarch64-...` 均在；`libace_napi.z.so` 双 ABI 在 | SDK 目录 |
| NAPI 线程能力 | `napi_create_threadsafe_function` 在头文件中 | `native/sysroot/usr/include/napi/native_api.h` |
| uitest 可用 | `@ohos.UiTest.d.ts` 有 `Driver/On/Component/UiWindow`、`findComponent`、`waitForComponent`、`screenCapture` | SDK `ets/api` |
| 后台任务无 SSH 类型 | `BackgroundMode` 只有 DATA_TRANSFER/AUDIO_PLAYBACK/LOCATION/BLUETOOTH_INTERACTION 等；`DATA_TRANSFER` 超 10 分钟无更新即取消 | `@ohos.resourceschedule.backgroundTaskManager.d.ts` |
| 设备→宿主通路 | `hdc rport remotenode localnode` | `hdc -h` |

---

## 9. 一句话结论

A′ 的工程难点**不在 UI 重写（那只是量大），而在三处"看不见的地基"**：① NAPI 句柄/线程/背压这一层如果做错，后面所有端口都得返工；② 终端引擎底座选错要重做 M1；③ 没有观测面（P7）就没有"1:1"的机器判定。

因此第一个 sprint 刻意把 45% 的缓冲留给 ①，把 2 周时间盒留给 ②，把 spec/capabilities 的骨架放在 ③ —— 这三件事做完，后面 18 个月才有资格谈"等价"。
