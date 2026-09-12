#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Configure-GoXlrStartup.ps1')
$taskBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$taskFixture = Join-Path $taskBase ('DeskSwitch-startup-tests-' + [Guid]::NewGuid().ToString('N'))
$taskEncoding = New-Object Text.UTF8Encoding($false)
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action) {
    $taskFailed = $false
    try { & $Action | Out-Null } catch { $taskFailed = $true }
    Assert $taskFailed 'Invalid startup configuration was accepted.'
}
try {
    $taskData = Join-Path $taskFixture 'Общий каталог с пробелами'
    [void][IO.Directory]::CreateDirectory($taskData)
    $taskExe = Join-Path $taskData 'goxlr-daemon.exe'
    $taskConfig = Join-Path $taskData 'settings.json'
    $taskMic = Join-Path $taskData 'Selected Mic.goxlrMicProfile'
    $taskLink = Join-Path $taskFixture 'Startup\GoXLR Utility.lnk'
    [IO.File]::WriteAllText($taskExe, 'fixture - never executed', $taskEncoding)
    [IO.File]::WriteAllText((Join-Path $taskData 'Selected.goxlr'), 'main', $taskEncoding)
    [IO.File]::WriteAllText($taskMic, 'mic', $taskEncoding)
    $taskJson = @{profile_directory=$taskData; mic_profile_directory=$taskData; devices=@{TEST=@{profile='Selected'; mic_profile='Selected Mic'}}} | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($taskConfig, $taskJson, $taskEncoding)
    Set-GoXlrStartupShortcut $taskExe $taskConfig $taskLink | Out-Null
    $taskShell = New-Object -ComObject WScript.Shell
    $taskSaved = $taskShell.CreateShortcut($taskLink)
    Assert ($taskSaved.TargetPath -ieq $taskExe) 'Wrong executable in startup.'
    Assert ($taskSaved.Arguments -ceq ('--config "' + $taskConfig + '"')) 'Spaces or Unicode changed the explicit config argument.'
    $taskHash = (Get-FileHash -LiteralPath $taskLink).Hash
    Set-GoXlrStartupShortcut $taskExe $taskConfig $taskLink | Out-Null
    Assert ((Get-FileHash -LiteralPath $taskLink).Hash -ceq $taskHash) 'Repeated setup changed a correct shortcut.'
    Assert ([IO.File]::ReadAllText($taskConfig) -ceq $taskJson) 'Startup setup changed profile settings.'
    $taskSaved.Arguments = ''
    $taskSaved.Save()
    $taskOldHash = (Get-FileHash -LiteralPath $taskLink).Hash
    Set-GoXlrStartupShortcut $taskExe $taskConfig $taskLink | Out-Null
    $taskBackups = @(Get-ChildItem -LiteralPath $taskData -Filter 'startup-before-*.lnk')
    Assert ($taskBackups.Count -eq 1 -and (Get-FileHash -LiteralPath $taskBackups[0].FullName).Hash -ceq $taskOldHash) 'Old startup shortcut was not backed up exactly.'
    $taskGoodHash = (Get-FileHash -LiteralPath $taskLink).Hash
    Remove-Item -LiteralPath $taskMic
    Expect-Failure { Set-GoXlrStartupShortcut $taskExe $taskConfig $taskLink }
    Assert ((Get-FileHash -LiteralPath $taskLink).Hash -ceq $taskGoodHash) 'Missing microphone profile changed startup.'
    [IO.File]::WriteAllText($taskMic, 'mic', $taskEncoding)
    Expect-Failure { Set-GoXlrStartupShortcut (Join-Path $taskFixture 'missing.exe') $taskConfig $taskLink }
    [IO.File]::WriteAllText($taskConfig, '{"devices":{}}', $taskEncoding)
    Expect-Failure { Set-GoXlrStartupShortcut $taskExe $taskConfig $taskLink }
    [IO.File]::WriteAllText($taskConfig, 'broken json', $taskEncoding)
    Expect-Failure { Set-GoXlrStartupShortcut $taskExe $taskConfig $taskLink }
    Assert ((Get-FileHash -LiteralPath $taskLink).Hash -ceq $taskGoodHash) 'Invalid settings changed a valid startup shortcut.'
    Write-Output 'GoXLR startup checks passed (isolated files and shortcut; no apps started or stopped).'
} finally {
    $taskResolved = [IO.Path]::GetFullPath($taskFixture)
    if ([IO.Path]::GetDirectoryName($taskResolved) -ine $taskBase -or [IO.Path]::GetFileName($taskResolved) -notmatch '^DeskSwitch-startup-tests-[0-9a-f]{32}$') { throw 'Refusing cleanup outside the unique fixture.' }
    if (Test-Path -LiteralPath $taskResolved) { Remove-Item -LiteralPath $taskResolved -Recurse -Force }
}
