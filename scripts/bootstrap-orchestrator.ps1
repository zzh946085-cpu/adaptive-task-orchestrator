[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BundleFile,

    [Parameter(Mandatory = $true)]
    [string]$Root
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SchemaVersion = 2
$memoryScript = Join-Path $PSScriptRoot 'memory-ledger.ps1'
$taskScript = Join-Path $PSScriptRoot 'task-ledger.ps1'

function ConvertTo-Slug {
    param([string]$Value)
    $slug = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9\p{L}\p{Nd}]+', '-'
    $slug = $slug.Trim('-') -replace '-{2,}', '-'
    if ([string]::IsNullOrWhiteSpace($slug)) { throw 'Task ID must contain a letter or digit.' }
    return $slug
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
$stateRoot = Join-Path $Root 'orchestrator-state'
$memoryRoot = Join-Path $stateRoot 'memory'
$taskFile = Join-Path (Join-Path $stateRoot 'tasks') "$taskSlug.json"
$statusPath = Join-Path $stateRoot 'bootstrap-status.json'
$handoffPath = Join-Path $stateRoot 'handoff-manifest.json'
$bundleHash = (Get-FileHash -LiteralPath $BundleFile -Algorithm SHA256).Hash.ToLowerInvariant()

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

[IO.Directory]::CreateDirectory($stateRoot) | Out-Null
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
