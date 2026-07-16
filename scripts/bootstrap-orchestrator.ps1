[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BundleFile,

    [Parameter(Mandatory = $true)]
    [string]$Root,

    [ValidateRange(1, 600)]
    [int]$LockTimeoutSeconds = 120,

    [ValidateRange(10, 1000)]
    [int]$LockRetryBaseMilliseconds = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SchemaVersion = 2
$memoryScript = Join-Path $PSScriptRoot 'memory-ledger.ps1'
$taskScript = Join-Path $PSScriptRoot 'task-ledger.ps1'

function ConvertTo-Slug {
    param([string]$Value, [ValidateRange(12, 120)][int]$MaxLength = 48)
    $slug = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9\p{L}\p{Nd}]+', '-'
    $slug = $slug.Trim('-') -replace '-{2,}', '-'
    if ([string]::IsNullOrWhiteSpace($slug)) { throw 'Task ID must contain a letter or digit.' }
    if ($slug.Length -gt $MaxLength) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
            $hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant().Substring(0, 8)
        }
        finally { $sha.Dispose() }
        $prefix = $slug.Substring(0, $MaxLength - $hash.Length - 1).TrimEnd('-')
        if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'task' }
        $slug = "$prefix-$hash"
    }
    return $slug
}

function Assert-SafeDescendantPath {
    param([string]$Base, [string]$Candidate)
    $baseDirectory = [IO.Path]::GetFullPath($Base).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $basePrefix = $baseDirectory + [IO.Path]::DirectorySeparatorChar
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    if (-not $candidateFull.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes bootstrap root: $candidateFull"
    }
    $current = $baseDirectory
    $relative = $candidateFull.Substring($basePrefix.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Path crosses a reparse point below the bootstrap root: $current"
            }
        }
    }
    return $candidateFull
}

function Enter-BootstrapLock {
    param([string]$Path)
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
    $attempt = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            $exponent = [Math]::Min($attempt, 5)
            $maximum = [Math]::Min(1000, [int]($LockRetryBaseMilliseconds * [Math]::Pow(2, $exponent)))
            $minimum = [Math]::Min($LockRetryBaseMilliseconds, $maximum)
            $delay = if ($maximum -gt $minimum) { Get-Random -Minimum $minimum -Maximum ($maximum + 1) } else { $minimum }
            Start-Sleep -Milliseconds $delay
            $attempt++
        }
    }
    throw "Timed out after $LockTimeoutSeconds second(s) acquiring bootstrap lock: $Path"
}

function Write-JsonAtomic {
    param([string]$Path, $Value)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.tmp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $backup = Join-Path $directory ('.bak-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    try {
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup, $true)
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Require-Property {
    param($Object, [string]$Name)
    if ($null -eq $Object.PSObject.Properties[$Name]) { throw "Bundle requires '$Name'." }
    $value = $Object.$Name
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { throw "Bundle property '$Name' cannot be empty." }
    return $value
}

$BundleFile = [IO.Path]::GetFullPath($BundleFile)
$Root = [IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $BundleFile -PathType Leaf)) { throw "Bundle file does not exist: $BundleFile" }
if (-not (Test-Path -LiteralPath $memoryScript -PathType Leaf)) { throw "Memory utility is missing: $memoryScript" }
if (-not (Test-Path -LiteralPath $taskScript -PathType Leaf)) { throw "Task utility is missing: $taskScript" }

try { $bundle = [IO.File]::ReadAllText($BundleFile) | ConvertFrom-Json }
catch { throw "Bundle is not valid JSON: $($_.Exception.Message)" }

$purpose = [string](Require-Property -Object $bundle -Name 'purpose')
$content = [string](Require-Property -Object $bundle -Name 'content')
$taskId = [string](Require-Property -Object $bundle -Name 'task_id')
$objective = [string](Require-Property -Object $bundle -Name 'objective')
$capabilities = Require-Property -Object $bundle -Name 'capabilities'
$checkpointText = [string](Require-Property -Object $bundle -Name 'checkpoint_text')
$null = Require-Property -Object $capabilities -Name 'client'
$null = Require-Property -Object $capabilities -Name 'tools'
$null = Require-Property -Object $capabilities -Name 'continuation'

$taskSlug = ConvertTo-Slug -Value $taskId
$stateRoot = Assert-SafeDescendantPath -Base $Root -Candidate (Join-Path $Root 'orchestrator-state')
$memoryRoot = Assert-SafeDescendantPath -Base $Root -Candidate (Join-Path $stateRoot 'memory')
$taskFile = Assert-SafeDescendantPath -Base $Root -Candidate (Join-Path (Join-Path $stateRoot 'tasks') "$taskSlug.json")
$statusPath = Assert-SafeDescendantPath -Base $Root -Candidate (Join-Path $stateRoot 'bootstrap-status.json')
$handoffPath = Assert-SafeDescendantPath -Base $Root -Candidate (Join-Path $stateRoot 'handoff-manifest.json')
$bootstrapLocksRoot = Assert-SafeDescendantPath -Base $Root -Candidate (Join-Path $stateRoot 'locks')
$bootstrapLockPath = Assert-SafeDescendantPath -Base $Root -Candidate (Join-Path $bootstrapLocksRoot 'bootstrap.lock')
$bundleHash = (Get-FileHash -LiteralPath $BundleFile -Algorithm SHA256).Hash.ToLowerInvariant()

$deepPathProbe = Join-Path $memoryRoot 'purposes\123456789012345678901234\contents\123456789012345678901234\checkpoints\session-123456789012\cp-20991231T235959999Z-12345678.json'
if ($env:OS -eq 'Windows_NT' -and -not (Test-Path -LiteralPath $statusPath) -and $deepPathProbe.Length -gt 248) {
    throw "Bootstrap root is too long for safe deep-state paths on Windows. Choose a shorter root: $Root"
}

[IO.Directory]::CreateDirectory($bootstrapLocksRoot) | Out-Null
$bootstrapLock = Enter-BootstrapLock -Path $bootstrapLockPath

try {
if (Test-Path -LiteralPath $statusPath) {
    $existingStatus = [IO.File]::ReadAllText($statusPath) | ConvertFrom-Json
    if ($existingStatus.status -eq 'complete' -and $existingStatus.bundle_hash -eq $bundleHash -and (Test-Path -LiteralPath $handoffPath)) {
        $existingHandoff = [IO.File]::ReadAllText($handoffPath) | ConvertFrom-Json
        $memoryCheck = & $memoryScript -Operation Verify -Purpose $purpose -Content $content -Root ([string]$existingHandoff.memory_root) | Select-Object -First 1 | ConvertFrom-Json
        $taskCheck = & $taskScript -Operation Verify -TaskFile ([string]$existingHandoff.task_file) | Select-Object -First 1 | ConvertFrom-Json
        if (-not $memoryCheck.valid -or -not $taskCheck.valid) {
            throw 'Completed bootstrap state failed idempotent verification.'
        }
        $existingHandoff | ConvertTo-Json -Depth 40
        return
    }
    throw "Bootstrap state already exists and is not an identical completed bundle: $statusPath"
}

$status = [ordered]@{
    schema_version = $SchemaVersion
    status = 'active'
    bundle_hash = $bundleHash
    started_at = [DateTime]::UtcNow.ToString('o')
    completed_at = $null
    failed_at = $null
    error = $null
}
Write-JsonAtomic -Path $statusPath -Value $status

try {
    $memoryInit = & $memoryScript -Operation Init -Purpose $purpose -Content $content -Root $memoryRoot | ConvertFrom-Json
    $capabilityResult = & $memoryScript -Operation WriteCapabilities -Purpose $purpose -Content $content -Root $memoryRoot -Text ($capabilities | ConvertTo-Json -Depth 30) | ConvertFrom-Json

    $eventResults = @()
    if ($null -ne $bundle.PSObject.Properties['events']) {
        foreach ($event in @($bundle.events)) {
            $kind = if ($null -eq $event.PSObject.Properties['kind']) { 'note' } else { [string]$event.kind }
            $importance = if ($null -eq $event.PSObject.Properties['importance']) { 1 } else { [int]$event.importance }
            $eventText = [string](Require-Property -Object $event -Name 'text')
            $eventResults += (& $memoryScript -Operation Append -Purpose $purpose -Content $content -Root $memoryRoot -Text $eventText -Kind $kind -Importance $importance | ConvertFrom-Json)
        }
    }

    $taskInit = & $taskScript -Operation Init -TaskFile $taskFile -TaskId $taskId -Objective $objective | ConvertFrom-Json
    $rowResults = @()
    if ($null -ne $bundle.PSObject.Properties['rows']) {
        foreach ($row in @($bundle.rows)) {
            $rowResults += (& $taskScript -Operation AddRow -TaskFile $taskFile -JsonText ($row | ConvertTo-Json -Depth 30) | ConvertFrom-Json)
        }
    }

    $checkpoint = & $memoryScript -Operation WriteCheckpoint -Purpose $purpose -Content $content -Root $memoryRoot -TaskId $taskId -Text $checkpointText | ConvertFrom-Json

    $transcript = $null
    if ($null -ne $bundle.PSObject.Properties['transcript'] -and $null -ne $bundle.transcript) {
        $transcriptPath = [string](Require-Property -Object $bundle.transcript -Name 'path_or_id')
        $transcriptClient = if ($null -eq $bundle.transcript.PSObject.Properties['client']) { [string]$capabilities.client } else { [string]$bundle.transcript.client }
        $forkNumber = if ($null -eq $bundle.transcript.PSObject.Properties['fork_number']) { 0 } else { [int]$bundle.transcript.fork_number }
        $sidechainNumber = if ($null -eq $bundle.transcript.PSObject.Properties['sidechain_number']) { 0 } else { [int]$bundle.transcript.sidechain_number }
        $transcript = & $memoryScript -Operation RegisterTranscript -Purpose $purpose -Content $content -Root $memoryRoot -TranscriptPath $transcriptPath -Client $transcriptClient -ForkNumber $forkNumber -SidechainNumber $sidechainNumber | ConvertFrom-Json
    }

    $maxChars = if ($null -eq $bundle.PSObject.Properties['context_max_characters']) { 12000 } else { [int]$bundle.context_max_characters }
    $context = & $memoryScript -Operation BuildContext -Purpose $purpose -Content $content -Root $memoryRoot -MaxChars $maxChars | ConvertFrom-Json
    $memoryVerify = & $memoryScript -Operation Verify -Purpose $purpose -Content $content -Root $memoryRoot | Select-Object -First 1 | ConvertFrom-Json
    $taskVerify = & $taskScript -Operation Verify -TaskFile $taskFile | Select-Object -First 1 | ConvertFrom-Json

    $handoff = [ordered]@{
        schema_version = $SchemaVersion
        object_type = 'orchestrator_handoff'
        bundle_hash = $bundleHash
        task_id = $taskId
        objective = $objective
        created_at = [DateTime]::UtcNow.ToString('o')
        state_root = $stateRoot
        memory_root = $memoryRoot
        task_file = $taskFile
        capability_manifest = $capabilityResult.path
        checkpoint_id = $checkpoint.id
        checkpoint_path = $checkpoint.path
        context_id = $context.id
        context_path = $context.current_path
        transcript = $transcript
        event_ids = @($eventResults | ForEach-Object { $_.id })
        row_ids = @($rowResults | ForEach-Object { $_.id })
        verification = [ordered]@{
            memory_valid = $memoryVerify.valid
            task_valid = $taskVerify.valid
        }
        exact_next_action = if ($null -eq $bundle.PSObject.Properties['exact_next_action']) { 'Read the context packet and run NextReady on the task ledger.' } else { [string]$bundle.exact_next_action }
    }
    Write-JsonAtomic -Path $handoffPath -Value $handoff
    $status.status = 'complete'
    $status.completed_at = [DateTime]::UtcNow.ToString('o')
    Write-JsonAtomic -Path $statusPath -Value $status
    $handoff | ConvertTo-Json -Depth 40
}
catch {
    $status.status = 'failed'
    $status.failed_at = [DateTime]::UtcNow.ToString('o')
    $status.error = $_.Exception.Message
    Write-JsonAtomic -Path $statusPath -Value $status
    throw
}
}
finally {
    if ($null -ne $bootstrapLock) { $bootstrapLock.Dispose() }
}
