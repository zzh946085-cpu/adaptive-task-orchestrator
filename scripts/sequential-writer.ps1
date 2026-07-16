[CmdletBinding()]
param(
    [string]$InputFile,
    [ValidateRange(1, 10000)]
    [int]$MaxCommands = 1000,
    [switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$memoryScript = Join-Path $PSScriptRoot 'memory-ledger.ps1'
$taskScript = Join-Path $PSScriptRoot 'task-ledger.ps1'

function Require-Property {
    param($Object, [string]$Name)
    if ($null -eq $Object.PSObject.Properties[$Name]) { throw "Command requires '$Name'." }
    $value = $Object.$Name
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { throw "Command property '$Name' cannot be empty." }
    return $value
}

function Read-Commands {
    $raw = if (-not [string]::IsNullOrWhiteSpace($InputFile)) {
        $full = [IO.Path]::GetFullPath($InputFile)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Input file does not exist: $full" }
        [IO.File]::ReadAllText($full)
    }
    elseif ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() }
    else { throw 'Provide -InputFile or redirected standard input.' }

    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Command input is empty.' }
    $trimmed = $raw.TrimStart()
    if ($trimmed.StartsWith('[')) {
        try { $parsed = $raw | ConvertFrom-Json }
        catch { throw "Command array is not valid JSON: $($_.Exception.Message)" }
        foreach ($item in @($parsed)) { Write-Output $item }
        return
    }

    $commands = @()
    $lineNumber = 0
    foreach ($line in $raw -split '\r?\n') {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $commands += ($line | ConvertFrom-Json) }
        catch { throw "Command line $lineNumber is not valid JSON: $($_.Exception.Message)" }
    }
    return $commands
}

if (-not (Test-Path -LiteralPath $memoryScript -PathType Leaf) -or -not (Test-Path -LiteralPath $taskScript -PathType Leaf)) {
    throw 'Ledger scripts are missing beside sequential-writer.ps1.'
}

$commands = @(Read-Commands)
if ($commands.Count -eq 0) { throw 'No commands were provided.' }
if ($commands.Count -gt $MaxCommands) { throw "Command count $($commands.Count) exceeds MaxCommands $MaxCommands." }

$results = [Collections.Generic.List[object]]::new()
$batchWatch = [Diagnostics.Stopwatch]::StartNew()

for ($index = 0; $index -lt $commands.Count; $index++) {
    $command = $commands[$index]
    $commandId = if ($null -eq $command.PSObject.Properties['id']) { "command-$index" } else { [string]$command.id }
    $target = [string](Require-Property -Object $command -Name 'target')
    $operation = [string](Require-Property -Object $command -Name 'operation')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $rawResult = switch ($target) {
            'memory' {
                if ($operation -ne 'Append') { throw "Sequential memory target supports only Append, not '$operation'." }
                $root = [string](Require-Property -Object $command -Name 'root')
                $purpose = [string](Require-Property -Object $command -Name 'purpose')
                $content = [string](Require-Property -Object $command -Name 'content')
                $body = [string](Require-Property -Object $command -Name 'text')
                $kind = if ($null -eq $command.PSObject.Properties['kind']) { 'note' } else { [string]$command.kind }
                $importance = if ($null -eq $command.PSObject.Properties['importance']) { 1 } else { [int]$command.importance }
                & $memoryScript -Operation Append -Purpose $purpose -Content $content -Root $root -Text $body -Kind $kind -Importance $importance
            }
            'task' {
                $taskFile = [string](Require-Property -Object $command -Name 'task_file')
                $rowId = [string](Require-Property -Object $command -Name 'row_id')
                switch ($operation) {
                    'RecordEvidence' {
                        $evidenceId = if ($null -eq $command.PSObject.Properties['evidence_id']) { '' } else { [string]$command.evidence_id }
                        $evidenceText = if ($null -eq $command.PSObject.Properties['evidence_text']) { '' } else { [string]$command.evidence_text }
                        $evidencePath = if ($null -eq $command.PSObject.Properties['evidence_path']) { '' } else { [string]$command.evidence_path }
                        $ownerId = if ($null -eq $command.PSObject.Properties['owner_id']) { '' } else { [string]$command.owner_id }
                        $attemptId = if ($null -eq $command.PSObject.Properties['attempt_id']) { '' } else { [string]$command.attempt_id }
                        & $taskScript -Operation RecordEvidence -TaskFile $taskFile -RowId $rowId -EvidenceId $evidenceId -EvidenceText $evidenceText -EvidencePath $evidencePath -OwnerId $ownerId -AttemptId $attemptId
                    }
                    'UpdateRow' {
                        $status = if ($null -eq $command.PSObject.Properties['status']) { '' } else { [string]$command.status }
                        $permission = if ($null -eq $command.PSObject.Properties['permission_state']) { '' } else { [string]$command.permission_state }
                        $ownerId = if ($null -eq $command.PSObject.Properties['owner_id']) { '' } else { [string]$command.owner_id }
                        $attemptId = if ($null -eq $command.PSObject.Properties['attempt_id']) { '' } else { [string]$command.attempt_id }
                        $lease = if ($null -eq $command.PSObject.Properties['lease_seconds']) { 900 } else { [int]$command.lease_seconds }
                        $updateParameters = @{ Operation = 'UpdateRow'; TaskFile = $taskFile; RowId = $rowId; LeaseSeconds = $lease }
                        if (-not [string]::IsNullOrWhiteSpace($status)) { $updateParameters.Status = $status }
                        if (-not [string]::IsNullOrWhiteSpace($permission)) { $updateParameters.PermissionState = $permission }
                        if (-not [string]::IsNullOrWhiteSpace($ownerId)) { $updateParameters.OwnerId = $ownerId }
                        if (-not [string]::IsNullOrWhiteSpace($attemptId)) { $updateParameters.AttemptId = $attemptId }
                        & $taskScript @updateParameters
                    }
                    'RenewLease' {
                        $ownerId = [string](Require-Property -Object $command -Name 'owner_id')
                        $attemptId = [string](Require-Property -Object $command -Name 'attempt_id')
                        $lease = if ($null -eq $command.PSObject.Properties['lease_seconds']) { 900 } else { [int]$command.lease_seconds }
                        & $taskScript -Operation RenewLease -TaskFile $taskFile -RowId $rowId -OwnerId $ownerId -AttemptId $attemptId -LeaseSeconds $lease
                    }
                    default { throw "Unsupported task operation: $operation" }
                }
            }
            default { throw "Unsupported command target: $target" }
        }

        $watch.Stop()
        $parsedResult = try { ($rawResult | Out-String).Trim() | ConvertFrom-Json } catch { ($rawResult | Out-String).Trim() }
        $results.Add([pscustomobject]@{ id = $commandId; index = $index; status = 'passed'; elapsed_ms = $watch.ElapsedMilliseconds; result = $parsedResult })
    }
    catch {
        $watch.Stop()
        $results.Add([pscustomobject]@{ id = $commandId; index = $index; status = 'failed'; elapsed_ms = $watch.ElapsedMilliseconds; error = $_.Exception.Message })
        if (-not $ContinueOnError) { break }
    }
}

$batchWatch.Stop()
$failed = @($results | Where-Object { $_.status -eq 'failed' }).Count
[pscustomobject]@{
    schema_version = 1
    object_type = 'sequential_write_batch_result'
    command_count = $commands.Count
    processed_count = $results.Count
    passed_count = @($results | Where-Object { $_.status -eq 'passed' }).Count
    failed_count = $failed
    elapsed_ms = $batchWatch.ElapsedMilliseconds
    results = @($results)
} | ConvertTo-Json -Depth 30

if ($failed -gt 0) { exit 1 }
