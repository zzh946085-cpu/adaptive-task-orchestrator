[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [ValidateSet('compact', 'single', 'dual')]
    [string]$Mode = 'compact',

    [ValidateRange(1, 3)]
    [int]$MaxPrimeDepth = 2,

    [switch]$WarningsAsErrors,
    [switch]$FailOnInvalid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-Issue {
    param([Collections.Generic.List[string]]$List, [string]$Message)
    if (-not $List.Contains($Message)) { $List.Add($Message) }
}

function Parse-Expression {
    param([string]$Text, [int]$LineNumber, [Collections.Generic.List[string]]$Issues)

    $value = ($Text -replace '\s+P\s+', ' + ').Trim()
    $hasPlus = $value.Contains('+')
    $hasAlternative = $value.Contains('|')
    if ($hasPlus -and $hasAlternative) {
        Add-Issue -List $Issues -Message "Line $LineNumber mixes '+' and '|'; split the relation."
        return [pscustomobject]@{ ids = @(); join = 'invalid' }
    }
    $join = if ($hasPlus) { 'all' } elseif ($hasAlternative) { 'any' } else { 'single' }
    $parts = if ($hasPlus) { @($value -split '\+') } elseif ($hasAlternative) { @($value -split '\|') } else { @($value) }
    $ids = @()
    foreach ($part in $parts) {
        $id = $part.Trim()
        if ($id -notmatch "^\d+'{0,3}$") {
            Add-Issue -List $Issues -Message "Line $LineNumber has invalid node reference '$id'."
        }
        elseif ($ids -contains $id) {
            Add-Issue -List $Issues -Message "Line $LineNumber repeats node '$id'."
        }
        else { $ids += $id }
    }
    return [pscustomobject]@{ ids = @($ids); join = $join }
}

function Get-Reachable {
    param([string[]]$Starts, [hashtable]$Adjacency)

    $seen = @{}
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($start in $Starts) {
        if (-not $seen.ContainsKey($start)) { $seen[$start] = $true; $queue.Enqueue($start) }
    }
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($Adjacency.ContainsKey($current)) {
            foreach ($next in @($Adjacency[$current])) {
                if (-not $seen.ContainsKey($next)) { $seen[$next] = $true; $queue.Enqueue($next) }
            }
        }
    }
    return @($seen.Keys)
}

function Test-ReachableWithoutEvidence {
    param(
        [string]$Start,
        [string[]]$Targets,
        [hashtable]$Adjacency,
        [Collections.IDictionary]$Nodes
    )

    $seen = @{}
    $queue = [Collections.Generic.Queue[string]]::new()
    $seen[$Start] = $true
    $queue.Enqueue($Start)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($current -ne $Start -and $Targets -contains $current) { return $true }
        if (-not $Adjacency.ContainsKey($current)) { continue }
        foreach ($next in @($Adjacency[$current])) {
            if ($seen.ContainsKey($next)) { continue }
            if ($Nodes.Contains($next) -and $Nodes[$next].type -eq 'E') { continue }
            $seen[$next] = $true
            $queue.Enqueue($next)
        }
    }
    return $false
}

$InputFile = [IO.Path]::GetFullPath($InputFile)
if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) { throw "Reasoning map does not exist: $InputFile" }

$issues = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$anchors = [ordered]@{}
$nodes = [ordered]@{}
$relations = [Collections.Generic.List[object]]::new()
$lines = [IO.File]::ReadAllLines($InputFile)

for ($index = 0; $index -lt $lines.Count; $index++) {
    $lineNumber = $index + 1
    $line = $lines[$index].Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    $line = $line.Replace([string][char]0x2192, '->')
    $line = $line.Replace([string][char]0x2190, '<-')
    $line = $line.Replace([string][char]0x21D0, '<-')

    if ($line -match '^@(?<name>[a-z][a-z0-9_-]*)\s*=\s*(?<value>.+)$') {
        $name = $Matches.name
        if ($anchors.Contains($name)) { Add-Issue -List $issues -Message "Line $lineNumber duplicates anchor '@$name'." }
        else { $anchors[$name] = $Matches.value.Trim() }
        continue
    }

    if ($line -match "^(?<id>\d+'{0,3})\s+\[(?<type>G|T|H|I|A|E|R|U|X)\]\s*=\s*(?<text>.+)$") {
        $id = $Matches.id
        if ($nodes.Contains($id)) { Add-Issue -List $issues -Message "Line $lineNumber duplicates node '$id'."; continue }
        $primeDepth = [regex]::Matches($id, "'").Count
        if ($primeDepth -gt $MaxPrimeDepth) {
            Add-Issue -List $issues -Message "Node '$id' exceeds maximum prime depth $MaxPrimeDepth."
        }
        $nodes[$id] = [pscustomobject]@{
            id = $id; type = $Matches.type; text = $Matches.text.Trim(); line = $lineNumber; prime_depth = $primeDepth
        }
        continue
    }

    if ($line -match '^(?<left>.+?)\s*(?<operator>->|<-)\s*(?<right>.+)$') {
        $left = Parse-Expression -Text $Matches.left -LineNumber $lineNumber -Issues $issues
        $right = Parse-Expression -Text $Matches.right -LineNumber $lineNumber -Issues $issues
        if ($Matches.operator -eq '->' -and @($right.ids).Count -ne 1) {
            Add-Issue -List $issues -Message "Line $lineNumber forward relation requires one conclusion on the right."
        }
        if ($Matches.operator -eq '<-' -and @($left.ids).Count -ne 1) {
            Add-Issue -List $issues -Message "Line $lineNumber backward relation requires one constrained target on the left."
        }
        $relations.Add([pscustomobject]@{
            line = $lineNumber; operator = $Matches.operator
            left_ids = @($left.ids); left_join = $left.join
            right_ids = @($right.ids); right_join = $right.join
        })
        continue
    }

    Add-Issue -List $issues -Message "Line $lineNumber does not match an anchor, node, or relation."
}

foreach ($requiredAnchor in @('context', 'goal')) {
    if (-not $anchors.Contains($requiredAnchor)) { Add-Issue -List $issues -Message "Missing required anchor '@$requiredAnchor'." }
}
if (-not $anchors.Contains('mode')) { Add-Issue -List $warnings -Message "Missing '@mode'; proof, solve, diagnose, or implement improves routing." }
elseif ($anchors.mode -notin @('chat', 'proof', 'solve', 'explore', 'diagnose', 'implement')) {
    Add-Issue -List $issues -Message "Unsupported '@mode' value '$($anchors.mode)'."
}

foreach ($node in @($nodes.Values)) {
    if ($node.prime_depth -gt 0) {
        $parent = $node.id.Substring(0, $node.id.Length - 1)
        if (-not $nodes.Contains($parent)) { Add-Issue -List $issues -Message "Branch '$($node.id)' is missing parent '$parent'." }
    }
}

$proofAdjacency = @{}
$forwardAdjacency = @{}
$requirementAdjacency = @{}
foreach ($relation in $relations) {
    foreach ($id in @($relation.left_ids) + @($relation.right_ids)) {
        if (-not $nodes.Contains($id)) { Add-Issue -List $issues -Message "Relation line $($relation.line) references undeclared node '$id'." }
        elseif ($nodes[$id].type -eq 'X') { Add-Issue -List $issues -Message "Rejected node '$id' participates in active relation line $($relation.line)." }
    }
    if ($relation.operator -eq '->' -and @($relation.right_ids).Count -eq 1) {
        $conclusion = $relation.right_ids[0]
        foreach ($dependency in @($relation.left_ids)) {
            if (-not $proofAdjacency.ContainsKey($dependency)) { $proofAdjacency[$dependency] = @() }
            if (-not $forwardAdjacency.ContainsKey($dependency)) { $forwardAdjacency[$dependency] = @() }
            $proofAdjacency[$dependency] = @($proofAdjacency[$dependency]) + $conclusion
            $forwardAdjacency[$dependency] = @($forwardAdjacency[$dependency]) + $conclusion
            if ($nodes.Contains($dependency) -and $nodes[$dependency].type -eq 'T') {
                Add-Issue -List $issues -Message "Target '$dependency' is used as a forward premise on line $($relation.line)."
            }
            if ($nodes.Contains($dependency) -and $nodes[$dependency].type -eq 'U') {
                Add-Issue -List $warnings -Message "Unknown '$dependency' is used as a forward premise on line $($relation.line); verify that only its constraints, not its value, are assumed."
            }
        }
    }
    elseif ($relation.operator -eq '<-' -and @($relation.left_ids).Count -eq 1) {
        $conclusion = $relation.left_ids[0]
        foreach ($requirement in @($relation.right_ids)) {
            if (-not $proofAdjacency.ContainsKey($requirement)) { $proofAdjacency[$requirement] = @() }
            if (-not $requirementAdjacency.ContainsKey($conclusion)) { $requirementAdjacency[$conclusion] = @() }
            $proofAdjacency[$requirement] = @($proofAdjacency[$requirement]) + $conclusion
            $requirementAdjacency[$conclusion] = @($requirementAdjacency[$conclusion]) + $requirement
        }
    }
}

$targetIds = @($nodes.Values | Where-Object { $_.type -eq 'T' } | ForEach-Object { $_.id })
$givenIds = @($nodes.Values | Where-Object { $_.type -in @('G', 'I') } | ForEach-Object { $_.id })
$hypothesisIds = @($nodes.Values | Where-Object { $_.type -eq 'H' } | ForEach-Object { $_.id })
$unknownIds = @($nodes.Values | Where-Object { $_.type -eq 'U' } | ForEach-Object { $_.id })
$objectiveIds = @($targetIds)
if ($anchors.Contains('mode') -and $anchors.mode -eq 'solve') { $objectiveIds = @($objectiveIds + $unknownIds | Sort-Object -Unique) }
if ($Mode -in @('single', 'dual')) {
    if ($objectiveIds.Count -eq 0) { Add-Issue -List $issues -Message "Mode '$Mode' requires at least one T node, or a U node in solve mode." }
    if ($givenIds.Count -eq 0) { Add-Issue -List $issues -Message "Mode '$Mode' requires at least one G or I node." }
    if ($relations.Count -eq 0) { Add-Issue -List $issues -Message "Mode '$Mode' requires at least one relation." }
}
if ($Mode -eq 'compact' -and $nodes.Count -lt 2) { Add-Issue -List $issues -Message 'Compact mode requires at least two nodes.' }

if ($anchors.Contains('mode')) {
    switch ($anchors.mode) {
        'solve' {
            if ($unknownIds.Count -eq 0) { Add-Issue -List $warnings -Message "Solve mode should represent the requested quantity with a U node." }
        }
        'diagnose' {
            if ($hypothesisIds.Count -eq 0) { Add-Issue -List $warnings -Message "Diagnose mode should include at least one falsifiable H node." }
        }
        'proof' {
            if (@($nodes.Values | Where-Object { $_.type -in @('A', 'E') }).Count -eq 0) {
                Add-Issue -List $warnings -Message "Proof mode should include a lemma, transformation, or evidence node."
            }
        }
    }
}

foreach ($hypothesisId in $hypothesisIds) {
    if (Test-ReachableWithoutEvidence -Start $hypothesisId -Targets $objectiveIds -Adjacency $forwardAdjacency -Nodes $nodes) {
        Add-Issue -List $warnings -Message "Hypothesis '$hypothesisId' reaches a target without passing through an E node."
    }
}

$bridgeIds = @()
if ($Mode -eq 'dual') {
    if (@($relations | Where-Object { $_.operator -eq '->' }).Count -eq 0) { Add-Issue -List $issues -Message 'Dual mode requires a forward relation.' }
    if (@($relations | Where-Object { $_.operator -eq '<-' }).Count -eq 0) { Add-Issue -List $issues -Message 'Dual mode requires a backward requirement relation.' }
    $forwardReach = Get-Reachable -Starts $givenIds -Adjacency $forwardAdjacency
    $backwardReach = Get-Reachable -Starts $objectiveIds -Adjacency $requirementAdjacency
    $bridgeIds = @($forwardReach | Where-Object {
        $backwardReach -contains $_ -and $nodes.Contains($_) -and $nodes[$_].type -in @('A', 'E', 'R')
    } | Sort-Object -Unique)
    if ($bridgeIds.Count -eq 0) { Add-Issue -List $issues -Message 'Forward consequences and backward requirements have no bridge node.' }
}

$visitState = @{}
$cycleFound = $false
function Visit-Node {
    param([string]$Id)
    if ($script:cycleFound) { return }
    if ($visitState[$Id] -eq 1) { $script:cycleFound = $true; return }
    if ($visitState[$Id] -eq 2) { return }
    $visitState[$Id] = 1
    if ($proofAdjacency.ContainsKey($Id)) {
        foreach ($next in @($proofAdjacency[$Id])) { Visit-Node -Id $next }
    }
    $visitState[$Id] = 2
}
foreach ($id in @($nodes.Keys)) { Visit-Node -Id $id }
if ($cycleFound) { Add-Issue -List $issues -Message 'Normalized dependency graph contains a cycle.' }

if ($WarningsAsErrors) { foreach ($warning in $warnings) { Add-Issue -List $issues -Message $warning } }
$valid = $issues.Count -eq 0
$result = [pscustomobject]@{
    schema_version = 2
    object_type = 'prime_line_validation'
    valid = $valid
    mode = $Mode
    node_count = $nodes.Count
    relation_count = $relations.Count
    bridge_ids = @($bridgeIds)
    anchors = $anchors
    issues = @($issues)
    warnings = @($warnings)
    nodes = @($nodes.Values)
    relations = @($relations)
}
$result | ConvertTo-Json -Depth 20
if (-not $valid -and $FailOnInvalid) { throw "Reasoning map validation failed with $($issues.Count) issue(s)." }
