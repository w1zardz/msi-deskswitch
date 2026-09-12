$ErrorActionPreference = 'Stop'
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$taskTemp = Join-Path ([IO.Path]::GetTempPath()) ('DeskSwitch-GoXlr-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskTemp | Out-Null
try {
    $taskExe = Join-Path $taskTemp 'GoXlrTests.exe'
    & $taskCompiler /nologo /target:exe /optimize+ /utf8output /r:System.Web.Extensions.dll "/out:$taskExe" "$PSScriptRoot\GoXlrAudio.cs" "$PSScriptRoot\GoXlrTests.cs"
    if ($LASTEXITCODE -ne 0) { throw 'GoXLR test build failed.' }
    & $taskExe
    if ($LASTEXITCODE -ne 0) { throw 'GoXLR tests failed.' }
} finally {
    Remove-Item -LiteralPath $taskTemp -Recurse -Force
}
