# Memory and Recovery Protocol

## Contents

1. Capability and privacy boundary
2. State objects and layout
3. Initialize and append
4. Inspect and compact
5. Checkpoint, context, and recall
6. Forks and transcript lineage
7. Capability manifest
8. Verification, expiration, and deletion

## Capability and privacy boundary

Use local state only after write authorization. Treat it as task state, not hidden personal profiling. Never store credentials, authentication tokens, private keys, unnecessary sensitive data, or unverified claims.

Cross-client recall requires access to the same path or an exported checkpoint. Reverify externally mutable facts after recall.

Resolve the default root in this order:

1. explicit `-Root`;
2. `$CODEX_HOME/memory/adaptive-task-orchestrator`;
3. `~/.codex/memory/adaptive-task-orchestrator`.

Invoke the script on Windows with a process-scoped policy override:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" <arguments>
```

Prefer `-InputFile` or redirected standard input over `-Text` for multiline or sensitive content.

## State objects and layout

Keep purpose and content topic as separate keys:

```text
memory-root/
  purposes/<purpose>/contents/<content>/
    manifest.json
    events/YYYY/MM/*.json
    summaries/weekly/*.json
    summaries/monthly/*.json
    summaries/durable/*.json
    checkpoints/<session>/*.json
    contexts/current.json
    contexts/<context-id>.json
    transcripts/index.json
    state/capabilities.json
    state/capabilities/*.json
    state/current-checkpoint.json
    archive/events/
    locks/ledger.lock
```

Long purpose or content values are stored as a readable prefix plus a stable eight-character hash. This bounds deep Windows paths without losing deterministic lookup. Existing unbounded v2 paths are detected before a new bounded path is selected.

Use four distinct objects:

- `context_packet`: smallest state for the next turn;
- `checkpoint`: exact resumable task state;
- `summary`: durable semantic memory with source coverage;
- `transcript entry`: audit and lineage reference, not default context.

All stored objects use schema version 2 and stable IDs. Writes use same-directory temporary files and atomic replacement. Mutations acquire an exclusive ledger lock.

## Initialize and append

Initialize:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation Init -Purpose "<purpose>" -Content "<topic>"
```

Append an event:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation Append -Purpose "<purpose>" -Content "<topic>" `
  -InputFile "<event.txt>" -Kind decision -Importance 2
```

Allowed kinds:

```text
fact, decision, artifact, failure, question, next_action, note
```

Record only state that changes future action:

- confirmed objective or constraint;
- decision and rationale;
- verified fact with source path;
- artifact and status;
- failed approach that should not be repeated;
- unresolved question;
- exact next action.

Exclude greetings, repeated plans, transient command output, and unsupported inference.

## Inspect and compact

Inspect uncovered events and thresholds:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation Inspect -Purpose "<purpose>" -Content "<topic>"
```

Read `compaction_jobs`. It returns due weekly, monthly, and durable jobs with exact source IDs and reasons. Monthly becomes due after four uncovered weekly summaries or a weekly window older than 30 days. Durable becomes due after six uncovered monthly summaries or a monthly window older than 180 days.

Trigger weekly compaction after any condition:

- eight uncovered events;
- 8,000 uncovered characters;
- completed milestone;
- expected context compaction or client handoff.

Write the summary fields:

```text
Objective:
Confirmed constraints:
Decisions and rationale:
Verified facts and sources:
Artifacts and status:
Failed approaches to avoid:
Unresolved items:
Next action:
```

Compact all eligible uncovered sources:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation Compact -Purpose "<purpose>" -Content "<topic>" `
  -Tier weekly -InputFile "<summary.txt>"
```

Or provide exact source IDs:

```powershell
... -Operation Compact -Tier weekly -SourceIds "evt-id-1,evt-id-2" -InputFile "<summary.txt>"
```

Enforce this lineage:

```text
events -> weekly summaries -> monthly summaries -> durable summaries
```

Do not generate monthly or durable summaries directly from raw chat when lower-tier summaries exist. The script records `source_ids` and updates each source's `covered_by` list.

Use age-sensitive detail:

| Age | Preferred object | Retain |
|---|---|---|
| 0-7 days | events and checkpoint | exact decisions, paths, failures, next action |
| 8-30 days | weekly | outcome, decisions, unresolved items, sources |
| 31-180 days | monthly | purpose, milestones, active risks |
| over 180 days | durable | facts and rules that still alter action |

## Checkpoint, context, and recall

Write an executable checkpoint using the schema in [long-task-control.md](long-task-control.md):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation WriteCheckpoint -Purpose "<purpose>" -Content "<topic>" `
  -TaskId "<task-id>" -InputFile "<checkpoint.txt>"
```

Build a bounded context packet:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation BuildContext -Purpose "<purpose>" -Content "<topic>" `
  -MaxChars 12000 -RecentDays 7
```

The builder selects the current checkpoint, then durable, monthly and weekly summaries, then recent events. It preserves the checkpoint even when that required state exceeds the requested budget and reports the exception.

Recall the current context packet:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation Recall -Purpose "<purpose>" -Content "<topic>"
```

If no context packet exists, Recall returns the current checkpoint plus recent summaries and events.

## Forks and transcript lineage

Fork from a checkpoint without overwriting the parent:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation Fork -Purpose "<purpose>" -Content "<topic>" `
  -ParentCheckpointId "<checkpoint-id>" -ForkNumber 1
```

Register a task, thread, transcript, or sidechain reference:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation RegisterTranscript -Purpose "<purpose>" -Content "<topic>" `
  -TranscriptPath "<path-or-client-id>" -Client "<client>" `
  -ForkNumber 1 -SidechainNumber 0
```

Treat the transcript index as audit metadata. Do not inject full transcripts into active context unless resolving a contradiction or recovery failure.

## Capability manifest

Prepare JSON using [state-and-capability-model.md](state-and-capability-model.md), then write it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation WriteCapabilities -Purpose "<purpose>" -Content "<topic>" `
  -InputFile "<capabilities.json>"
```

The script requires `tools` and `continuation` objects, adds missing schema and capture metadata, writes versioned history, and updates `state/capabilities.json`.

## Verification, expiration, and deletion

Verify IDs, summary coverage, checkpoint parents, schema version, and pointer containment:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/memory-ledger.ps1" `
  -Operation Verify -Purpose "<purpose>" -Content "<topic>"
```

Treat a nonzero exit code as invalid state.

Preview expiration candidates:

```powershell
... -Operation Expire -RetentionDays 365
```

Move eligible covered, noncritical events to the archive only with explicit confirmation:

```powershell
... -Operation Expire -RetentionDays 365 -ConfirmAction
```

Delete only an exact unreferenced event or summary:

```powershell
... -Operation Delete -TargetId "<id>" -ConfirmAction
```

Deletion refuses checkpoints, covered objects, and objects referenced by summaries. Preserve lineage by default.
