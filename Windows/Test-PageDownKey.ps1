param([switch]$NativeHook)
$ErrorActionPreference = 'Stop'
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$taskTemp = Join-Path ([IO.Path]::GetTempPath()) ('DeskSwitch-PageDown-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskTemp | Out-Null
try {
    $taskExe = Join-Path $taskTemp 'PageDownKeyTests.exe'
    & $taskCompiler /nologo /target:exe /optimize+ /utf8output "/out:$taskExe" "$PSScriptRoot\PageDownKey.cs" "$PSScriptRoot\PageDownKeyTests.cs"
    if ($LASTEXITCODE -ne 0) { throw 'PageDown test build failed.' }
    & $taskExe
    if ($LASTEXITCODE -ne 0) { throw 'PageDown tests failed.' }
    if ($NativeHook) {
        if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Native hook input tests must run on the isolated GitHub Actions desktop.' }
        $taskNativeExe = Join-Path $taskTemp 'PageDownHookTests.exe'
        & $taskCompiler /nologo /target:exe /optimize+ /utf8output /r:System.Windows.Forms.dll /r:System.Drawing.dll "/out:$taskNativeExe" "$PSScriptRoot\PageDownKey.cs" "$PSScriptRoot\PageDownHook.cs" "$PSScriptRoot\PageDownHookTests.cs"
        if ($LASTEXITCODE -ne 0) { throw 'Native PageDown hook test build failed.' }
        & $taskNativeExe --allow-input-injection
        if ($LASTEXITCODE -ne 0) { throw 'Native PageDown hook tests failed.' }
    }
} finally {
    Remove-Item -LiteralPath $taskTemp -Recurse -Force
}
