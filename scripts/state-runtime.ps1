$ErrorActionPreference = 'Stop'
$RuntimeArguments = $args
$scriptPath = Join-Path $PSScriptRoot 'state-runtime.mjs'
$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
$nodePath = if ($nodeCommand) { $nodeCommand.Source } else { $null }

if (-not $nodePath -and $env:LOCALAPPDATA) {
    $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes'
    if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
        $nodePath = Get-ChildItem -Path (Join-Path $runtimeRoot 'cua_node\*\bin\node.exe') -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
}

if (-not $nodePath) {
    throw 'SQLite v3 runtime requires Node.js 22.5 or newer. No compatible Node executable was found.'
}

$versionText = & $nodePath --version
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^v(\d+)\.(\d+)\.') {
    throw "Unable to determine Node.js version from $nodePath"
}
$major = [int]$Matches[1]
$minor = [int]$Matches[2]
if ($major -lt 22 -or ($major -eq 22 -and $minor -lt 5)) {
    throw "SQLite v3 runtime requires Node.js 22.5 or newer; found $versionText"
}

& $nodePath --disable-warning=ExperimentalWarning $scriptPath @RuntimeArguments
exit $LASTEXITCODE
