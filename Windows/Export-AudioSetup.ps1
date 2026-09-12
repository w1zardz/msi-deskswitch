#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ObsRoot = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'obs-studio'),
    [string]$DeskSwitchRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MSI-DeskSwitch'),
    [string]$OutputPath,
    [string]$ProfileName,
    [string]$SceneCollectionName,
    [string]$MixerSerial,
    [Nullable[int]]$UtilityPort,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'

# This exporter never starts applications, applies audio settings, or reads service/websocket files.
function Assert-AudioPath([string]$Path, [string]$Root) {
    $taskFull = [IO.Path]::GetFullPath($Path)
    $taskRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($taskFull.StartsWith('\\') -or ($taskFull -ine $taskRoot -and -not $taskFull.StartsWith($taskRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) { throw 'Путь находится вне выбранной локальной папки.' }
    $taskCurrent = $taskFull
    while (-not (Test-Path -LiteralPath $taskCurrent)) {
        $taskCurrent = [IO.Path]::GetDirectoryName($taskCurrent)
        if ([string]::IsNullOrEmpty($taskCurrent)) { throw 'Папка недоступна.' }
    }
    $taskItem = Get-Item -LiteralPath $taskCurrent -Force
    while ($null -ne $taskItem) {
        if (($taskItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Ссылки и junction не читаются: выбери исходную папку.' }
        if ($taskItem -is [IO.FileInfo]) { $taskItem = $taskItem.Directory } else { $taskItem = $taskItem.Parent }
    }
    return $taskFull
}

function Read-AudioText([string]$Path, [string]$Root, [long]$Limit = 1048576) {
    $taskPath = Assert-AudioPath $Path $Root
    $taskItem = Get-Item -LiteralPath $taskPath
    if ($taskItem -isnot [IO.FileInfo] -or $taskItem.Length -gt $Limit) { throw 'Файл настроек недоступен или слишком большой.' }
    return [IO.File]::ReadAllText($taskPath, [Text.Encoding]::UTF8).TrimStart([char]0xfeff)
}

function Select-AudioFields($Object, [string[]]$TextKeys = @(), [string[]]$NumberKeys = @(), [string[]]$BoolKeys = @()) {
    $taskResult = [ordered]@{}
    foreach ($taskKey in $TextKeys) {
        $taskValue = $Object.$taskKey
        if ($taskValue -is [string] -and $taskValue.Length -le 512) { $taskResult[$taskKey] = $taskValue }
    }
    foreach ($taskKey in $NumberKeys) {
        $taskValue = $Object.$taskKey
        if ($null -ne $taskValue -and [Type]::GetTypeCode($taskValue.GetType()) -in @([TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16, [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64, [TypeCode]::Single, [TypeCode]::Double, [TypeCode]::Decimal)) {
            if (-not [double]::IsNaN([double]$taskValue) -and -not [double]::IsInfinity([double]$taskValue)) { $taskResult[$taskKey] = $taskValue }
        }
    }
    foreach ($taskKey in $BoolKeys) { if ($Object.$taskKey -is [bool]) { $taskResult[$taskKey] = $Object.$taskKey } }
    return $taskResult
}

function Read-AudioIni([string]$Path, [string]$Root, $Allowed) {
    $taskResult = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $taskResult }
    $taskSection = ''
    foreach ($taskLine in ((Read-AudioText $Path $Root) -split '\r?\n')) {
        if ($taskLine -match '^\s*\[([^\]]+)\]\s*$') { $taskSection = $Matches[1]; continue }
        if (-not $Allowed.Contains($taskSection) -or $taskLine -notmatch '^\s*([^=;#]+?)\s*=(.*)$') { continue }
        $taskKey = $Matches[1].Trim(); $taskValue = $Matches[2].Trim()
        if ($taskKey -notin $Allowed[$taskSection] -or $taskValue.Length -gt 512) { continue }
        if (-not $taskResult.Contains($taskSection)) { $taskResult[$taskSection] = [ordered]@{} }
        $taskResult[$taskSection][$taskKey] = $taskValue
    }
    return $taskResult
}

function Get-AudioSetupProcesses {
    $taskNames = @(Get-Process -ErrorAction Stop | Select-Object -ExpandProperty ProcessName)
    return [ordered]@{
        DeskSwitch = ('DeskSwitch' -in $taskNames)
        GoXlrUtility = ('goxlr-daemon' -in $taskNames)
        OfficialGoXlrApp = (@($taskNames | Where-Object { $_ -in @('GoXLR App', 'GoXLR Beta App') }).Count -gt 0)
        Obs = (@($taskNames | Where-Object { $_ -in @('obs64', 'obs32') }).Count -gt 0)
    }
}

function Get-AudioApiTimeLeft([Diagnostics.Stopwatch]$Clock) {
    $taskRemaining = 3000 - $Clock.ElapsedMilliseconds
    if ($taskRemaining -le 0) { throw 'Utility API deadline exceeded.' }
    return [int]$taskRemaining
}

function Get-AudioSetupUtilityStatus([int]$Port) {
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'Некорректный порт Utility.' }
    $taskClock = [Diagnostics.Stopwatch]::StartNew()
    # Fixed loopback address, selected port, no proxy/redirects, read-only bounded GetStatus.
    $taskRequest = [Net.HttpWebRequest]::Create(('http://127.0.0.1:' + $Port + '/api/command'))
    $taskRequest.Proxy = $null; $taskRequest.AllowAutoRedirect = $false
    $taskRequest.Timeout = 3000; $taskRequest.ReadWriteTimeout = 3000
    $taskRequest.Method = 'POST'; $taskRequest.ContentType = 'application/json'
    $taskBytes = [Text.Encoding]::UTF8.GetBytes('"GetStatus"')
    $taskRequest.ContentLength = $taskBytes.Length
    $taskStream = $taskRequest.GetRequestStream()
    try {
        if (-not $taskStream.CanTimeout) { throw 'Utility stream does not support bounded writes.' }
        $taskStream.WriteTimeout = Get-AudioApiTimeLeft $taskClock
        $taskStream.Write($taskBytes, 0, $taskBytes.Length)
    } finally { $taskStream.Dispose() }
    [void](Get-AudioApiTimeLeft $taskClock)
    $taskResponse = $taskRequest.GetResponse()
    try {
        if ([int]$taskResponse.StatusCode -ne 200) { throw 'Utility API unavailable.' }
        $taskStream = $taskResponse.GetResponseStream(); $taskMemory = New-Object IO.MemoryStream
        try {
            if (-not $taskStream.CanTimeout) { throw 'Utility stream does not support bounded reads.' }
            $taskBuffer = New-Object byte[] 81920
            while ($true) {
                $taskStream.ReadTimeout = Get-AudioApiTimeLeft $taskClock
                $taskCount = $taskStream.Read($taskBuffer, 0, $taskBuffer.Length)
                if ($taskCount -eq 0) { break }
                if ($taskMemory.Length + $taskCount -gt 4194304) { throw 'Utility response too large.' }
                $taskMemory.Write($taskBuffer, 0, $taskCount)
            }
            return ([Text.Encoding]::UTF8.GetString($taskMemory.ToArray()) | ConvertFrom-Json)
        } finally { $taskStream.Dispose(); $taskMemory.Dispose() }
    } finally { $taskResponse.Dispose() }
}

function Select-AudioUtilityStatus($Response, [string]$Serial) {
    $taskResult = [ordered]@{ Available = $false; Selection = 'api-unavailable'; Mixers = @() }
    if ($null -eq $Response.Status.mixers -or $Response.Status.mixers -isnot [Management.Automation.PSCustomObject]) { return $taskResult }
    $taskResult.Available = $true
    $taskAvailable = @($Response.Status.mixers.PSObject.Properties.Name | Where-Object { $_.Length -le 256 })
    $taskResult.AvailableSerials = $taskAvailable
    if ([string]::IsNullOrWhiteSpace($Serial)) { $taskResult.Selection = 'serial-not-selected'; return $taskResult }
    if ($Serial -cnotin $taskAvailable) { $taskResult.Selection = 'selected-serial-not-connected'; return $taskResult }
    $taskMixer = $Response.Status.mixers.$Serial
    $taskSelected = Select-AudioFields $taskMixer @('profile_name', 'mic_profile_name')
    $taskSelected.Serial = $Serial
    $taskSelected.Volumes = Select-AudioFields $taskMixer.levels.volumes @() @('Mic', 'LineIn', 'Console', 'System', 'Game', 'Chat', 'Sample', 'Music', 'Headphones', 'MicMonitor', 'LineOut')
    $taskSelected.Router = [ordered]@{}
    foreach ($taskInput in @('Microphone', 'Chat', 'Music', 'Game', 'Console', 'LineIn', 'System', 'Samples')) {
        $taskRoutes = Select-AudioFields $taskMixer.router.$taskInput @() @() @('Headphones', 'BroadcastMix', 'ChatMic', 'Sampler', 'LineOut', 'StreamMix2')
        if ($taskRoutes.Count -gt 0) { $taskSelected.Router[$taskInput] = $taskRoutes }
    }
    $taskResult.Selection = 'explicit-serial'; $taskResult.Mixers = @($taskSelected)
    return $taskResult
}

function Select-AudioObsSource($Source, [string]$Slot) {
    $taskId = $Source.id
    if ($taskId -notin @('wasapi_input_capture', 'wasapi_output_capture', 'wasapi_process_output_capture')) { return $null }
    $taskResult = Select-AudioFields $Source @('name', 'id', 'versioned_id') @('volume', 'mixers', 'monitoring_type', 'balance') @('muted', 'enabled')
    if (-not [string]::IsNullOrEmpty($Slot)) { $taskResult.GlobalSlot = $Slot }
    $taskSync = Select-AudioFields $Source @() @('sync', 'sync_offset')
    if ($taskSync.Contains('sync')) { $taskResult.sync_offset_ns = $taskSync.sync }
    elseif ($taskSync.Contains('sync_offset')) { $taskResult.sync_offset_ns = $taskSync.sync_offset }
    $taskResult.settings = Select-AudioFields $Source.settings @('device_id') @('priority') @('use_device_timing')
    # OBS's window string also contains a window title. Export only an executable basename.
    if ($taskId -eq 'wasapi_process_output_capture' -and $Source.settings.window -is [string]) {
        $taskExe = ($Source.settings.window -split ':')[-1]
        if ($taskExe -match '^[^\\/:*?"<>|\x00-\x1f]{1,128}\.exe$') { $taskResult.settings.process_executable = $taskExe }
    }
    $taskFilterNumbers = @{
        gain_filter = @('db')
        compressor_filter = @('ratio', 'threshold', 'attack_time', 'release_time', 'output_gain')
        limiter_filter = @('threshold', 'release_time')
        noise_gate_filter = @('open_threshold', 'close_threshold', 'attack_time', 'hold_time', 'release_time')
        noise_suppress_filter = @('suppress_level')
        expander_filter = @('ratio', 'threshold', 'attack_time', 'release_time', 'output_gain', 'knee_width')
        upward_compressor_filter = @('ratio', 'threshold', 'attack_time', 'release_time', 'output_gain', 'knee_width')
        basic_eq_filter = @('low', 'mid', 'high')
        invert_polarity_filter = @()
    }
    $taskFilters = New-Object 'Collections.Generic.List[object]'
    foreach ($taskFilter in @($Source.filters)) {
        if ($null -eq $taskFilter) { continue }
        $taskClean = Select-AudioFields $taskFilter @('name', 'id', 'versioned_id') @() @('enabled')
        if ($taskFilter.id -is [string] -and $taskFilterNumbers.ContainsKey($taskFilter.id)) {
            $taskClean.settings = Select-AudioFields $taskFilter.settings @() $taskFilterNumbers[$taskFilter.id]
            foreach ($taskEnum in @(@{Key='method'; Values=@('speex','rnnoise')}, @{Key='detector'; Values=@('RMS','peak')}, @{Key='presets'; Values=@('expander','gate')})) {
                if ($taskFilter.id -in @('noise_suppress_filter','expander_filter','upward_compressor_filter') -and $taskFilter.settings.($taskEnum.Key) -in $taskEnum.Values) { $taskClean.settings[$taskEnum.Key] = $taskFilter.settings.($taskEnum.Key) }
            }
        }
        $taskFilters.Add($taskClean)
    }
    $taskResult.filters = @($taskFilters.ToArray())
    return $taskResult
}

function Select-AudioObsOtherSource($Source) {
    if ($Source.id -in @('wasapi_input_capture', 'wasapi_output_capture', 'wasapi_process_output_capture')) { return $null }
    $taskLevels = Select-AudioFields $Source @() @('volume', 'mixers', 'monitoring_type', 'balance') @('muted', 'enabled')
    if ($taskLevels.Count -eq 0) { return $null }
    $taskResult = Select-AudioFields $Source @('name', 'id', 'versioned_id')
    foreach ($taskKey in $taskLevels.Keys) { $taskResult[$taskKey] = $taskLevels[$taskKey] }
    $taskSync = Select-AudioFields $Source @() @('sync', 'sync_offset')
    if ($taskSync.Contains('sync')) { $taskResult.sync_offset_ns = $taskSync.sync }
    elseif ($taskSync.Contains('sync_offset')) { $taskResult.sync_offset_ns = $taskSync.sync_offset }
    if ($Source.id -eq 'game_capture' -and $Source.settings.capture_audio -is [bool]) { $taskResult.capture_audio = $Source.settings.capture_audio }
    # Metadata only: these may be video/scene sources, not necessarily active audio feeds.
    return $taskResult
}

function Select-AudioObsItem([object[]]$Items, [string]$Explicit, [string]$ConfiguredFile, [string]$ConfiguredName, [string]$Title, [bool]$Interactive) {
    if ($Items.Count -eq 0) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        $taskMatches = @($Items | Where-Object { $_.Key -ceq $Explicit -or $_.Name -ceq $Explicit })
        if ($taskMatches.Count -eq 1) { return $taskMatches[0] }
        throw "Не найден однозначный выбор: $Title. Укажи имя из списка: $(($Items.Key) -join ', ')."
    }
    foreach ($taskMatchBy in @('Key', 'Name')) {
        $taskWanted = if ($taskMatchBy -eq 'Key') { $ConfiguredFile } else { $ConfiguredName }
        if (-not [string]::IsNullOrWhiteSpace($taskWanted)) {
            $taskMatches = @($Items | Where-Object { $_.$taskMatchBy -ceq $taskWanted })
            if ($taskMatches.Count -eq 1) { return $taskMatches[0] }
        }
    }
    if ($Items.Count -eq 1) { return $Items[0] }
    if (-not $Interactive) { throw "Нужен явный выбор: $Title. Доступно: $(($Items.Key) -join ', ')." }
    Add-Type -AssemblyName System.Windows.Forms
    $taskForm = New-Object Windows.Forms.Form
    $taskForm.Text = $Title; $taskForm.Width = 560; $taskForm.Height = 340; $taskForm.StartPosition = 'CenterScreen'
    $taskList = New-Object Windows.Forms.ListBox
    $taskList.Left = 15; $taskList.Top = 15; $taskList.Width = 510; $taskList.Height = 220
    foreach ($taskItem in $Items) { [void]$taskList.Items.Add(($taskItem.Name + ' [' + $taskItem.Key + ']')) }
    $taskButton = New-Object Windows.Forms.Button
    $taskButton.Text = 'Выбрать'; $taskButton.Left = 405; $taskButton.Top = 245; $taskButton.Width = 120
    $taskButton.Add_Click({ if ($taskList.SelectedIndex -ge 0) { $taskForm.DialogResult = [Windows.Forms.DialogResult]::OK; $taskForm.Close() } })
    $taskForm.Controls.Add($taskList); $taskForm.Controls.Add($taskButton)
    try {
        if ($taskForm.ShowDialog() -ne [Windows.Forms.DialogResult]::OK -or $taskList.SelectedIndex -lt 0) { throw 'Выбор отменён. Отчёт не создан.' }
        return $Items[$taskList.SelectedIndex]
    } finally { $taskForm.Dispose() }
}

function Get-AudioObsSetup([string]$Root, [string]$Profile, [string]$Collection, [bool]$Interactive) {
    $taskResult = [ordered]@{ InstalledConfiguration = (Test-Path -LiteralPath $Root); Sources = @(); OtherSources = @() }
    if (-not $taskResult.InstalledConfiguration) { return $taskResult }
    [void](Assert-AudioPath $Root $Root)
    $taskSelectionPath = Join-Path $Root 'user.ini'
    if (-not (Test-Path -LiteralPath $taskSelectionPath)) { $taskSelectionPath = Join-Path $Root 'global.ini' }
    $taskSelection = Read-AudioIni $taskSelectionPath $Root ([ordered]@{Basic=@('Profile', 'ProfileDir', 'SceneCollection', 'SceneCollectionFile')})
    $taskResult.SavedSelection = $taskSelection.Basic
    $taskProfiles = New-Object 'Collections.Generic.List[object]'
    $taskProfileRoot = Join-Path $Root 'basic/profiles'
    if (Test-Path -LiteralPath $taskProfileRoot) {
        [void](Assert-AudioPath $taskProfileRoot $Root)
        foreach ($taskDir in @(Get-ChildItem -LiteralPath $taskProfileRoot -Directory)) {
            [void](Assert-AudioPath $taskDir.FullName $Root)
            $taskBasic = Join-Path $taskDir.FullName 'basic.ini'
            if (-not (Test-Path -LiteralPath $taskBasic)) { continue }
            $taskName = (Read-AudioIni $taskBasic $Root ([ordered]@{General=@('Name')})).General.Name
            if ([string]::IsNullOrEmpty($taskName)) { $taskName = $taskDir.Name }
            $taskProfiles.Add([pscustomobject]@{Key=$taskDir.Name; Name=$taskName; Path=$taskBasic})
        }
    }
    $taskChosen = Select-AudioObsItem @($taskProfiles.ToArray()) $Profile $taskSelection.Basic.ProfileDir $taskSelection.Basic.Profile 'Профиль OBS' $Interactive
    if ($null -ne $taskChosen) {
        $taskResult.Profile = [ordered]@{Name=$taskChosen.Name; Directory=$taskChosen.Key}
        $taskResult.Profile.AudioAndRecording = Read-AudioIni $taskChosen.Path $Root ([ordered]@{
            Output=@('Mode')
            SimpleOutput=@('RecQuality', 'RecFormat', 'RecFormat2', 'RecTracks')
            AdvOut=@('RecType', 'RecFormat', 'RecFormat2', 'RecTracks', 'TrackIndex', 'VodTrackIndex', 'VodTrackEnabled', 'FFAudioTrack', 'FFAudioMixes')
            Audio=@('SampleRate', 'ChannelSetup', 'MonitoringDeviceId', 'MonitoringDeviceName')
        })
    }
    $taskCollections = New-Object 'Collections.Generic.List[object]'
    $taskSceneRoot = Join-Path $Root 'basic/scenes'
    if (Test-Path -LiteralPath $taskSceneRoot) {
        [void](Assert-AudioPath $taskSceneRoot $Root)
        foreach ($taskFile in @(Get-ChildItem -LiteralPath $taskSceneRoot -File -Filter '*.json')) {
            [void](Assert-AudioPath $taskFile.FullName $Root)
            $taskCollections.Add([pscustomobject]@{Key=$taskFile.BaseName; Name=$taskFile.BaseName; Path=$taskFile.FullName})
        }
    }
    $taskChosen = Select-AudioObsItem @($taskCollections.ToArray()) $Collection $taskSelection.Basic.SceneCollectionFile $taskSelection.Basic.SceneCollection 'Коллекция сцен OBS (имя файла)' $Interactive
    if ($null -ne $taskChosen) {
        try { $taskScene = Read-AudioText $taskChosen.Path $Root 33554432 | ConvertFrom-Json } catch { throw 'Не удалось прочитать выбранную коллекцию OBS. Никакие настройки не изменены.' }
        if ($taskScene -isnot [Management.Automation.PSCustomObject]) { throw 'Выбранная коллекция OBS не является JSON-объектом.' }
        $taskResult.SceneCollection = [ordered]@{File=$taskChosen.Key}
        if ($taskScene.name -is [string] -and $taskScene.name.Length -le 512) { $taskResult.SceneCollection.Name = $taskScene.name }
        $taskSources = New-Object 'Collections.Generic.List[object]'
        foreach ($taskSlot in @('DesktopAudioDevice1', 'DesktopAudioDevice2', 'AuxAudioDevice1', 'AuxAudioDevice2', 'AuxAudioDevice3', 'AuxAudioDevice4')) {
            $taskSource = Select-AudioObsSource $taskScene.$taskSlot $taskSlot
            if ($null -ne $taskSource) { $taskSources.Add($taskSource) }
        }
        $taskOtherSources = New-Object 'Collections.Generic.List[object]'
        foreach ($taskRawSource in @($taskScene.sources)) {
            $taskSource = Select-AudioObsSource $taskRawSource ''
            if ($null -ne $taskSource) { $taskSources.Add($taskSource) }
            $taskOther = Select-AudioObsOtherSource $taskRawSource
            if ($null -ne $taskOther) { $taskOtherSources.Add($taskOther) }
        }
        $taskResult.Sources = @($taskSources.ToArray())
        $taskResult.OtherSources = @($taskOtherSources.ToArray())
    }
    return $taskResult
}

function Export-AudioSetup {
    param(
        [Parameter(Mandatory=$true)][string]$ObsRoot,
        [Parameter(Mandatory=$true)][string]$DeskSwitchRoot,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [string]$ProfileName, [string]$SceneCollectionName, [string]$MixerSerial,
        [Nullable[int]]$UtilityPort,
        [switch]$Interactive
    )
    $taskOutput = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $taskOutput) { throw 'Файл отчёта уже существует. Выбери другое имя.' }
    [void](Assert-AudioPath $taskOutput (Split-Path -Parent $taskOutput))
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $taskOutput) -PathType Container)) { throw 'Папка для отчёта не существует.' }
    $taskDesk = [ordered]@{Installed=$false; Config=[ordered]@{}}
    $taskExe = Join-Path $DeskSwitchRoot 'DeskSwitch.exe'
    if (Test-Path -LiteralPath $taskExe -PathType Leaf) {
        $taskDesk.Path = Assert-AudioPath $taskExe $DeskSwitchRoot
        $taskDesk.Installed = $true
        $taskDesk.Version = [Diagnostics.FileVersionInfo]::GetVersionInfo($taskDesk.Path).FileVersion
    }
    $taskConfiguredPort = $null; $taskHasConfiguredPort = $false
    $taskConfig = Join-Path $DeskSwitchRoot 'goxlr.json'
    if (Test-Path -LiteralPath $taskConfig) {
        try {
            $taskRaw = Read-AudioText $taskConfig $DeskSwitchRoot | ConvertFrom-Json
            if ($taskRaw -isnot [Management.Automation.PSCustomObject]) { throw 'Invalid DeskSwitch object.' }
            $taskHasConfiguredPort = ('Port' -in @($taskRaw.PSObject.Properties.Name))
            $taskConfiguredPort = $taskRaw.Port
            $taskDesk.Config = Select-AudioFields $taskRaw @('Serial') @('Port') @('Enabled')
        }
        catch { $taskDesk.ConfigReadError = 'configuration-unreadable' }
    }
    if ([string]::IsNullOrWhiteSpace($MixerSerial)) { $MixerSerial = $taskDesk.Config.Serial }
    $taskPort = 14564
    if ($null -ne $UtilityPort) { $taskPort = [int]$UtilityPort }
    elseif ($taskHasConfiguredPort) {
        $taskValue = $taskConfiguredPort
        if ($taskValue -isnot [int] -and $taskValue -isnot [long]) { throw 'Порт в настройках DeskSwitch должен быть целым числом.' }
        $taskPort = $taskValue
    }
    if ($taskPort -lt 1 -or $taskPort -gt 65535) { throw 'Порт Utility должен быть от 1 до 65535.' }
    $taskProcesses = Get-AudioSetupProcesses
    $taskObs = Get-AudioObsSetup $ObsRoot $ProfileName $SceneCollectionName $Interactive.IsPresent
    if ($taskDesk.ConfigReadError -and $null -eq $UtilityPort) {
        $taskUtility = [ordered]@{Available=$false; Selection='deskswitch-config-unreadable'; Mixers=@(); Port=$null}
    } else {
        try { $taskUtility = Select-AudioUtilityStatus (Get-AudioSetupUtilityStatus $taskPort) $MixerSerial }
        catch { $taskUtility = [ordered]@{Available=$false; Selection='api-unavailable'; Mixers=@()} }
        $taskUtility.Port = $taskPort
    }
    $taskReport = [ordered]@{SchemaVersion=1; CapturedAtUtc=[DateTime]::UtcNow.ToString('o'); Processes=$taskProcesses; DeskSwitch=$taskDesk; GoXlrUtility=$taskUtility; Obs=$taskObs}
    $taskBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($taskReport | ConvertTo-Json -Depth 16) + "`n")
    $taskFile = [IO.File]::Open($taskOutput, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $taskFile.Write($taskBytes, 0, $taskBytes.Length) } finally { $taskFile.Dispose() }
    Write-Host 'Готово: только аудионастройки. Звук и приложения не изменены.'
    Write-Host $taskOutput
    Write-Host 'Прикрепи этот JSON вручную в чат. Скрипт ничего никуда не отправляет.'
    return $taskOutput
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $taskDesktop = [Environment]::GetFolderPath('Desktop')
        $taskBase = 'DeskSwitch-Audio-' + (Get-Date -Format 'yyyy-MM-dd-HHmmss')
        $OutputPath = Join-Path $taskDesktop ($taskBase + '.json')
        if (Test-Path -LiteralPath $OutputPath) { $OutputPath = Join-Path $taskDesktop ($taskBase + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json') }
    }
    Export-AudioSetup -ObsRoot $ObsRoot -DeskSwitchRoot $DeskSwitchRoot -OutputPath $OutputPath -ProfileName $ProfileName -SceneCollectionName $SceneCollectionName -MixerSerial $MixerSerial -UtilityPort $UtilityPort -Interactive:(-not $NonInteractive)
}
