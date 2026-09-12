#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$taskTemp = Join-Path ([IO.Path]::GetTempPath()) ('DeskSwitch-export-tests-' + [Guid]::NewGuid().ToString('N'))
$taskExporter = Join-Path $PSScriptRoot 'Export-GoXlrProfiles.ps1'

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Expect-Failure([scriptblock]$Action, [string]$Message) {
    $taskFailed = $false
    try { & $Action | Out-Null } catch { $taskFailed = $true }
    Assert $taskFailed $Message
}

try {
    [void][IO.Directory]::CreateDirectory($taskTemp)
    $taskSource = Join-Path $taskTemp 'GoXLR'
    $taskProfiles = Join-Path $taskSource 'Profiles'
    $taskMicProfiles = Join-Path $taskSource 'Mic Profiles'
    [void][IO.Directory]::CreateDirectory($taskProfiles)
    [void][IO.Directory]::CreateDirectory($taskMicProfiles)
    $taskMain = Join-Path $taskProfiles 'My profile.goxlr'
    $taskMic = Join-Path $taskMicProfiles 'Microphone.GOXLRMICPROFILE'
    [IO.File]::WriteAllText($taskMain, 'original main profile bytes')
    [IO.File]::WriteAllText((Join-Path $taskSource 'sample.wav'), 'exclude audio')
    [IO.File]::WriteAllText((Join-Path $taskSource 'log.txt'), 'exclude log')
    [IO.File]::WriteAllText((Join-Path $taskSource 'fake.goxlr.zip'), 'exclude misleading extension')
    $taskZip = Join-Path $taskTemp 'export.zip'
    Expect-Failure { & $taskExporter -SourceFolder $taskSource -OutputPath $taskZip } 'Missing microphone profile must fail.'
    Assert (-not (Test-Path -LiteralPath $taskZip)) 'Failed validation must not create an archive.'
    [IO.File]::WriteAllText($taskMic, 'original mic profile bytes')
    $taskOutside = Join-Path $taskTemp 'outside'
    [void][IO.Directory]::CreateDirectory($taskOutside)
    [IO.File]::WriteAllText((Join-Path $taskOutside 'unrelated.goxlr'), 'must never follow this junction')
    $taskJunction = Join-Path $taskSource 'linked'
    [void](New-Item -ItemType Junction -Path $taskJunction -Target $taskOutside)
    $taskResult = & $taskExporter -SourceFolder $taskSource -OutputPath $taskZip
    Assert ($taskResult -eq $taskZip) 'The exact output path must be returned.'
    $taskArchive = [IO.Compression.ZipFile]::OpenRead($taskZip)
    try {
        Assert ($taskArchive.Entries.Count -eq 2) 'Only the two profile files should be exported.'
        foreach ($taskExpected in @('Profiles/My profile.goxlr', 'Mic Profiles/Microphone.GOXLRMICPROFILE')) {
            Assert ($null -ne $taskArchive.GetEntry($taskExpected)) "Missing ZIP entry: $taskExpected"
        }
        $taskReader = New-Object IO.StreamReader($taskArchive.GetEntry('Profiles/My profile.goxlr').Open())
        try { Assert ($taskReader.ReadToEnd() -eq 'original main profile bytes') 'Profile bytes must be preserved.' }
        finally { $taskReader.Dispose() }
    } finally { $taskArchive.Dispose() }
    $taskHash = (Get-FileHash -LiteralPath $taskZip -Algorithm SHA256).Hash
    Expect-Failure { & $taskExporter -SourceFolder $taskSource -OutputPath $taskZip } 'Existing ZIP must not be overwritten.'
    Assert ((Get-FileHash -LiteralPath $taskZip -Algorithm SHA256).Hash -eq $taskHash) 'Existing ZIP changed.'
    Assert ([IO.File]::ReadAllText($taskMain) -eq 'original main profile bytes') 'Original main profile changed.'
    Assert ([IO.File]::ReadAllText($taskMic) -eq 'original mic profile bytes') 'Original mic profile changed.'
    Expect-Failure { & $taskExporter -SourceFolder $taskJunction -OutputPath (Join-Path $taskTemp 'link.zip') } 'A source junction must be rejected.'
    Expect-Failure { & $taskExporter -SourceFolder (Join-Path $taskTemp 'missing') -OutputPath (Join-Path $taskTemp 'missing.zip') } 'Explicit missing source must fail without a dialog.'
    Remove-Item -LiteralPath $taskMain
    Expect-Failure { & $taskExporter -SourceFolder $taskSource -OutputPath (Join-Path $taskTemp 'mic-only.zip') } 'Missing main profile must fail, without following the junction.'
    Write-Output 'PASS: GoXLR export includes only both profile types, preserves bytes, skips junctions and never overwrites.'
} finally {
    # Remove the junction itself before deleting the disposable fixture tree.
    if ($taskJunction -and (Test-Path -LiteralPath $taskJunction)) { [IO.Directory]::Delete($taskJunction) }
    if (Test-Path -LiteralPath $taskTemp) { Remove-Item -LiteralPath $taskTemp -Recurse -Force }
}
