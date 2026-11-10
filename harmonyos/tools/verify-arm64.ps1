# verify-arm64.ps1 —— 真机（arm64）全量验证
#
# 与 sweep.ps1 的区别：这是**真机**流程，必须显式给 -Serial（不接受默认模拟器序列号）。
# 设备不存在 / 是模拟器序列号 / 签名装不上时，**明确报错退出**，绝不假装通过。
param(
  [Parameter(Mandatory = $true)][string]$Serial,
  [string]$OutDir = "harmonyos/spec/runs/device",
  [string]$Matrix = "harmonyos/spec/matrix/matrix-device.json"
)
$ErrorActionPreference = "Stop"
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$hap = Join-Path $repo "harmonyos\ohos\app\entry\build\default\outputs\default\entry-default-signed.hap"
$exe = Join-Path $repo "harmonyos\.bin\sshfixture.exe"
$key = Join-Path $repo "harmonyos\.bin\.sshfixture\hostkey"

# 1) 目标必须是真机，不能是模拟器的 127.0.0.1:1010x
$targets = (& $hdc list targets 2>&1) -join " "
if ($targets -notmatch [regex]::Escape($Serial)) {
    [Console]::Error.WriteLine("设备 $Serial 不在 hdc list targets 中（当前：$targets）。真机需开启 USB 调试。")
    exit 3
}
if ($Serial -match '^127\.0\.0\.1:1010') {
    [Console]::Error.WriteLine("序列号 $Serial 看起来是模拟器。真机验证必须用真机序列号；模拟器请用 tools/sweep.ps1。")
    exit 4
}
if (-not (Test-Path $hap)) {
    [Console]::Error.WriteLine("缺少 HAP：$hap（先在 harmonyos\ohos\app 跑 devecocli build）")
    exit 5
}

# 2) 安装
$install = (& $hdc -t $Serial install -r $hap 2>&1) -join " "
Write-Host "install: $install"
if ($install -notmatch 'AppMod finish|success') {
    [Console]::Error.WriteLine("安装失败（真机需带该设备 UDID 的签名 Profile）：$install")
    exit 6
}

# 3) 端口转发 + 夹具
& $hdc -t $Serial rport tcp:2222 tcp:2223 | Out-Null
& $hdc -t $Serial rport tcp:5901 tcp:5901 | Out-Null
& $hdc -t $Serial rport tcp:2297 tcp:2297 | Out-Null
Get-Process sshfixture -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400
Start-Process -FilePath $exe -ArgumentList @("-addr", "127.0.0.1:2223", "-hostkey", $key, "-hostkeytype", "rsa") `
  -RedirectStandardOutput (Join-Path $repo "harmonyos\.bin\sshfixture.log") `
  -RedirectStandardError (Join-Path $repo "harmonyos\.bin\sshfixture.err") -WindowStyle Hidden
Start-Sleep -Milliseconds 1500

# 4) 逐条执行（夹具模式映射与 sweep 一致）
$authSpecs = @("vnc.auth-hextile", "vnc.negative")
$resizeSpecs = @("vnc.desktopsize", "vnc.adapt")
$specs = Get-ChildItem (Join-Path $repo "harmonyos\spec\scenarios") -Filter "*.yaml" | Sort-Object Name
$rows = @()
foreach ($sp in $specs) {
    $name = [IO.Path]::GetFileNameWithoutExtension($sp.Name)
    Get-Process sshfixture -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
    $fargs = @("-addr", "127.0.0.1:2223", "-hostkey", $key, "-hostkeytype", "rsa")
    if ($authSpecs -contains $name) { $fargs += @("-vnc-auth", "secret") }
    if ($resizeSpecs -contains $name) { $fargs += @("-vnc-resize") }
    Start-Process -FilePath $exe -ArgumentList $fargs `
      -RedirectStandardOutput (Join-Path $repo "harmonyos\.bin\sshfixture.log") `
      -RedirectStandardError (Join-Path $repo "harmonyos\.bin\sshfixture.err") -WindowStyle Hidden
    Start-Sleep -Milliseconds 1000
    & $hdc -t $Serial rport tcp:2222 tcp:2223 | Out-Null
    & $hdc -t $Serial rport tcp:5901 tcp:5901 | Out-Null
    & $hdc -t $Serial rport tcp:2297 tcp:2297 | Out-Null

    $out = Join-Path $repo ($OutDir + "\" + $name)
    $log = & C:\Python315\python.exe (Join-Path $repo "harmonyos\spec\run.py") $sp.FullName `
        --serial $Serial --profile device --fresh --out $out 2>&1
    $passed = (($log -join " ") -match '"passed": true')
    $err = ($log | Select-String '"error"').Line
    $rows += [pscustomobject]@{ spec = $name; passed = $passed
        error = ($err -replace '^\s+"error":\s*', '').Trim('"') }
    "{0,-26} {1}" -f $name, $(if ($passed) { "PASS" } else { "FAIL" })
}

# 5) 矩阵与判据
New-Item -ItemType Directory -Path (Split-Path (Join-Path $repo $Matrix) -Parent) -Force | Out-Null
$rows | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 (Join-Path $repo $Matrix)
$total = $rows.Count; $ok = ($rows | Where-Object passed).Count
Write-Host "=== 真机结果: $ok / $total （判据要求全部通过）==="
if ($ok -ne $total) { exit 1 }
exit 0
