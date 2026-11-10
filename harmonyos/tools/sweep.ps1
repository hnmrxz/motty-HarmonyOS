# 全量回归驱动：按 spec 需要选择夹具模式（VNC Auth vs None），逐条跑并记录矩阵
param(
  [string]$Serial = "127.0.0.1:10101",
  [string]$Profile = "tablet",
  [string]$OutDir = "harmonyos/spec/runs/sweep-tablet"
)
$ErrorActionPreference = "Continue"
$repo = "E:\motty-HarmonyOS"
$hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$exe = Join-Path $repo "harmonyos\.bin\sshfixture.exe"
$key = Join-Path $repo "harmonyos\.bin\.sshfixture\hostkey"
New-Item -ItemType Directory -Path (Join-Path $repo $OutDir) -Force | Out-Null

# 需要 VNC Auth 的两条（其余走 None）
$authSpecs = @("vnc.auth-hextile", "vnc.negative")

$specs = Get-ChildItem (Join-Path $repo "harmonyos\spec\scenarios") -Filter "*.yaml" | Sort-Object Name
$matrix = @()
foreach ($sp in $specs) {
    $name = [IO.Path]::GetFileNameWithoutExtension($sp.Name)
    $mode = if ($authSpecs -contains $name) { "auth" } else { "none" }

    Get-Process sshfixture -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 400
    $args = @("-addr", "127.0.0.1:2223", "-hostkey", $key, "-hostkeytype", "rsa")
    if ($mode -eq "auth") { $args += @("-vnc-auth", "secret") }
    Start-Process -FilePath $exe -ArgumentList $args -RedirectStandardOutput (Join-Path $repo "harmonyos\.bin\sshfixture.log") -RedirectStandardError (Join-Path $repo "harmonyos\.bin\sshfixture.err") -WindowStyle Hidden
    Start-Sleep -Milliseconds 1200

    # 每次重建 rport（模拟器切换或长时间后可能失效）
    & $hdc -t $Serial rport tcp:2222 tcp:2223 2>&1 | Out-Null
    & $hdc -t $Serial rport tcp:5901 tcp:5901 2>&1 | Out-Null

    $out = Join-Path $repo ($OutDir + "\" + $name)
    $r = & C:\Python315\python.exe (Join-Path $repo "harmonyos\spec\run.py") $sp.FullName --serial $Serial --profile $Profile --fresh --out $out 2>&1
    $passed = (($r -join " ") -match '"passed": true')
    $err = ($r | Select-String '"error"').Line
    $matrix += [pscustomobject]@{ spec = $name; fixture = $mode; passed = $passed; error = ($err -replace '^\s+"error":\s*','').Trim('"') }
    "{0,-26} {1,-5} {2}" -f $name, $mode, $(if ($passed) { "PASS" } else { "FAIL" })
}
$matrix | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 (Join-Path $repo "harmonyos\spec\runs\matrix-$Profile.json")
"=== 总计: {0} / 通过: {1} ===" -f $matrix.Count, ($matrix | Where-Object passed).Count
