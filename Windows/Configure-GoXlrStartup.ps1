#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$UtilityExe = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local\Programs\GoXLR Utility\goxlr-daemon.exe'),
    [string]$UtilityConfigPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.deskswitch\GoXLR-Utility\settings.json'),
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Startup')) 'GoXLR Utility.lnk')
)
$ErrorActionPreference = 'Stop'
$script:GoXlrStartupSource = Join-Path $PSScriptRoot 'GoXlrStartupShortcut.cs'

function Get-GoXlrStartupArguments([string]$UtilityConfigPath) {
    $taskConfig = [IO.Path]::GetFullPath($UtilityConfigPath)
    if ($taskConfig -match '["\x00-\x1f]' -or -not (Test-Path -LiteralPath $taskConfig -PathType Leaf)) { throw 'Укажи существующий settings.json Utility.' }
    if ((Get-Item -LiteralPath $taskConfig).Length -gt 2097152) { throw 'settings.json превышает 2 МБ.' }
    $taskSettings = Get-Content -LiteralPath $taskConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($taskSettings -isnot [Management.Automation.PSCustomObject] -or
        $taskSettings.devices -isnot [Management.Automation.PSCustomObject] -or
        @($taskSettings.devices.PSObject.Properties).Count -eq 0) { throw 'Сначала перенеси и выбери профили GoXLR.' }
    foreach ($taskDevice in $taskSettings.devices.PSObject.Properties) {
        foreach ($taskPair in @(@('profile_directory','profile','.goxlr'), @('mic_profile_directory','mic_profile','.goxlrMicProfile'))) {
            $taskDirectory = $taskSettings.($taskPair[0])
            $taskName = $taskDevice.Value.($taskPair[1])
            if ($taskDirectory -isnot [string] -or -not [IO.Path]::IsPathRooted($taskDirectory) -or
                $taskName -isnot [string] -or [string]::IsNullOrWhiteSpace($taskName) -or
                $taskName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $taskName -in @('.', '..')) {
                throw 'В settings.json нужны абсолютные каталоги и выбранные имена обоих профилей.'
            }
            $taskProfile = Join-Path $taskDirectory ($taskName + $taskPair[2])
            if (-not (Test-Path -LiteralPath $taskProfile -PathType Leaf) -or (Get-Item -LiteralPath $taskProfile).Length -eq 0) {
                throw "Не найден выбранный профиль: $taskProfile. Автозапуск не изменён."
            }
        }
    }
    return '--config "' + $taskConfig + '"'
}

function Set-GoXlrStartupShortcut([string]$UtilityExe, [string]$UtilityConfigPath, [string]$ShortcutPath) {
    $taskArguments = Get-GoXlrStartupArguments $UtilityConfigPath
    $taskExe = [IO.Path]::GetFullPath($UtilityExe)
    if ([IO.Path]::GetFileName($taskExe) -ine 'goxlr-daemon.exe' -or -not (Test-Path -LiteralPath $taskExe -PathType Leaf)) {
        throw 'Не найден goxlr-daemon.exe. Установи GoXLR Utility или передай -UtilityExe с её полным путём.'
    }
    $taskLink = [IO.Path]::GetFullPath($ShortcutPath)
    if ([IO.Path]::GetExtension($taskLink) -ine '.lnk') { throw 'Ярлык должен иметь расширение .lnk.' }
    if (-not ('DeskSwitch.GoXlrStartupShortcut' -as [type])) { Add-Type -Path $script:GoXlrStartupSource }
    if (Test-Path -LiteralPath $taskLink) {
        $taskOld = [DeskSwitch.GoXlrStartupShortcut]::Read($taskLink)
        if ($taskOld[0] -ieq $taskExe -and $taskOld[1] -ceq $taskArguments) {
            Write-Output "Автозапуск уже использует выбранный конфиг: $taskLink"
            return
        }
        $taskBackup = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($UtilityConfigPath))) ('startup-before-' + [Guid]::NewGuid().ToString('N') + '.lnk')
        Copy-Item -LiteralPath $taskLink -Destination $taskBackup
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $taskLink))
    [DeskSwitch.GoXlrStartupShortcut]::Write($taskLink, $taskExe, $taskArguments)
    $taskCheck = [DeskSwitch.GoXlrStartupShortcut]::Read($taskLink)
    if ($taskCheck[0] -ine $taskExe -or $taskCheck[1] -cne $taskArguments) { throw 'Не удалось проверить сохранённый ярлык.' }
    Write-Output "Автозапуск настроен. Для первого запуска открой: $taskLink"
    Write-Output 'Если Utility уже работает с другим конфигом, закрой её через меню и открой этот ярлык. Профили и работающие программы помощник не меняет.'
}

if ($MyInvocation.InvocationName -ne '.') {
    Set-GoXlrStartupShortcut -UtilityExe $UtilityExe -UtilityConfigPath $UtilityConfigPath -ShortcutPath $ShortcutPath
}
