---
name: adaptive-task-orchestrator
description: Orchestrate difficult, high-risk, multi-artifact, or cross-session work with compact reasoning maps, explicit task state, capability routing, checkpoints, compressed memory, recovery, and reverse-goal verification. Use when the work has multiple dependent stages, requires a difficult proof, code diagnosis, or architecture decision, is likely to cross sessions, requests memory/resumption/scheduling, or explicitly asks for a prime-line reasoning map, forward/backward derivation, or thought scaffold. Do not invoke automatically for routine one-step answers, ordinary summaries, or short plans; allow explicit $adaptive-task-orchestrator invocation for those cases.
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

## Use a bounded reasoning kernel

Read [reasoning-kernel.md](references/reasoning-kernel.md) when the user asks for a thought scaffold or when mathematical, code, or causal relations need a visible main line and material branches.

When changing routing, notation, or semantic guards, read [reasoning-evaluation.md](references/reasoning-evaluation.md) and run the bundled evaluation corpus. Keep structural validation separate from claims about answer correctness.

Use `1`, `1'`, and `1''` for main, branch, and sub-branch nodes. Normalize `P` to `+`, use `->` for forward transformation, `<-` for backward requirements, and `|` for alternatives. Anchor the map with context and an observable goal.

Do not output a hidden chain-of-thought. Return only the compact map, decisive rationale, validity conditions, and evidence that help the user verify the result. Do not use a map for a direct answer unless the user explicitly requests it.

## Route difficult reasoning

### Mathematics

1. Extract objects, relations, environment, validity conditions, target or unknown, and output type.
2. Classify the request as proof, solve, or exploration; never use a target value as an unverified premise.
3. For nontrivial work, build from the given end and target end until they meet at a bridge lemma, transformation, or check.
4. Define symbols, domain, assumptions, precision, and admissible methods.
5. Separate derivation from verification and label proof, approximation, numerical evidence, and conjecture separately.
6. Check dimensions, signs, boundary cases, convergence, and one independent route when feasible.
7. Return the compact map when useful, then the result, validity conditions, expected behavior, error bounds, and equivalent forms.

### Code

1. Anchor repository, revision, runtime, role, user objective, and expected output.
2. Map the observed input or failure forward through falsifiable hypotheses; map acceptance backward through required invariants and tests.
3. Inspect the smallest path that can distinguish hypotheses and serve as the bridge between both ends.
4. Express the behavior as input, state transition, output, invariants, and failure cases.
5. Preserve unrelated edits and existing conventions.
6. Classify reads as parallel-safe only when independent; serialize mutations unless an adapter proves otherwise.
7. Verify with focused tests first, then broader checks proportional to risk.
8. Return the compact map when useful, changed paths, observed evidence, expected runtime effects, and remaining risk.

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

Use the SQLite v3 runtime in [transactional-runtime.md](references/transactional-runtime.md) when concurrent writers share one task, several state objects must commit atomically, crash replay must be tested, or a task will remain active across repeated recovery cycles. Keep JSON v2 for portable, low-contention work. Never treat both backends as authoritative for the same task.

Follow [concurrency-and-recovery.md](references/concurrency-and-recovery.md) when several workers, clients, retries, or mutation bursts can touch state. Use `scripts/sequential-writer.ps1` for same-ledger mutation batches. Treat each task file and memory purpose/content pair as one consistency partition.

Apply these global rules:

- Run independent `read_only` rows concurrently when the client supports it.
- Serialize local and external mutations by default.
- Require a fresh checkpoint before irreversible or non-idempotent work.
- Reinspect external state before retrying a resumed operation.
- Allow only one active mutation row unless a tool-specific adapter proves isolation.
- Bind evidence to the active attempt. Preserve its owner, lease, and fencing token across long-running work.
- Bound per-ledger concurrency; prefer a warm single writer or independent shards over cold-process contention.

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

Before shipping changes to this skill, run `scripts/reasoning-eval.ps1`, `scripts/self-test.ps1`, and `scripts/state-runtime-self-test.ps1`. They must pass routing and semantic-map regression, concurrent bootstrap, bounded paths, reparse protection, no-side-effect reads, attempt-bound evidence, lease/fencing, sequential writer, memory, task-ledger, transactional rollback, deterministic replay, outbox fencing, and WAL contention checks.
