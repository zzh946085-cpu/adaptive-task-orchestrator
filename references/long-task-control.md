# Long-Task Control

## Contents

1. Create the task table
2. Use the machine-checked ledger
3. Plan and execute
4. Verify backward
5. Checkpoint and resume
6. Schedule or wake up

## Create the task table

Use [state-and-capability-model.md](state-and-capability-model.md) for field definitions.

| ID | Target state | Dependencies | Action/path | Execution class | Permission | Idempotency key | Evidence ID | Status | Recovery |
|---|---|---|---|---|---|---|---|---|---|
| T1 | one observable result | task IDs | exact tool, command, or edit | read_only | granted | stable key | E1 | pending | reversible action |

Allow only one active mutation row. Run multiple rows concurrently only when all are independent and `read_only`.

## Use the machine-checked ledger

Initialize a task file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/task-ledger.ps1" `
  -Operation Init -TaskFile "<task.json>" -TaskId "<task-id>" `
  -Objective "<observable terminal state>"
```

Write one row as JSON using [state-and-capability-model.md](state-and-capability-model.md), then add it:

```powershell
... -Operation AddRow -TaskFile "<task.json>" -InputFile "<row.json>"
```

Find ready work:

```powershell
... -Operation NextReady -TaskFile "<task.json>"
```

`parallel_read_only` may run concurrently when independent. Run only the single returned `next_mutation` by default.

Update through valid transitions:

```powershell
... -Operation UpdateRow -TaskFile "<task.json>" -RowId T1 -Status active
... -Operation RecordEvidence -TaskFile "<task.json>" -RowId T1 -EvidencePath "<path-or-id>"
... -Operation UpdateRow -TaskFile "<task.json>" -RowId T1 -Status passed
```

The ledger refuses activation before dependencies and permissions are ready, refuses `passed` without evidence, and refuses simultaneous active mutation rows.

Verify and export:

```powershell
... -Operation Verify -TaskFile "<task.json>"
... -Operation ExportTable -TaskFile "<task.json>"
```

## Plan forward

1. Define the terminal artifact or observable state.
2. Define the evidence that proves it.
3. Identify inputs, permissions, and capabilities.
4. Map dependencies and execution classes.
5. Assign idempotency keys before external or repeatable actions.
6. Choose the smallest first action that reduces uncertainty or produces evidence.
7. Add checkpoints before irreversible actions, after mutations, at milestones, and before handoff.

## Execute a row

Apply this state machine:

```text
validate structure
-> validate values and paths
-> refresh capabilities
-> verify permission
-> verify dependencies
-> activate row
-> execute once
-> capture evidence
-> run acceptance check
-> pass, fail, or block
-> checkpoint when required
```

On resume, inspect external state with the idempotency key before repeating the action.

## Verify backward from the goal

1. Start with the terminal objective.
2. Name the evidence that proves it.
3. Locate the artifact or observed state containing that evidence.
4. Trace its producing task row.
5. Trace every dependency.
6. Confirm each row passed its own acceptance check.
7. Confirm no explicit requirement lacks a row or unsupported disposition.
8. Confirm the result states validity conditions, expected effects, and important transformations.

Reopen the earliest unsupported row when any link is missing.

## Write a checkpoint

Use this content schema:

```text
Task ID:
Session ID:
Parent checkpoint ID:
Objective:
Completed rows and evidence IDs:
Active row:
Decisions and rationale:
Artifacts and paths:
Capability manifest path and captured time:
Known failures and retry counts:
Unresolved items:
Exact next safe action:
Completion test:
```

Make the checkpoint executable without prior conversation. Preserve old checkpoints; update only the current pointer.

## Handle long tool runs

Record the external job or session identifier and idempotency key. Poll in intervals that allow user updates. Inspect the running state after resumption before reissuing a command. Treat absence of new output as normal unless a timeout or failure condition is met.

## Schedule or wake up

1. Inspect callable automation, reminder, monitor, thread-wakeup, and notification capabilities.
2. Distinguish scheduled execution from notification.
3. Require user authorization for time, cadence, timezone, scope, and external effects.
4. Store task ID, checkpoint, idempotency rule, stop condition, and failure behavior.
5. Read the created automation back when possible.
6. If unavailable, save the checkpoint and exact resume prompt; do not claim background continuation.
