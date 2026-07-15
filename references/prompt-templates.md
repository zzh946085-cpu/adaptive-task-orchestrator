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
Solve <target>. Define symbols and domain first. Separate assumptions, derivation, and verification. Decompose into lemmas or transformations. Check boundary cases, signs, convergence, dimensional consistency, and one independent route when feasible. Return the result, validity conditions, expected behavior, equivalent forms, and any approximation error.
```

## Complex code prompt

```text
Implement or diagnose <behavior> in <repository/path>. Inspect repository instructions, current state, dependencies, and tests first. Express the behavior as input -> state transition -> output. Identify invariants and failure cases. Make scoped changes, preserve unrelated edits, run proportional verification, and return changed paths, test evidence, expected runtime effects, and remaining risks.
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
