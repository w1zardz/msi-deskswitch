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
} finally {
    Remove-Item -LiteralPath $taskTemp -Recurse -Force
}
