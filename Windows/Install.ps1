$ErrorActionPreference = 'Stop'
$taskSource = Join-Path $PSScriptRoot 'DeskSwitch.exe'
if (-not (Test-Path -LiteralPath $taskSource)) { & (Join-Path $PSScriptRoot 'Build.ps1') }
$taskInstall = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.deskswitch'
New-Item -ItemType Directory -Path $taskInstall -Force | Out-Null
$taskTarget = Join-Path $taskInstall 'DeskSwitch.exe'
if (Get-Process -Name DeskSwitch -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId }) {
    throw 'DeskSwitch is already running. Use Exit in its tray menu before updating.'
}
$taskSettings = Join-Path $taskInstall 'goxlr.json'
$taskLegacySettings = Join-Path $env:LOCALAPPDATA 'MSI-DeskSwitch\goxlr.json'
if (-not (Test-Path -LiteralPath $taskSettings) -and (Test-Path -LiteralPath $taskLegacySettings)) {
    Copy-Item -LiteralPath $taskLegacySettings -Destination $taskSettings
}
Copy-Item -LiteralPath $taskSource -Destination $taskTarget -Force
$taskShell = New-Object -ComObject WScript.Shell
$taskShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'MSI DeskSwitch.lnk'
$taskShortcut = $taskShell.CreateShortcut($taskShortcutPath)
$taskShortcut.TargetPath = $taskTarget
$taskShortcut.Arguments = 'tray'
$taskShortcut.WorkingDirectory = $taskInstall
$taskShortcut.Description = 'PageDown: MSI monitor and its KVM to MacBook'
$taskShortcut.Save()
Start-Process -FilePath $taskTarget -ArgumentList 'tray' -WindowStyle Hidden
Write-Output 'Installed. PageDown -> MacBook. Ctrl+Shift+F11 is the backup. Startup enabled.'
