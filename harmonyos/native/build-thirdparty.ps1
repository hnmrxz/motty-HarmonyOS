# 第三方 C 库交叉编译（mbedTLS + libssh2）
#
# 为什么不用 OpenSSL：OpenSSL 构建依赖 Perl（生成汇编），本机没有 Perl。
# mbedTLS 是纯 C + CMake，交叉编译成本低得多，libssh2 原生支持 mbedTLS 后端。
#
# 为什么要手写 toolchain 文件：NDK 的 *-ohos-clang 是 sh 脚本（170–250 字节），
# Windows 上不可执行，必须直接调 clang.exe 并显式给 -target 与 --sysroot。
#
# 用法：
#   pwsh -File harmonyos/native/build-thirdparty.ps1                 # x86_64（模拟器/PC）
#   pwsh -File harmonyos/native/build-thirdparty.ps1 -Arch arm64     # arm64（真机，需先有 arm64 toolchain 文件）
param(
  [string]$Arch = "x86_64"
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot                                 # harmonyos/native
$harmony = Split-Path -Parent $root                  # harmonyos
$src = Join-Path $root "third_party\src"
$build = Join-Path $root "build"
$prefix = Join-Path $root "third_party\ohos\$Arch"
$cmake = "C:\ohos-ndk\build-tools\cmake\bin\cmake.exe"
$toolchain = Join-Path $root "cmake\ohos-$Arch.cmake"

function EnsureSource {
  # 源码不进仓库（99 MB），首次运行时下载并解压。两个来源都是官方发布包：
  #  - mbedTLS 必须用 releases 的 tar.bz2（GitHub 的 archive/refs 归档缺 framework 子模块）
  #  - libssh2 用其 releases 的 tar.gz
  param([string]$Name, [string]$Url, [string]$Archive, [string]$Dir)
  $src = Join-Path $root "third_party\src"
  New-Item -ItemType Directory -Path $src -Force | Out-Null
  if (Test-Path (Join-Path $src $Dir)) { return }
  $file = Join-Path $src $Archive
  if (-not (Test-Path $file)) {
    Write-Host "  下载 $Archive ..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $file -TimeoutSec 300 -UseBasicParsing
  }
  Push-Location $src
  if ($Archive -like "*.tar.bz2") { tar -xjf $Archive } else { tar -xzf $Archive }
  Pop-Location
  if (-not (Test-Path (Join-Path $src $Dir))) { throw "解压后目录不存在: $Dir" }
}
$env:PATH = "C:\ohos-ndk\build-tools\cmake\bin;" + $env:PATH

if (-not (Test-Path $toolchain)) { throw "缺少 toolchain 文件: $toolchain" }

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

EnsureSource -Name "mbedtls" -Url "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.2/mbedtls-3.6.2.tar.bz2" -Archive "mbedtls-3.6.2.tar.bz2" -Dir "mbedtls-3.6.2"
EnsureSource -Name "libssh2" -Url "https://github.com/libssh2/libssh2/releases/download/libssh2-1.11.1/libssh2-1.11.1.tar.gz" -Archive "libssh2-1.11.1.tar.gz" -Dir "libssh2-1.11.1"

Step "mbedTLS"
$mbBuild = Join-Path $build "mbedtls-$Arch"
& $cmake -S (Join-Path $src "mbedtls-3.6.2") -B $mbBuild -G Ninja `
  "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
  -DCMAKE_BUILD_TYPE=Release -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF `
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON `
  "-DCMAKE_INSTALL_PREFIX=$prefix"
if ($LASTEXITCODE -ne 0) { throw "mbedTLS configure 失败" }
& $cmake --build $mbBuild --target install
if ($LASTEXITCODE -ne 0) { throw "mbedTLS build 失败" }

Step "libssh2（mbedTLS 后端、静态）"
$lsBuild = Join-Path $build "libssh2-$Arch"
& $cmake -S (Join-Path $src "libssh2-1.11.1") -B $lsBuild -G Ninja `
  "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
  -DCMAKE_BUILD_TYPE=Release -DCRYPTO_BACKEND=mbedTLS `
  -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF `
  "-DMBEDTLS_INCLUDE_DIR=$prefix/include" `
  "-DMBEDCRYPTO_LIBRARY=$prefix/lib/libmbedcrypto.a" `
  "-DCMAKE_INSTALL_PREFIX=$prefix"
if ($LASTEXITCODE -ne 0) { throw "libssh2 configure 失败" }
& $cmake --build $lsBuild --target install
if ($LASTEXITCODE -ne 0) { throw "libssh2 build 失败" }

Step "产物"
Get-ChildItem (Join-Path $prefix "lib") -File | Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize

Write-Host "`n完成（$Arch）。应用侧通过 externalNativeOptions.arguments 传入 -DOHOS_SSH_ROOT=<harmonyos/native/third_party/ohos>，CMake 会按 OHOS_ARCH 自动选 x86_64 或 arm64 子目录。" -ForegroundColor Green
