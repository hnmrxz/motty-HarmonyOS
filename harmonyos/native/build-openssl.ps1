# build-openssl.ps1 —— 为 OHOS 交叉编译 OpenSSL（RDP / FreeRDP 的前置）
#
# 为什么需要：FreeRDP 的源码在 crypto/tls.h 等文件里**无条件** include <openssl/*>，
# mbedTLS 后端是社区实验分支、编不过（见 harmonyos/docs/RDP.md）。
# 所以 RDP 要落地，必须先有 OHOS 版 OpenSSL。
#
# 本脚本把这一路上踩到的坑都固化下来，任何一条都不能省：
#   1. 本机没有 Perl —— 用便携版 Strawberry Perl（解压到 .bin/tools/perl）
#   2. OpenSSL 的 unix-checker.pm 会因 Windows Perl 产出反斜杠路径而 die -> 打补丁跳过
#   3. 汇编生成(perlasm)在 Windows 下跑不通 -> no-asm
#   4. `rm -f` 在 sh 下会把反斜杠路径吃掉 -> 强制 SHELL=cmd.exe，并提供一个 rm.bat 兜底
#   5. 直接 make libcrypto.a 会因缺少生成的头文件失败 -> 先 build_generated
#   6. install_sw 在 sh 下会因反斜杠路径失败 -> 手工拷贝 libs/headers 到前缀目录
#
# 用法：pwsh -File native/build-openssl.ps1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$tools = Join-Path (Split-Path $root -Parent) '.bin\tools'
$perlDir = Join-Path $tools 'perl'
$perl = Join-Path $perlDir 'perl\bin\perl.exe'
$gmake = Join-Path $perlDir 'c\bin\gmake.exe'
$fakeUnix = Join-Path $tools 'fakeunix'
$src = Join-Path $root 'third_party\src\openssl-3.0.15'
$ndk = 'C:/ohos-ndk'

if (-not (Test-Path $perl)) { throw "缺少便携版 Perl：$perl（解压 strawberry-perl-portable.zip 到 $perlDir）" }
if (-not (Test-Path $src))  { throw "缺少 OpenSSL 源码：$src" }

# rm.bat：cmd.exe 下模拟 rm -f
New-Item -ItemType Directory -Path $fakeUnix -Force | Out-Null
@"
@echo off
for %%A in (%*) do (
  if not "%%A"=="-f" if not "%%A"=="-rf" del /q "%%A" 2>nul
)
exit /b 0
"@ | Set-Content -Encoding ASCII (Join-Path $fakeUnix 'rm.bat')

$env:PATH = "$fakeUnix;C:\ohos-ndk\llvm\bin;$perlDir\c\bin;$perlDir\perl\bin;" + $env:PATH

foreach ($arch in @(
        @{ name = 'x86_64'; target = 'linux-x86_64'; cc = 'x86_64-linux-ohos' },
        @{ name = 'arm64'; target = 'linux-aarch64'; cc = 'aarch64-linux-ohos' })) {
    $prefix = "E:/motty-HarmonyOS/harmonyos/native/third_party/ohos/$($arch.name)"
    Write-Host "=== OpenSSL [$($arch.name)] ==="
    Push-Location $src
    try {
        & $gmake clean 2>&1 | Out-Null
        & $perl Configure $arch.target no-shared no-tests no-engine no-module no-asm `
            "--prefix=$prefix" "--openssldir=$prefix/ssl" `
            "CC=clang --target=$($arch.cc) --sysroot=$ndk/sysroot -D__MUSL__ -fPIC" `
            'AR=llvm-ar' 'RANLIB=llvm-ranlib' 'NM=llvm-nm' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "configure 失败 [$($arch.name)]" }
        & $gmake -j4 'SHELL=cmd.exe' build_generated | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "build_generated 失败 [$($arch.name)]" }
        & $gmake -j4 'SHELL=cmd.exe' libcrypto.a libssl.a | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "libs 构建失败 [$($arch.name)]" }
        $libDst = Join-Path $root "third_party\ohos\$($arch.name)\lib"
        $incDst = Join-Path $root "third_party\ohos\$($arch.name)\include"
        New-Item -ItemType Directory -Path $libDst, $incDst -Force | Out-Null
        Copy-Item (Join-Path $src 'libcrypto.a'), (Join-Path $src 'libssl.a') $libDst -Force
        Copy-Item (Join-Path $src 'include\openssl') $incDst -Recurse -Force
        Get-ChildItem $libDst -Filter 'lib*ssl*.a' | ForEach-Object {
            Write-Host ("  {0}: {1:N1} MB" -f $_.Name, ($_.Length / 1MB))
        }
    }
    finally { Pop-Location }
}
Write-Host '完成：libcrypto.a / libssl.a + 头文件已就位（第三方产物不入库，见 .gitignore）'
