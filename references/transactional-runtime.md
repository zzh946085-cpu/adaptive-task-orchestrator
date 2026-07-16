# Transactional State Runtime

## Contents

1. Selection rule
2. Runtime gate
3. Bootstrap
4. Task lifecycle
5. Checkpoint and bounded context
6. Transactional outbox
7. Recovery and verification
8. Explicit limits

## Selection rule

Choose the backend before writing task state.

| Condition | JSON v2 ledgers | SQLite v3 runtime |
|---|---:|---:|
| One writer, short task, portable inspection | Preferred | Optional |
| Several independent state files but no atomic cross-file update | Acceptable | Optional |
| Concurrent writers to one task | Avoid | Preferred |
| Task row, evidence, checkpoint, and operation log must commit together | Unsupported | Required |
| Crash-injection or durable replay testing | Limited | Preferred |
| Multi-host or network-share coordination | Unsupported | Unsupported; use an external database and queue |

Do not migrate a healthy low-contention task only to gain a newer schema number. Do not run JSON and SQLite as co-authoritative state for one task.

## Runtime gate

Run `scripts/state-runtime.ps1`. It requires Node.js 22.5 or newer because the implementation uses the native `node:sqlite` module. The launcher searches `PATH` first and then the bundled Codex Node runtime on Windows.

Use a database on a trusted local disk. Do not place it on a network share, inside an untrusted writable parent, or behind a file-sync service that rewrites SQLite side files. The runtime creates `-wal` and `-shm` files beside the database.

The runtime enables:

```text
foreign_keys = ON
journal_mode = WAL
synchronous = FULL
busy_timeout = caller value, default 30000 ms
```

If the runtime gate fails, continue with JSON v2 at low contention or install/authorize a supported runtime. Do not claim SQLite guarantees when the launcher did not run.

## Bootstrap

```powershell
$runtime = "<skill>/scripts/state-runtime.ps1"
$db = "<task-root>/state/task.db"

& $runtime --db $db init `
  --task-id TASK-001 `
  --objective "Observable terminal state" `
  --operation-id "TASK-001:init:v1"
```

Every mutating command should carry a stable `--operation-id`. Reusing the same ID with identical canonical input returns the committed result with `replayed: true`. Reusing it with different input fails with `idempotency_conflict`.

Generated attempt, checkpoint, context, and outbox IDs are derived from the operation ID. Therefore a retry that omits those optional IDs still replays safely.

## Task lifecycle

Create a row as a JSON input file:

```json
{
  "id": "T1",
  "target_state": "Parser accepts the generated artifact",
  "inputs": ["src/input.json"],
  "action_path": "tool or command path",
  "dependencies": [],
  "execution_class": "local_reversible",
  "permission_state": "granted",
  "idempotency_key": "TASK-001:T1:input-sha256",
  "checkpoint_before": false,
  "checkpoint_after": true,
  "retry_limit": 1,
  "evidence_id": "E1",
  "failure_recovery": "Restore the previous artifact",
  "next_check": "Parser exit code is zero"
}
```

Then run:

```powershell
& $runtime --db $db add-row --task-id TASK-001 --input-file row.json --operation-id "TASK-001:add:T1:v1"
& $runtime --db $db next-ready --task-id TASK-001

$active = & $runtime --db $db activate --task-id TASK-001 --row-id T1 `
  --owner-id worker-A --lease-seconds 900 --operation-id "TASK-001:activate:T1:v1" | ConvertFrom-Json

& $runtime --db $db record-evidence --task-id TASK-001 --row-id T1 --evidence-id E1 `
  --owner-id worker-A --attempt-id $active.attempt_id --fencing-token $active.fencing_token `
  --path-or-id output.json --text "Parser exit code 0" --operation-id "TASK-001:evidence:E1:v1"

& $runtime --db $db transition --task-id TASK-001 --row-id T1 --status passed `
  --owner-id worker-A --attempt-id $active.attempt_id --fencing-token $active.fencing_token `
  --operation-id "TASK-001:pass:T1:v1"
```

`passed` requires evidence from the current attempt and fencing token. `renew-lease` and every active-row commit require the same owner, attempt, unexpired lease, and fence. A newer activation increments the fence and invalidates delayed workers.

## Checkpoint and bounded context

`append-event` records exact task-local observations or decisions. `write-checkpoint` stores an exact resumable state with parent lineage. `build-context` writes a bounded packet containing the newest checkpoint first, then events ordered by importance and recency.

This is deterministic selection, not semantic memory compression. Continue to use the memory protocol for curated durable memory, time-based abstraction, supersession, and sensitive-data exclusion.

```powershell
& $runtime --db $db append-event --task-id TASK-001 --kind decision --importance 5 `
  --text "Use adapter A" --operation-id "TASK-001:event:adapter-A"
& $runtime --db $db write-checkpoint --task-id TASK-001 `
  --text "T1 passed; T2 ready; resume with adapter A" --operation-id "TASK-001:checkpoint:2"
& $runtime --db $db build-context --task-id TASK-001 --max-chars 8000 `
  --operation-id "TASK-001:context:2"
```

## Transactional outbox

Use the outbox when a committed local decision must lead to an external mutation.

1. Enqueue an adapter-specific action with an external idempotency key.
2. Claim one item with a bounded owner lease.
3. Send the action using the same external idempotency key.
4. Read the external state back.
5. Complete the item with the claim owner and fencing token.

```powershell
& $runtime --db $db enqueue-outbox --task-id TASK-001 --row-id T2 `
  --idempotency-key "provider:resource:desired-state-sha256" --input-file action.json `
  --operation-id "TASK-001:outbox:T2:v1"
& $runtime --db $db claim-outbox --owner-id sender-A --lease-seconds 300 `
  --operation-id "sender-A:claim:sequence-17"
```

The outbox makes local enqueue and task state crash-atomic. It does not make the remote service exactly-once. Exactly-once observable effect additionally requires provider-side idempotency or read-before-write/read-after-write reconciliation.

## Recovery and verification

After interruption:

1. Run `verify` and stop if `integrity_check`, foreign keys, cycles, or evidence invariants fail.
2. Run `next-ready` and inspect `stale_active`.
3. Reconcile stale task and outbox attempts with external state before retrying.
4. Use the original operation ID for a replay. Never invent a new operation ID merely because the response was lost.
5. Write a new checkpoint after recovery and rebuild context.

Use `--fault-point before-commit` only in an isolated test database. It raises an error after all transaction writes and before commit so rollback can be verified.

Run the packaged test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/state-runtime-self-test.ps1"
```

The test covers deterministic replay, dependency gates, evidence binding, stale owner/fence rejection, checkpoint/context construction, outbox fencing, injected rollback, integrity checks, and 24-process WAL contention.

## Explicit limits

- One local host and local filesystem only.
- One database is one consistency partition; transactions do not span databases.
- No background worker or scheduler is created by this runtime.
- No automatic semantic summarization or secret detection is performed.
- No remote permission, provider idempotency, or external readback is inferred.
- No automatic JSON-to-SQLite migration is performed. Import only verified state through explicit commands and preserve the original ledger as lineage evidence.
