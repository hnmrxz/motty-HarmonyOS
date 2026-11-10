# A′ 现状收口（2026-11-10，第 14 轮）

> 这份文档只回答两个问题：**现在到底有什么是经过实测的**，以及**离"1:1 完成"还差什么**。
> 判据严格遵循 [PLAN.md](./PLAN.md) §11.3 的证据等级：**E1 = 模拟器双画像实测；E2 = 仅编译/静态；E3 = 未验证**。
> 全文不出现"完成""就绪"这类词去描述尚未验证的部分。

## 1. 一句话状态

**协议骨干（SSH 握手/认证/主机密钥/exec/交互/最小 VT）在 x86_64 模拟器的 2in1 与 tablet 两个画像上被机器判定验收；产品功能只有一个切片（主机列表 + 连接 + 终端）；82 个行为规格完成 9 个（11%）。arm64 只有编译证据。**

## 2. 可以拿出去说的（全部 E1，双画像实测）

| 能力 | 证据 |
|---|---|
| SSH 协议栈（libssh2 + mbedTLS 静态链入 NAPI） | `ssh.exec`、`ssh.connect-from-list` |
| 主机密钥校验 fail-closed（未知不认证 / 不匹配不认证 / 无"仍要信任"入口） | `ssh.hostkey` + 对端日志 |
| known_hosts 持久化 + 用户确认闭环 | `ssh.connect-from-list`（二次连接不再弹框） |
| 密码认证 + keyboard-interactive 之外的基础认证链路 | 同上 |
| 主机列表 CRUD + `relationalStore` 持久化 | `infra.host-create-by-id`、`host.persist` |
| 设备→宿主 TCP 通路（`hdc rport`）与 SSH banner | `net.reachability` |
| 流式 exec（多块到达） | `terminal.view` |
| 交互式通道（键盘输入 → 远端回显） | `terminal.interactive` |
| 最小 VT 引擎（CUP/ED/EL/SGR/滚动/CJK 双宽） | `terminal.vt` |

**18 份通过证据** = 9 个 spec × 2 画像，全部是在同一份最终构建上跑的（`spec/runs/`）。

## 3. 只有编译证据的（E2，不能当"能用"）

| 项 | 状态 |
|---|---|
| arm64-v8a 的 libssh2/mbedTLS/NAPI | 交叉编译通过，`libmottynapi.so` 是 AArch64；**没有真机，零执行证据** |
| 双 ABI 打包 | HAP 内两个 ABI 都在，x86_64 侧可安装运行；arm64 侧未安装过 |

## 4. 完全没有的（E3 / 未开始）

| 类别 | 缺口 |
|---|---|
| 终端 | 备用屏、回滚缓冲、组合字符与零宽连接、连字、SIXEL/Kitty/iTerm2 图片、鼠标上报、DECSET 2026、选择/复制、pty 尺寸协商 |
| 会话 | 会话复用、多标签、分屏、重连、会话恢复 |
| 文件 | SFTP/SCP 全部、内置编辑器、传输队列 |
| 网络 | 端口转发（本地/远程/SOCKS5/HTTP CONNECT）、跳板链、代理 |
| 桌面 | VNC、RDP 全部 |
| 数据 | 保险库（口令目前只在内存）、`.mottybak`、云同步、known_hosts 的删除/重置 |
| AI | Ask/Agent、审批门、MCP |
| 平台 | 后台保活、多窗口/分屏、触控交互范式、i18n 资源 |
| 交付 | 发布签名、上架材料、SBOM、渗透测试 |

## 5. 82 个行为规格的进度

已转译并通过（9）：
`terminal.vt`、`terminal.view`、`terminal.interactive`、`ssh.connect-from-list`、`infra.host-create-by-id`、`host.persist`、`net.reachability`、`ssh.exec`、`ssh.hostkey`


未开始（73）：按 [TRANSFER-PLAN.md](./TRANSFER-PLAN.md) 的 B1–B10 批次推进；B11 的 14 个已判定不转译
（12 个本就是截图素材，3 个已判 T3，其中 1 个重叠）。

## 6. 这 14 轮里最有价值的四个结论

1. **Go 不能在鸿蒙应用内运行**（c-shared 的 musl TLS 失败、子进程 `EACCES`）→ 路线只能走 A′，这不是偏好而是实测结果。
2. **NAPI + C 库这条路是通的**（libssh2 + mbedTLS 静态链），并且 **NAPI 的 `nm_modname` 必须等于 `.so` 文件名主干**，否则 `import` 拿到空模块且**不报错**。
3. **中文输入法会吃掉 `uiInput text` 与 `inputText`**，必须 `keyEvent 2054` 提交组合串再回读校验；`type` 步骤必须声明 `target`。
4. **证据等级必须写进流程**：arm64 全绿之前，任何"真机可用"的说法都是假的。

## 7. 下一步的真实顺序（按依赖，不按愿望）

1. **CJK 之外的字符宽度**：目前是区段近似 + 只覆盖 0x20 以上可打印；组合字符、零宽连接、emoji 序列都会错位。
2. **回滚缓冲 + 备用屏**：没有回滚的终端不可用；这是 B2 批次能继续的前提。
3. **真 pty**：当前对端是 `term-echo` 的"行回显"，不是 shell。要么找 Linux 对端，要么在设备侧解决 pty。
4. **保险库**：口令现在只在内存，进程退出即失；M1-b 必须先做 HUKS/Asset。
5. **B1 剩下 7 个 spec**（证书、ppk、OTP、autofill 等）——它们都需要真实凭据路径，依赖第 4 项。

## 8. 给接手者的三条提醒

- `harmonyos/native/build-thirdparty.ps1` 会重下 99 MB 源码；不要在没网的环境里假设能编。
- `devecocli` 的模拟器实例名**不能含连字符**；换实例后 `rport` 必须重建。
- **PowerShell 里判断外部命令成败不能只看 exit code**（go/git 会把进度写 stderr），要落文件再判读。
