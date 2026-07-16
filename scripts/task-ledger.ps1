[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'AddRow', 'UpdateRow', 'RenewLease', 'RecordEvidence', 'NextReady', 'List', 'Verify', 'ExportTable')]
    [string]$Operation,

    [Parameter(Mandatory = $true)]
    [string]$TaskFile,

    [string]$TaskId,
    [string]$Objective,
    [string]$InputFile,
    [string]$JsonText,
    [string]$RowId,
    [string]$EvidenceId,
    [string]$EvidencePath,
    [string]$EvidenceText,
    [string]$OwnerId,
    [string]$AttemptId,

    [ValidateRange(30, 86400)]
    [int]$LeaseSeconds = 900,

    [ValidateRange(1, 300)]
    [int]$LockTimeoutSeconds = 30,

    [ValidateRange(10, 1000)]
    [int]$LockRetryBaseMilliseconds = 40,

    [ValidateSet('pending', 'active', 'passed', 'failed', 'blocked', 'abandoned')]
    [string]$Status,

    [ValidateSet('unknown', 'not_required', 'requested', 'granted', 'denied')]
    [string]$PermissionState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SchemaVersion = 2
$ExecutionClasses = @('read_only', 'local_reversible', 'external_reversible', 'irreversible', 'scheduled')
$Statuses = @('pending', 'active', 'passed', 'failed', 'blocked', 'abandoned')

function Get-UtcTimestamp { return [DateTime]::UtcNow.ToString('o') }

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Write-JsonAtomic {
    param([string]$Path, $Value)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.tmp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $backup = Join-Path $directory ('.bak-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    try {
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup, $true)
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Read-InputObject {
    $raw = $null
    if (-not [string]::IsNullOrWhiteSpace($InputFile)) {
        $full = [IO.Path]::GetFullPath($InputFile)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Input file does not exist: $full"
        }
        $raw = [IO.File]::ReadAllText($full)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($JsonText)) {
        $raw = $JsonText
    }
    elseif ([Console]::IsInputRedirected) {
        $raw = [Console]::In.ReadToEnd()
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Provide row JSON with -InputFile, -JsonText, or redirected standard input for operation '$Operation'."
    }
    try { return ($raw | ConvertFrom-Json) }
    catch { throw "Input file is not valid JSON: $($_.Exception.Message)" }
}

function Add-PropertyIfMissing {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-Task {
    $task = Read-JsonFile -Path $TaskFile
    if ($null -eq $task) { throw 'Task ledger is missing. Run Init first.' }
    return $task
}

function Get-Row {
    param($Task, [string]$Id)
    $matches = @($Task.rows | Where-Object { $_.id -eq $Id })
    if ($matches.Count -eq 0) { throw "Task row does not exist: $Id" }
    if ($matches.Count -gt 1) { throw "Duplicate task row ID: $Id" }
    return $matches[0]
}

function Assert-RowShape {
    param($Row, $Task)

    $required = @('id', 'target_state', 'action_path', 'execution_class', 'permission_state', 'idempotency_key', 'evidence_id', 'status', 'failure_recovery')
    foreach ($name in $required) {
        if ($null -eq $Row.PSObject.Properties[$name]) { throw "Task row requires '$name'." }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Row.id)) { throw 'Task row ID cannot be empty.' }
    if ($ExecutionClasses -notcontains [string]$Row.execution_class) { throw "Invalid execution_class: $($Row.execution_class)" }
    if ($Statuses -notcontains [string]$Row.status) { throw "Invalid status: $($Row.status)" }
    if (@('unknown', 'not_required', 'requested', 'granted', 'denied') -notcontains [string]$Row.permission_state) {
        throw "Invalid permission_state: $($Row.permission_state)"
    }
    if ($Row.execution_class -ne 'read_only' -and [string]::IsNullOrWhiteSpace([string]$Row.idempotency_key)) {
        throw 'Mutating and scheduled rows require idempotency_key.'
    }
    if ($Row.execution_class -in @('irreversible', 'scheduled') -and -not [bool]$Row.checkpoint_before) {
        throw "$($Row.execution_class) rows require checkpoint_before=true."
    }
    foreach ($dependency in @($Row.dependencies)) {
        if (@($Task.rows | Where-Object { $_.id -eq $dependency }).Count -eq 0) {
            throw "Missing dependency '$dependency' for row '$($Row.id)'."
        }
    }
}

function Test-DependenciesPassed {
    param($Task, $Row)
    foreach ($dependency in @($Row.dependencies)) {
        $dependencyRow = Get-Row -Task $Task -Id ([string]$dependency)
        if ($dependencyRow.status -ne 'passed') { return $false }
    }
    return $true
}

function Test-PermissionReady {
    param($Row)
    return $Row.permission_state -in @('granted', 'not_required')
}

$TaskFile = [IO.Path]::GetFullPath($TaskFile)
if ($env:OS -eq 'Windows_NT' -and $TaskFile.Length -gt 240) {
    throw "Task file exceeds the safe Windows path budget (240 characters): $TaskFile"
}
$taskDirectory = Split-Path -Parent $TaskFile
$lockPath = Join-Path $taskDirectory ((Split-Path -Leaf $TaskFile) + '.lock')
$isMutation = $Operation -in @('Init', 'AddRow', 'UpdateRow', 'RenewLease', 'RecordEvidence')
$lock = $null

if ($isMutation) {
    [IO.Directory]::CreateDirectory($taskDirectory) | Out-Null
}
elseif (-not (Test-Path -LiteralPath $taskDirectory -PathType Container)) {
    throw 'Task ledger is missing. Run Init first.'
}

try {
    if ($isMutation) {
        $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
        $attempt = 0
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                break
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
        if ($null -eq $lock) { throw "Timed out after $LockTimeoutSeconds second(s) acquiring task lock: $lockPath" }
    }

    switch ($Operation) {
        'Init' {
            if (Test-Path -LiteralPath $TaskFile) { throw "Task ledger already exists: $TaskFile" }
            if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Objective)) {
                throw 'Init requires -TaskId and -Objective.'
            }
            $now = Get-UtcTimestamp
            $task = [ordered]@{
                schema_version = $SchemaVersion
                object_type = 'task_ledger'
                task_id = $TaskId
                objective = $Objective
                created_at = $now
                updated_at = $now
                rows = @()
            }
            Write-JsonAtomic -Path $TaskFile -Value $task
            [pscustomobject]@{ task_id = $TaskId; path = $TaskFile } | ConvertTo-Json
        }

        'AddRow' {
            $task = Get-Task
            $row = Read-InputObject
            Add-PropertyIfMissing -Object $row -Name 'inputs' -Value @()
            Add-PropertyIfMissing -Object $row -Name 'dependencies' -Value @()
            Add-PropertyIfMissing -Object $row -Name 'checkpoint_before' -Value $false
            Add-PropertyIfMissing -Object $row -Name 'checkpoint_after' -Value $false
            Add-PropertyIfMissing -Object $row -Name 'retry_limit' -Value 1
            Add-PropertyIfMissing -Object $row -Name 'retry_count' -Value 0
            Add-PropertyIfMissing -Object $row -Name 'evidence' -Value @()
            Add-PropertyIfMissing -Object $row -Name 'next_check' -Value $null
            Add-PropertyIfMissing -Object $row -Name 'attempt_id' -Value $null
            Add-PropertyIfMissing -Object $row -Name 'owner_id' -Value $null
            Add-PropertyIfMissing -Object $row -Name 'lease_expires_at' -Value $null
            Add-PropertyIfMissing -Object $row -Name 'fencing_token' -Value 0
            Add-PropertyIfMissing -Object $row -Name 'created_at' -Value (Get-UtcTimestamp)
            Add-PropertyIfMissing -Object $row -Name 'updated_at' -Value (Get-UtcTimestamp)
            if (@($task.rows | Where-Object { $_.id -eq $row.id }).Count -gt 0) {
                throw "Task row already exists: $($row.id)"
            }
            Assert-RowShape -Row $row -Task $task
            $task.rows = @($task.rows) + $row
            $task.updated_at = Get-UtcTimestamp
            Write-JsonAtomic -Path $TaskFile -Value $task
            $row | ConvertTo-Json -Depth 20
        }

        'RecordEvidence' {
            if ([string]::IsNullOrWhiteSpace($RowId)) { throw '-RowId is required.' }
            $task = Get-Task
            $row = Get-Row -Task $task -Id $RowId
            if ([string]$row.status -ne 'active') { throw 'Evidence can be recorded only for an active row.' }
            if (-not [string]::IsNullOrWhiteSpace($AttemptId)) {
                if ($null -eq $row.PSObject.Properties['attempt_id'] -or [string]$row.attempt_id -ne $AttemptId) {
                    throw "Evidence attempt does not match the active row attempt: $AttemptId"
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
                if ($null -eq $row.PSObject.Properties['owner_id'] -or [string]$row.owner_id -ne $OwnerId) {
                    throw "Evidence owner does not match the active row owner: $OwnerId"
                }
            }
            $resolvedEvidenceId = if ([string]::IsNullOrWhiteSpace($EvidenceId)) { [string]$row.evidence_id } else { $EvidenceId }
            if ([string]::IsNullOrWhiteSpace($resolvedEvidenceId)) { throw 'Evidence ID cannot be empty.' }
            $content = $EvidenceText
            if (-not [string]::IsNullOrWhiteSpace($InputFile)) {
                $content = [IO.File]::ReadAllText([IO.Path]::GetFullPath($InputFile))
            }
            if ([string]::IsNullOrWhiteSpace($content) -and [string]::IsNullOrWhiteSpace($EvidencePath)) {
                throw 'Provide -EvidenceText, -InputFile, or -EvidencePath.'
            }
            $existingInOtherRows = @($task.rows | Where-Object { $_.id -ne $RowId } | ForEach-Object { @($_.evidence) } | Where-Object { $_.id -eq $resolvedEvidenceId })
            if ($existingInOtherRows.Count -gt 0) {
                throw "Evidence ID already belongs to another row: $resolvedEvidenceId"
            }
            $existing = @($row.evidence | Where-Object { $_.id -eq $resolvedEvidenceId })
            if ($existing.Count -gt 0) {
                $samePath = [string]$existing[0].path_or_id -eq [string]$(if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $null } else { $EvidencePath })
                $sameContent = [string]$existing[0].content -eq [string]$(if ([string]::IsNullOrWhiteSpace($content)) { $null } else { $content })
                if ($existing.Count -eq 1 -and $samePath -and $sameContent) {
                    [pscustomobject]@{ id = $resolvedEvidenceId; idempotent = $true; evidence = $existing[0] } | ConvertTo-Json -Depth 10
                    break
                }
                throw "Evidence ID already exists with different content or duplicate entries: $resolvedEvidenceId"
            }
            $evidence = [pscustomobject]@{
                id = $resolvedEvidenceId
                captured_at = Get-UtcTimestamp
                attempt_id = if ($null -eq $row.PSObject.Properties['attempt_id']) { $null } else { $row.attempt_id }
                owner_id = if ($null -eq $row.PSObject.Properties['owner_id']) { $null } else { $row.owner_id }
                path_or_id = if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $null } else { $EvidencePath }
                content = if ([string]::IsNullOrWhiteSpace($content)) { $null } else { $content }
            }
            $row.evidence = @($row.evidence) + $evidence
            $row.updated_at = Get-UtcTimestamp
            $task.updated_at = Get-UtcTimestamp
            Write-JsonAtomic -Path $TaskFile -Value $task
            $evidence | ConvertTo-Json -Depth 10
        }

        'RenewLease' {
            if ([string]::IsNullOrWhiteSpace($RowId) -or [string]::IsNullOrWhiteSpace($OwnerId) -or [string]::IsNullOrWhiteSpace($AttemptId)) {
                throw 'RenewLease requires -RowId, -OwnerId, and -AttemptId.'
            }
            $task = Get-Task
            $row = Get-Row -Task $task -Id $RowId
            if ([string]$row.status -ne 'active') { throw 'Only an active row lease can be renewed.' }
            if ($null -eq $row.PSObject.Properties['owner_id'] -or [string]$row.owner_id -ne $OwnerId) { throw 'Lease owner does not match.' }
            if ($null -eq $row.PSObject.Properties['attempt_id'] -or [string]$row.attempt_id -ne $AttemptId) { throw 'Lease attempt does not match.' }
            $row.lease_expires_at = [DateTime]::UtcNow.AddSeconds($LeaseSeconds).ToString('o')
            $row.updated_at = Get-UtcTimestamp
            $task.updated_at = Get-UtcTimestamp
            Write-JsonAtomic -Path $TaskFile -Value $task
            [pscustomobject]@{ row_id = $RowId; owner_id = $OwnerId; attempt_id = $AttemptId; lease_expires_at = $row.lease_expires_at } | ConvertTo-Json
        }

        'UpdateRow' {
            if ([string]::IsNullOrWhiteSpace($RowId)) { throw '-RowId is required.' }
            $task = Get-Task
            $row = Get-Row -Task $task -Id $RowId
            if (-not [string]::IsNullOrWhiteSpace($PermissionState)) {
                $row.permission_state = $PermissionState
            }
            if (-not [string]::IsNullOrWhiteSpace($Status)) {
                $allowedTransitions = @{
                    pending = @('active', 'blocked')
                    active = @('passed', 'failed', 'blocked')
                    failed = @('active', 'abandoned')
                    blocked = @('pending')
                    passed = @()
                    abandoned = @()
                }
                $current = [string]$row.status
                if ($allowedTransitions[$current] -notcontains $Status) {
                    throw "Invalid state transition: $current -> $Status"
                }
                if ($Status -eq 'active') {
                    if ($current -eq 'failed' -and [int]$row.retry_count -gt [int]$row.retry_limit) {
                        throw 'Retry count exceeds retry limit; change the task or abandon the row.'
                    }
                    if (-not (Test-DependenciesPassed -Task $task -Row $row)) { throw 'Cannot activate a row with incomplete dependencies.' }
                    if (-not (Test-PermissionReady -Row $row)) { throw 'Cannot activate a row without ready permission.' }
                    $activeMutations = @($task.rows | Where-Object {
                        $_.status -eq 'active' -and $_.execution_class -ne 'read_only' -and $_.id -ne $row.id
                    })
                    if ($row.execution_class -ne 'read_only' -and $activeMutations.Count -gt 0) {
                        throw "Another mutation row is active: $($activeMutations[0].id)"
                    }
                    Add-PropertyIfMissing -Object $row -Name 'attempt_id' -Value $null
                    Add-PropertyIfMissing -Object $row -Name 'owner_id' -Value $null
                    Add-PropertyIfMissing -Object $row -Name 'lease_expires_at' -Value $null
                    Add-PropertyIfMissing -Object $row -Name 'fencing_token' -Value 0
                    $row.attempt_id = if ([string]::IsNullOrWhiteSpace($AttemptId)) { 'attempt-' + [Guid]::NewGuid().ToString('N').Substring(0, 12) } else { $AttemptId }
                    $row.owner_id = if ([string]::IsNullOrWhiteSpace($OwnerId)) { "process-$PID" } else { $OwnerId }
                    $row.lease_expires_at = [DateTime]::UtcNow.AddSeconds($LeaseSeconds).ToString('o')
                    $row.fencing_token = [int]$row.fencing_token + 1
                }
                if ($Status -eq 'passed' -and @($row.evidence).Count -eq 0) {
                    throw 'Cannot pass a row without evidence.'
                }
                if ($Status -eq 'failed') {
                    $row.retry_count = [int]$row.retry_count + 1
                }
                if ($Status -in @('passed', 'failed', 'blocked', 'abandoned')) {
                    Add-PropertyIfMissing -Object $row -Name 'lease_expires_at' -Value $null
                    $row.lease_expires_at = $null
                }
                $row.status = $Status
            }
            $row.updated_at = Get-UtcTimestamp
            $task.updated_at = Get-UtcTimestamp
            Write-JsonAtomic -Path $TaskFile -Value $task
            $row | ConvertTo-Json -Depth 20
        }

        'NextReady' {
            $task = Get-Task
            $ready = @($task.rows | Where-Object {
                $_.status -eq 'pending' -and (Test-DependenciesPassed -Task $task -Row $_) -and (Test-PermissionReady -Row $_)
            })
            $reads = @($ready | Where-Object { $_.execution_class -eq 'read_only' })
            $mutations = @($ready | Where-Object { $_.execution_class -ne 'read_only' })
            $staleActive = @($task.rows | Where-Object {
                $_.status -eq 'active' -and $null -ne $_.PSObject.Properties['lease_expires_at'] -and
                -not [string]::IsNullOrWhiteSpace([string]$_.lease_expires_at) -and
                ([DateTime]$_.lease_expires_at).ToUniversalTime() -lt [DateTime]::UtcNow
            })
            [pscustomobject]@{
                parallel_read_only = @($reads | ForEach-Object { $_.id })
                next_mutation = if ($mutations.Count -gt 0) { $mutations[0].id } else { $null }
                blocked_or_waiting = @($task.rows | Where-Object { $_.status -in @('pending', 'blocked') -and $ready -notcontains $_ } | ForEach-Object { $_.id })
                stale_active = @($staleActive | ForEach-Object { $_.id })
            } | ConvertTo-Json -Depth 10
        }

        'List' {
            Get-Task | ConvertTo-Json -Depth 30
        }

        'Verify' {
            $task = Get-Task
            $issues = [Collections.Generic.List[string]]::new()
            if ([int]$task.schema_version -ne $SchemaVersion) { $issues.Add("Task schema version is not $SchemaVersion.") }
            $ids = @{}
            $globalEvidenceIds = @{}
            foreach ($row in @($task.rows)) {
                try { Assert-RowShape -Row $row -Task $task }
                catch { $issues.Add($_.Exception.Message) }
                if ($ids.ContainsKey([string]$row.id)) { $issues.Add("Duplicate row ID: $($row.id)") }
                else { $ids[[string]$row.id] = $row }
                if ($row.status -eq 'passed' -and @($row.evidence).Count -eq 0) { $issues.Add("Passed row lacks evidence: $($row.id)") }
                if ($row.status -eq 'active' -and [int]$row.retry_count -gt [int]$row.retry_limit) { $issues.Add("Active row exceeds retry limit: $($row.id)") }
                if ($row.status -eq 'active' -and $null -ne $row.PSObject.Properties['attempt_id'] -and [string]::IsNullOrWhiteSpace([string]$row.attempt_id)) { $issues.Add("Active row lacks attempt ID: $($row.id)") }
                if ($row.status -eq 'active' -and $null -ne $row.PSObject.Properties['owner_id'] -and [string]::IsNullOrWhiteSpace([string]$row.owner_id)) { $issues.Add("Active row lacks owner ID: $($row.id)") }
                if ($row.status -eq 'active' -and $null -ne $row.PSObject.Properties['lease_expires_at'] -and [string]::IsNullOrWhiteSpace([string]$row.lease_expires_at)) { $issues.Add("Active row lacks lease expiry: $($row.id)") }
                $evidenceIds = @{}
                foreach ($evidence in @($row.evidence)) {
                    if ($evidenceIds.ContainsKey([string]$evidence.id)) { $issues.Add("Duplicate evidence ID in row $($row.id): $($evidence.id)") }
                    else { $evidenceIds[[string]$evidence.id] = $true }
                    if ($globalEvidenceIds.ContainsKey([string]$evidence.id)) { $issues.Add("Duplicate evidence ID across task: $($evidence.id)") }
                    else { $globalEvidenceIds[[string]$evidence.id] = [string]$row.id }
                }
            }
            $activeMutations = @($task.rows | Where-Object { $_.status -eq 'active' -and $_.execution_class -ne 'read_only' })
            if ($activeMutations.Count -gt 1) { $issues.Add('More than one mutation row is active.') }

            $visiting = @{}
            $visited = @{}
            function Visit-Row {
                param([string]$Id)
                if ($visiting.ContainsKey($Id)) { $issues.Add("Dependency cycle detected at $Id"); return }
                if ($visited.ContainsKey($Id) -or -not $ids.ContainsKey($Id)) { return }
                $visiting[$Id] = $true
                foreach ($dependency in @($ids[$Id].dependencies)) { Visit-Row -Id ([string]$dependency) }
                $visiting.Remove($Id)
                $visited[$Id] = $true
            }
            foreach ($id in @($ids.Keys)) { Visit-Row -Id $id }

            [pscustomobject]@{
                valid = ($issues.Count -eq 0)
                issue_count = $issues.Count
                issues = @($issues)
                row_count = @($task.rows).Count
            } | ConvertTo-Json -Depth 20
            if ($issues.Count -gt 0) { throw "Task verification failed with $($issues.Count) issue(s)." }
        }

        'ExportTable' {
            $task = Get-Task
            "| ID | Target state | Dependencies | Execution class | Permission | Evidence ID | Status |"
            "|---|---|---|---|---|---|---|"
            foreach ($row in @($task.rows)) {
                $target = ([string]$row.target_state).Replace('|', '\|')
                $dependencies = (@($row.dependencies) -join ', ').Replace('|', '\|')
                "| $($row.id) | $target | $dependencies | $($row.execution_class) | $($row.permission_state) | $($row.evidence_id) | $($row.status) |"
            }
        }
    }
}
finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
