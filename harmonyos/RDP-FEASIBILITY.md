# RDP（FreeRDP）可行性评估

**结论（2026-11-11）**：FreeRDP 目前**不能**以 mbedTLS 后端在 OHOS 上构建；
可行路径只有先交叉编译 OpenSSL，而本机缺 Perl（OpenSSL 构建依赖 Perl + make）。
因此 RDP 仍为**未实现**，本文记录实测证据，避免重复试错。

## 1. 为什么想用 FreeRDP

- 许可 **Apache-2.0**（与本仓库原许可一致，不引入 GPL 义务）
- 上游 Motty 的 `internal/rdpcore` 是 38,410 行自研实现，自研复刻不现实
- FreeRDP 是唯一成熟的 C 实现（客户端 + 服务端 + 通道）

## 2. 试过的路线 A：mbedTLS 后端（不用 OpenSSL）

FreeRDP 的 `docs/README.building.md` 写着支持：

> **MBedTLS** (supported by community, `-DWITH_OPENSSL=OFF -DWITH_MBEDTLS=ON`)

我们已有 OHOS 的 mbedTLS 静态库，所以先试这条。

### 实测过程与结果
| 步骤 | 结果 |
|---|---|
| 3.9.0 配置 `-DWITH_OPENSSL=OFF -DWITH_MBEDTLS=ON` | **失败**：`Could NOT find OpenSSL` |
| 读 `CMakeLists.txt` | `set(OPENSSL_FEATURE_TYPE "REQUIRED")`，`MBEDTLS` 只是 `OPTIONAL`——3.9.0 **不支持**无 OpenSSL |
| 查 master 分支的 CMakeLists | 仍是 `OPENSSL_FEATURE_TYPE "REQUIRED"`（README 与代码不一致） |
| 打补丁（OpenSSL→OPTIONAL，MbedTLS→REQUIRED）后配置 | **成功**（`Found mbed TLS: libmbedtls.a;libmbedcrypto.a;libmbedx509.a`） |
| 编译 | **失败**，两类硬阻塞：①源码无条件 `#include <openssl/...>`（`libfreerdp/utils/http.c`、`crypto/certificate.h`、`crypto/tls.h`）；②`winpr/libwinpr/crypto/cipher.c` 的 mbedTLS 分支本身有编译错误（`use of undeclared identifier 'i'`） |

**判断**：mbedTLS 后端是社区实验分支，源码层面就没法只靠 CMake 开关生效；要让它可编译需要改动 FreeRDP 多个文件——这属于"维护一个 fork"，不是接入。

### 附带解决的一个小问题
配置初期还卡在 `Could NOT find ZLIB`：sysroot 里有 `libz.so` 但 FindZLIB 找不到，
需要显式传 `-DZLIB_LIBRARY=<sysroot>/libz.so -DZLIB_INCLUDE_DIR=<sysroot>/include`。
这条以后编 FreeRDP 仍然需要。

## 3. 路线 B：OpenSSL（推荐，但有前置条件）

| 前置 | 现状 |
|---|---|
| OpenSSL 源码 | 可下载（3.x LTS） |
| **Perl** | **本机没有**。OpenSSL 的 `Configure` 与部分生成步骤是 Perl |
| `make` / `gmake` | 本机没有；Strawberry Perl 便携版自带 `gmake` |

可行步骤（尚未执行）：
1. 下载 **Strawberry Perl 便携版**（免安装，解压即用，同时提供 `perl` 与 `gmake`）
2. `perl Configure linux-x86_64 no-shared no-tests --prefix=...`，用 `CC=clang --target=x86_64-linux-ohos --sysroot=...` 覆盖工具链
3. `gmake -j && gmake install` → 产出 `libcrypto.a` / `libssl.a`（arm64 同法）
4. 回到 FreeRDP：`-DWITH_OPENSSL=ON` + `-DOPENSSL_ROOT_DIR=<prefix>`，其余选项同本轮
5. 才开始 RDP 客户端接入（帧、输入、通道）

## 4. 结论与建议

- **不要**再尝试 mbedTLS-only：源码不支持，改造成本高于收益
- **要**做 RDP 就先做 **OpenSSL 里程碑**（便携 Perl + 双 ABI 静态库），把它当**独立一轮**验证完成，
  再开 FreeRDP 一轮；否则又会变成"一轮内既编译又接入"然后回退（第 28 轮的教训）
- 在此之前，RDP 在能力表里保持 **E3（未验证）**，文档与 spec 都不声称它可用

## 5. 本轮顺带交付

`forward.http` 用例（HTTP CONNECT 动态转发）已在双画像上通过——它实现于第 29 轮但当时未断言，
本轮补齐证据：`200 Connection Established` 与隧道内 `SSH-2.0-` 同时断言。
