# Prompt Templates

## General execution prompt

```text
Objective: <observable terminal state>
Inputs: <paths, IDs, data, or assumptions>
Constraints: <scope, safety, format, time, client limits>
Unknowns: <material uncertainties only>
Execution path: <ordered point-to-point actions>
Required tools: <capabilities, not invented tool names>
Output schema: <exact sections, table columns, or artifact type>
Acceptance checks: <evidence that proves completion>
Checkpoint rule: <when and where to persist state>
Idempotency rule: <key and external-state check before retry>
Stop conditions: <completion, real blocker, required authority>
```

## Difficult mathematics prompt

```text
Solve <target>. Extract objects, relations, environment, validity conditions, unknown or target, and output type. Classify the task as proof, solve, or exploration. Build a bounded Prime-Line Map from the given end and target end; do not assume the target value. Identify the bridge, then separate assumptions, derivation, and verification. Check boundary cases, signs, convergence, dimensional consistency, and one independent route when feasible. Return the compact map when useful, result, validity conditions, expected behavior, equivalent forms, and approximation error.
```

## Complex code prompt

```text
Implement or diagnose <behavior> in <repository/path>. Anchor the repository, revision, runtime, role, user objective, and expected output. Map observed behavior forward through falsifiable hypotheses and acceptance backward through invariants and tests. Inspect the smallest bridge that distinguishes the hypotheses. Express behavior as input -> state transition -> output, make scoped changes, preserve unrelated edits, run proportional verification, and return the compact map when useful, changed paths, test evidence, expected runtime effects, and remaining risks.
```

## Prime-line reasoning prompt

```text
Create a bounded Prime-Line Map for <problem>. Use numbered main nodes, primes for material branch depth, + or P for combined prerequisites, -> for forward transformation, <- for backward requirements, and | for alternatives. Include @context and @goal. For proof or diagnosis, make the two ends meet at a bridge. Treat candidate results as H until verified. Do not expose hidden chain-of-thought; return the compact map, decisive rationale, validity conditions, and verification evidence.
```

## Document operation prompt

```text
Transform <source identifier> into <output identifier>. Preserve <required structures>. Apply these point-to-point changes: <changes>. Use <read method> and <write method>. Verify by <readback/render/parser>. Preserve the original at <path or revision> and report any unsupported feature directly.
```

## Resume prompt

```text
Resume task <task ID> from checkpoint <path or connector ID>. Re-detect client capabilities before acting. Verify the recorded active artifact and last completed row. Do not repeat non-idempotent operations. Execute the recorded next safe action, update the task table and memory, run the acceptance check, and leave a new checkpoint if the task remains incomplete.
```

## Scheduled continuation prompt

```text
At <time/cadence and timezone>, inspect task <task ID> using checkpoint <path>. Check <external state>. If <completion condition>, verify and close the task. If <progress condition>, execute <authorized next action>. If <failure condition>, record evidence and notify <destination>. Do not repeat non-idempotent actions. Stop after <stop condition>.
```

## Prompt self-check

Reject or repair the prompt when any answer is no:

1. Is the terminal state observable?
2. Are inputs and authority explicit?
3. Can every action be mapped to an available capability?
4. Are output format and evidence defined?
5. Are irreversible or non-idempotent actions guarded?
6. Can a fresh session resume without hidden context?
7. Does every mutating or scheduled action have a permission state and idempotency rule?
