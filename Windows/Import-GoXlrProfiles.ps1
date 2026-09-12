#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'GoXLR-Import.json'),
    [string]$UtilityConfigPath = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'GoXLR-on-Linux\GoXLR-Utility\config\settings.json'),
    [string]$UtilityDataPath = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'GoXLR-on-Linux\GoXLR-Utility\data'),
    [string]$DeskSwitchConfigPath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MSI-DeskSwitch\goxlr.json')
)
$ErrorActionPreference = 'Stop'

function Assert-ImportProcessesStopped {
    $taskBlocked = @(Get-Process -ErrorAction Stop | Where-Object {
        $_.ProcessName -in @('GoXLR App', 'GoXLR Beta App', 'goxlr-daemon', 'goxlr-launcher', 'goxlr-utility-ui', 'DeskSwitch')
    })
    if ($taskBlocked.Count -gt 0) {
        throw ('Сначала закрой через меню: ' + (($taskBlocked.ProcessName | Select-Object -Unique) -join ', ') + '. Затем запусти импорт снова. Процессы не завершались.')
    }
}

function Assert-ImportPath([string]$Path) {
    $taskFull = [IO.Path]::GetFullPath($Path)
    if ($taskFull.StartsWith('\\')) { throw 'Для переноса выбери локальный диск Windows.' }
    $taskCurrent = $taskFull
    while (-not (Test-Path -LiteralPath $taskCurrent)) {
        $taskCurrent = [IO.Path]::GetDirectoryName($taskCurrent)
        if ([string]::IsNullOrEmpty($taskCurrent)) { throw "Путь недоступен: $Path" }
    }
    $taskItem = Get-Item -LiteralPath $taskCurrent -Force
    while ($null -ne $taskItem) {
        if (($taskItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Путь содержит ссылку или junction: $Path" }
        if ($taskItem -is [IO.FileInfo]) { $taskItem = $taskItem.Directory } else { $taskItem = $taskItem.Parent }
    }
    return $taskFull
}

function Assert-ImportBackup([string]$Path) {
    [void](Assert-ImportPath $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $taskBackupItem = Get-Item -LiteralPath $Path
        if ($taskBackupItem -isnot [IO.FileInfo] -or $taskBackupItem.Length -le 0 -or $taskBackupItem.Length -gt 2097152) { throw 'Invalid backup size.' }
        $taskBackupObject = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($taskBackupObject -isnot [Management.Automation.PSCustomObject]) { throw 'Invalid backup JSON object.' }
    } catch { throw "Резервная копия DeskSwitch повреждена: $Path. Настройки DeskSwitch не заменены; сначала сохрани и проверь этот файл вручную." }
}

function Get-ImportHash([byte[]]$Bytes) {
    $taskHash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($taskHash.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $taskHash.Dispose() }
}

function Get-ImportText($Object, [string]$Name) {
    $taskValue = $Object.$Name
    if ($taskValue -isnot [string] -or [string]::IsNullOrWhiteSpace($taskValue)) { throw "В manifest отсутствует строка $Name." }
    return $taskValue
}

function Assert-ImportProfileName([string]$Name) {
    if ($Name.Length -gt 150 -or $Name -ne $Name.Trim() -or $Name.EndsWith('.') -or $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $Name -in @('.', '..') -or $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
        throw "Неподходящее имя профиля: $Name"
    }
}

function Read-ImportEntry($Archive, [string]$EntryName, [string]$ExpectedHash) {
    $taskEntries = @($Archive.Entries | Where-Object { $_.FullName -ceq $EntryName })
    if ($taskEntries.Count -ne 1 -or $taskEntries[0].Length -le 0 -or $taskEntries[0].Length -gt 16777216) {
        throw "В ZIP должен быть один непустой профиль: $EntryName (до 16 МБ)."
    }
    $taskInput = $taskEntries[0].Open()
    $taskBuffer = New-Object byte[] 81920
    $taskMemory = New-Object IO.MemoryStream
    try {
        while (($taskCount = $taskInput.Read($taskBuffer, 0, $taskBuffer.Length)) -gt 0) {
            if ($taskMemory.Length + $taskCount -gt 16777216) { throw 'Профиль превышает 16 МБ.' }
            $taskMemory.Write($taskBuffer, 0, $taskCount)
        }
        $taskBytes = $taskMemory.ToArray()
        if ((Get-ImportHash $taskBytes) -cne $ExpectedHash) { throw "SHA256 профиля не совпал: $EntryName. Ничего не применено." }
        return ,$taskBytes
    } finally { $taskInput.Dispose(); $taskMemory.Dispose() }
}

function Invoke-GoXlrProfileImport {
    param(
        [Parameter(Mandatory=$true)][string]$ManifestPath,
        [Parameter(Mandatory=$true)][string]$UtilityConfigPath,
        [Parameter(Mandatory=$true)][string]$UtilityDataPath,
        [Parameter(Mandatory=$true)][string]$DeskSwitchConfigPath
    )
    Assert-ImportProcessesStopped
    $taskManifestPath = Assert-ImportPath $ManifestPath
    if ((Get-Item -LiteralPath $taskManifestPath).Length -gt 65536) { throw 'Manifest слишком большой.' }
    $taskManifest = Get-Content -LiteralPath $taskManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($taskManifest -isnot [Management.Automation.PSCustomObject]) { throw 'Manifest должен быть JSON-объектом.' }
    $taskSerial = Get-ImportText $taskManifest 'Serial'
    if ($taskSerial.Length -gt 256 -or $taskSerial -match '[\x00-\x1f]' -or $taskSerial -ne $taskSerial.Trim()) { throw 'Некорректный serial в manifest.' }
    $taskPort = $taskManifest.Port
    if (($taskPort -isnot [int] -and $taskPort -isnot [long]) -or $taskPort -lt 1 -or $taskPort -gt 65535) { throw 'Port должен быть целым числом 1–65535.' }
    if ($taskPort -ne 14564) { throw 'Этот перенос использует штатный запуск Utility на порту 14564. Другой порт требует отдельной настройки запуска Utility.' }
    $taskMainName = Get-ImportText $taskManifest 'MainProfileName'
    $taskMicName = Get-ImportText $taskManifest 'MicProfileName'
    Assert-ImportProfileName $taskMainName
    Assert-ImportProfileName $taskMicName
    $taskMainEntry = Get-ImportText $taskManifest 'MainEntry'
    $taskMicEntry = Get-ImportText $taskManifest 'MicEntry'
    if ([IO.Path]::GetFileName($taskMainEntry) -cne ($taskMainName + '.goxlr') -or
        [IO.Path]::GetFileName($taskMicEntry) -ine ($taskMicName + '.goxlrMicProfile')) { throw 'Имена выбранных файлов и профилей в manifest не совпадают.' }
    foreach ($taskKey in @('ArchiveSha256', 'MainSha256', 'MicSha256')) {
        if ((Get-ImportText $taskManifest $taskKey) -cnotmatch '^[0-9a-f]{64}$') { throw "Некорректный SHA256: $taskKey" }
    }
    $taskArchiveName = Get-ImportText $taskManifest 'ArchiveFile'
    if ([IO.Path]::IsPathRooted($taskArchiveName) -or [IO.Path]::GetFileName($taskArchiveName) -ne $taskArchiveName) { throw 'ArchiveFile должен указывать имя ZIP рядом с manifest.' }
    $taskZipPath = Assert-ImportPath (Join-Path (Split-Path -Parent $taskManifestPath) $taskArchiveName)
    if ((Get-Item -LiteralPath $taskZipPath).Length -gt 67108864) { throw 'ZIP превышает 64 МБ.' }
    $taskZipBytes = [IO.File]::ReadAllBytes($taskZipPath)
    if ((Get-ImportHash $taskZipBytes) -cne $taskManifest.ArchiveSha256) { throw 'SHA256 ZIP не совпал. Используй архив, который был проверен вместе с manifest.' }
    Add-Type -AssemblyName System.IO.Compression
    $taskZipStream = New-Object IO.MemoryStream(,$taskZipBytes)
    $taskArchive = New-Object IO.Compression.ZipArchive($taskZipStream, [IO.Compression.ZipArchiveMode]::Read, $false)
    try {
        $taskMainBytes = Read-ImportEntry $taskArchive $taskMainEntry $taskManifest.MainSha256
        $taskMicBytes = Read-ImportEntry $taskArchive $taskMicEntry $taskManifest.MicSha256
    } finally { $taskArchive.Dispose(); $taskZipStream.Dispose() }

    $taskConfigPath = Assert-ImportPath $UtilityConfigPath
    $taskDataPath = Assert-ImportPath $UtilityDataPath
    $taskDeskPath = Assert-ImportPath $DeskSwitchConfigPath
    $taskProfilesPath = Join-Path $taskDataPath 'profiles'
    $taskMicsPath = Join-Path $taskDataPath 'mic-profiles'
    $taskDeviceSettings = [ordered]@{}
    $taskDeviceSettings[$taskSerial] = [ordered]@{profile=$taskMainName; mic_profile=$taskMicName; shutdown_commands=@(); sleep_commands=@(); wake_commands=@()}
    $taskUtilitySettings = [ordered]@{allow_network_access=$false; profile_directory=$taskProfilesPath; mic_profile_directory=$taskMicsPath; devices=$taskDeviceSettings}
    $taskEncoding = New-Object Text.UTF8Encoding($false)
    $taskConfigBytes = $taskEncoding.GetBytes(($taskUtilitySettings | ConvertTo-Json -Depth 12) + "`n")
    $taskDeskOriginal = $null
    if (Test-Path -LiteralPath $taskDeskPath) {
        if ((Get-Item -LiteralPath $taskDeskPath).Length -gt 2097152) { throw 'Настройки DeskSwitch превышают 2 МБ.' }
        $taskDeskOriginal = [IO.File]::ReadAllBytes($taskDeskPath)
        $taskDeskSettings = $taskEncoding.GetString($taskDeskOriginal).TrimStart([char]0xfeff) | ConvertFrom-Json
        if ($taskDeskSettings -isnot [Management.Automation.PSCustomObject]) { throw 'Настройки DeskSwitch повреждены; файл сохранён без изменений.' }
    } else { $taskDeskSettings = New-Object PSObject }
    $taskDeskSettings | Add-Member -MemberType NoteProperty -Name Enabled -Value $true -Force
    $taskDeskSettings | Add-Member -MemberType NoteProperty -Name Serial -Value $taskSerial -Force
    $taskDeskSettings | Add-Member -MemberType NoteProperty -Name Port -Value ([int]$taskPort) -Force
    $taskDeskBytes = $taskEncoding.GetBytes(($taskDeskSettings | ConvertTo-Json -Depth 32) + "`n")
    $taskBackupPath = Assert-ImportPath (Join-Path (Split-Path -Parent $taskDeskPath) 'goxlr.before-profile-import.json')
    Assert-ImportBackup $taskBackupPath

    $taskWrites = New-Object 'Collections.Generic.List[object]'
    $taskWrites.Add(@{Path=(Join-Path $taskProfilesPath ($taskMainName + '.goxlr')); Bytes=$taskMainBytes})
    $taskWrites.Add(@{Path=(Join-Path $taskMicsPath ($taskMicName + '.goxlrMicProfile')); Bytes=$taskMicBytes})
    if ($taskMainName -ine 'Default') { $taskWrites.Add(@{Path=(Join-Path $taskProfilesPath 'Default.goxlr'); Bytes=$taskMainBytes}) }
    if ($taskMicName -ine 'DEFAULT') { $taskWrites.Add(@{Path=(Join-Path $taskMicsPath 'DEFAULT.goxlrMicProfile'); Bytes=$taskMicBytes}) }
    # Utility settings are last, after all startup profile copies exist.
    $taskWrites.Add(@{Path=$taskConfigPath; Bytes=$taskConfigBytes})
    foreach ($taskWrite in $taskWrites) {
        [void](Assert-ImportPath $taskWrite.Path)
        if (Test-Path -LiteralPath $taskWrite.Path) {
            if ((Get-Item -LiteralPath $taskWrite.Path).Length -gt 16777216 -or
                (Get-ImportHash ([IO.File]::ReadAllBytes($taskWrite.Path))) -cne (Get-ImportHash $taskWrite.Bytes)) {
                throw "Уже существует другой файл: $($taskWrite.Path). Он не заменён. Если Utility уже настроена, выбери в ней эти профили вручную; этот помощник предназначен для первого переноса."
            }
        }
    }
    Assert-ImportProcessesStopped
    if ($null -ne $taskDeskOriginal -and (Get-ImportHash ([IO.File]::ReadAllBytes($taskDeskPath))) -cne (Get-ImportHash $taskDeskOriginal)) { throw 'Настройки DeskSwitch изменились во время подготовки; повтори импорт.' }
    if ($null -eq $taskDeskOriginal -and (Test-Path -LiteralPath $taskDeskPath)) { throw 'Настройки DeskSwitch появились во время подготовки; повтори импорт.' }

    # No archives are extracted as directories: only these exact, hash-verified files are copied.
    foreach ($taskWrite in $taskWrites) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $taskWrite.Path))
        [void](Assert-ImportPath $taskWrite.Path)
        if (Test-Path -LiteralPath $taskWrite.Path) {
            if ((Get-ImportHash ([IO.File]::ReadAllBytes($taskWrite.Path))) -cne (Get-ImportHash $taskWrite.Bytes)) { throw 'Файл появился или изменился во время переноса; повтори импорт.' }
        } else {
            $taskStage = $taskWrite.Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            try {
                [IO.File]::WriteAllBytes($taskStage, $taskWrite.Bytes)
                [IO.File]::Move($taskStage, $taskWrite.Path)
            } finally { if (Test-Path -LiteralPath $taskStage) { Remove-Item -LiteralPath $taskStage } }
        }
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $taskDeskPath))
    Assert-ImportBackup $taskBackupPath
    if ($null -ne $taskDeskOriginal -and -not (Test-Path -LiteralPath $taskBackupPath)) {
        $taskBackupStage = $taskBackupPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllBytes($taskBackupStage, $taskDeskOriginal)
            [IO.File]::Move($taskBackupStage, $taskBackupPath)
        } finally { if (Test-Path -LiteralPath $taskBackupStage) { Remove-Item -LiteralPath $taskBackupStage } }
    }
    Assert-ImportBackup $taskBackupPath
    $taskTemporary = $taskDeskPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($taskTemporary, $taskDeskBytes)
        [void](Assert-ImportPath $taskDeskPath)
        if ($null -ne $taskDeskOriginal -and (Get-ImportHash ([IO.File]::ReadAllBytes($taskDeskPath))) -cne (Get-ImportHash $taskDeskOriginal)) { throw 'Настройки DeskSwitch изменились; сохранена подготовленная Utility, конфигурация DeskSwitch не заменена.' }
        if ($null -ne $taskDeskOriginal) { [IO.File]::Replace($taskTemporary, $taskDeskPath, $null) }
        else { [IO.File]::Move($taskTemporary, $taskDeskPath) }
    } finally { if (Test-Path -LiteralPath $taskTemporary) { Remove-Item -LiteralPath $taskTemporary } }
    Write-Host "Профили готовы: $taskMainName / $taskMicName. GoXLR: $taskSerial."
    Write-Host 'Теперь запусти GoXLR Utility, затем MSI DeskSwitch. Вращение меняет Headphones; нажатие твоей ручки остаётся Delete.'
    Write-Host 'Оригинальный GoXLR App, его драйвер и профили не изменены. Не запускай GoXLR App одновременно с Utility.'
}

# Dot sourcing only defines functions for isolated tests; running the script performs the import.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-GoXlrProfileImport -ManifestPath $ManifestPath -UtilityConfigPath $UtilityConfigPath -UtilityDataPath $UtilityDataPath -DeskSwitchConfigPath $DeskSwitchConfigPath
}
