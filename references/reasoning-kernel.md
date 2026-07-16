# Prime-Line Reasoning Kernel

## Contents

1. Purpose and limits
2. Minimal notation
3. Activation and depth
4. Turn-point extraction
5. Single-line reasoning
6. Two-end mathematical reasoning
7. Two-end code reasoning
8. Context anchor and output contract
9. Failure controls

## Purpose and limits

Use a Prime-Line Map as a compact external reasoning scaffold. It is not a transcript of hidden reasoning and does not replace a proof, calculation, test, or artifact inspection.

The map must do three jobs:

1. expose the main transformation without prose expansion;
2. attach only branches that can change the result or next action;
3. show where forward evidence meets backward requirements.

Do not force the notation onto a direct answer. Show the map only when the user asks for the reasoning structure or when it materially clarifies a difficult relation.

## Minimal notation

Declare nodes:

```text
1 [G] = main given or observed state
1' [I] = direct branch, condition, or invariant of 1
1'' [H] = sub-branch or hypothesis under 1'
2 [T] = target state
```

Node identifiers encode placement only:

- `1`, `2`, `3`: main line;
- `1'`: branch attached to `1`;
- `1''`: branch attached to `1'`;
- use at most three primes and prefer two or fewer.

Node types:

| Type | Meaning |
|---|---|
| `G` | given, input, or observed state |
| `T` | target or acceptance condition |
| `H` | hypothesis to test, not a fact |
| `I` | invariant, constraint, or validity condition |
| `A` | action, transformation, or lemma |
| `E` | evidence, check, or independently verified result |
| `R` | derived result |
| `U` | unresolved variable or unknown |
| `X` | rejected branch with a recorded reason |

Declare relations:

```text
1 -> 2          forward transformation
1 + 1' -> 2     both inputs are required
1 P 1' -> 2     accepted input alias; normalize P to +
1 | 1' -> 2     alternative candidates
2 <- 3          target 2 requires condition 3
```

Use `P` only as an ASCII alias for addition. Do not use phrases such as `1to2for'P'1`; normalize them to `1 + 1' -> 2` before reasoning.

Anchor the map:

```text
@context = repository, mathematical space, or conversation scope
@time = relevant version, date, or execution moment
@role = solver, reviewer, implementer, or explainer
@goal = observable user objective and expected output
@mode = chat, proof, solve, diagnose, or implement
```

`@context` and `@goal` are required. Use `@time` only when facts or state may change. Use `@role` when it affects authority or output.

## Activation and depth

| Situation | Map behavior |
|---|---|
| Direct fact or one operation | No map by default |
| User explicitly asks for a thought guide | Two to four nodes; one prime maximum |
| Structured low-difficulty math or code | Compact map when it prevents ambiguity; one prime maximum |
| Difficult proof, diagnosis, or architecture | Two-end map; two primes maximum |
| Long and difficult task | Persist only the bridge, rejected branches, decisions, and next action; three primes maximum |

Stop expanding when a new branch does not change a hypothesis, condition, action, evidence check, or output.

## Turn-point extraction

Before building the map, reduce the request to these turn points:

```text
objects
relations
environment and validity conditions
unknown or target
required output type
```

Do not treat every noun phrase as a turn point. A turn point must change the valid transformation or the proof obligation.

For an underspecified geometry statement such as "three lines form angles whose inner triangle sums to 180 degrees," extract:

```text
objects: three lines, intersections, bounded triangle, interior angles
environment: Euclidean plane
conditions: pairwise nonparallel and not all concurrent
target: identify the relevant interior angles and prove their sum
output: proof, not a numerical guess
```

## Single-line reasoning

Use a single line when one transformation chain is sufficient:

```text
@context = bounded local problem
@goal = observable result
1 [G] = input state
1' [I] = condition that changes validity
2 [A] = smallest valid transformation
3 [E] = acceptance check
4 [R] = result
1 + 1' -> 2
2 -> 3
3 -> 4
```

Keep branches attached to the earliest node they qualify. Do not add a branch merely to restate the main line.

## Two-end mathematical reasoning

Classify the mathematical request first:

- `proof`: the target is fixed and becomes a backward constraint;
- `solve`: the target is an unknown variable; a candidate value remains `H` until verified;
- `explore`: several candidates may remain alternatives.

Build from both ends:

```text
given and invariants -> forward consequences -> bridge
target <- required theorem or condition <- bridge
```

Example:

```text
@context = Euclidean plane
@role = prover
@goal = prove the interior-angle sum of the triangle formed by three lines
@mode = proof
1 [G] = three pairwise nonparallel lines form a bounded triangle
1' [I] = the three lines are not concurrent
2 [T] = the three interior angles sum to 180 degrees
3 [A] = identify the three intersections as the vertices of one Euclidean triangle
4 [E] = apply or independently derive the Euclidean triangle-angle theorem
1 + 1' -> 3
2 <- 4
3 -> 4
4 -> 2
```

The bridge is `4`: it is reachable from the givens and satisfies a requirement expanded from the target.

Never assume the target value as a premise. For a numerical question use:

```text
2 [U] = required angle sum
2' [H] = candidate value 180 degrees
```

Then derive constraints from the environment and test `2'`. Promote it to `R` only after verification.

## Two-end code reasoning

Use two ends for diagnosis and implementation:

```text
observed input or failure -> hypotheses -> inspected bridge
acceptance target <- required invariant and tests <- inspected bridge
```

Template:

```text
@context = repository, runtime, version, and relevant path
@time = inspected revision or execution time
@role = implementer
@goal = exact behavior and verification output
@mode = diagnose or implement
1 [G] = observed behavior or input
1' [H] = first falsifiable cause
1'' [H] = competing cause
2 [T] = required behavior
2' [I] = interface or safety invariant
3 [E] = smallest inspection that distinguishes the hypotheses
4 [A] = smallest coherent change
5 [E] = focused test and readback
1 | 1' | 1'' -> 3
2 <- 2' + 5
3 -> 4
4 -> 5
5 -> 2
```

Reject a hypothesis when evidence contradicts it and retain only the rejection reason when it prevents repeated work.

## Context anchor and output contract

The context anchor limits uncontrolled expansion:

```text
@context = where the problem exists
@time = when the inspected state is valid
@role = what authority and responsibility the agent has
@goal = what the user will receive
```

Convert the final map into a concise output contract:

```text
User objective:
Expected output:
Main line:
Material branches:
Bridge or decisive check:
Validity conditions:
Next action or result:
```

Do not expose discarded internal exploration. Return the map, decisive rationale, and evidence required for the user to verify the answer.

## Failure controls

Reject or repair the map when:

1. a branch exists without its parent;
2. the target is used as an unverified forward premise;
3. a hypothesis is labelled as a given, result, or evidence;
4. forward and backward lines never meet;
5. a cycle appears in the normalized dependency graph;
6. the context or goal anchor is missing;
7. prime depth grows without changing an action or check;
8. notation replaces domain proof, code inspection, tests, or artifact evidence.

Also treat these as semantic-risk signals:

- an `H` node reaches a target without an intervening `E` check;
- a `U` node is used forward as if its value were already known;
- an `X` node participates in an active relation;
- `@mode` conflicts with node roles, such as `solve` without an unknown or `diagnose` without a falsifiable hypothesis.

Validate reusable maps with `scripts/reasoning-map.ps1`.
