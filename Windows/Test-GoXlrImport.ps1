#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Import-GoXlrProfiles.ps1')
Add-Type -AssemblyName System.IO.Compression
$taskTemp = Join-Path ([IO.Path]::GetTempPath()) ('DeskSwitch-import-tests-' + [Guid]::NewGuid().ToString('N'))
$taskEncoding = New-Object Text.UTF8Encoding($false)
$script:taskFakeProcesses = @()
# The test never inspects or modifies running applications and never uses real settings paths.
function Get-Process { [CmdletBinding()]param() return $script:taskFakeProcesses }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Message) {
    $taskFailed = $false
    try { & $Action | Out-Null } catch { $taskFailed = $true }
    Assert $taskFailed $Message
}
function Save-Manifest($Fixture) {
    [IO.File]::WriteAllText($Fixture.ManifestPath, ($Fixture.Manifest | ConvertTo-Json -Depth 10), $taskEncoding)
}
function New-Fixture([string]$Name) {
    $taskFolder = Join-Path $taskTemp $Name
    [void][IO.Directory]::CreateDirectory($taskFolder)
    $taskZip = Join-Path $taskFolder 'profiles.zip'
    $taskMain = $taskEncoding.GetBytes('only the selected main profile')
    $taskMic = $taskEncoding.GetBytes('only the selected microphone profile')
    $taskStream = [IO.File]::Open($taskZip, [IO.FileMode]::CreateNew)
    $taskArchive = New-Object IO.Compression.ZipArchive($taskStream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($taskPair in @(@{Name='Profiles/Selected.goxlr'; Bytes=$taskMain}, @{Name='MicProfiles/Selected Mic.goxlrMicProfile'; Bytes=$taskMic}, @{Name='../outside.txt'; Bytes=$taskMain})) {
            $taskEntry = $taskArchive.CreateEntry($taskPair.Name).Open()
            try { $taskEntry.Write($taskPair.Bytes, 0, $taskPair.Bytes.Length) } finally { $taskEntry.Dispose() }
        }
    } finally { $taskArchive.Dispose(); $taskStream.Dispose() }
    $taskFixture = [pscustomobject]@{
        Folder=$taskFolder; Zip=$taskZip; MainBytes=$taskMain; MicBytes=$taskMic
        ManifestPath=(Join-Path $taskFolder 'manifest.json')
        Config=(Join-Path $taskFolder 'utility/config/settings.json')
        Data=(Join-Path $taskFolder 'utility/data')
        Desk=(Join-Path $taskFolder 'desk/goxlr.json')
        Manifest=[ordered]@{
            ArchiveFile='profiles.zip'; ArchiveSha256=(Get-ImportHash ([IO.File]::ReadAllBytes($taskZip)))
            MainEntry='Profiles/Selected.goxlr'; MainProfileName='Selected'; MainSha256=(Get-ImportHash $taskMain)
            MicEntry='MicProfiles/Selected Mic.goxlrMicProfile'; MicProfileName='Selected Mic'; MicSha256=(Get-ImportHash $taskMic)
            Serial='EXPLICIT-TEST-SERIAL'; Port=14564
        }
    }
    Save-Manifest $taskFixture
    return $taskFixture
}
function Invoke-Fixture($Fixture) {
    Invoke-GoXlrProfileImport -ManifestPath $Fixture.ManifestPath -UtilityConfigPath $Fixture.Config -UtilityDataPath $Fixture.Data -DeskSwitchConfigPath $Fixture.Desk
}
function Assert-NoWrites($Fixture) {
    Assert (-not (Test-Path -LiteralPath (Join-Path $Fixture.Folder 'utility'))) 'Failed preparation wrote Utility files.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $Fixture.Folder 'desk'))) 'Failed preparation wrote DeskSwitch files.'
}

try {
    $taskGood = New-Fixture 'good'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $taskGood.Desk))
    $taskOld = '{"Enabled":false,"Serial":"previous","Port":15555,"custom":{"preserve":true}}'
    [IO.File]::WriteAllText($taskGood.Desk, $taskOld, $taskEncoding)
    Invoke-Fixture $taskGood
    $taskUtility = Get-Content -LiteralPath $taskGood.Config -Raw | ConvertFrom-Json
    Assert ($taskUtility.devices.'EXPLICIT-TEST-SERIAL'.profile -ceq 'Selected') 'Wrong main profile or serial.'
    Assert ($taskUtility.devices.'EXPLICIT-TEST-SERIAL'.mic_profile -ceq 'Selected Mic') 'Wrong microphone profile.'
    Assert ($taskUtility.allow_network_access -eq $false) 'Network API must not be enabled.'
    foreach ($taskPair in @(@{Path='profiles/Selected.goxlr'; Bytes=$taskGood.MainBytes}, @{Path='profiles/Default.goxlr'; Bytes=$taskGood.MainBytes}, @{Path='mic-profiles/Selected Mic.goxlrMicProfile'; Bytes=$taskGood.MicBytes}, @{Path='mic-profiles/DEFAULT.goxlrMicProfile'; Bytes=$taskGood.MicBytes})) {
        Assert ((Get-ImportHash ([IO.File]::ReadAllBytes((Join-Path $taskGood.Data $taskPair.Path)))) -ceq (Get-ImportHash $taskPair.Bytes)) 'Profile copy changed bytes.'
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $taskGood.Folder 'outside.txt'))) 'Unselected ZIP entries were extracted.'
    $taskDesk = Get-Content -LiteralPath $taskGood.Desk -Raw | ConvertFrom-Json
    Assert ($taskDesk.Enabled -eq $true -and $taskDesk.Serial -ceq 'EXPLICIT-TEST-SERIAL' -and $taskDesk.Port -eq 14564) 'DeskSwitch was not configured.'
    Assert ($taskDesk.custom.preserve -eq $true) 'Unrelated DeskSwitch settings were lost.'
    $taskBackup = Join-Path (Split-Path -Parent $taskGood.Desk) 'goxlr.before-profile-import.json'
    Assert ([IO.File]::ReadAllText($taskBackup) -ceq $taskOld) 'Original small config backup is missing or changed.'
    Invoke-Fixture $taskGood
    Assert ([IO.File]::ReadAllText($taskBackup) -ceq $taskOld) 'Repeated import replaced the original backup.'

    foreach ($taskCase in @('bad-archive-hash', 'bad-main-hash', 'missing-mic', 'invalid-name', 'missing-serial', 'wrong-port')) {
        $taskFixture = New-Fixture $taskCase
        switch ($taskCase) {
            'bad-archive-hash' { $taskFixture.Manifest.ArchiveSha256 = ('0' * 64) }
            'bad-main-hash' { $taskFixture.Manifest.MainSha256 = ('0' * 64) }
            'missing-mic' { $taskFixture.Manifest.MicEntry = 'missing/Selected Mic.goxlrMicProfile' }
            'invalid-name' { $taskFixture.Manifest.MainProfileName = '..\escape' }
            'missing-serial' { $taskFixture.Manifest.Serial = '' }
            'wrong-port' { $taskFixture.Manifest.Port = 15555 }
        }
        Save-Manifest $taskFixture
        Expect-Failure { Invoke-Fixture $taskFixture } "Case should fail: $taskCase"
        Assert-NoWrites $taskFixture
    }
    foreach ($taskBadBackup in @('{"Enabled":', '[]')) {
        $taskBackupFixture = New-Fixture ('bad-backup-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $taskBackupFixture.Desk))
        [IO.File]::WriteAllText($taskBackupFixture.Desk, $taskOld, $taskEncoding)
        $taskBrokenPath = Join-Path (Split-Path -Parent $taskBackupFixture.Desk) 'goxlr.before-profile-import.json'
        [IO.File]::WriteAllText($taskBrokenPath, $taskBadBackup, $taskEncoding)
        Expect-Failure { Invoke-Fixture $taskBackupFixture } 'A partial or non-object backup must block replacement.'
        Assert ([IO.File]::ReadAllText($taskBackupFixture.Desk) -ceq $taskOld) 'A broken backup allowed replacing original DeskSwitch settings.'
        Assert ([IO.File]::ReadAllText($taskBrokenPath) -ceq $taskBadBackup) 'An existing broken backup was overwritten.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $taskBackupFixture.Folder 'utility'))) 'A broken backup allowed writing Utility files.'
    }
    $taskExisting = New-Fixture 'existing-utility'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $taskExisting.Config))
    [IO.File]::WriteAllText($taskExisting.Config, '{"devices":{"keep":{"profile":"keep"}}}', $taskEncoding)
    $taskExistingHash = Get-ImportHash ([IO.File]::ReadAllBytes($taskExisting.Config))
    Expect-Failure { Invoke-Fixture $taskExisting } 'Different Utility settings must not be replaced.'
    Assert ((Get-ImportHash ([IO.File]::ReadAllBytes($taskExisting.Config))) -ceq $taskExistingHash) 'Existing Utility settings changed.'
    Assert (-not (Test-Path -LiteralPath $taskExisting.Data)) 'A conflict wrote profile data.'
    Assert (-not (Test-Path -LiteralPath $taskExisting.Desk)) 'A conflict wrote DeskSwitch settings.'
    $taskBusy = New-Fixture 'process-running'
    $script:taskFakeProcesses = @([pscustomobject]@{ProcessName='GoXLR App'})
    Expect-Failure { Invoke-Fixture $taskBusy } 'Running official app must block import.'
    Assert-NoWrites $taskBusy
    $script:taskFakeProcesses = @()
    Write-Output 'PASS: GoXLR import checks hashes, exact selection, aliases, preserved config, atomic backup, damaged-backup refusal, repeat import and process refusal.'
} finally {
    if (Test-Path -LiteralPath $taskTemp) { Remove-Item -LiteralPath $taskTemp -Recurse -Force }
}
