# build-libvnc.ps1 —— 交叉编译 LibVNC client 到 OHOS（x86_64 / arm64）
#
# 为什么需要它：整包现在按 GPLv3 组合分发（见 harmonyos/LICENSING.md），
# GPL 要求"可复现的完整对应源码"——所以第三方库的编译必须是脚本，不能是手工命令。
#
# 只编 client（libvncclient.a）：本工程不用 LibVNC 的服务端。
# 关闭 TLS/JPEG/PNG/SASL/LZO/ZSTD，保留 zlib（系统 libz），
# 这样初始阶段只多出 VNC Auth；TLS/VeNCrypt 需要 OpenSSL/GnuTLS，后续再评估。
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cmake = 'C:\ohos-ndk\build-tools\cmake\bin\cmake.exe'
$ninja = 'C:\ohos-ndk\build-tools\cmake\bin\ninja.exe'
$src = Join-Path $root 'third_party\src\libvncserver'

if (-not (Test-Path $src)) {
    Write-Host "缺少 LibVNC 源码：$src"
    Write-Host "请先执行：git clone --depth 1 https://github.com/LibVNC/libvncserver.git native/third_party/src/libvncserver"
    exit 1
}

foreach ($arch in @('x86_64', 'arm64')) {
    $tc = Join-Path $root "cmake\ohos-$arch.cmake"
    $bld = Join-Path $root "build\libvnc-$arch"
    $inst = Join-Path $root "third_party\ohos\$arch"
    Write-Host "=== LibVNC [$arch] ==="
    & $cmake -S $src -B $bld -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" "-DCMAKE_TOOLCHAIN_FILE=$tc" `
        -DCMAKE_BUILD_TYPE=Release "-DCMAKE_INSTALL_PREFIX=$inst" `
        -DBUILD_SHARED_LIBS=OFF `
        -DWITH_OPENSSL=OFF -DWITH_GCRYPT=OFF -DWITH_GNUTLS=OFF `
        -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_ZLIB=ON -DWITH_ZSTD=OFF `
        -DWITH_SASL=OFF -DWITH_LZO=OFF -DWITH_LIBSSH2=OFF `
        -DLIBVNCSERVER_BUILD_TESTS=OFF -DLIBVNCSERVER_INSTALL=ON | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "configure 失败 [$arch]" }
    & $cmake --build $bld | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "build 失败 [$arch]" }
    & $cmake --install $bld | Out-Null
    Get-ChildItem (Join-Path $inst 'lib') -Filter '*vnc*' |
        ForEach-Object { Write-Host ("  {0}: {1:N1} KB" -f $_.Name, ($_.Length / 1KB)) }
}
Write-Host "完成：libvncclient.a 已安装到 third_party/ohos/<arch>/lib"
