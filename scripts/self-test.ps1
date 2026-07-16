[CmdletBinding()]
param(
    [string]$ParentRoot = (Join-Path ([IO.Path]::GetTempPath()) 'ato-tests'),
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapScript = Join-Path $PSScriptRoot 'bootstrap-orchestrator.ps1'
$memoryScript = Join-Path $PSScriptRoot 'memory-ledger.ps1'
$taskScript = Join-Path $PSScriptRoot 'task-ledger.ps1'
$sequentialWriterScript = Join-Path $PSScriptRoot 'sequential-writer.ps1'
$reasoningScript = Join-Path $PSScriptRoot 'reasoning-map.ps1'
$reasoningEvalScript = Join-Path $PSScriptRoot 'reasoning-eval.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Self-test assertion failed: $Message" }
}

function Invoke-ExpectedFailure {
    param([scriptblock]$Action, [string]$Message)
    $failed = $false
    try { & $Action | Out-Null }
    catch { $failed = $true }
    Assert-True -Condition $failed -Message $Message
}

foreach ($script in @($bootstrapScript, $memoryScript, $taskScript, $sequentialWriterScript, $reasoningScript, $reasoningEvalScript)) {
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "Required script is missing: $script"
    }
}

$parent = [IO.Path]::GetFullPath($ParentRoot)
[IO.Directory]::CreateDirectory($parent) | Out-Null
$testRoot = Join-Path $parent ('ato-selftest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$bundlePath = Join-Path $testRoot 'bundle.json'

$bundle = [ordered]@{
    purpose = 'Adaptive task orchestrator regression validation with a deliberately long purpose name'
    content = 'Bootstrap dependency evidence memory task and Windows path-length gates'
    task_id = 'SELFTEST-001-with-a-deliberately-long-task-identifier-that-must-use-a-stable-bounded-file-slug'
    objective = 'Prove that the packaged orchestration state can be initialized and closed with evidence'
    capabilities = [ordered]@{
        client = 'powershell-self-test'
        workspace_roots = @($testRoot)
        tools = [ordered]@{
            'filesystem.read' = [ordered]@{
                available = $true
                execution_class = 'read_only'
                permission_scope = $testRoot
                external_side_effect = $false
                supports_resume = $true
                refresh_rule = 'after client change'
            }
            'filesystem.write' = [ordered]@{
                available = $true
                execution_class = 'local_reversible'
                permission_scope = $testRoot
                external_side_effect = $false
                supports_resume = $true
                refresh_rule = 'after client change'
            }
        }
        continuation = [ordered]@{
            thread_resume = $true
            scheduled_wakeup = $false
            background_execution = $false
            notification_only = $false
        }
    }
    events = @(
        [ordered]@{ kind = 'decision'; importance = 2; text = 'Use the single-bundle bootstrap path.' },
        [ordered]@{ kind = 'next_action'; importance = 2; text = 'Execute the first ready row and capture evidence.' }
    )
    rows = @(
        [ordered]@{
            id = 'T1'; target_state = 'Input inspected'; inputs = @('bundle.json')
            action_path = 'Read the bounded bootstrap input'; dependencies = @()
            execution_class = 'read_only'; permission_state = 'not_required'; idempotency_key = ''
            checkpoint_before = $false; checkpoint_after = $false; retry_limit = 1; retry_count = 0
            evidence_id = 'E1'; evidence = @(); status = 'pending'
            failure_recovery = 'Repeat the bounded read'; next_check = 'E1 is recorded'
        },
        [ordered]@{
            id = 'T2'; target_state = 'Verified local output produced'; inputs = @('E1')
            action_path = 'Write a scoped result and verify readback'; dependencies = @('T1')
            execution_class = 'local_reversible'; permission_state = 'granted'; idempotency_key = 'SELFTEST-001:T2:v1'
            checkpoint_before = $false; checkpoint_after = $true; retry_limit = 1; retry_count = 0
            evidence_id = 'E2'; evidence = @(); status = 'pending'
            failure_recovery = 'Remove the scoped result'; next_check = 'E2 is recorded'
        }
    )
    checkpoint_text = "Task ID: SELFTEST-001`nObjective: Prove the packaged state`nCompleted rows: none`nExact next safe action: activate T1`nCompletion test: both rows pass with evidence"
    transcript = [ordered]@{
        path_or_id = 'self-test:local'; client = 'powershell-self-test'; fork_number = 0; sidechain_number = 0
    }
    context_max_characters = 8000
    exact_next_action = 'Activate T1, record E1, then execute T2.'
}

[IO.File]::WriteAllText($bundlePath, ($bundle | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))

try {
    $validReasoningPath = Join-Path $testRoot 'valid-reasoning.map'
    $validReasoningText = @(
        '@context = Euclidean plane',
        '@goal = prove a triangle interior-angle sum',
        '@mode = proof',
        '1 [G] = three lines form a bounded triangle',
        "1' [I] = the lines are pairwise nonparallel and not concurrent",
        '2 [T] = the interior angles sum to 180 degrees',
        '3 [A] = identify the three intersections as triangle vertices',
        '4 [E] = apply the Euclidean triangle-angle theorem',
        "1 + 1' -> 3",
        '2 <- 4',
        '3 -> 4',
        '4 -> 2'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($validReasoningPath, $validReasoningText, [Text.UTF8Encoding]::new($false))
    $validReasoning = & $reasoningScript -InputFile $validReasoningPath -Mode dual -MaxPrimeDepth 2 | ConvertFrom-Json
    Assert-True -Condition ($validReasoning.valid -and @($validReasoning.bridge_ids) -contains '4') -Message 'two-end reasoning map must validate with a bridge'

    $invalidReasoningPath = Join-Path $testRoot 'invalid-reasoning.map'
    $invalidReasoningText = @(
        '@context = circular proof',
        '@goal = reject target reuse',
        '@mode = proof',
        '1 [G] = premise',
        '2 [T] = target',
        '1 -> 2',
        '2 -> 1'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($invalidReasoningPath, $invalidReasoningText, [Text.UTF8Encoding]::new($false))
    $invalidReasoning = & $reasoningScript -InputFile $invalidReasoningPath -Mode single -MaxPrimeDepth 1 | ConvertFrom-Json
    Assert-True -Condition (-not $invalidReasoning.valid -and @($invalidReasoning.issues) -contains 'Normalized dependency graph contains a cycle.') -Message 'reasoning validator must reject circular support'

    $reasoningEvaluation = & $reasoningEvalScript -SkillRoot (Split-Path -Parent $PSScriptRoot) | ConvertFrom-Json
    Assert-True -Condition ($reasoningEvaluation.pass -and $reasoningEvaluation.routing.passed -eq $reasoningEvaluation.routing.total -and $reasoningEvaluation.maps.passed -eq $reasoningEvaluation.maps.total) -Message 'reasoning routing and semantic-map corpus must pass'

    $first = & $bootstrapScript -BundleFile $bundlePath -Root $testRoot | ConvertFrom-Json
    Assert-True -Condition $first.verification.memory_valid -Message 'bootstrap memory verification must pass'
    Assert-True -Condition $first.verification.task_valid -Message 'bootstrap task verification must pass'
    Assert-True -Condition (Test-Path -LiteralPath $first.checkpoint_path -PathType Leaf) -Message 'checkpoint must exist'
    Assert-True -Condition (Test-Path -LiteralPath $first.context_path -PathType Leaf) -Message 'context packet must exist'
    $capabilitySegments = @(([string]$first.capability_manifest) -split '[\\/]')
    $purposeIndex = [Array]::IndexOf($capabilitySegments, 'purposes') + 1
    $contentIndex = [Array]::IndexOf($capabilitySegments, 'contents') + 1
    Assert-True -Condition ($purposeIndex -gt 0 -and $capabilitySegments[$purposeIndex].Length -le 24) -Message 'long purpose slug must be bounded'
    Assert-True -Condition ($contentIndex -gt 0 -and $capabilitySegments[$contentIndex].Length -le 24) -Message 'long content slug must be bounded'
    Assert-True -Condition ((Split-Path -Leaf ([string]$first.task_file)).Length -le 53) -Message 'long task slug must be bounded'

    $second = & $bootstrapScript -BundleFile $bundlePath -Root $testRoot | ConvertFrom-Json
    Assert-True -Condition ($second.bundle_hash -eq $first.bundle_hash) -Message 'identical bootstrap must be idempotent'
    Assert-True -Condition ($second.checkpoint_id -eq $first.checkpoint_id) -Message 'idempotent bootstrap must not duplicate checkpoints'

    $taskFile = [string]$first.task_file
    $missingTask = Join-Path $testRoot 'missing-task-parent\missing.json'
    Invoke-ExpectedFailure -Message 'a missing read must fail' -Action {
        & $taskScript -Operation List -TaskFile $missingTask
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Split-Path -Parent $missingTask))) -Message 'read-only task operations must not create directories'

    Invoke-ExpectedFailure -Message 'dependency gate must reject T2 before T1 passes' -Action {
        & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T2 -Status active
    }
    Invoke-ExpectedFailure -Message 'pending rows must reject evidence' -Action {
        & $taskScript -Operation RecordEvidence -TaskFile $taskFile -RowId T1 -EvidenceText 'premature evidence'
    }

    & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T1 -Status active | Out-Null
    $activeState = & $taskScript -Operation List -TaskFile $taskFile | ConvertFrom-Json
    $activeT1 = @($activeState.rows | Where-Object { $_.id -eq 'T1' })[0]
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$activeT1.attempt_id)) -Message 'active row must have an attempt ID'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$activeT1.owner_id)) -Message 'active row must have an owner ID'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$activeT1.lease_expires_at)) -Message 'active row must have a lease expiry'
    Assert-True -Condition ([int]$activeT1.fencing_token -eq 1) -Message 'first activation must issue fencing token 1'
    Invoke-ExpectedFailure -Message 'mismatched attempts must reject evidence' -Action {
        & $taskScript -Operation RecordEvidence -TaskFile $taskFile -RowId T1 -AttemptId wrong-attempt -EvidenceText 'wrong attempt'
    }
    $oldLease = [DateTime]$activeT1.lease_expires_at
    Start-Sleep -Milliseconds 20
    & $taskScript -Operation RenewLease -TaskFile $taskFile -RowId T1 -OwnerId ([string]$activeT1.owner_id) -AttemptId ([string]$activeT1.attempt_id) -LeaseSeconds 900 | Out-Null
    $renewedState = & $taskScript -Operation List -TaskFile $taskFile | ConvertFrom-Json
    $renewedT1 = @($renewedState.rows | Where-Object { $_.id -eq 'T1' })[0]
    Assert-True -Condition (([DateTime]$renewedT1.lease_expires_at) -gt $oldLease) -Message 'matching owner and attempt must renew the lease'
    Invoke-ExpectedFailure -Message 'evidence gate must reject passing T1 without evidence' -Action {
        & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T1 -Status passed
    }
    & $taskScript -Operation RecordEvidence -TaskFile $taskFile -RowId T1 -EvidenceText 'Bundle input was inspected.' | Out-Null
    $idempotentEvidence = & $taskScript -Operation RecordEvidence -TaskFile $taskFile -RowId T1 -EvidenceText 'Bundle input was inspected.' | ConvertFrom-Json
    Assert-True -Condition $idempotentEvidence.idempotent -Message 'identical evidence retry must be idempotent'
    Invoke-ExpectedFailure -Message 'conflicting duplicate evidence must fail before write' -Action {
        & $taskScript -Operation RecordEvidence -TaskFile $taskFile -RowId T1 -EvidenceText 'different content'
    }
    $evidenceState = & $taskScript -Operation List -TaskFile $taskFile | ConvertFrom-Json
    Assert-True -Condition (@((@($evidenceState.rows | Where-Object { $_.id -eq 'T1' })[0]).evidence).Count -eq 1) -Message 'idempotent and conflicting retries must not duplicate evidence'
    & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T1 -Status passed | Out-Null
    & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T2 -Status active | Out-Null
    & $taskScript -Operation RecordEvidence -TaskFile $taskFile -RowId T2 -EvidenceText 'Scoped result readback matched.' | Out-Null
    & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T2 -Status passed | Out-Null

    $batchPath = Join-Path $testRoot 'sequential-memory-batch.json'
    $batchCommands = @(for ($i = 0; $i -lt 16; $i++) {
        [ordered]@{
            id = "append-$i"; target = 'memory'; operation = 'Append'; root = [string]$first.memory_root
            purpose = [string]$bundle.purpose; content = [string]$bundle.content; text = "queued-event-$i"
            kind = 'note'; importance = 1
        }
    })
    [IO.File]::WriteAllText($batchPath, ($batchCommands | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $batchResult = & $sequentialWriterScript -InputFile $batchPath | ConvertFrom-Json
    Assert-True -Condition ($batchResult.passed_count -eq 16 -and $batchResult.failed_count -eq 0) -Message 'sequential writer must process the complete mutation batch'
    $batchInspect = & $memoryScript -Operation Inspect -Purpose $bundle.purpose -Content $bundle.content -Root ([string]$first.memory_root) | ConvertFrom-Json
    Assert-True -Condition ($batchInspect.event_count -eq 18) -Message 'sequential writer must retain all queued events'
    & $memoryScript -Operation BuildContext -Purpose $bundle.purpose -Content $bundle.content -Root ([string]$first.memory_root) | Out-Null

    $taskVerify = & $taskScript -Operation Verify -TaskFile $taskFile | Select-Object -First 1 | ConvertFrom-Json
    $memoryVerify = & $memoryScript -Operation Verify -Purpose $bundle.purpose -Content $bundle.content -Root ([string]$first.memory_root) | Select-Object -First 1 | ConvertFrom-Json
    Assert-True -Condition $taskVerify.valid -Message 'completed task ledger must verify'
    Assert-True -Condition $memoryVerify.valid -Message 'memory ledger must verify'

    $taskState = & $taskScript -Operation List -TaskFile $taskFile | ConvertFrom-Json
    Assert-True -Condition (@($taskState.rows | Where-Object { $_.status -eq 'passed' }).Count -eq 2) -Message 'both task rows must pass'

    if ($env:OS -eq 'Windows_NT') {
        $junctionLedger = Join-Path $testRoot 'junction-ledger'
        $junctionTarget = Join-Path $testRoot 'junction-target'
        [IO.Directory]::CreateDirectory((Join-Path $junctionLedger 'purposes')) | Out-Null
        [IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
        $junctionPath = Join-Path $junctionLedger 'purposes\escape-test'
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
        Invoke-ExpectedFailure -Message 'ledger writes must reject descendant reparse points' -Action {
            & $memoryScript -Operation Init -Purpose escape-test -Content redirected -Root $junctionLedger
        }
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $junctionTarget 'contents\redirected\manifest.json'))) -Message 'reparse rejection must occur before redirected write'
    }

    $raceRoot = Join-Path $testRoot 'bootstrap-race'
    $raceIo = Join-Path $testRoot 'bootstrap-race-io'
    [IO.Directory]::CreateDirectory($raceIo) | Out-Null
    $raceProcesses = @()
    for ($i = 0; $i -lt 4; $i++) {
        $outPath = Join-Path $raceIo "$i.out"
        $errPath = Join-Path $raceIo "$i.err"
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bootstrapScript, '-BundleFile', $bundlePath, '-Root', $raceRoot)
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $raceProcesses += [pscustomobject]@{ process = $process; out = $outPath; err = $errPath }
    }
    foreach ($item in $raceProcesses) {
        if (-not $item.process.WaitForExit(120000)) { $item.process.Kill(); throw 'Concurrent bootstrap worker timed out.' }
    }
    $raceSuccess = @($raceProcesses | Where-Object { (Get-Item -LiteralPath $_.out).Length -gt 0 -and (Get-Item -LiteralPath $_.err).Length -eq 0 }).Count
    Assert-True -Condition ($raceSuccess -eq 4) -Message 'identical concurrent bootstraps must all return the same completed handoff'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath (Join-Path $raceRoot 'orchestrator-state\memory') -Recurse -Filter 'cp-*.json' -File).Count -eq 1) -Message 'concurrent bootstrap must create one checkpoint'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath (Join-Path $raceRoot 'orchestrator-state\memory') -Recurse -Filter 'evt-*.json' -File).Count -eq 2) -Message 'concurrent bootstrap must not duplicate events'

    if ($env:OS -eq 'Windows_NT') {
        $tooLongRoot = Join-Path $testRoot ('long-root-' + ('x' * 120))
        Invoke-ExpectedFailure -Message 'unsafe deep Windows paths must fail before bootstrap state is created' -Action {
            & $bootstrapScript -BundleFile $bundlePath -Root $tooLongRoot
        }
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $tooLongRoot 'orchestrator-state'))) -Message 'path-budget preflight must not leave partial state'
    }

    [pscustomobject]@{
        status = 'PASS'; test_root = $testRoot; idempotent_bootstrap = $true
        concurrent_bootstrap = $true; reasoning_kernel = $true; reasoning_evaluation = $true; dependency_gate = $true; evidence_attempt_gate = $true; evidence_idempotency = $true
        lease_and_fencing = $true; sequential_writer = $true; no_side_effect_reads = $true; reparse_guard = ($env:OS -eq 'Windows_NT')
        path_budget_preflight = ($env:OS -eq 'Windows_NT')
        bounded_long_slugs = $true; memory_valid = $memoryVerify.valid
        task_valid = $taskVerify.valid; passed_rows = 2; artifacts_retained = [bool]$KeepArtifacts
    } | ConvertTo-Json -Depth 10
}
finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $testRoot)) {
        $resolvedParent = [IO.Path]::GetFullPath($parent).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $resolvedTest = [IO.Path]::GetFullPath($testRoot)
        $leaf = Split-Path -Leaf $resolvedTest
        if (-not $resolvedTest.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or $leaf -notlike 'ato-selftest-*') {
            throw "Refusing to remove an unexpected self-test path: $resolvedTest"
        }
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
