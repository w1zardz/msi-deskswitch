$ErrorActionPreference = 'Stop'
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$taskTemp = Join-Path ([IO.Path]::GetTempPath()) ('DeskSwitch-overlay-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskTemp | Out-Null
$taskExe = Join-Path $taskTemp 'HeadphonesOverlayTests.exe'
$taskOutput = Join-Path $taskTemp 'stdout.txt'
$taskError = Join-Path $taskTemp 'stderr.txt'
try {
    & $taskCompiler /nologo /target:exe /optimize+ /utf8output /r:System.Windows.Forms.dll /r:System.Drawing.dll "/out:$taskExe" "$PSScriptRoot\HeadphonesOverlay.cs" "$PSScriptRoot\HeadphonesOverlayTests.cs"
    if ($LASTEXITCODE -ne 0) { throw 'Overlay test build failed.' }
    $taskProcess = Start-Process -FilePath $taskExe -WindowStyle Hidden -RedirectStandardOutput $taskOutput -RedirectStandardError $taskError -PassThru
    if (-not $taskProcess.WaitForExit(20000)) {
        $taskProcess.Kill()
        $taskProcess.WaitForExit()
        throw 'Overlay tests timed out.'
    }
    Get-Content -LiteralPath $taskOutput
    if ($taskProcess.ExitCode -ne 0) {
        Get-Content -LiteralPath $taskError
        throw 'Overlay tests failed.'
    }
} finally {
    # Delete only the three files created above, then the now-empty fixture directory.
    foreach ($taskFile in @($taskExe, $taskOutput, $taskError)) { [IO.File]::Delete($taskFile) }
    [IO.Directory]::Delete($taskTemp)
}
