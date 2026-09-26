$ErrorActionPreference = 'Stop'
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $taskCompiler /nologo /target:winexe /optimize+ /utf8output /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll "/out:$PSScriptRoot\DeskSwitch.exe" "$PSScriptRoot\DeskSwitch.cs" "$PSScriptRoot\PageDownKey.cs" "$PSScriptRoot\PageDownHook.cs" "$PSScriptRoot\WheelRepair.cs" "$PSScriptRoot\GoXlrAudio.cs" "$PSScriptRoot\HeadphonesOverlay.cs"
if ($LASTEXITCODE -ne 0) { throw 'DeskSwitch build failed.' }
$taskDist = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'
New-Item -ItemType Directory -Path $taskDist -Force | Out-Null
$taskZip = Join-Path $taskDist 'DeskSwitch-Windows.zip'
Compress-Archive -LiteralPath (Join-Path $PSScriptRoot 'DeskSwitch.exe'), (Join-Path $PSScriptRoot 'Install.ps1'), (Join-Path $PSScriptRoot 'Install.cmd'), (Join-Path $PSScriptRoot 'Export-GoXlrProfiles.cmd'), (Join-Path $PSScriptRoot 'Export-GoXlrProfiles.ps1'), (Join-Path $PSScriptRoot 'Import-GoXlrProfiles.cmd'), (Join-Path $PSScriptRoot 'Import-GoXlrProfiles.ps1'), (Join-Path $PSScriptRoot 'Export-AudioSetup.cmd'), (Join-Path $PSScriptRoot 'Export-AudioSetup.ps1'), (Join-Path $PSScriptRoot 'OBS-GoXLR.md'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'LICENSE'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'THIRD_PARTY.md') -DestinationPath $taskZip -Force
Compress-Archive -LiteralPath (Join-Path $PSScriptRoot 'Configure-GoXlrStartup.cmd'), (Join-Path $PSScriptRoot 'Configure-GoXlrStartup.ps1'), (Join-Path $PSScriptRoot 'GoXlrStartupShortcut.cs'), (Join-Path $PSScriptRoot 'MX-Master-3S.md') -DestinationPath $taskZip -Update
Write-Output "Created: $taskZip"
