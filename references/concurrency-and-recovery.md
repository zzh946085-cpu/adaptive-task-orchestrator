# Concurrency and Recovery

## Local operating model

Treat each memory purpose/content pair and each task file as one consistency partition.

- Run independent reads concurrently through a bounded worker pool.
- Submit mutation bursts through `scripts/sequential-writer.ps1`.
- Shard unrelated work by task file or purpose/content pair.
- Do not create many cold processes that mutate one ledger.
- Use one bootstrap root per task. Concurrent identical bootstraps serialize and return the same verified handoff.

The JSON utilities use file locks, atomic replacement for individual files, configurable exponential backoff with jitter, and post-write verification. They do not provide a transaction across several files. Route crash-atomic multi-object state and concurrent writers to [transactional-runtime.md](transactional-runtime.md).

## Sequential writer input

Provide a JSON array or JSON Lines file. A memory append command uses:

```json
{
  "id": "A1",
  "target": "memory",
  "operation": "Append",
  "root": "C:/state/memory",
  "purpose": "task",
  "content": "analysis",
  "text": "Verified decision",
  "kind": "decision",
  "importance": 2
}
```

Supported task operations are `UpdateRow`, `RecordEvidence`, and `RenewLease`. Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/sequential-writer.ps1" `
  -InputFile "<commands.json>"
```

The writer processes commands in order, stops at the first failure by default, and returns one batch result. Use `-ContinueOnError` only when commands are independent and every failure will be inspected.

## Attempts, leases, and fencing

Activation creates:

```text
attempt_id
owner_id
lease_expires_at
fencing_token
```

Pass explicit `-OwnerId` and `-AttemptId` when a caller must retain identity across processes. Record evidence only while the row is active. When provided, evidence owner and attempt must match the active row.

Renew a long-running attempt before its lease expires:

```powershell
... task-ledger.ps1 -Operation RenewLease -TaskFile <task.json> `
  -RowId T1 -OwnerId <owner> -AttemptId <attempt> -LeaseSeconds 900
```

`NextReady` reports expired active leases in `stale_active`. Inspect the external action and its idempotency key before moving a stale row to `failed`, retrying it, or abandoning it. Never let an expired worker commit evidence after a newer fencing token has been issued.

## Lock behavior

Memory and task mutations default to a 30-second lock deadline with exponential backoff and jitter. Bootstrap defaults to 120 seconds because followers may wait for initialization and verification.

Tune `-LockTimeoutSeconds` only after measuring queue depth and latency. A longer timeout does not increase capacity. Prefer admission control, one warm writer, or sharding.

## Path boundary

Memory and bootstrap paths reject descendant reparse points such as Junctions or symbolic links. Treat the explicitly supplied root itself as trusted and authorized. Do not place a ledger under an untrusted or remotely writable parent.

## Recovery boundary

After interruption:

1. run memory and task `Verify`;
2. inspect `bootstrap-status.json` and the handoff manifest;
3. inspect `stale_active` rows and external idempotency state;
4. rebuild context after repaired memory changes;
5. resume only from the latest verified checkpoint.

For one-host high-contention work, use the SQLite v3 runtime and its transactional outbox. For multi-host writers or externally guaranteed exactly-once effects, use an authoritative service database, durable queue, provider idempotency, and reconciliation outside this skill.
