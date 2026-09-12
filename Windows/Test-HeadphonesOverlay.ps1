$ErrorActionPreference = 'Stop'
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$taskTemp = Join-Path ([IO.Path]::GetTempPath()) ('DeskSwitch-overlay-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskTemp | Out-Null
$taskExe = Join-Path $taskTemp 'HeadphonesOverlayTests.exe'
$taskOutput = Join-Path $taskTemp 'stdout.txt'
$taskError = Join-Path $taskTemp 'stderr.txt'
$taskProcess = $null
try {
    & $taskCompiler /nologo /target:exe /optimize+ /utf8output /r:System.Windows.Forms.dll /r:System.Drawing.dll "/out:$taskExe" "$PSScriptRoot\HeadphonesOverlay.cs" "$PSScriptRoot\HeadphonesOverlayTests.cs"
    if ($LASTEXITCODE -ne 0) { throw 'Overlay test build failed.' }
    $taskProcess = Start-Process -FilePath $taskExe -WindowStyle Hidden -RedirectStandardOutput $taskOutput -RedirectStandardError $taskError -PassThru
    # Windows PowerShell can lose ExitCode unless the process handle is retained before exit.
    [void]$taskProcess.Handle
    if (-not $taskProcess.WaitForExit(20000)) {
        $taskProcess.Kill()
        if (-not $taskProcess.WaitForExit(2000)) { throw 'Overlay test process did not exit after termination.' }
        throw 'Overlay tests timed out.'
    }
    $taskExitCode = $taskProcess.ExitCode
    # Windows Start-Process redirects to native file handles. Wait for their writers to close,
    # bounded even if an unexpected descendant inherited them; no unbounded WaitForExit().
    $taskDrainClock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($taskFile in @($taskOutput, $taskError)) {
        while ($true) {
            try {
                $taskProbe = [IO.File]::Open($taskFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                $taskProbe.Dispose()
                break
            } catch [IO.IOException] {
                if ($taskDrainClock.ElapsedMilliseconds -ge 2000) { throw 'Overlay test output did not close within the deadline.' }
                [Threading.Thread]::Sleep(25)
            }
        }
    }
    Get-Content -LiteralPath $taskOutput
    if ($null -eq $taskExitCode) { throw 'Overlay test exit code is unavailable.' }
    if ($taskExitCode -ne 0) {
        Get-Content -LiteralPath $taskError
        throw "Overlay tests failed (exit $taskExitCode)."
    }
} finally {
    if ($null -ne $taskProcess) { $taskProcess.Dispose() }
    # Delete only the three files created above, then the now-empty fixture directory.
    foreach ($taskFile in @($taskExe, $taskOutput, $taskError)) { [IO.File]::Delete($taskFile) }
    [IO.Directory]::Delete($taskTemp)
}
