# Bootstrap Bundle

Use one bundle to initialize task state, capabilities, memory, checkpoint, context, transcript lineage, and verification.

```json
{
  "purpose": "Stable reason for the work",
  "content": "Workstream or topic",
  "task_id": "TASK-001",
  "objective": "Observable terminal state",
  "capabilities": {
    "client": "codex-desktop",
    "workspace_roots": [],
    "tools": {},
    "continuation": {
      "thread_resume": false,
      "scheduled_wakeup": false,
      "background_execution": false,
      "notification_only": false
    }
  },
  "events": [
    { "kind": "decision", "importance": 2, "text": "Durable decision" }
  ],
  "rows": [
    {
      "id": "T1",
      "target_state": "One observable result",
      "inputs": [],
      "action_path": "Exact tool or path",
      "dependencies": [],
      "execution_class": "read_only",
      "permission_state": "not_required",
      "idempotency_key": "",
      "checkpoint_before": false,
      "checkpoint_after": false,
      "retry_limit": 1,
      "retry_count": 0,
      "evidence_id": "E1",
      "evidence": [],
      "status": "pending",
      "failure_recovery": "Repeat bounded read",
      "next_check": "Evidence captured"
    }
  ],
  "checkpoint_text": "Task ID: TASK-001\nObjective: ...\nExact next safe action: ...",
  "transcript": {
    "path_or_id": "client-thread-or-path",
    "client": "codex-desktop",
    "fork_number": 0,
    "sidechain_number": 0
  },
  "context_max_characters": 12000,
  "exact_next_action": "Run NextReady and execute the returned read-only rows."
}
```

Run once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/bootstrap-orchestrator.ps1" `
  -BundleFile "<bundle.json>" -Root "<authorized-root>"
```

Do not create separate event, row, checkpoint, or capability input files before this command. The bundle is the only bootstrap input. Split artifacts only after a verified handoff exists and a later operation requires them.

Order rows topologically: each dependency must appear before the row that names it.

The bootstrap is idempotent for an identical completed bundle hash and re-verifies memory and task state before returning it. It refuses a different or partial state at the same root and records failure in `orchestrator-state/bootstrap-status.json`.

Use `orchestrator-state/handoff-manifest.json` as the stable resume entrypoint. Read it before traversing individual state directories.

Run the packaged regression check after changing this skill:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>/scripts/self-test.ps1"
```
