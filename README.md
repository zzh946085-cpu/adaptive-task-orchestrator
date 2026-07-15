# Adaptive Task Orchestrator

An evidence-gated Codex skill for difficult, multi-stage, high-risk, or cross-session work.

It separates four state objects that are often incorrectly combined:

- a small context packet for the next turn;
- an exact resumable checkpoint;
- durable compressed memory with source lineage;
- a transcript index for audit and fork tracking.

It also provides a machine-checked task ledger with dependency, permission, execution-class, retry, idempotency, checkpoint, and evidence gates.

## Repository layout

```text
SKILL.md                         Skill policy and routing
agents/openai.yaml               Codex UI metadata
references/                      Schemas and operating protocols
scripts/bootstrap-orchestrator.ps1
scripts/memory-ledger.ps1
scripts/task-ledger.ps1
scripts/self-test.ps1
docs/                            Architecture and source-map assessments
```

## Install

Place this repository at:

```text
$CODEX_HOME/skills/adaptive-task-orchestrator
```

or install it from this GitHub repository using the Codex skill installer.

## Validate

On Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\self-test.ps1
```

The packaged test checks:

- one-bundle bootstrap;
- idempotent re-entry;
- bounded Windows path slugs;
- dependency and evidence gates;
- memory-ledger verification;
- task-ledger verification.

## Start a difficult task

Create one JSON bootstrap bundle using the schema in `references/bootstrap-bundle.md`, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\bootstrap-orchestrator.ps1 `
  -BundleFile <bundle.json> `
  -Root <authorized-task-root>
```

Use the resulting `orchestrator-state/handoff-manifest.json` as the stable resume entrypoint.

## Boundaries

This is a skill plus local state utilities. It does not independently provide:

- background execution or verified wakeups;
- cross-machine synchronization;
- client permission enforcement;
- autonomous semantic summarization;
- connector or MCP installation.

Those features remain capability-gated and require a supporting client, automation service, connector, or MCP server.

## Documentation

- `docs/build-report.md` — v2 architecture, requirement mapping, tests, strict score, and remaining limits.
- `docs/source-map-gap-analysis.md` — comparison with the `claude-code-sourcemap` structure and reusable design ideas.

## Privacy

Do not commit generated memory ledgers, checkpoints, context packets, transcripts, credentials, tokens, or user-specific task state.

No open-source license has been assigned. The repository is intended to remain private unless the owner explicitly chooses a license and changes visibility.
