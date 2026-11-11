# rdp-peer-check.ps1 —— RDP 服务端对端检查（脚本化机器判定）
#
# 为什么单独写：runner 的 --fresh 路径在本机会导致"跑旧二进制"（见 INDEX Round 55-58），
# 而手动序列（force-stop → start → 按 id 点击 → dump）稳定拿到新二进制。
# 本脚本把那条序列固定下来，输出 PASS/FAIL 与退出码，供机器判定。
#
# 用法: pwsh -File harmonyos\tools\rdp-peer-check.ps1 [-Serial 127.0.0.1:10101]
param(
  [string]$Serial = "127.0.0.1:10101",
  [int]$Port = 13389
)
$ErrorActionPreference = "Stop"
$hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$py = "C:\Python315\python.exe"
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dumpPy = Join-Path $PSScriptRoot "rdp-peer-check-dump.py"

& $py $dumpPy --serial $Serial --port $Port --hdc $hdc
exit $LASTEXITCODE
