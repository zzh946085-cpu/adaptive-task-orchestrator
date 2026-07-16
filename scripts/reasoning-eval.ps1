[CmdletBinding()]
param(
    [string]$CorpusFile,
    [string]$SkillRoot,
    [string]$BaselineSkillRoot,
    [switch]$FailOnMismatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($CorpusFile)) { $CorpusFile = Join-Path $scriptRoot 'reasoning-eval-corpus.json' }
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = Split-Path -Parent $scriptRoot }

function Get-Level {
    param([object]$Case)
    $score = 0
    foreach ($factor in @($Case.factors)) {
        $value = [int]$factor
        if ($value -lt 0 -or $value -gt 2) { throw "Case '$($Case.id)' has a factor outside 0..2." }
        $score += $value
    }
    $score = [Math]::Min($score, 10)
    $level = if ($score -le 2) { 0 } elseif ($score -le 5) { 1 } elseif ($score -le 8) { 2 } else { 3 }
    if ($Case.kind -in @('scheduling', 'memory', 'continuation') -and $level -lt 2) { $level = 2 }
    return [pscustomobject]@{ score = $score; level = $level }
}

function Get-MapRoute {
    param([object]$Case, [int]$Level)
    if (-not [bool]$Case.reasoning_relevant) { return [pscustomobject]@{ behavior = 'none'; depth = 0 } }
    if ($Level -eq 3) { return [pscustomobject]@{ behavior = 'dual-persist'; depth = 3 } }
    if ([bool]$Case.competing_hypotheses) { return [pscustomobject]@{ behavior = 'dual'; depth = 2 } }
    if ($Level -eq 2) {
        if ($Case.kind -in @('proof', 'diagnose', 'architecture')) {
            return [pscustomobject]@{ behavior = 'dual'; depth = 2 }
        }
        return [pscustomobject]@{ behavior = 'single'; depth = 1 }
    }
    if ($Level -eq 1 -and [bool]$Case.relation_complexity) {
        return [pscustomobject]@{ behavior = 'single'; depth = 1 }
    }
    if ($Level -eq 0 -and [bool]$Case.relation_complexity) { return [pscustomobject]@{ behavior = 'compact'; depth = 1 } }
    if ([bool]$Case.explicit_scaffold) { return [pscustomobject]@{ behavior = 'compact'; depth = 1 } }
    return [pscustomobject]@{ behavior = 'none'; depth = 0 }
}

function Test-ContainsAll {
    param([object[]]$Values, [object[]]$Needles)
    $joined = (@($Values) -join "`n")
    foreach ($needle in @($Needles)) {
        if ($joined.IndexOf([string]$needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Get-Coverage {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }
    $resolved = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "Skill root does not exist: $resolved" }
    $skillFile = Join-Path $resolved 'SKILL.md'
    $difficultyFile = Join-Path $resolved 'references\difficulty-routing.md'
    $validatorFile = Join-Path $resolved 'scripts\reasoning-map.ps1'
    $skillText = if (Test-Path -LiteralPath $skillFile) { [IO.File]::ReadAllText($skillFile) } else { '' }
    $difficultyText = if (Test-Path -LiteralPath $difficultyFile) { [IO.File]::ReadAllText($difficultyFile) } else { '' }
    $validatorText = if (Test-Path -LiteralPath $validatorFile) { [IO.File]::ReadAllText($validatorFile) } else { '' }
    $checks = [ordered]@{
        bounded_reasoning_reference = Test-Path -LiteralPath (Join-Path $resolved 'references\reasoning-kernel.md') -PathType Leaf
        executable_validator = Test-Path -LiteralPath $validatorFile -PathType Leaf
        evaluation_contract = Test-Path -LiteralPath (Join-Path $resolved 'references\reasoning-evaluation.md') -PathType Leaf
        two_end_route = $skillText.Contains('given end and target end')
        separate_activation_scale = $difficultyText.Contains('Scale the reasoning map separately')
        target_premise_guard = $validatorText.Contains('used as a forward premise')
        hypothesis_evidence_guard = $validatorText.Contains('reaches a target without passing through an E node')
    }
    $passed = @($checks.Values | Where-Object { $_ }).Count
    return [pscustomobject]@{ root = $resolved; passed = $passed; total = $checks.Count; checks = $checks }
}

$CorpusFile = [IO.Path]::GetFullPath($CorpusFile)
$SkillRoot = [IO.Path]::GetFullPath($SkillRoot)
if (-not (Test-Path -LiteralPath $CorpusFile -PathType Leaf)) { throw "Evaluation corpus does not exist: $CorpusFile" }
$validator = Join-Path $SkillRoot 'scripts\reasoning-map.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) { throw "Reasoning validator does not exist: $validator" }
$corpus = [IO.File]::ReadAllText($CorpusFile) | ConvertFrom-Json
$failures = [Collections.Generic.List[string]]::new()
$routingResults = @()

foreach ($case in @($corpus.routing_cases)) {
    $levelResult = Get-Level -Case $case
    $route = Get-MapRoute -Case $case -Level $levelResult.level
    $pass = $levelResult.level -eq [int]$case.expected_level -and
        $route.behavior -eq [string]$case.expected_map -and
        $route.depth -eq [int]$case.expected_depth
    if (-not $pass) {
        $failures.Add("Routing case '$($case.id)' expected level/map/depth $($case.expected_level)/$($case.expected_map)/$($case.expected_depth), got $($levelResult.level)/$($route.behavior)/$($route.depth).")
    }
    $routingResults += [pscustomobject]@{
        id = $case.id; pass = $pass; score = $levelResult.score; level = $levelResult.level
        map = $route.behavior; depth = $route.depth
    }
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase ('ato-reasoning-eval-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$mapResults = @()
try {
    foreach ($case in @($corpus.map_cases)) {
        $path = Join-Path $tempRoot ($case.id + '.map')
        [IO.File]::WriteAllLines($path, @($case.lines), [Text.UTF8Encoding]::new($false))
        $actual = & $validator -InputFile $path -Mode $case.mode -MaxPrimeDepth ([int]$case.depth) | ConvertFrom-Json
        $pass = [bool]$actual.valid -eq [bool]$case.expected_valid
        if ($pass -and $case.PSObject.Properties.Name -contains 'issue_contains') {
            $pass = Test-ContainsAll -Values @($actual.issues) -Needles @($case.issue_contains)
        }
        if ($pass -and $case.PSObject.Properties.Name -contains 'warning_contains') {
            $pass = Test-ContainsAll -Values @($actual.warnings) -Needles @($case.warning_contains)
        }
        if ($pass -and $case.PSObject.Properties.Name -contains 'bridge_contains') {
            foreach ($bridge in @($case.bridge_contains)) {
                if (@($actual.bridge_ids) -notcontains [string]$bridge) { $pass = $false }
            }
        }
        if (-not $pass) { $failures.Add("Map case '$($case.id)' did not match its validity, issue, warning, or bridge contract.") }
        $mapResults += [pscustomobject]@{
            id = $case.id; pass = $pass; valid = [bool]$actual.valid
            issues = @($actual.issues); warnings = @($actual.warnings); bridges = @($actual.bridge_ids)
        }
    }
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

$currentCoverage = Get-Coverage -Root $SkillRoot
$baselineCoverage = if ([string]::IsNullOrWhiteSpace($BaselineSkillRoot)) { $null } else { Get-Coverage -Root $BaselineSkillRoot }
$result = [pscustomobject]@{
    schema_version = 1
    object_type = 'prime_line_evaluation'
    pass = $failures.Count -eq 0
    corpus_sha256 = (Get-FileHash -LiteralPath $CorpusFile -Algorithm SHA256).Hash.ToLowerInvariant()
    routing = [pscustomobject]@{ passed = @($routingResults | Where-Object { $_.pass }).Count; total = $routingResults.Count; cases = $routingResults }
    maps = [pscustomobject]@{ passed = @($mapResults | Where-Object { $_.pass }).Count; total = $mapResults.Count; cases = $mapResults }
    coverage = [pscustomobject]@{ current = $currentCoverage; baseline = $baselineCoverage }
    failures = @($failures)
    limitation = 'Structural routing and map checks do not establish answer correctness; use independent forward-tests for performance claims.'
}
$result | ConvertTo-Json -Depth 30
if (-not $result.pass -and $FailOnMismatch) { throw "Reasoning evaluation failed with $($failures.Count) mismatch(es)." }
