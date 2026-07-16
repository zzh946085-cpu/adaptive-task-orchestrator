# Difficulty Routing

## Score the request

Assign points before choosing modules. Use observable conditions.

| Factor | 0 points | 1 point | 2 points |
|---|---|---|---|
| Reasoning depth | direct retrieval or one operation | several dependent steps | proof, architecture, or competing hypotheses |
| Ambiguity | output and constraints are explicit | one material uncertainty | objective or acceptance criteria require reconstruction |
| Execution span | under 10 minutes and one artifact | multiple artifacts or tools | multiple sessions, wakeups, or external dependencies |
| Risk | easily reversible | meaningful rework if wrong | destructive, high-stakes, production, legal, medical, or financial consequence |
| Context load | fits in the current exchange | several files or long evidence | compaction, persistent memory, or cross-client resumption is likely |

Cap the score at 10.

## Activate modules

| Level | Score | Required behavior |
|---|---:|---|
| 0: Direct | 0-2 | Answer or act directly. Do not create memory or a task table. |
| 1: Structured | 3-5 | State objective, constraints, short plan, and acceptance check. Use task-type workflow. |
| 2: Difficult | 6-8 | Add explicit unknowns, invariants, evidence log, independent verification, expected effects, and a checkpoint if context is large. |
| 3: Long/critical | 9-10 | Add the full task table, filesystem memory when authorized, reverse-goal verification, capability audit, recovery path, and wakeup plan when supported. |

## Scale the reasoning map separately

Use [reasoning-kernel.md](reasoning-kernel.md) without turning every task into a ledger:

| Level | Prime-line behavior |
|---|---|
| 0 | No map for a direct fact. If explicitly requested, or if a compact map prevents ambiguity in a material multi-step relation, use two to four nodes and one prime maximum. |
| 1 | Use a compact single line only when it prevents ambiguity in math, code, or causal explanation. Do not persist it. |
| 2 | Use a two-end map for proof, diagnosis, or competing hypotheses. Use two primes maximum. |
| 3 | Persist only the bridge, material rejected branches, decisions, and next action. Use three primes maximum. |

Lower notation depth when the symbols cost more effort than the relation they expose.

Treat competing hypotheses as a reason for a dual map even when the task ledger remains level 1. Map depth and task-state overhead are separate decisions.

Activate a higher level regardless of score when the user explicitly requests persistent memory, scheduled continuation, a long task, or a full audit trail.

## Reduce or raise the level during execution

Raise the level when a new dependency, contradiction, unsafe operation, large document set, or failed verification appears. Lower the active overhead only after the uncertainty is resolved and the remaining work is direct. Preserve existing checkpoints when lowering.

## Separate difficulty from length

- Treat a short proof with subtle assumptions as difficult but not long.
- Treat a repetitive migration as long but not necessarily difficult.
- Activate verification for difficulty.
- Activate checkpoints, memory, and wakeups for length.
- Activate both sets for long and difficult work.
