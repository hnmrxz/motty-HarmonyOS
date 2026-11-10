# build-freerdp.ps1 —— 为 OHOS 交叉编译 FreeRDP 静态库（RDP 前置）
#
# 前置：先跑 native/build-openssl.ps1（FreeRDP 的源码无条件 include <openssl/*>，
# mbedTLS 后端编不过——见 harmonyos/RDP-FEASIBILITY.md）。
#
# 本脚本固化的坑（每条都实测踩过）：
#   1. 不要打"OpenSSL 改 OPTIONAL"的补丁：走 OpenSSL 时保持上游默认 REQUIRED 即可
#   2. `WITH_ABSOLUTE_PLUGIN_LOAD_PATHS=OFF`：否则 FREERDP_INSTALL_PREFIX 里的
#      `E:\...\ohos\...` 反斜杠会变成非法转义 `\o`，编译直接报
#      "expected '{' after '\o' escape sequence"
#   3. 只构建库目标（freerdp / winpr / freerdp-client）：示例可执行文件
#      `client/Sample/sfreerdp` 会因 musl 缺 pthread_cancel 链接失败
#   4. 头文件要三份合起来：源码 include/ + 源码 winpr/include/ + **构建目录生成的
#      winpr 头**（wtypes.h / build-config.h / buildflags.h 是生成物，源码里没有）
#   5. 产物用 `cmake --install` 会带一堆额外步骤，直接手工拷贝更可靠
#   6. 应用侧链接时必须提供 pthread_cancel 桩（musl 未实现 TerminateThread 所需符号）
#
# 用法：pwsh -File native/build-freerdp.ps1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cmake = 'C:\ohos-ndk\build-tools\cmake\bin\cmake.exe'
$ninja = 'C:\ohos-ndk\build-tools\cmake\bin\ninja.exe'
$src = Join-Path $root 'third_party\src\FreeRDP'
$zlibLib = 'C:/ohos-ndk/sysroot/usr/lib/x86_64-linux-ohos/libz.so'
$zlibInc = 'C:/ohos-ndk/sysroot/usr/include'

if (-not (Test-Path $src)) { throw "缺少 FreeRDP 源码：$src" }

# 确认没有残留的 mbedTLS 补丁（有的话先还原）
Push-Location $src
try { & git checkout -- CMakeLists.txt 2>&1 | Out-Null } finally { Pop-Location }

foreach ($arch in @(
        @{ name = 'x86_64'; triple = 'x86_64-linux-ohos'; tc = 'ohos-x86_64.cmake'; zlib = 'x86_64-linux-ohos' },
        @{ name = 'arm64'; triple = 'aarch64-linux-ohos'; tc = 'ohos-arm64.cmake'; zlib = 'aarch64-linux-ohos' })) {
    $p = "E:/motty-HarmonyOS/harmonyos/native/third_party/ohos/$($arch.name)"
    $bld = Join-Path $root "build/freerdp-$($arch.name)"
    $tcPath = Join-Path $root "cmake/$($arch.tc)"
    $zlib = "C:/ohos-ndk/sysroot/usr/lib/$($arch.zlib)/libz.so"
    if (-not (Test-Path $zlib)) { $zlib = $zlibLib }

    Write-Host "=== FreeRDP [$($arch.name)] ==="
    Remove-Item -Recurse -Force $bld -ErrorAction SilentlyContinue
    & $cmake -S $src -B $bld -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" "-DCMAKE_TOOLCHAIN_FILE=$tcPath" `
        -DCMAKE_BUILD_TYPE=Release "-DCMAKE_INSTALL_PREFIX=$p" `
        "-DZLIB_LIBRARY=$zlib" "-DZLIB_INCLUDE_DIR=$zlibInc" `
        "-DOPENSSL_ROOT_DIR=$p" "-DOPENSSL_INCLUDE_DIR=$p/include" `
        "-DOPENSSL_CRYPTO_LIBRARY=$p/lib/libcrypto.a" "-DOPENSSL_SSL_LIBRARY=$p/lib/libssl.a" `
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DWITH_ABSOLUTE_PLUGIN_LOAD_PATHS=OFF `
        -DWITH_OPENSSL=ON -DWITH_MBEDTLS=OFF `
        -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON `
        -DWITH_KRB5=OFF -DWITH_PCSC=OFF -DWITH_PKCS11=OFF -DWITH_CUPS=OFF `
        -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF `
        -DWITH_FUSE=OFF -DWITH_SWSCALE=OFF -DWITH_CAIRO=OFF -DWITH_FFMPEG=OFF -DWITH_OPENH264=OFF `
        -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_SDL3=OFF -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF `
        -DWITH_JSON_DISABLED=ON -DWITH_UNICODE_BUILTIN=ON -DCHANNEL_URBDRC=OFF -DCHANNEL_RDPEWA=OFF `
        "-DCMAKE_PREFIX_PATH=$p" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "configure 失败 [$($arch.name)]" }

    # 只编库，避开示例可执行文件的 pthread_cancel 链接问题
    & $cmake --build $bld --target freerdp winpr freerdp-client | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "build 失败 [$($arch.name)]" }

    $libDst = Join-Path $root "third_party/ohos/$($arch.name)/lib"
    $incDst = Join-Path $root "third_party/ohos/$($arch.name)/include"
    New-Item -ItemType Directory -Path $libDst, $incDst -Force | Out-Null
    Get-ChildItem $bld -Recurse -Filter '*.a' |
        Where-Object { $_.Name -match 'freerdp|winpr' } |
        ForEach-Object { Copy-Item $_.FullName $libDst -Force }
    Copy-Item (Join-Path $src 'include/freerdp') $incDst -Recurse -Force
    Copy-Item (Join-Path $src 'winpr/include/winpr') $incDst -Recurse -Force
    # 生成的 winpr 头（wtypes.h / build-config.h / buildflags.h）
    Copy-Item (Join-Path $bld 'winpr/include/winpr/*') (Join-Path $incDst 'winpr') -Force
    Get-ChildItem $libDst -Filter '*freerdp*.a' | ForEach-Object {
        Write-Host ("  {0}: {1:N1} MB" -f $_.Name, ($_.Length / 1MB))
    }
}
Write-Host '完成：libfreerdp3.a / libfreerdp-client3.a / libwinpr3.a + 头文件已就位'
Write-Host '提醒：应用侧链接需要 pthread_cancel 桩（musl 未实现）'
