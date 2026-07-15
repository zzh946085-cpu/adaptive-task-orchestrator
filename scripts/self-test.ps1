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

foreach ($script in @($bootstrapScript, $memoryScript, $taskScript)) {
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
    task_id = 'SELFTEST-001'
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

    $second = & $bootstrapScript -BundleFile $bundlePath -Root $testRoot | ConvertFrom-Json
    Assert-True -Condition ($second.bundle_hash -eq $first.bundle_hash) -Message 'identical bootstrap must be idempotent'
    Assert-True -Condition ($second.checkpoint_id -eq $first.checkpoint_id) -Message 'idempotent bootstrap must not duplicate checkpoints'

    $taskFile = [string]$first.task_file
    Invoke-ExpectedFailure -Message 'dependency gate must reject T2 before T1 passes' -Action {
        & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T2 -Status active
    }

    & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T1 -Status active | Out-Null
    Invoke-ExpectedFailure -Message 'evidence gate must reject passing T1 without evidence' -Action {
        & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T1 -Status passed
    }
    & $taskScript -Operation RecordEvidence -TaskFile $taskFile -RowId T1 -EvidenceText 'Bundle input was inspected.' | Out-Null
    & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T1 -Status passed | Out-Null
    & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T2 -Status active | Out-Null
    & $taskScript -Operation RecordEvidence -TaskFile $taskFile -RowId T2 -EvidenceText 'Scoped result readback matched.' | Out-Null
    & $taskScript -Operation UpdateRow -TaskFile $taskFile -RowId T2 -Status passed | Out-Null

    $taskVerify = & $taskScript -Operation Verify -TaskFile $taskFile | Select-Object -First 1 | ConvertFrom-Json
    $memoryVerify = & $memoryScript -Operation Verify -Purpose $bundle.purpose -Content $bundle.content -Root ([string]$first.memory_root) | Select-Object -First 1 | ConvertFrom-Json
    Assert-True -Condition $taskVerify.valid -Message 'completed task ledger must verify'
    Assert-True -Condition $memoryVerify.valid -Message 'memory ledger must verify'

    $taskState = & $taskScript -Operation List -TaskFile $taskFile | ConvertFrom-Json
    Assert-True -Condition (@($taskState.rows | Where-Object { $_.status -eq 'passed' }).Count -eq 2) -Message 'both task rows must pass'

    [pscustomobject]@{
        status = 'PASS'; test_root = $testRoot; idempotent_bootstrap = $true
        dependency_gate = $true; evidence_gate = $true; bounded_long_slugs = $true; memory_valid = $memoryVerify.valid
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
