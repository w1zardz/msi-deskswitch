$ErrorActionPreference = 'Stop'
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $taskCompiler /nologo /target:winexe /optimize+ /utf8output /r:System.Windows.Forms.dll /r:System.Drawing.dll "/out:$PSScriptRoot\DeskSwitch.exe" "$PSScriptRoot\DeskSwitch.cs" "$PSScriptRoot\WheelRepair.cs"
if ($LASTEXITCODE -ne 0) { throw 'DeskSwitch build failed.' }
