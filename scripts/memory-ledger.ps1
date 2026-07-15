[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'Init', 'Append', 'Inspect', 'Compact', 'BuildContext',
        'WriteCheckpoint', 'Fork', 'WriteCapabilities',
        'RegisterTranscript', 'Recall', 'Verify', 'Expire', 'Delete'
    )]
    [string]$Operation,

    [Parameter(Mandatory = $true)]
    [string]$Purpose,

    [Parameter(Mandatory = $true)]
    [string]$Content,

    [string]$Text,
    [string]$InputFile,
    [string]$Root,
    [string]$SessionId,
    [string]$TaskId,
    [string]$ParentCheckpointId,
    [string]$SourceIds,
    [string]$TargetId,
    [string]$TranscriptPath,
    [string]$ParentSessionId,
    [string]$Client = 'unknown',

    [ValidateSet('weekly', 'monthly', 'durable')]
    [string]$Tier = 'weekly',

    [ValidateSet('fact', 'decision', 'artifact', 'failure', 'question', 'next_action', 'note')]
    [string]$Kind = 'note',

    [ValidateRange(0, 3)]
    [int]$Importance = 1,

    [ValidateRange(1, 100)]
    [int]$MaxItems = 12,

    [ValidateRange(1000, 200000)]
    [int]$MaxChars = 12000,

    [ValidateRange(1, 3650)]
    [int]$RecentDays = 7,

    [ValidateRange(1, 36500)]
    [int]$RetentionDays = 365,

    [ValidateRange(0, 1000000)]
    [int]$ForkNumber = 0,

    [ValidateRange(0, 1000000)]
    [int]$SidechainNumber = 0,

    [switch]$ConfirmAction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SchemaVersion = 2

function ConvertTo-Slug {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [ValidateRange(12, 120)][int]$MaxLength = 24,
        [switch]$Unlimited
    )

    $slug = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9\p{L}\p{Nd}]+', '-'
    $slug = $slug.Trim('-') -replace '-{2,}', '-'
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw 'Purpose and content must contain at least one letter or digit.'
    }
    if (-not $Unlimited -and $slug.Length -gt $MaxLength) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
            $hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant().Substring(0, 8)
        }
        finally { $sha.Dispose() }
        $prefixLength = $MaxLength - $hash.Length - 1
        $prefix = $slug.Substring(0, $prefixLength).TrimEnd('-')
        if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'item' }
        $slug = "$prefix-$hash"
    }
    return $slug
}

function Get-UtcTimestamp {
    return [DateTime]::UtcNow.ToString('o')
}

function New-ObjectId {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    return "$Prefix-$stamp-$nonce"
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [IO.Path]::GetFullPath($Path)
}

function Assert-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Candidate
    )

    $baseFull = (Get-FullPath -Path $Base).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $candidateFull = Get-FullPath -Path $Candidate
    if (-not $candidateFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes ledger root: $candidateFull"
    }
    return $candidateFull
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return $raw | ConvertFrom-Json
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.tmp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $backup = Join-Path $directory ('.bak-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $json = $Value | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))

    try {
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup, $true)
            if (Test-Path -LiteralPath $backup) {
                Remove-Item -LiteralPath $backup -Force
            }
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
}

function Get-InputText {
    if (-not [string]::IsNullOrWhiteSpace($InputFile)) {
        $inputFull = Get-FullPath -Path $InputFile
        if (-not (Test-Path -LiteralPath $inputFull -PathType Leaf)) {
            throw "Input file does not exist: $inputFull"
        }
        return [IO.File]::ReadAllText($inputFull)
    }

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    if ([Console]::IsInputRedirected) {
        $stdinText = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($stdinText)) {
            return $stdinText
        }
    }

    throw "Provide content with -InputFile, -Text, or redirected standard input for operation '$Operation'."
}

function ConvertTo-IdList {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    return @($Value -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Add-PropertyIfMissing {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $Root = Join-Path $env:CODEX_HOME 'memory\adaptive-task-orchestrator'
    }
    else {
        $Root = Join-Path $HOME '.codex\memory\adaptive-task-orchestrator'
    }
}

$Root = Get-FullPath -Path $Root
$purposeSlug = ConvertTo-Slug -Value $Purpose
$contentSlug = ConvertTo-Slug -Value $Content
$purposePath = Assert-ContainedPath -Base $Root -Candidate (Join-Path $Root "purposes\$purposeSlug")
$contentPath = Assert-ContainedPath -Base $Root -Candidate (Join-Path $purposePath "contents\$contentSlug")
$legacyPurposeSlug = ConvertTo-Slug -Value $Purpose -Unlimited
$legacyContentSlug = ConvertTo-Slug -Value $Content -Unlimited
$legacyPurposePath = Assert-ContainedPath -Base $Root -Candidate (Join-Path $Root "purposes\$legacyPurposeSlug")
$legacyContentPath = Assert-ContainedPath -Base $Root -Candidate (Join-Path $legacyPurposePath "contents\$legacyContentSlug")
if ($legacyContentPath -ne $contentPath -and (Test-Path -LiteralPath $legacyContentPath -PathType Container)) {
    $purposePath = $legacyPurposePath
    $contentPath = $legacyContentPath
}
$manifestPath = Join-Path $contentPath 'manifest.json'
$eventsRoot = Join-Path $contentPath 'events'
$summariesRoot = Join-Path $contentPath 'summaries'
$checkpointsRoot = Join-Path $contentPath 'checkpoints'
$contextsRoot = Join-Path $contentPath 'contexts'
$transcriptsRoot = Join-Path $contentPath 'transcripts'
$stateRoot = Join-Path $contentPath 'state'
$archiveRoot = Join-Path $contentPath 'archive'
$locksRoot = Join-Path $contentPath 'locks'
$lockPath = Join-Path $locksRoot 'ledger.lock'

function Initialize-Directories {
    $directories = @(
        $eventsRoot,
        (Join-Path $summariesRoot 'weekly'),
        (Join-Path $summariesRoot 'monthly'),
        (Join-Path $summariesRoot 'durable'),
        $checkpointsRoot,
        $contextsRoot,
        $transcriptsRoot,
        $stateRoot,
        (Join-Path $archiveRoot 'events'),
        $locksRoot
    )
    foreach ($directory in $directories) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
}

function Enter-LedgerLock {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            return [IO.File]::Open(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            Start-Sleep -Milliseconds 80
        }
    }
    throw "Timed out acquiring ledger lock: $lockPath"
}

function Get-Manifest {
    $manifest = Read-JsonFile -Path $manifestPath
    if ($null -eq $manifest) {
        throw 'Ledger manifest is missing. Run Init first.'
    }
    return $manifest
}

function Initialize-Manifest {
    if (Test-Path -LiteralPath $manifestPath) {
        return Get-Manifest
    }

    $now = Get-UtcTimestamp
    $initialSession = if ([string]::IsNullOrWhiteSpace($SessionId)) {
        "session-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    }
    else {
        $SessionId
    }
    $manifest = [ordered]@{
        schema_version = $SchemaVersion
        object_type = 'ledger_manifest'
        purpose = [ordered]@{ name = $Purpose; slug = $purposeSlug }
        content = [ordered]@{ name = $Content; slug = $contentSlug }
        created_at = $now
        updated_at = $now
        current_session_id = $initialSession
    }
    Write-JsonAtomic -Path $manifestPath -Value $manifest
    return Read-JsonFile -Path $manifestPath
}

function Update-Manifest {
    param([string]$CurrentSessionId)

    $manifest = Get-Manifest
    $manifest.updated_at = Get-UtcTimestamp
    if (-not [string]::IsNullOrWhiteSpace($CurrentSessionId)) {
        $manifest.current_session_id = $CurrentSessionId
    }
    Write-JsonAtomic -Path $manifestPath -Value $manifest
}

function Get-CurrentSessionId {
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return $SessionId
    }
    return [string](Get-Manifest).current_session_id
}

function Get-EventRecords {
    if (-not (Test-Path -LiteralPath $eventsRoot)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $eventsRoot -Filter '*.json' -File -Recurse | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName; Object = (Read-JsonFile -Path $_.FullName) }
    })
}

function Get-SummaryRecords {
    if (-not (Test-Path -LiteralPath $summariesRoot)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $summariesRoot -Filter '*.json' -File -Recurse | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName; Object = (Read-JsonFile -Path $_.FullName) }
    })
}

function Get-ArchivedEventRecords {
    $archivedEventsRoot = Join-Path $archiveRoot 'events'
    if (-not (Test-Path -LiteralPath $archivedEventsRoot)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $archivedEventsRoot -Filter '*.json' -File -Recurse | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName; Object = (Read-JsonFile -Path $_.FullName) }
    })
}

function Get-CheckpointRecords {
    if (-not (Test-Path -LiteralPath $checkpointsRoot)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $checkpointsRoot -Filter '*.json' -File -Recurse | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName; Object = (Read-JsonFile -Path $_.FullName) }
    })
}

function Get-AllRecordsById {
    $index = @{}
    foreach ($record in @((Get-EventRecords) + (Get-ArchivedEventRecords) + (Get-SummaryRecords) + (Get-CheckpointRecords))) {
        if ($null -ne $record.Object -and $null -ne $record.Object.PSObject.Properties['id']) {
            $index[[string]$record.Object.id] = $record
        }
    }
    return $index
}

function Set-SourceCoveredBy {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$SummaryId
    )

    Add-PropertyIfMissing -Object $Record.Object -Name 'covered_by' -Value @()
    $covered = @($Record.Object.covered_by)
    if ($covered -notcontains $SummaryId) {
        $Record.Object.covered_by = @($covered + $SummaryId)
        Write-JsonAtomic -Path $Record.Path -Value $Record.Object
    }
}

function Get-CurrentCheckpointRecord {
    $pointerPath = Join-Path $stateRoot 'current-checkpoint.json'
    $pointer = Read-JsonFile -Path $pointerPath
    if ($null -eq $pointer) {
        return $null
    }
    $checkpointPath = Assert-ContainedPath -Base $contentPath -Candidate ([string]$pointer.path)
    if (-not (Test-Path -LiteralPath $checkpointPath)) {
        return $null
    }
    return [pscustomobject]@{ Path = $checkpointPath; Object = (Read-JsonFile -Path $checkpointPath) }
}

function Invalidate-CurrentContext {
    $currentContext = Join-Path $contextsRoot 'current.json'
    if (Test-Path -LiteralPath $currentContext) {
        Remove-Item -LiteralPath $currentContext -Force
    }
}

$isMutation = $Operation -in @(
    'Init', 'Append', 'Compact', 'BuildContext', 'WriteCheckpoint', 'Fork',
    'WriteCapabilities', 'RegisterTranscript', 'Expire', 'Delete'
)
if ($Operation -eq 'Init' -or $isMutation) {
    Initialize-Directories
}
elseif (-not (Test-Path -LiteralPath $manifestPath)) {
    throw 'Ledger manifest is missing. Run Init first.'
}
$lockHandle = $null

try {
    if ($isMutation) {
        $lockHandle = Enter-LedgerLock
    }

    if ($Operation -eq 'Init') {
        $manifest = Initialize-Manifest
        [pscustomobject]@{
            schema_version = $SchemaVersion
            root = $Root
            purpose = $purposeSlug
            content = $contentSlug
            session_id = $manifest.current_session_id
            manifest = $manifestPath
        } | ConvertTo-Json -Depth 10
        return
    }

    $null = Get-Manifest

    switch ($Operation) {
        'Append' {
            $body = Get-InputText
            $eventId = New-ObjectId -Prefix 'evt'
            $now = Get-UtcTimestamp
            $eventDirectory = Join-Path $eventsRoot ([DateTime]::UtcNow.ToString('yyyy\MM'))
            $eventPath = Assert-ContainedPath -Base $contentPath -Candidate (Join-Path $eventDirectory "$eventId.json")
            $currentSession = Get-CurrentSessionId
            $event = [ordered]@{
                schema_version = $SchemaVersion
                object_type = 'event'
                id = $eventId
                purpose = $purposeSlug
                content = $contentSlug
                session_id = $currentSession
                timestamp = $now
                importance = $Importance
                kind = $Kind
                covered_by = @()
                text = $body
            }
            Write-JsonAtomic -Path $eventPath -Value $event
            Invalidate-CurrentContext
            Update-Manifest -CurrentSessionId $currentSession
            [pscustomobject]@{ id = $eventId; path = $eventPath; timestamp = $now } | ConvertTo-Json
        }

        'Inspect' {
            $events = @(Get-EventRecords)
            $summaries = @(Get-SummaryRecords)
            $uncoveredEvents = @($events | Where-Object { @($_.Object.covered_by).Count -eq 0 })
            $uncoveredChars = ($uncoveredEvents | ForEach-Object { ([string]$_.Object.text).Length } | Measure-Object -Sum).Sum
            if ($null -eq $uncoveredChars) { $uncoveredChars = 0 }
            $oldest = $uncoveredEvents | Sort-Object { [DateTime]$_.Object.timestamp } | Select-Object -First 1
            $oldestAgeDays = $null
            if ($null -ne $oldest) {
                $oldestAgeDays = [Math]::Floor(([DateTime]::UtcNow - ([DateTime]$oldest.Object.timestamp).ToUniversalTime()).TotalDays)
            }
            $weeklyUncovered = @($summaries | Where-Object { $_.Object.tier -eq 'weekly' -and @($_.Object.covered_by).Count -eq 0 })
            $monthlyUncovered = @($summaries | Where-Object { $_.Object.tier -eq 'monthly' -and @($_.Object.covered_by).Count -eq 0 })
            $weeklyDue = ($uncoveredEvents.Count -ge 8 -or $uncoveredChars -ge 8000 -or ($null -ne $oldestAgeDays -and $oldestAgeDays -ge 8))
            $monthlyDueSources = @($weeklyUncovered | Where-Object {
                $age = [Math]::Floor(([DateTime]::UtcNow - ([DateTime]$_.Object.window_end).ToUniversalTime()).TotalDays)
                $age -ge 31
            })
            if ($weeklyUncovered.Count -ge 4) { $monthlyDueSources = $weeklyUncovered }
            $durableDueSources = @($monthlyUncovered | Where-Object {
                $age = [Math]::Floor(([DateTime]::UtcNow - ([DateTime]$_.Object.window_end).ToUniversalTime()).TotalDays)
                $age -ge 181
            })
            if ($monthlyUncovered.Count -ge 6) { $durableDueSources = $monthlyUncovered }
            [pscustomobject]@{
                schema_version = $SchemaVersion
                event_count = $events.Count
                summary_count = $summaries.Count
                uncovered_event_count = $uncoveredEvents.Count
                uncovered_event_characters = [int]$uncoveredChars
                oldest_uncovered_event_age_days = $oldestAgeDays
                should_compact_weekly = $weeklyDue
                weekly_summaries_ready_for_monthly = $monthlyDueSources.Count
                monthly_summaries_ready_for_durable = $durableDueSources.Count
                compaction_jobs = @(
                    [pscustomobject]@{
                        tier = 'weekly'
                        due = $weeklyDue
                        source_ids = if ($weeklyDue) { @($uncoveredEvents | ForEach-Object { [string]$_.Object.id }) } else { @() }
                        reason = 'eight events, 8000 characters, or oldest event age of eight days'
                    },
                    [pscustomobject]@{
                        tier = 'monthly'
                        due = ($monthlyDueSources.Count -gt 0)
                        source_ids = @($monthlyDueSources | ForEach-Object { [string]$_.Object.id })
                        reason = 'four weekly summaries or a weekly window older than 30 days'
                    },
                    [pscustomobject]@{
                        tier = 'durable'
                        due = ($durableDueSources.Count -gt 0)
                        source_ids = @($durableDueSources | ForEach-Object { [string]$_.Object.id })
                        reason = 'six monthly summaries or a monthly window older than 180 days'
                    }
                )
            } | ConvertTo-Json
        }

        'Compact' {
            $summaryText = Get-InputText
            $allRecords = Get-AllRecordsById
            $requestedIds = @(ConvertTo-IdList -Value $SourceIds)
            if ($requestedIds.Count -eq 0) {
                if ($Tier -eq 'weekly') {
                    $requestedIds = @((Get-EventRecords) | Where-Object { @($_.Object.covered_by).Count -eq 0 } | ForEach-Object { [string]$_.Object.id })
                }
                elseif ($Tier -eq 'monthly') {
                    $requestedIds = @((Get-SummaryRecords) | Where-Object { $_.Object.tier -eq 'weekly' -and @($_.Object.covered_by).Count -eq 0 } | ForEach-Object { [string]$_.Object.id })
                }
                else {
                    $requestedIds = @((Get-SummaryRecords) | Where-Object { $_.Object.tier -eq 'monthly' -and @($_.Object.covered_by).Count -eq 0 } | ForEach-Object { [string]$_.Object.id })
                }
            }
            if ($requestedIds.Count -eq 0) {
                throw "No uncovered sources are available for tier '$Tier'."
            }

            $sourceRecords = @()
            foreach ($sourceId in $requestedIds) {
                if (-not $allRecords.ContainsKey($sourceId)) {
                    throw "Source ID does not exist: $sourceId"
                }
                $record = $allRecords[$sourceId]
                $allowed = ($Tier -eq 'weekly' -and $record.Object.object_type -eq 'event') -or
                    ($Tier -eq 'monthly' -and $record.Object.object_type -eq 'summary' -and $record.Object.tier -eq 'weekly') -or
                    ($Tier -eq 'durable' -and $record.Object.object_type -eq 'summary' -and $record.Object.tier -eq 'monthly')
                if (-not $allowed) {
                    throw "Source '$sourceId' is not valid for tier '$Tier'."
                }
                $sourceRecords += $record
            }

            $summaryId = New-ObjectId -Prefix "sum-$Tier"
            $summaryPath = Assert-ContainedPath -Base $contentPath -Candidate (Join-Path (Join-Path $summariesRoot $Tier) "$summaryId.json")
            $timestamps = @($sourceRecords | ForEach-Object { [DateTime]$_.Object.timestamp } | Sort-Object)
            $summary = [ordered]@{
                schema_version = $SchemaVersion
                object_type = 'summary'
                id = $summaryId
                purpose = $purposeSlug
                content = $contentSlug
                session_id = Get-CurrentSessionId
                timestamp = Get-UtcTimestamp
                tier = $Tier
                window_start = $timestamps[0].ToUniversalTime().ToString('o')
                window_end = $timestamps[$timestamps.Count - 1].ToUniversalTime().ToString('o')
                source_ids = @($requestedIds)
                covered_by = @()
                text = $summaryText
            }
            Write-JsonAtomic -Path $summaryPath -Value $summary
            foreach ($record in $sourceRecords) {
                Set-SourceCoveredBy -Record $record -SummaryId $summaryId
            }
            Invalidate-CurrentContext
            Update-Manifest -CurrentSessionId (Get-CurrentSessionId)
            [pscustomobject]@{ id = $summaryId; tier = $Tier; path = $summaryPath; source_ids = @($requestedIds) } | ConvertTo-Json -Depth 10
        }

        'WriteCheckpoint' {
            $checkpointText = Get-InputText
            if ([string]::IsNullOrWhiteSpace($TaskId)) {
                throw '-TaskId is required for WriteCheckpoint.'
            }
            $currentSession = Get-CurrentSessionId
            $checkpointId = New-ObjectId -Prefix 'cp'
            if ([string]::IsNullOrWhiteSpace($ParentCheckpointId)) {
                $currentRecord = Get-CurrentCheckpointRecord
                if ($null -ne $currentRecord) {
                    $ParentCheckpointId = [string]$currentRecord.Object.id
                }
            }
            $checkpointDirectory = Join-Path $checkpointsRoot $currentSession
            $checkpointPath = Assert-ContainedPath -Base $contentPath -Candidate (Join-Path $checkpointDirectory "$checkpointId.json")
            $checkpoint = [ordered]@{
                schema_version = $SchemaVersion
                object_type = 'checkpoint'
                id = $checkpointId
                task_id = $TaskId
                session_id = $currentSession
                parent_checkpoint_id = if ([string]::IsNullOrWhiteSpace($ParentCheckpointId)) { $null } else { $ParentCheckpointId }
                timestamp = Get-UtcTimestamp
                capability_manifest = Join-Path $stateRoot 'capabilities.json'
                text = $checkpointText
            }
            Write-JsonAtomic -Path $checkpointPath -Value $checkpoint
            Invalidate-CurrentContext
            $pointer = [ordered]@{
                schema_version = $SchemaVersion
                checkpoint_id = $checkpointId
                session_id = $currentSession
                path = $checkpointPath
                updated_at = Get-UtcTimestamp
            }
            Write-JsonAtomic -Path (Join-Path $stateRoot 'current-checkpoint.json') -Value $pointer
            Update-Manifest -CurrentSessionId $currentSession
            [pscustomobject]@{ id = $checkpointId; path = $checkpointPath; session_id = $currentSession } | ConvertTo-Json
        }

        'Fork' {
            $currentRecord = Get-CurrentCheckpointRecord
            if ([string]::IsNullOrWhiteSpace($ParentCheckpointId)) {
                if ($null -eq $currentRecord) {
                    throw 'No current checkpoint exists. Provide -ParentCheckpointId.'
                }
                $ParentCheckpointId = [string]$currentRecord.Object.id
            }
            $records = Get-AllRecordsById
            if (-not $records.ContainsKey($ParentCheckpointId)) {
                throw "Parent checkpoint does not exist: $ParentCheckpointId"
            }
            $parent = $records[$ParentCheckpointId]
            if ($parent.Object.object_type -ne 'checkpoint') {
                throw "Parent ID is not a checkpoint: $ParentCheckpointId"
            }
            $newSession = if ([string]::IsNullOrWhiteSpace($SessionId)) {
                "session-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
            }
            else { $SessionId }
            $forkId = New-ObjectId -Prefix 'cp'
            $forkPath = Assert-ContainedPath -Base $contentPath -Candidate (Join-Path (Join-Path $checkpointsRoot $newSession) "$forkId.json")
            $fork = [ordered]@{
                schema_version = $SchemaVersion
                object_type = 'checkpoint'
                id = $forkId
                task_id = $parent.Object.task_id
                session_id = $newSession
                parent_session_id = $parent.Object.session_id
                parent_checkpoint_id = $ParentCheckpointId
                fork_number = $ForkNumber
                timestamp = Get-UtcTimestamp
                capability_manifest = Join-Path $stateRoot 'capabilities.json'
                text = $parent.Object.text
            }
            Write-JsonAtomic -Path $forkPath -Value $fork
            Invalidate-CurrentContext
            Write-JsonAtomic -Path (Join-Path $stateRoot 'current-checkpoint.json') -Value ([ordered]@{
                schema_version = $SchemaVersion
                checkpoint_id = $forkId
                session_id = $newSession
                path = $forkPath
                updated_at = Get-UtcTimestamp
            })
            Update-Manifest -CurrentSessionId $newSession
            [pscustomobject]@{ id = $forkId; session_id = $newSession; parent_checkpoint_id = $ParentCheckpointId; path = $forkPath } | ConvertTo-Json
        }

        'WriteCapabilities' {
            $capabilityText = Get-InputText
            try {
                $capabilities = $capabilityText | ConvertFrom-Json
            }
            catch {
                throw "Capability input is not valid JSON: $($_.Exception.Message)"
            }
            Add-PropertyIfMissing -Object $capabilities -Name 'schema_version' -Value $SchemaVersion
            Add-PropertyIfMissing -Object $capabilities -Name 'client' -Value $Client
            Add-PropertyIfMissing -Object $capabilities -Name 'client_version' -Value $null
            Add-PropertyIfMissing -Object $capabilities -Name 'captured_at' -Value (Get-UtcTimestamp)
            Add-PropertyIfMissing -Object $capabilities -Name 'expires_at' -Value $null
            Add-PropertyIfMissing -Object $capabilities -Name 'workspace_roots' -Value @()
            if ($null -eq $capabilities.PSObject.Properties['tools']) {
                throw "Capability input requires a 'tools' object."
            }
            if ($null -eq $capabilities.PSObject.Properties['continuation']) {
                throw "Capability input requires a 'continuation' object."
            }
            $capabilityId = New-ObjectId -Prefix 'cap'
            Add-PropertyIfMissing -Object $capabilities -Name 'id' -Value $capabilityId
            $historyPath = Join-Path (Join-Path $stateRoot 'capabilities') "$capabilityId.json"
            Write-JsonAtomic -Path $historyPath -Value $capabilities
            Write-JsonAtomic -Path (Join-Path $stateRoot 'capabilities.json') -Value $capabilities
            Invalidate-CurrentContext
            [pscustomobject]@{ id = $capabilityId; path = (Join-Path $stateRoot 'capabilities.json'); history_path = $historyPath } | ConvertTo-Json
        }

        'RegisterTranscript' {
            if ([string]::IsNullOrWhiteSpace($TranscriptPath)) {
                throw '-TranscriptPath is required for RegisterTranscript.'
            }
            $indexPath = Join-Path $transcriptsRoot 'index.json'
            $index = Read-JsonFile -Path $indexPath
            if ($null -eq $index) {
                $index = [pscustomobject]@{ schema_version = $SchemaVersion; entries = @() }
            }
            $entry = [pscustomobject]@{
                id = New-ObjectId -Prefix 'transcript'
                session_id = Get-CurrentSessionId
                parent_session_id = if ([string]::IsNullOrWhiteSpace($ParentSessionId)) { $null } else { $ParentSessionId }
                fork_number = $ForkNumber
                sidechain_number = $SidechainNumber
                client = $Client
                path_or_id = $TranscriptPath
                registered_at = Get-UtcTimestamp
            }
            $index.entries = @($index.entries) + $entry
            Write-JsonAtomic -Path $indexPath -Value $index
            $entry | ConvertTo-Json -Depth 10
        }

        'BuildContext' {
            $contextId = New-ObjectId -Prefix 'ctx'
            $sections = [Collections.Generic.List[object]]::new()
            $budgetState = @{ used = 0; exceeded = $false }
            $coveredIds = @{}
            $recordIndex = Get-AllRecordsById

            function Add-ContextSection {
                param($Item, [string]$Type)
                $textValue = [string]$Item.text
                $length = $textValue.Length
                if ($budgetState.used + $length -gt $MaxChars -and $sections.Count -gt 0) {
                    return $false
                }
                if ($budgetState.used + $length -gt $MaxChars) {
                    $budgetState.exceeded = $true
                }
                $sections.Add([pscustomobject]@{
                    id = [string]$Item.id
                    type = $Type
                    timestamp = [string]$Item.timestamp
                    text = $textValue
                })
                $budgetState.used += $length
                return $true
            }

            function Mark-CoveredSources {
                param($Item)
                if ($null -eq $Item.PSObject.Properties['source_ids']) { return }
                foreach ($sourceIdValue in @($Item.source_ids)) {
                    $sourceId = [string]$sourceIdValue
                    if ($coveredIds.ContainsKey($sourceId)) { continue }
                    $coveredIds[$sourceId] = $true
                    if ($recordIndex.ContainsKey($sourceId)) {
                        $sourceObject = $recordIndex[$sourceId].Object
                        if ($sourceObject.object_type -eq 'summary') {
                            Mark-CoveredSources -Item $sourceObject
                        }
                    }
                }
            }

            $checkpointRecord = Get-CurrentCheckpointRecord
            if ($null -ne $checkpointRecord) {
                $null = Add-ContextSection -Item $checkpointRecord.Object -Type 'checkpoint'
            }

            $summaries = @(Get-SummaryRecords)
            foreach ($candidateTier in @('durable', 'monthly', 'weekly')) {
                $candidates = @($summaries | Where-Object { $_.Object.tier -eq $candidateTier } | Sort-Object { [DateTime]$_.Object.timestamp } -Descending)
                foreach ($candidate in $candidates) {
                    if ($coveredIds.ContainsKey([string]$candidate.Object.id)) { continue }
                    if (-not (Add-ContextSection -Item $candidate.Object -Type "summary:$candidateTier")) { break }
                    Mark-CoveredSources -Item $candidate.Object
                }
            }

            $cutoff = [DateTime]::UtcNow.AddDays(-$RecentDays)
            $recentEvents = @((Get-EventRecords) | Where-Object { ([DateTime]$_.Object.timestamp).ToUniversalTime() -ge $cutoff } | Sort-Object { [DateTime]$_.Object.timestamp } -Descending)
            foreach ($event in $recentEvents) {
                if ($coveredIds.ContainsKey([string]$event.Object.id)) { continue }
                if (-not (Add-ContextSection -Item $event.Object -Type 'event')) { break }
            }

            $packet = [ordered]@{
                schema_version = $SchemaVersion
                object_type = 'context_packet'
                id = $contextId
                purpose = $purposeSlug
                content = $contentSlug
                session_id = Get-CurrentSessionId
                timestamp = Get-UtcTimestamp
                max_characters = $MaxChars
                used_characters = $budgetState.used
                budget_exceeded_by_required_checkpoint = $budgetState.exceeded
                source_ids = @($sections | ForEach-Object { $_.id })
                sections = @($sections)
            }
            $versionPath = Join-Path $contextsRoot "$contextId.json"
            Write-JsonAtomic -Path $versionPath -Value $packet
            Write-JsonAtomic -Path (Join-Path $contextsRoot 'current.json') -Value $packet
            [pscustomobject]@{ id = $contextId; path = $versionPath; current_path = (Join-Path $contextsRoot 'current.json'); used_characters = $budgetState.used; source_ids = $packet.source_ids } | ConvertTo-Json -Depth 20
        }

        'Recall' {
            $currentContextPath = Join-Path $contextsRoot 'current.json'
            if (Test-Path -LiteralPath $currentContextPath) {
                [IO.File]::ReadAllText($currentContextPath)
                break
            }
            $checkpoint = Get-CurrentCheckpointRecord
            $summaries = @(Get-SummaryRecords | Sort-Object { [DateTime]$_.Object.timestamp } -Descending | Select-Object -First $MaxItems)
            $events = @(Get-EventRecords | Sort-Object { [DateTime]$_.Object.timestamp } -Descending | Select-Object -First $MaxItems)
            [pscustomobject]@{
                checkpoint = if ($null -eq $checkpoint) { $null } else { $checkpoint.Object }
                summaries = @($summaries | ForEach-Object { $_.Object })
                events = @($events | ForEach-Object { $_.Object })
            } | ConvertTo-Json -Depth 30
        }

        'Verify' {
            $issues = [Collections.Generic.List[string]]::new()
            $manifest = Read-JsonFile -Path $manifestPath
            if ($null -eq $manifest) {
                $issues.Add('manifest.json is missing or empty.')
            }
            elseif ([int]$manifest.schema_version -ne $SchemaVersion) {
                $issues.Add("Manifest schema version is not $SchemaVersion.")
            }

            $records = @((Get-EventRecords) + (Get-ArchivedEventRecords) + (Get-SummaryRecords) + (Get-CheckpointRecords))
            $idMap = @{}
            foreach ($record in $records) {
                if ($null -eq $record.Object -or $null -eq $record.Object.PSObject.Properties['id']) {
                    $issues.Add("Object without ID: $($record.Path)")
                    continue
                }
                $id = [string]$record.Object.id
                if ($idMap.ContainsKey($id)) {
                    $issues.Add("Duplicate object ID: $id")
                }
                else {
                    $idMap[$id] = $record
                }
            }

            foreach ($record in $records) {
                if ($null -eq $record.Object -or $null -eq $record.Object.PSObject.Properties['id']) { continue }
                $id = [string]$record.Object.id
                if ($record.Object.object_type -eq 'summary') {
                    foreach ($sourceId in @($record.Object.source_ids)) {
                        if (-not $idMap.ContainsKey([string]$sourceId)) {
                            $issues.Add("Summary $id references missing source $sourceId")
                        }
                        else {
                            $sourceObject = $idMap[[string]$sourceId].Object
                            if (@($sourceObject.covered_by) -notcontains $id) {
                                $issues.Add("Source $sourceId does not record coverage by $id")
                            }
                            $lineageValid = ($record.Object.tier -eq 'weekly' -and $sourceObject.object_type -eq 'event') -or
                                ($record.Object.tier -eq 'monthly' -and $sourceObject.object_type -eq 'summary' -and $sourceObject.tier -eq 'weekly') -or
                                ($record.Object.tier -eq 'durable' -and $sourceObject.object_type -eq 'summary' -and $sourceObject.tier -eq 'monthly')
                            if (-not $lineageValid) {
                                $issues.Add("Summary $id has invalid tier lineage from source $sourceId")
                            }
                        }
                    }
                }
                if ($null -ne $record.Object.PSObject.Properties['covered_by']) {
                    foreach ($summaryId in @($record.Object.covered_by)) {
                        if (-not $idMap.ContainsKey([string]$summaryId)) {
                            $issues.Add("Object $id references missing covering summary $summaryId")
                        }
                        elseif ($idMap[[string]$summaryId].Object.object_type -ne 'summary' -or @($idMap[[string]$summaryId].Object.source_ids) -notcontains $id) {
                            $issues.Add("Object $id has nonreciprocal coverage reference $summaryId")
                        }
                    }
                }
                if ($record.Object.object_type -eq 'checkpoint' -and -not [string]::IsNullOrWhiteSpace([string]$record.Object.parent_checkpoint_id)) {
                    if (-not $idMap.ContainsKey([string]$record.Object.parent_checkpoint_id)) {
                        $issues.Add("Checkpoint $id references missing parent $($record.Object.parent_checkpoint_id)")
                    }
                }
            }

            $pointerPath = Join-Path $stateRoot 'current-checkpoint.json'
            $pointer = Read-JsonFile -Path $pointerPath
            if ($null -ne $pointer) {
                try {
                    $pointerTarget = Assert-ContainedPath -Base $contentPath -Candidate ([string]$pointer.path)
                    if (-not (Test-Path -LiteralPath $pointerTarget)) {
                        $issues.Add('Current checkpoint pointer target is missing.')
                    }
                }
                catch {
                    $issues.Add("Current checkpoint pointer is unsafe: $($_.Exception.Message)")
                }
            }

            $currentContextPath = Join-Path $contextsRoot 'current.json'
            $currentContext = Read-JsonFile -Path $currentContextPath
            if ($null -ne $currentContext) {
                foreach ($sourceId in @($currentContext.source_ids)) {
                    if (-not $idMap.ContainsKey([string]$sourceId)) {
                        $issues.Add("Current context references missing source $sourceId")
                    }
                }
                if ($null -ne $pointer -and @($currentContext.source_ids) -notcontains [string]$pointer.checkpoint_id) {
                    $issues.Add('Current context does not contain the current checkpoint.')
                }
            }

            $capabilityPath = Join-Path $stateRoot 'capabilities.json'
            $capabilities = Read-JsonFile -Path $capabilityPath
            if ($null -ne $capabilities) {
                if ($null -eq $capabilities.PSObject.Properties['tools']) { $issues.Add('Capability manifest lacks tools.') }
                if ($null -eq $capabilities.PSObject.Properties['continuation']) { $issues.Add('Capability manifest lacks continuation.') }
            }

            $result = [pscustomobject]@{
                schema_version = $SchemaVersion
                valid = ($issues.Count -eq 0)
                issue_count = $issues.Count
                issues = @($issues)
                object_count = $records.Count
            }
            $result | ConvertTo-Json -Depth 20
            if ($issues.Count -gt 0) { throw "Ledger verification failed with $($issues.Count) issue(s)." }
        }

        'Expire' {
            $cutoff = [DateTime]::UtcNow.AddDays(-$RetentionDays)
            $candidates = @((Get-EventRecords) | Where-Object {
                ([DateTime]$_.Object.timestamp).ToUniversalTime() -lt $cutoff -and
                @($_.Object.covered_by).Count -gt 0 -and
                [int]$_.Object.importance -lt 3
            })
            $moved = @()
            if ($ConfirmAction) {
                foreach ($candidate in $candidates) {
                    $relative = $candidate.Path.Substring($eventsRoot.Length).TrimStart('\', '/')
                    $destination = Assert-ContainedPath -Base $contentPath -Candidate (Join-Path (Join-Path $archiveRoot 'events') $relative)
                    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
                    Move-Item -LiteralPath $candidate.Path -Destination $destination
                    $moved += [string]$candidate.Object.id
                }
                Invalidate-CurrentContext
                Update-Manifest -CurrentSessionId (Get-CurrentSessionId)
            }
            [pscustomobject]@{
                retention_days = $RetentionDays
                confirm_required = (-not $ConfirmAction)
                candidate_ids = @($candidates | ForEach-Object { [string]$_.Object.id })
                moved_ids = @($moved)
            } | ConvertTo-Json -Depth 10
        }

        'Delete' {
            if ([string]::IsNullOrWhiteSpace($TargetId)) {
                throw '-TargetId is required for Delete.'
            }
            if (-not $ConfirmAction) {
                throw 'Delete requires -ConfirmAction.'
            }
            $records = Get-AllRecordsById
            if (-not $records.ContainsKey($TargetId)) {
                throw "Target ID does not exist: $TargetId"
            }
            $target = $records[$TargetId]
            if ($target.Object.object_type -eq 'checkpoint') {
                throw 'Delete does not remove checkpoints. Preserve task lineage.'
            }
            if (@($target.Object.covered_by).Count -gt 0) {
                throw 'Delete refuses an object referenced by a higher summary. Use retention/expiration or rebuild summaries first.'
            }
            foreach ($record in $records.Values) {
                if ($record.Object.object_type -eq 'summary' -and @($record.Object.source_ids) -contains $TargetId) {
                    throw "Delete refuses an object referenced by summary $($record.Object.id)."
                }
            }
            $safeTarget = Assert-ContainedPath -Base $contentPath -Candidate $target.Path
            Remove-Item -LiteralPath $safeTarget -Force
            Invalidate-CurrentContext
            Update-Manifest -CurrentSessionId (Get-CurrentSessionId)
            [pscustomobject]@{ deleted_id = $TargetId; deleted_path = $safeTarget } | ConvertTo-Json
        }
    }
}
finally {
    if ($null -ne $lockHandle) {
        $lockHandle.Dispose()
    }
}
