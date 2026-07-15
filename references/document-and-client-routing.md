# Document and Client Routing

## Detect the environment

Record:

- current client or CLI;
- callable tools and installed plugins;
- authenticated connectors;
- local filesystem roots and write scope;
- available runtimes and document libraries;
- network availability;
- automation or wakeup support;
- thread or session continuation support.

Write verified results to the capability manifest defined in [state-and-capability-model.md](state-and-capability-model.md). Attach capture time and refresh rules. Record unavailable or unverified capabilities as false or null.

Use the narrowest native capability that preserves structure and permits readback. Use connector APIs for connected cloud documents, document libraries for local files, and UI control only when no semantic API is available.

Classify every operation as `read_only`, `local_reversible`, `external_reversible`, `irreversible`, or `scheduled`. Run independent reads concurrently. Serialize mutations unless an adapter proves isolation.

## Build the document path

Create this map before mutation:

| Stage | Required entry |
|---|---|
| Source | exact file, URL, connector ID, or range |
| Read method | parser, connector read, export, OCR, or rendering |
| Transformation | point-to-point edits and preserved elements |
| Output | exact destination and format |
| Verification | reopen, parse, render, formula check, or connector readback |
| Recovery | original path, copy, revision, or reversible patch |

## Execute document work

1. Read the applicable document skill or format instructions completely.
2. Inspect the source before selecting the transformation method.
3. Preserve styles, formulas, citations, links, comments, or tracked changes when they are in scope.
4. Apply the smallest coherent change set.
5. Reopen the output through an independent read path when feasible.
6. For visual documents, render and inspect representative or changed pages.
7. Report the output path and verification evidence.

## Route across clients

- Treat local filesystem memory as shared only among clients that can access the same path.
- Treat connector state as shared only when the same account and connector are available.
- Treat a task or thread identifier as client-specific unless verified otherwise.
- Convert state into a portable checkpoint when moving between CLI, desktop, browser, or another agent.
- Include exact artifact paths or connector identifiers and the resume prompt.
- Re-run capability detection after every client handoff.

## Degrade explicitly

If a requested operation is unsupported or inadvisable, state:

1. the missing capability or risk;
2. the exact effect on the requested workflow;
3. the nearest supported alternative;
4. what the user must provide or enable, if anything.

Do not simulate successful edits, scheduled work, memory, or readback.
