#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceFolder,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$taskInteractive = -not $PSBoundParameters.ContainsKey('SourceFolder') -and -not $PSBoundParameters.ContainsKey('OutputPath')

function Assert-NoReparsePath([string]$Path) {
    $taskItem = Get-Item -LiteralPath $Path -Force
    while ($null -ne $taskItem) {
        if (($taskItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Выбери обычную папку, а не ссылку или junction: $($taskItem.FullName)"
        }
        $taskItem = $taskItem.Parent
    }
}

try {
    if (-not $PSBoundParameters.ContainsKey('SourceFolder')) {
        $SourceFolder = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GoXLR'
        if (-not (Test-Path -LiteralPath $SourceFolder -PathType Container)) {
            if (-not $taskInteractive) { throw 'Папка Документы\GoXLR не найдена. Укажи -SourceFolder.' }
            Add-Type -AssemblyName System.Windows.Forms
            $taskDialog = New-Object Windows.Forms.FolderBrowserDialog
            try {
                $taskDialog.Description = 'Выбери папку GoXLR с основными профилями и профилями микрофона.'
                $taskDialog.ShowNewFolderButton = $false
                if ($taskDialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw 'Экспорт отменён.' }
                $SourceFolder = $taskDialog.SelectedPath
            } finally { $taskDialog.Dispose() }
        }
    }
    if ([string]::IsNullOrWhiteSpace($SourceFolder) -or -not (Test-Path -LiteralPath $SourceFolder -PathType Container)) {
        throw 'Папка GoXLR не найдена. Укажи папку, в которой сохранены твои профили.'
    }
    Assert-NoReparsePath $SourceFolder
    $taskSource = (Get-Item -LiteralPath $SourceFolder -Force).FullName.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $taskFolders = New-Object 'Collections.Generic.Queue[string]'
    $taskFiles = New-Object 'Collections.Generic.List[IO.FileInfo]'
    $taskFolders.Enqueue($taskSource)
    while ($taskFolders.Count -gt 0) {
        foreach ($taskItem in Get-ChildItem -LiteralPath ($taskFolders.Dequeue()) -Force) {
            if (($taskItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($taskItem.PSIsContainer) { $taskFolders.Enqueue($taskItem.FullName) }
            elseif ($taskItem.Extension -ieq '.goxlr' -or $taskItem.Extension -ieq '.goxlrMicProfile') { $taskFiles.Add($taskItem) }
        }
    }
    $taskMainCount = @($taskFiles | Where-Object { $_.Extension -ieq '.goxlr' }).Count
    $taskMicCount = @($taskFiles | Where-Object { $_.Extension -ieq '.goxlrMicProfile' }).Count
    if ($taskMainCount -eq 0 -or $taskMicCount -eq 0) {
        throw "Нужны оба типа профилей: основной .goxlr и микрофона .goxlrMicProfile. Найдено: $taskMainCount и $taskMicCount. Сохрани оба в GoXLR App и повтори экспорт."
    }
    if ($PSBoundParameters.ContainsKey('OutputPath')) {
        if ([string]::IsNullOrWhiteSpace($OutputPath) -or [IO.Path]::GetExtension($OutputPath) -ine '.zip') { throw 'Путь результата должен оканчиваться на .zip.' }
        $taskZipPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    } else {
        $taskDesktop = [Environment]::GetFolderPath('DesktopDirectory')
        $taskBaseName = 'GoXLR-Profiles-' + (Get-Date -Format 'yyyy-MM-dd-HHmmss')
        $taskZipPath = Join-Path $taskDesktop ($taskBaseName + '.zip')
        $taskSuffix = 1
        while (Test-Path -LiteralPath $taskZipPath) {
            $taskZipPath = Join-Path $taskDesktop ($taskBaseName + '-' + $taskSuffix + '.zip')
            $taskSuffix++
        }
    }
    Assert-NoReparsePath (Split-Path -Parent $taskZipPath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $taskCreated = $false
    $taskStream = $null
    $taskArchive = $null
    try {
        # CreateNew prevents overwriting an existing export, even if another process just created it.
        $taskStream = [IO.File]::Open($taskZipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $taskCreated = $true
        $taskArchive = New-Object IO.Compression.ZipArchive($taskStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        foreach ($taskFile in $taskFiles) {
            $taskRelative = $taskFile.FullName.Substring($taskSource.Length).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($taskArchive, $taskFile.FullName, $taskRelative, [IO.Compression.CompressionLevel]::Optimal)
        }
        $taskArchive.Dispose()
        $taskArchive = $null
        $taskStream.Dispose()
        $taskStream = $null
    } catch {
        if ($null -ne $taskArchive) { $taskArchive.Dispose(); $taskArchive = $null }
        if ($null -ne $taskStream) { $taskStream.Dispose(); $taskStream = $null }
        if ($taskCreated) { Remove-Item -LiteralPath $taskZipPath -Force }
        throw
    }
    $taskMessage = "Готово: $taskMainCount основных профилей, $taskMicCount профилей микрофона.`r`n`r`n$taskZipPath`r`n`r`nПеренеси этот ZIP на Mac. Исходные настройки не изменены; сэмплы и логи не включены."
    Write-Host $taskMessage
    if ($taskInteractive) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($taskMessage, 'Профили GoXLR сохранены')
    }
    Write-Output $taskZipPath
} catch {
    if ($taskInteractive) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Не удалось сохранить профили GoXLR')
    }
    throw
}
