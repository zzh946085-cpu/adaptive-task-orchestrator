# State and Capability Model

## Contents

1. Capability manifest
2. Execution classes
3. Task-row schema
4. State transitions
5. Freshness and refresh
6. Subagent sidechains

## Capability manifest

Write `state/capabilities.json` for level 2 or 3 work. Use this shape:

```json
{
  "schema_version": 2,
  "client": "codex-desktop",
  "client_version": null,
  "captured_at": "2026-07-15T12:00:00Z",
  "expires_at": null,
  "workspace_roots": [],
  "tools": {
    "filesystem.read": {
      "available": true,
      "execution_class": "read_only",
      "permission_scope": "workspace",
      "external_side_effect": false,
      "supports_resume": true,
      "refresh_rule": "after client or permission change"
    }
  },
  "continuation": {
    "thread_resume": false,
    "scheduled_wakeup": false,
    "background_execution": false,
    "notification_only": false
  }
}
```

Record only observed capabilities. Use `false` or `null` for unverified support. Do not infer availability from a product name.

## Execution classes

| Class | Parallel default | Checkpoint | Permission rule | Example |
|---|---:|---|---|---|
| `read_only` | Yes when independent | Optional | Read scope | File reads, searches, calculations |
| `local_reversible` | No | After | Workspace write | Patch or generated local artifact |
| `external_reversible` | No | Before and after | Explicit external authorization | Update a ticket or cloud document |
| `irreversible` | No | Mandatory before | Explicit confirmation or prior authority | Delete, publish, send, destructive migration |
| `scheduled` | No | Mandatory before | Explicit schedule authorization | Wakeup, monitor, recurring continuation |

Treat an unknown tool as mutating and non-parallel until verified.

## Task-row schema

Use one row per independently verifiable target state:

```json
{
  "id": "T1",
  "target_state": "Observable result",
  "inputs": ["path-or-id"],
  "action_path": "Exact tool, command, or edit path",
  "dependencies": [],
  "execution_class": "read_only",
  "permission_state": "granted",
  "idempotency_key": "task:T1:input-hash",
  "checkpoint_before": false,
  "checkpoint_after": false,
  "retry_limit": 1,
  "retry_count": 0,
  "evidence_id": "E1",
  "evidence": [],
  "status": "pending",
  "failure_recovery": "Exact reversible recovery",
  "next_check": "Condition or time"
}
```

Split any row with more than one acceptance condition. Never mark `passed` without evidence.

## State transitions

Allow these transitions:

```text
pending -> active -> passed
pending -> blocked
active -> failed -> active
active -> blocked
blocked -> pending
failed -> abandoned
```

Reject `pending -> passed` unless the row is a validated import of existing evidence. Reject retries after `retry_limit` without a changed hypothesis, input, or authorization.

## Freshness and refresh

Attach these fields to mutable environment facts:

```text
captured_at
source
scope
expires_at
refresh_command_or_tool
```

Refresh after repository mutation, client handoff, permission change, connector change, failed capability call, context compaction, or a suspension longer than the source's validity window.

## Subagent sidechains

Record:

```json
{
  "sidechain_id": "S1",
  "parent_task_id": "T1",
  "objective": "Independent bounded objective",
  "allowed_capabilities": ["filesystem.read"],
  "write_scope": [],
  "raw_inputs": [],
  "output_schema": "Exact return structure",
  "acceptance_checks": [],
  "result_path": null,
  "verified_by_primary": false
}
```

Do not let a sidechain approve its own integration or final completion.
