#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Export-AudioSetup.ps1')
$taskTemp = Join-Path ([IO.Path]::GetTempPath()) ('DeskSwitch-audio-tests-' + [Guid]::NewGuid().ToString('N'))
$taskEncoding = New-Object Text.UTF8Encoding($false)
$script:taskApiCalls = 0
$script:taskApiFailure = $false
# The test never reads real AppData, queries audio devices or contacts the Utility API.
function Get-AudioSetupProcesses { return [ordered]@{DeskSwitch=$true; GoXlrUtility=$true; OfficialGoXlrApp=$false; Obs=$true} }
function Get-AudioSetupUtilityStatus([int]$Port) {
    $script:taskLastApiPort = $Port
    $script:taskApiCalls++
    if ($script:taskApiFailure) { throw 'NEVER_EXPORT_API_EXCEPTION_SECRET' }
    return $script:taskFakeApi
}
$script:taskReadPaths = New-Object 'Collections.Generic.List[string]'
Set-Item Function:Read-AudioTextOriginal ${function:Read-AudioText}
function Read-AudioText([string]$Path, [string]$Root, [long]$Limit = 1048576) {
    $script:taskReadPaths.Add([IO.Path]::GetFullPath($Path))
    return Read-AudioTextOriginal $Path $Root $Limit
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Message) {
    $taskFailed = $false
    try { & $Action | Out-Null } catch { $taskFailed = $true }
    Assert $taskFailed $Message
}
function Save-Text([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, $taskEncoding)
}
function Save-Json([string]$Path, $Value) { Save-Text $Path ($Value | ConvertTo-Json -Depth 20) }
function File-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
try {
    $taskObs = Join-Path $taskTemp 'input/obs'
    $taskDesk = Join-Path $taskTemp 'input/desk'
    $taskGlobal = Join-Path $taskObs 'global.ini'
    Save-Text $taskGlobal "[Basic]`nProfile=Selected profile`nProfileDir=Selected`nSceneCollection=Selected collection`nSceneCollectionFile=SelectedScenes`n[Twitch]`nToken=NEVER_EXPORT_GLOBAL_SECRET`n"
    $taskBasic = Join-Path $taskObs 'basic/profiles/Selected/basic.ini'
    Save-Text $taskBasic "[General]`nName=Selected profile`n[Output]`nMode=Advanced`n[AdvOut]`nRecType=Standard`nRecFormat2=mkv`nRecTracks=63`nTrackIndex=1`nVodTrackIndex=2`nVodTrackEnabled=true`nRecFilePath=NEVER_EXPORT_RECORDING_PATH`n[Audio]`nSampleRate=48000`nChannelSetup=Stereo`nMonitoringDeviceId=default`n[Stream]`nKey=NEVER_EXPORT_STREAM_KEY`n"
    Save-Text (Join-Path $taskObs 'basic/profiles/Other/basic.ini') "[General]`nName=Other profile`n[Audio]`nSampleRate=44100`n"
    Save-Text (Join-Path $taskObs 'basic/profiles/Selected/service.json') 'NEVER_EXPORT_SERVICE_SECRET invalid JSON'
    Save-Text (Join-Path $taskObs 'plugin_config/obs-websocket/config.json') 'NEVER_EXPORT_WEBSOCKET_SECRET invalid JSON'
    $taskMic = [ordered]@{
        id='wasapi_input_capture'; name='Voice'; volume=0.8; muted=$false; enabled=$true; mixers=3; monitoring_type=1; sync=12000000
        settings=@{device_id='MIC-ENDPOINT'; use_device_timing=$true; token='NEVER_EXPORT_SOURCE_SECRET'}
        filters=@(
            @{id='gain_filter'; name='Gain'; enabled=$true; settings=@{db=-3.0; state='NEVER_EXPORT_GAIN_STATE'}},
            @{id='noise_suppress_filter'; versioned_id='noise_suppress_filter_v2'; name='Noise'; enabled=$true; settings=@{method='rnnoise'; suppress_level=-30; private='NEVER_EXPORT_FILTER_SECRET'}},
            @{id='vst_filter'; name='My VST'; enabled=$true; settings=@{plugin_path='NEVER_EXPORT_VST_PATH'; chunk_data='NEVER_EXPORT_VST_BINARY'}},
            @{id='third_party_filter'; name='Another filter'; enabled=$false; settings=@{threshold=-10; password='NEVER_EXPORT_PLUGIN_SECRET'}}
        )
    }
    $taskScene = [ordered]@{
        name='Selected collection'; current_scene='NEVER_EXPORT_SCENE_STATE'; private='NEVER_EXPORT_SCENE_SECRET'
        DesktopAudioDevice1=@{id='wasapi_output_capture'; name='Desktop'; settings=@{device_id='SYSTEM-ENDPOINT'}; mixers=1; muted=$false; volume=1.0; monitoring_type=0; sync=0}
        AuxAudioDevice1=@{id='wasapi_input_capture'; name='Aux mic'; settings=@{device_id='AUX-ENDPOINT'}; mixers=2; volume=1.0; muted=$true}
        sources=@(
            $taskMic,
            @{id='wasapi_process_output_capture'; name='Chat app'; settings=@{window='NEVER_EXPORT_PRIVATE_WINDOW_TITLE:Class:Discord.exe'; priority=2}; mixers=4; volume=0.5; muted=$false},
            @{id='browser_source'; name='Browser overlay'; settings=@{url='https://NEVER_EXPORT_BROWSER_URL'; password='NEVER_EXPORT_BROWSER_PASSWORD'}; volume=1.0},
            @{id='ffmpeg_source'; name='Media clip'; settings=@{local_file='NEVER_EXPORT_MEDIA_PATH'}; volume=1.0},
            @{id='game_capture'; name='Game'; settings=@{capture_audio=$true; window='NEVER_EXPORT_GAME_WINDOW'}; volume=1.0; mixers=8; monitoring_type=0}
        )
    }
    Save-Json (Join-Path $taskObs 'basic/scenes/SelectedScenes.json') $taskScene
    Save-Text (Join-Path $taskObs 'basic/scenes/OtherScenes.json') 'NEVER_READ_UNSELECTED_SCENES invalid JSON'
    Save-Json (Join-Path $taskDesk 'goxlr.json') @{Enabled=$true; Serial='TEST-SERIAL'; Port=15555; private='NEVER_EXPORT_DESKSWITCH_SECRET'}
    $script:taskFakeApi = @{
        Status=@{
            config=@{private='NEVER_EXPORT_API_CONFIG'}
            files=@{samples=@('NEVER_EXPORT_SAMPLE_FILE')}
            mixers=@{
                'TEST-SERIAL'=@{profile_name='Selected GoXLR'; mic_profile_name='Selected microphone'; levels=@{volumes=@{Headphones=104; System=233; Secret='NEVER_EXPORT_VOLUME_SECRET'}}; router=@{Microphone=@{Headphones=$false; ChatMic=$true; Secret='NEVER_EXPORT_ROUTER_SECRET'}; System=@{Headphones=$true}}; sampler=@{files=@('NEVER_EXPORT_SAMPLER_FILE')}; mic_status=@{private='NEVER_EXPORT_MIC_DSP'}}
                'OTHER-SERIAL'=@{profile_name='NEVER_EXPORT_UNSELECTED_PROFILE'; levels=@{volumes=@{Headphones=0}}}
            }
        }
    } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $taskBefore = @{}
    foreach ($taskFile in @(Get-ChildItem -LiteralPath (Join-Path $taskTemp 'input') -File -Recurse)) { $taskBefore[$taskFile.FullName] = File-Hash $taskFile.FullName }
    $taskOutput = Join-Path $taskTemp 'report.json'
    Export-AudioSetup -ObsRoot $taskObs -DeskSwitchRoot $taskDesk -OutputPath $taskOutput | Out-Null
    $taskText = [IO.File]::ReadAllText($taskOutput)
    $taskReport = $taskText | ConvertFrom-Json
    Assert (-not $taskText.Contains('NEVER_EXPORT_')) 'Unrelated private data leaked into the report.'
    Assert ($taskReport.Obs.Profile.Directory -ceq 'Selected' -and $taskReport.Obs.SceneCollection.File -ceq 'SelectedScenes') 'Saved OBS selection was not used.'
    Assert ($taskReport.Obs.Profile.AudioAndRecording.AdvOut.RecTracks -eq '63' -and $taskReport.Obs.Profile.AudioAndRecording.Audio.SampleRate -eq '48000') 'Recording tracks or sample rate were lost.'
    Assert (@($taskReport.Obs.Sources).Count -eq 4) 'Expected only two global and two selected audio sources.'
    Assert (@($taskReport.Obs.OtherSources).Count -eq 3) 'Potential extra audio sources were lost.'
    Assert ($taskReport.Obs.OtherSources[2].capture_audio -and $taskReport.Obs.OtherSources[2].mixers -eq 8 -and $null -eq $taskReport.Obs.OtherSources[2].settings) 'Game audio metadata missing or private settings leaked.'
    $taskVoice = @($taskReport.Obs.Sources | Where-Object { $_.name -ceq 'Voice' })[0]
    Assert ($taskVoice.settings.device_id -ceq 'MIC-ENDPOINT' -and $taskVoice.mixers -eq 3 -and $taskVoice.sync_offset_ns -eq 12000000) 'Voice device, tracks or sync offset changed.'
    Assert ($taskVoice.filters[0].settings.db -eq -3 -and $taskVoice.filters[1].settings.method -eq 'rnnoise') 'Safe official audio filter settings were not preserved.'
    Assert ($null -eq $taskVoice.filters[2].settings -and $null -eq $taskVoice.filters[3].settings) 'VST or third-party filter state leaked.'
    Assert ($taskVoice.filters[2].name -ceq 'My VST' -and $taskVoice.filters[2].enabled) 'VST identity was lost.'
    $taskProcess = @($taskReport.Obs.Sources | Where-Object { $_.id -ceq 'wasapi_process_output_capture' })[0]
    Assert ($taskProcess.settings.process_executable -ceq 'Discord.exe' -and $null -eq $taskProcess.settings.window) 'Process capture exported a private title or lost executable.'
    Assert ($taskReport.GoXlrUtility.Mixers.Count -eq 1 -and $taskReport.GoXlrUtility.Mixers[0].Volumes.Headphones -eq 104 -and $taskReport.GoXlrUtility.Mixers[0].Router.Microphone.ChatMic) 'Selected GoXLR routing was not preserved.'
    Assert ($taskReport.DeskSwitch.Config.Enabled -and $taskReport.DeskSwitch.Config.Serial -ceq 'TEST-SERIAL') 'DeskSwitch selection was not preserved.'
    Assert ($script:taskApiCalls -eq 1) 'Unexpected Utility API requests.'
    Assert ($script:taskLastApiPort -eq 15555 -and $taskReport.GoXlrUtility.Port -eq 15555) 'Saved Utility port was ignored.'
    foreach ($taskPath in $script:taskReadPaths) { Assert ($taskPath -notmatch 'service\.json|obs-websocket|OtherScenes\.json') 'A forbidden or unselected file was read.' }
    foreach ($taskPath in $taskBefore.Keys) { Assert ((File-Hash $taskPath) -ceq $taskBefore[$taskPath]) 'An original configuration file was modified.' }
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $taskTemp 'input') -File -Recurse).Count -eq $taskBefore.Count) 'A file was written inside configuration folders.'
    Expect-Failure { Export-AudioSetup -ObsRoot $taskObs -DeskSwitchRoot $taskDesk -OutputPath $taskOutput } 'Existing reports must never be overwritten.'
    Assert ([IO.File]::ReadAllText($taskOutput) -ceq $taskText) 'Existing report changed.'

    # Unknown selection never falls back to the first device/profile/collection.
    $taskNoSerial = Select-AudioUtilityStatus $script:taskFakeApi ''
    Assert ($taskNoSerial.Selection -ceq 'serial-not-selected' -and $taskNoSerial.Mixers.Count -eq 0) 'Unselected mixer was guessed.'
    $taskMissingSerial = Select-AudioUtilityStatus $script:taskFakeApi 'MISSING'
    Assert ($taskMissingSerial.Selection -ceq 'selected-serial-not-connected' -and $taskMissingSerial.Mixers.Count -eq 0) 'Unknown mixer silently fell back.'
    $taskItems = @([pscustomobject]@{Key='one'; Name='One'}, [pscustomobject]@{Key='two'; Name='Two'})
    Expect-Failure { Select-AudioObsItem $taskItems '' 'missing' '' 'test' $false } 'Ambiguous selection must fail without user input.'
    Expect-Failure { Select-AudioObsItem $taskItems 'missing' '' '' 'test' $false } 'Explicit unknown selection must fail.'
    Assert ((Select-AudioObsItem $taskItems 'two' '' '' 'test' $false).Key -ceq 'two') 'Explicit selection was ignored.'
    Expect-Failure { Assert-AudioPath (Join-Path $taskTemp 'outside.json') $taskObs } 'Reading outside selected root must fail.'

    # New OBS user.ini takes priority over a conflicting old global.ini; unreachable API stays optional.
    Save-Text (Join-Path $taskObs 'user.ini') "[Basic]`nProfileDir=Other`nSceneCollectionFile=SelectedScenes`n"
    $script:taskApiFailure = $true
    $taskOfflineOutput = Join-Path $taskTemp 'offline.json'
    Export-AudioSetup -ObsRoot $taskObs -DeskSwitchRoot $taskDesk -OutputPath $taskOfflineOutput -UtilityPort 16666 | Out-Null
    $taskOffline = Get-Content -LiteralPath $taskOfflineOutput -Raw | ConvertFrom-Json
    Assert ($taskOffline.Obs.Profile.Directory -ceq 'Other') 'user.ini did not override global.ini.'
    Assert ($script:taskLastApiPort -eq 16666) 'Explicit Utility port was ignored.'
    Expect-Failure { Export-AudioSetup -ObsRoot $taskObs -DeskSwitchRoot $taskDesk -OutputPath (Join-Path $taskTemp 'invalid-port.json') -UtilityPort 0 } 'Invalid Utility port must fail.'
    Assert (-not $taskOffline.GoXlrUtility.Available -and $taskOffline.GoXlrUtility.Selection -ceq 'api-unavailable') 'Unavailable Utility blocked the useful report.'
    Assert (-not [IO.File]::ReadAllText($taskOfflineOutput).Contains('NEVER_EXPORT_')) 'API exception details leaked.'
    Save-Json (Join-Path $taskDesk 'goxlr.json') @{Enabled=$true; Serial='TEST-SERIAL'; Port='15555'}
    $taskApiBefore = $script:taskApiCalls
    Expect-Failure { Export-AudioSetup -ObsRoot $taskObs -DeskSwitchRoot $taskDesk -OutputPath (Join-Path $taskTemp 'bad-config-port.json') } 'Non-numeric configured port must fail, not query the default.'
    Assert ($script:taskApiCalls -eq $taskApiBefore) 'Invalid configured port caused an API query.'
    Write-Output 'PASS: audio export selection, track/filter preservation, secret exclusion, original bytes, ambiguous selection and offline API.'
} finally {
    if (Test-Path -LiteralPath $taskTemp) { Remove-Item -LiteralPath $taskTemp -Recurse -Force }
}
