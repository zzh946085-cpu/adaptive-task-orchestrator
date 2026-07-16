[CmdletBinding()]
param(
    [string]$TestRoot
)

$ErrorActionPreference = 'Stop'
$runtime = Join-Path $PSScriptRoot 'state-runtime.ps1'
$runtimeModule = Join-Path $PSScriptRoot 'state-runtime.mjs'
$createdRoot = $false
if (-not $TestRoot) {
    $TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('ato-state-v3-' + [guid]::NewGuid().ToString('N'))
    $createdRoot = $true
}
$resolvedRoot = [IO.Path]::GetFullPath($TestRoot)
New-Item -ItemType Directory -Path $resolvedRoot -Force | Out-Null
$db = Join-Path $resolvedRoot 'state.db'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Invoke-StateRuntime {
    param(
        [string[]]$Arguments,
        [switch]$ExpectFailure
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $script:NodePath --disable-warning=ExperimentalWarning $runtimeModule @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($ExpectFailure) {
        if ($exitCode -eq 0) { throw "Expected runtime failure, received success: $text" }
    }
    elseif ($exitCode -ne 0) {
        throw "Runtime failed with exit code ${exitCode}: $text"
    }
    try { return $text | ConvertFrom-Json }
    catch { throw "Runtime returned invalid JSON: $text" }
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Find-Node {
    $command = Get-Command node -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes'
    return Get-ChildItem -Path (Join-Path $root 'cua_node\*\bin\node.exe') -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

$script:NodePath = Find-Node
if (-not $script:NodePath) { throw 'Node.js runtime was not found' }

try {
    $row1Path = Join-Path $resolvedRoot 'row-1.json'
    $row2Path = Join-Path $resolvedRoot 'row-2.json'
    $actionPath = Join-Path $resolvedRoot 'outbox-action.json'
    Write-JsonFile $row1Path ([ordered]@{
        id = 'T1'; target_state = 'First result exists'; inputs = @(); action_path = 'local:test'
        dependencies = @(); execution_class = 'local_reversible'; permission_state = 'granted'
        idempotency_key = 'task:T1:v1'; checkpoint_before = $false; checkpoint_after = $true
        retry_limit = 1; evidence_id = 'E1'; failure_recovery = 'Delete test artifact'; next_check = 'Evidence E1 exists'
    })
    Write-JsonFile $row2Path ([ordered]@{
        id = 'T2'; target_state = 'Dependent result exists'; inputs = @(); action_path = 'external:test'
        dependencies = @('T1'); execution_class = 'external_reversible'; permission_state = 'granted'
        idempotency_key = 'task:T2:v1'; checkpoint_before = $true; checkpoint_after = $true
        retry_limit = 1; evidence_id = 'E2'; failure_recovery = 'Compensate test action'; next_check = 'External readback matches'
    })
    Write-JsonFile $actionPath ([ordered]@{ adapter = 'test'; operation = 'apply'; payload = @{ value = 7 } })

    $init = Invoke-StateRuntime @('--db', $db, 'init', '--task-id', 'SELFTEST', '--objective', 'Verify SQLite v3 runtime', '--operation-id', 'op-init')
    Assert-True ($init.revision -eq 1) 'initial revision is 1'
    $launcherOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $runtime --db $db inspect --task-id SELFTEST 2>&1
    Assert-True ($LASTEXITCODE -eq 0 -and (($launcherOutput -join "`n") | ConvertFrom-Json).task.task_id -eq 'SELFTEST') 'PowerShell launcher locates a compatible Node runtime'
    $replay = Invoke-StateRuntime @('--db', $db, 'init', '--task-id', 'SELFTEST', '--objective', 'Verify SQLite v3 runtime', '--operation-id', 'op-init')
    Assert-True ($replay.replayed -and $replay.revision -eq 1) 'operation replay is idempotent'

    Invoke-StateRuntime @('--db', $db, 'add-row', '--task-id', 'SELFTEST', '--input-file', $row1Path, '--operation-id', 'op-row-1') | Out-Null
    Invoke-StateRuntime @('--db', $db, 'add-row', '--task-id', 'SELFTEST', '--input-file', $row2Path, '--operation-id', 'op-row-2') | Out-Null
    $ready = Invoke-StateRuntime @('--db', $db, 'next-ready', '--task-id', 'SELFTEST')
    Assert-True ($ready.ready.Count -eq 1 -and $ready.ready[0].row_id -eq 'T1') 'dependency readiness exposes only T1'

    $active = Invoke-StateRuntime @('--db', $db, 'activate', '--task-id', 'SELFTEST', '--row-id', 'T1', '--owner-id', 'worker-1', '--lease-seconds', '300', '--operation-id', 'op-activate-1')
    $activeReplay = Invoke-StateRuntime @('--db', $db, 'activate', '--task-id', 'SELFTEST', '--row-id', 'T1', '--owner-id', 'worker-1', '--lease-seconds', '300', '--operation-id', 'op-activate-1')
    Assert-True ($activeReplay.replayed -and $activeReplay.attempt_id -eq $active.attempt_id) 'generated attempt ID is stable across operation replay'
    $stale = Invoke-StateRuntime @('--db', $db, 'record-evidence', '--task-id', 'SELFTEST', '--row-id', 'T1', '--evidence-id', 'E1', '--owner-id', 'wrong-worker', '--attempt-id', $active.attempt_id, '--fencing-token', $active.fencing_token, '--text', 'wrong', '--operation-id', 'op-stale-evidence') -ExpectFailure
    Assert-True ($stale.code -eq 'stale_attempt') 'stale owner is rejected'
    Invoke-StateRuntime @('--db', $db, 'record-evidence', '--task-id', 'SELFTEST', '--row-id', 'T1', '--evidence-id', 'E1', '--owner-id', 'worker-1', '--attempt-id', $active.attempt_id, '--fencing-token', $active.fencing_token, '--text', 'verified', '--operation-id', 'op-evidence-1') | Out-Null
    Invoke-StateRuntime @('--db', $db, 'transition', '--task-id', 'SELFTEST', '--row-id', 'T1', '--status', 'passed', '--owner-id', 'worker-1', '--attempt-id', $active.attempt_id, '--fencing-token', $active.fencing_token, '--operation-id', 'op-pass-1') | Out-Null
    $ready = Invoke-StateRuntime @('--db', $db, 'next-ready', '--task-id', 'SELFTEST')
    Assert-True ($ready.ready.Count -eq 1 -and $ready.ready[0].row_id -eq 'T2') 'T2 becomes ready after evidence-gated pass'

    Invoke-StateRuntime @('--db', $db, 'append-event', '--task-id', 'SELFTEST', '--kind', 'decision', '--importance', '5', '--text', 'Use transactional runtime', '--operation-id', 'op-event-base') | Out-Null
    $checkpoint = Invoke-StateRuntime @('--db', $db, 'write-checkpoint', '--task-id', 'SELFTEST', '--text', 'T1 passed; T2 ready', '--operation-id', 'op-checkpoint')
    $checkpointReplay = Invoke-StateRuntime @('--db', $db, 'write-checkpoint', '--task-id', 'SELFTEST', '--text', 'T1 passed; T2 ready', '--operation-id', 'op-checkpoint')
    Assert-True ($checkpointReplay.replayed -and $checkpointReplay.checkpoint_id -eq $checkpoint.checkpoint_id) 'generated checkpoint ID is stable across replay'
    $context = Invoke-StateRuntime @('--db', $db, 'build-context', '--task-id', 'SELFTEST', '--max-chars', '2000', '--operation-id', 'op-context')
    $contextReplay = Invoke-StateRuntime @('--db', $db, 'build-context', '--task-id', 'SELFTEST', '--max-chars', '2000', '--operation-id', 'op-context')
    Assert-True ($contextReplay.replayed -and $contextReplay.context_id -eq $context.context_id) 'generated context ID is stable across replay'
    Assert-True ($context.content.items.Count -ge 2 -and $context.used_chars -le 2000) 'context is checkpoint-led and bounded'

    $queued = Invoke-StateRuntime @('--db', $db, 'enqueue-outbox', '--task-id', 'SELFTEST', '--row-id', 'T2', '--idempotency-key', 'external:T2:v1', '--input-file', $actionPath, '--operation-id', 'op-enqueue')
    $queuedReplay = Invoke-StateRuntime @('--db', $db, 'enqueue-outbox', '--task-id', 'SELFTEST', '--row-id', 'T2', '--idempotency-key', 'external:T2:v1', '--input-file', $actionPath, '--operation-id', 'op-enqueue')
    Assert-True ($queuedReplay.replayed -and $queuedReplay.outbox_id -eq $queued.outbox_id) 'generated outbox ID is stable across replay'
    $claim = Invoke-StateRuntime @('--db', $db, 'claim-outbox', '--owner-id', 'sender-1', '--lease-seconds', '300', '--operation-id', 'op-claim')
    Assert-True ($claim.claimed -and $claim.outbox_id -eq $queued.outbox_id) 'outbox item is claimed'
    $staleOutbox = Invoke-StateRuntime @('--db', $db, 'complete-outbox', '--outbox-id', $claim.outbox_id, '--owner-id', 'sender-1', '--fencing-token', ([int]$claim.fencing_token + 1), '--status', 'done', '--message', 'wrong fence', '--operation-id', 'op-stale-outbox') -ExpectFailure
    Assert-True ($staleOutbox.code -eq 'stale_fence') 'stale outbox fence is rejected'
    Invoke-StateRuntime @('--db', $db, 'complete-outbox', '--outbox-id', $claim.outbox_id, '--owner-id', 'sender-1', '--fencing-token', $claim.fencing_token, '--status', 'done', '--message', 'readback matched', '--operation-id', 'op-complete') | Out-Null

    $beforeFault = Invoke-StateRuntime @('--db', $db, 'inspect', '--task-id', 'SELFTEST')
    $fault = Invoke-StateRuntime @('--db', $db, 'append-event', '--task-id', 'SELFTEST', '--kind', 'observation', '--importance', '2', '--text', 'must roll back', '--operation-id', 'op-fault', '--fault-point', 'before-commit') -ExpectFailure
    Assert-True ($fault.code -eq 'fault_injected') 'fault injection is reported'
    $afterFault = Invoke-StateRuntime @('--db', $db, 'inspect', '--task-id', 'SELFTEST')
    Assert-True ($afterFault.revision -eq $beforeFault.revision) 'fault rolls back state revision and operation log'
    Invoke-StateRuntime @('--db', $db, 'append-event', '--task-id', 'SELFTEST', '--kind', 'observation', '--importance', '2', '--text', 'must roll back', '--operation-id', 'op-fault') | Out-Null

    $node = $script:NodePath
    $processes = @()
    $writerCount = 24
    for ($index = 0; $index -lt $writerCount; $index++) {
        $stdout = Join-Path $resolvedRoot ("writer-{0}.out" -f $index)
        $stderr = Join-Path $resolvedRoot ("writer-{0}.err" -f $index)
        $arguments = @('--disable-warning=ExperimentalWarning', $runtimeModule, '--db', $db, '--timeout-ms', '60000', 'append-event', '--task-id', 'SELFTEST', '--kind', 'concurrency', '--importance', '1', '--text', ("writer-{0}" -f $index), '--operation-id', ("op-writer-{0}" -f $index))
        $processes += [pscustomobject]@{
            Process = Start-Process -FilePath $node -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
            Stdout = $stdout; Stderr = $stderr
        }
    }
    $writerFailures = @()
    foreach ($entry in $processes) {
        $entry.Process.WaitForExit()
        if ($entry.Process.ExitCode -ne 0) {
            $writerFailures += (Get-Content -Raw -LiteralPath $entry.Stderr -ErrorAction SilentlyContinue)
        }
    }
    Assert-True ($writerFailures.Count -eq 0) ("concurrent writers all commit: " + ($writerFailures -join '; '))

    $verification = Invoke-StateRuntime @('--db', $db, 'verify', '--task-id', 'SELFTEST')
    Assert-True ($verification.ok) ('verification passes: ' + ($verification.errors -join '; '))
    Assert-True ($verification.counts.events -eq ($writerCount + 2)) 'faulted event is absent and all concurrent events exist'
    $result = [ordered]@{
        ok = $true
        schema_version = 3
        final_revision = $verification.revision
        concurrent_writers = $writerCount
        event_count = $verification.counts.events
        rollback_verified = $true
        idempotency_verified = $true
        lease_and_fencing_verified = $true
        outbox_verified = $true
        context_budget_verified = $true
        database = $db
    }
    $result | ConvertTo-Json -Depth 10
}
finally {
    if ($createdRoot -and (Test-Path -LiteralPath $resolvedRoot)) {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedRoot -Leaf) -like 'ato-state-v3-*') {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
