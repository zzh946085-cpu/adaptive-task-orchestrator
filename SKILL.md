---
name: adaptive-task-orchestrator
description: Orchestrate difficult, high-risk, multi-artifact, or cross-session work with explicit task state, capability routing, checkpoints, compressed memory, recovery, and reverse-goal verification. Use when the work has multiple dependent stages, requires a difficult proof or architecture decision, is likely to cross sessions, requests memory/resumption/scheduling, or contains consequential and difficult-to-reverse actions. Do not invoke automatically for routine one-step answers, ordinary summaries, or short plans; allow explicit $adaptive-task-orchestrator invocation for those cases.
---

# Adaptive Task Orchestrator

## Operating boundary

Treat this Skill as policy plus local state utilities. Do not claim that instructions alone enforce permissions, background execution, cross-client synchronization, or semantic compression. Verify each capability and degrade explicitly.

Use concrete English in task artifacts. Prefer identifiers, paths, schemas, tests, equations, state transitions, and evidence over conversational description.

For new level 2 or 3 work, prefer the single-file bootstrap in [bootstrap-bundle.md](references/bootstrap-bundle.md). Use separate ledger commands only for later updates, compaction, forks, and recovery.

## Start the control loop

1. Define the terminal state and acceptance evidence.
2. Score the request with [difficulty-routing.md](references/difficulty-routing.md).
3. Classify it as answer, diagnosis, implementation, proof, document operation, research, memory, continuation, scheduling, or mixed work.
4. Inspect the current client and create or refresh the capability manifest from [state-and-capability-model.md](references/state-and-capability-model.md).
5. Select only the required task, memory, document, or continuation modules.
6. Execute the next reversible in-scope action; ask only for a material choice that cannot be discovered safely.
7. Compare evidence with the acceptance condition, update state, and repeat.

For every tool action, apply this order:

```text
structural validation
-> value and path validation
-> capability check
-> permission check
-> execution-class check
-> execution
-> evidence capture
-> state transition
```

Do not bypass a failed stage by rewriting it as prose.

## Route difficult reasoning

### Mathematics

1. Define symbols, domain, assumptions, target quantity, precision, and admissible methods.
2. Split the target into lemmas, transformations, or computable subproblems.
3. Separate derivation from verification.
4. Check dimensions, signs, boundary cases, convergence, and one independent route when feasible.
5. Label proof, approximation, numerical evidence, and conjecture separately.
6. Return validity conditions, expected behavior, error bounds when available, and useful equivalent forms.

### Code

1. Inspect repository instructions, dirty state, dependencies, runtime, tests, and the smallest relevant path.
2. Express the behavior as input, state transition, output, invariants, and failure cases.
3. Preserve unrelated edits and existing conventions.
4. Classify reads as parallel-safe only when independent; serialize mutations unless an adapter proves otherwise.
5. Verify with focused tests first, then broader checks proportional to risk.
6. Return changed paths, observed evidence, expected runtime effects, and remaining risk.

## Keep four state objects separate

Use [memory-protocol.md](references/memory-protocol.md) and do not merge these objects:

| Object | Function | Injection rule |
|---|---|---|
| Context packet | Minimum state for the next turn | Inject first; replace after compaction |
| Checkpoint | Exact resumable task state | Load on resume or failure recovery |
| Durable memory | Stable decisions and facts | Retrieve selectively; verify mutable facts |
| Transcript index | Audit and lineage references | Do not inject by default |

Use `scripts/memory-ledger.ps1` only after local-write authorization. Prefer input files or standard input for content. Never store credentials, secrets, private keys, unnecessary sensitive data, or unsupported personal profiles.

## Control long work

Follow [long-task-control.md](references/long-task-control.md). Give every task row an execution class, dependencies, permission state, idempotency key, evidence identifier, retry limit, and checkpoint policy.

Use `scripts/task-ledger.ps1` when level 2 or 3 work needs machine-checked task transitions, dependency readiness, evidence gating, or mutation serialization.

Apply these global rules:

- Run independent `read_only` rows concurrently when the client supports it.
- Serialize local and external mutations by default.
- Require a fresh checkpoint before irreversible or non-idempotent work.
- Reinspect external state before retrying a resumed operation.
- Allow only one active mutation row unless a tool-specific adapter proves isolation.

## Bound subagents

Use a subagent only for an independent task whose result can be verified. Pass the objective, raw evidence paths, allowed tools, write scope, output schema, acceptance checks, and one final return contract. Do not leak the expected conclusion. Store or reference the result as a sidechain and verify it before merging.

Do not delegate a required user decision, permission grant, irreversible action, or final completion judgment.

## Route documents and clients

Follow [document-and-client-routing.md](references/document-and-client-routing.md). Use native structured APIs before UI control. Preserve sources unless replacement is explicit. Verify by parser, render, formula check, connector readback, or another independent read path.

Refresh capability state after a client handoff, permission change, connector change, tool failure, context compaction, or long suspension.

## Generate execution prompts

Use [prompt-templates.md](references/prompt-templates.md) for another agent, client, scheduled continuation, or future session. Include objective, inputs, constraints, allowed capabilities, output schema, acceptance checks, checkpoint rule, idempotency rule, and stop conditions.

Do not conceal an unresolved choice inside a prompt.

## Schedule or resume

Use a real automation or wakeup tool only when it is callable and authorized. Record task ID, checkpoint path, time and timezone, stop condition, idempotency rule, and failure behavior. Read the automation back when possible.

If only notification is available, call it notification. If no wakeup capability exists, write a checkpoint and exact resume prompt; do not claim automatic continuation.

## Complete with reverse evidence

Before completion:

1. Start at the terminal objective and identify the proving evidence.
2. Trace the artifact and producing task row backward through every dependency.
3. Confirm each dependency passed its own acceptance check.
4. Confirm every explicit requirement has evidence or an explicit unsupported disposition.
5. Run state verification when local state is active.
6. Record durable decisions, final artifacts, unresolved risks, and the next action only if work remains.
7. Return the result first, followed by evidence and limitations.

Before shipping changes to this skill, run `scripts/self-test.ps1`. It must pass the bootstrap idempotency, dependency, evidence, memory, and task-ledger checks.
