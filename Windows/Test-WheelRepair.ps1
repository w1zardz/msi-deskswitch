$ErrorActionPreference = 'Stop'
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$taskTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$taskTemp = [IO.Path]::GetFullPath((Join-Path $taskTempRoot ('DeskSwitch-Wheel-tests-' + [Guid]::NewGuid().ToString('N'))))
if (-not $taskTemp.StartsWith($taskTempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid test directory.' }
New-Item -ItemType Directory -Path $taskTemp | Out-Null
try {
    $taskExe = Join-Path $taskTemp 'WheelRepairTests.exe'
    & $taskCompiler /nologo /target:exe /optimize+ /utf8output "/out:$taskExe" "$PSScriptRoot\WheelRepair.cs" "$PSScriptRoot\WheelRepairTests.cs"
    if ($LASTEXITCODE -ne 0) { throw 'Wheel protocol test build failed.' }
    & $taskExe
    if ($LASTEXITCODE -ne 0) { throw 'Wheel protocol tests failed.' }
} finally {
    Remove-Item -LiteralPath $taskTemp -Recurse -Force
}
