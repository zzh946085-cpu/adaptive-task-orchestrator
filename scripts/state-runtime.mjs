#!/usr/bin/env node
import { createHash, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const SCHEMA_VERSION = 3;
const COMMANDS = new Set([
  'init', 'add-row', 'activate', 'renew-lease', 'record-evidence', 'transition',
  'append-event', 'write-checkpoint', 'build-context', 'enqueue-outbox',
  'claim-outbox', 'complete-outbox', 'next-ready', 'inspect', 'verify'
]);
const TRANSITIONS = {
  pending: new Set(['active', 'blocked']),
  active: new Set(['passed', 'failed', 'blocked']),
  failed: new Set(['active', 'abandoned']),
  blocked: new Set(['pending'])
};

class RuntimeFailure extends Error {
  constructor(message, code = 'runtime_error') {
    super(message);
    this.code = code;
  }
}

const utcNow = () => new Date().toISOString();
const after = seconds => new Date(Date.now() + seconds * 1000).toISOString();
const plain = value => value && typeof value === 'object' ? { ...value } : value;
const sorted = value => {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])]));
  }
  return value;
};
const canonical = value => JSON.stringify(sorted(value));
const digest = value => createHash('sha256').update(canonical(value), 'utf8').digest('hex');
const readJson = path => JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''));
const readText = path => readFileSync(path, 'utf8').replace(/^\uFEFF/, '');
const bool = value => ['1', 'true', 'yes'].includes(String(value).toLowerCase()) ? 1 : 0;
const generatedId = (args, prefix) => {
  const operationId = args.operation_id === true ? null : args.operation_id;
  return operationId ? `${prefix}-${digest({ operationId, prefix }).slice(0, 32)}` : randomUUID();
};
const integer = (value, name, minimum = 0) => {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed < minimum) fail(`${name} must be an integer >= ${minimum}`, 'invalid_input');
  return parsed;
};
const fail = (message, code) => { throw new RuntimeFailure(message, code); };
const requireValue = (args, name) => {
  const value = args[name];
  if (value === undefined || value === true || value === '') fail(`missing --${name.replaceAll('_', '-')}`, 'invalid_input');
  return value;
};
const artifactDigest = path => {
  if (!path || !existsSync(path) || !statSync(path).isFile()) return null;
  return createHash('sha256').update(readFileSync(path)).digest('hex');
};

function parseArguments(values) {
  const args = {};
  let command = null;
  for (let index = 0; index < values.length; index += 1) {
    const token = values[index];
    if (!token.startsWith('--')) {
      if (command) fail(`unexpected positional argument: ${token}`, 'invalid_input');
      command = token;
      continue;
    }
    const key = token.slice(2).replaceAll('-', '_');
    const next = values[index + 1];
    args[key] = next !== undefined && !next.startsWith('--') ? values[++index] : true;
  }
  if (!command || !COMMANDS.has(command)) fail(`unknown or missing command: ${command ?? ''}`, 'invalid_input');
  args.command = command;
  return args;
}

function initializeSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS tasks(
      task_id TEXT PRIMARY KEY, objective TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS task_rows(
      task_id TEXT NOT NULL,row_id TEXT NOT NULL,target_state TEXT NOT NULL,inputs_json TEXT NOT NULL DEFAULT '[]',
      action_path TEXT NOT NULL,execution_class TEXT NOT NULL,permission_state TEXT NOT NULL,idempotency_key TEXT NOT NULL,
      checkpoint_before INTEGER NOT NULL DEFAULT 0,checkpoint_after INTEGER NOT NULL DEFAULT 0,
      retry_limit INTEGER NOT NULL DEFAULT 1,retry_count INTEGER NOT NULL DEFAULT 0,expected_evidence_id TEXT,
      status TEXT NOT NULL DEFAULT 'pending',failure_recovery TEXT NOT NULL,next_check TEXT NOT NULL,
      attempt_id TEXT,owner_id TEXT,lease_expires_at TEXT,fencing_token INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,updated_at TEXT NOT NULL,
      PRIMARY KEY(task_id,row_id),UNIQUE(task_id,idempotency_key),
      FOREIGN KEY(task_id) REFERENCES tasks(task_id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS dependencies(
      task_id TEXT NOT NULL,row_id TEXT NOT NULL,depends_on TEXT NOT NULL,PRIMARY KEY(task_id,row_id,depends_on),
      FOREIGN KEY(task_id,row_id) REFERENCES task_rows(task_id,row_id) ON DELETE CASCADE,
      FOREIGN KEY(task_id,depends_on) REFERENCES task_rows(task_id,row_id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS evidence(
      task_id TEXT NOT NULL,evidence_id TEXT NOT NULL,row_id TEXT NOT NULL,attempt_id TEXT NOT NULL,owner_id TEXT NOT NULL,
      fencing_token INTEGER NOT NULL,captured_at TEXT NOT NULL,path_or_id TEXT,content TEXT,artifact_digest TEXT,digest TEXT NOT NULL,
      PRIMARY KEY(task_id,evidence_id),FOREIGN KEY(task_id,row_id) REFERENCES task_rows(task_id,row_id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS events(
      event_id INTEGER PRIMARY KEY AUTOINCREMENT,task_id TEXT NOT NULL,kind TEXT NOT NULL,importance INTEGER NOT NULL,
      text TEXT NOT NULL,digest TEXT NOT NULL,created_at TEXT NOT NULL,
      FOREIGN KEY(task_id) REFERENCES tasks(task_id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS checkpoints(
      checkpoint_id TEXT PRIMARY KEY,task_id TEXT NOT NULL,parent_id TEXT,revision INTEGER NOT NULL,text TEXT NOT NULL,
      digest TEXT NOT NULL,created_at TEXT NOT NULL,FOREIGN KEY(task_id) REFERENCES tasks(task_id) ON DELETE CASCADE,
      FOREIGN KEY(parent_id) REFERENCES checkpoints(checkpoint_id)
    );
    CREATE TABLE IF NOT EXISTS contexts(
      context_id TEXT PRIMARY KEY,task_id TEXT NOT NULL,checkpoint_id TEXT,revision INTEGER NOT NULL,max_chars INTEGER NOT NULL,
      used_chars INTEGER NOT NULL,content_json TEXT NOT NULL,digest TEXT NOT NULL,created_at TEXT NOT NULL,
      FOREIGN KEY(task_id) REFERENCES tasks(task_id) ON DELETE CASCADE,FOREIGN KEY(checkpoint_id) REFERENCES checkpoints(checkpoint_id)
    );
    CREATE TABLE IF NOT EXISTS outbox(
      outbox_id TEXT PRIMARY KEY,task_id TEXT NOT NULL,row_id TEXT NOT NULL,idempotency_key TEXT NOT NULL UNIQUE,
      action_json TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'pending',attempt_count INTEGER NOT NULL DEFAULT 0,
      available_at TEXT NOT NULL,lease_owner TEXT,lease_expires_at TEXT,fencing_token INTEGER NOT NULL DEFAULT 0,
      result_json TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,
      FOREIGN KEY(task_id,row_id) REFERENCES task_rows(task_id,row_id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS operation_log(
      operation_id TEXT PRIMARY KEY,operation TEXT NOT NULL,task_id TEXT,target_id TEXT,input_digest TEXT NOT NULL,
      status TEXT NOT NULL,result_json TEXT NOT NULL,revision INTEGER NOT NULL,created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_rows_status ON task_rows(task_id,status);
    CREATE INDEX IF NOT EXISTS idx_events_task ON events(task_id,event_id DESC);
    CREATE INDEX IF NOT EXISTS idx_outbox_claim ON outbox(status,available_at,lease_expires_at);
  `);
  db.prepare("INSERT OR IGNORE INTO meta VALUES('schema_version',?)").run(String(SCHEMA_VERSION));
  db.prepare("INSERT OR IGNORE INTO meta VALUES('state_revision','0')").run();
  const version = Number(db.prepare("SELECT value FROM meta WHERE key='schema_version'").get().value);
  if (version !== SCHEMA_VERSION) fail(`schema ${version} is incompatible with runtime ${SCHEMA_VERSION}`, 'schema_mismatch');
}

const revision = db => Number(db.prepare("SELECT value FROM meta WHERE key='state_revision'").get().value);
function requireTask(db, taskId) {
  if (!db.prepare('SELECT 1 FROM tasks WHERE task_id=?').get(taskId)) fail(`task not found: ${taskId}`, 'not_found');
}
function getRow(db, taskId, rowId) {
  const row = db.prepare('SELECT * FROM task_rows WHERE task_id=? AND row_id=?').get(taskId, rowId);
  if (!row) fail(`row not found: ${rowId}`, 'not_found');
  return row;
}

function mutate(db, { operation, taskId = null, targetId = null, operationId = null, input, faultPoint = null }, action) {
  const inputDigest = digest(input);
  db.exec('BEGIN IMMEDIATE');
  try {
    if (operationId) {
      const previous = db.prepare('SELECT operation,input_digest,result_json FROM operation_log WHERE operation_id=?').get(operationId);
      if (previous) {
        if (previous.operation !== operation || previous.input_digest !== inputDigest) {
          fail(`operation_id reused with different input: ${operationId}`, 'idempotency_conflict');
        }
        const result = JSON.parse(previous.result_json);
        result.replayed = true;
        db.exec('COMMIT');
        return result;
      }
    }
    const result = action();
    const nextRevision = revision(db) + 1;
    db.prepare("UPDATE meta SET value=? WHERE key='state_revision'").run(String(nextRevision));
    Object.assign(result, { ok: true, operation, revision: nextRevision, replayed: false });
    if (operationId) {
      db.prepare('INSERT INTO operation_log VALUES(?,?,?,?,?,?,?,?,?)').run(
        operationId, operation, taskId, targetId, inputDigest, 'committed', canonical(result), nextRevision, utcNow()
      );
    }
    if ((faultPoint ?? process.env.ATO_FAULT_POINT) === 'before-commit') fail('injected fault before commit', 'fault_injected');
    db.exec('COMMIT');
    return result;
  } catch (error) {
    if (db.isTransaction) db.exec('ROLLBACK');
    throw error;
  }
}

function attemptIdentity(args) {
  return {
    ownerId: requireValue(args, 'owner_id'),
    attemptId: requireValue(args, 'attempt_id'),
    fencingToken: integer(requireValue(args, 'fencing_token'), 'fencing-token', 1)
  };
}
function requireAttempt(row, identity) {
  if (row.status !== 'active') fail('row is not active', 'stale_attempt');
  if (row.attempt_id !== identity.attemptId || row.owner_id !== identity.ownerId) fail('attempt or owner does not match active row', 'stale_attempt');
  if (row.fencing_token !== identity.fencingToken) fail('fencing token does not match active row', 'stale_fence');
  if (row.lease_expires_at && row.lease_expires_at <= utcNow()) fail('active lease has expired', 'lease_expired');
}

function commandInit(db, args) {
  const taskId = requireValue(args, 'task_id');
  const objective = requireValue(args, 'objective');
  const input = { taskId, objective };
  return mutate(db, options(args, 'init', taskId, taskId, input), () => {
    const existing = db.prepare('SELECT objective FROM tasks WHERE task_id=?').get(taskId);
    if (existing && existing.objective !== objective) fail('task_id already has a different objective', 'conflict');
    const stamp = utcNow();
    db.prepare('INSERT OR IGNORE INTO tasks VALUES(?,?,?,?)').run(taskId, objective, stamp, stamp);
    return { task_id: taskId, created: !existing };
  });
}

function normalizeRow(value) {
  const required = ['id', 'target_state', 'action_path', 'execution_class', 'permission_state', 'idempotency_key', 'failure_recovery', 'next_check'];
  const missing = required.filter(key => !value[key]);
  if (missing.length) fail(`missing row fields: ${missing.join(', ')}`, 'invalid_input');
  return {
    ...value, inputs: value.inputs ?? [], dependencies: value.dependencies ?? [],
    checkpoint_before: value.checkpoint_before ?? false, checkpoint_after: value.checkpoint_after ?? false,
    retry_limit: integer(value.retry_limit ?? 1, 'retry-limit', 0), evidence_id: value.evidence_id ?? null
  };
}

function commandAddRow(db, args) {
  const taskId = requireValue(args, 'task_id');
  const value = normalizeRow(readJson(requireValue(args, 'input_file')));
  const rowId = String(value.id);
  return mutate(db, options(args, 'add-row', taskId, rowId, value), () => {
    requireTask(db, taskId);
    if (db.prepare('SELECT 1 FROM task_rows WHERE task_id=? AND row_id=?').get(taskId, rowId)) fail(`row already exists: ${rowId}`, 'conflict');
    for (const dependency of value.dependencies) {
      if (dependency === rowId) fail('a row cannot depend on itself', 'invalid_input');
      if (!db.prepare('SELECT 1 FROM task_rows WHERE task_id=? AND row_id=?').get(taskId, dependency)) fail(`dependency not found: ${dependency}`, 'not_found');
    }
    const stamp = utcNow();
    db.prepare(`INSERT INTO task_rows(
      task_id,row_id,target_state,inputs_json,action_path,execution_class,permission_state,idempotency_key,
      checkpoint_before,checkpoint_after,retry_limit,expected_evidence_id,failure_recovery,next_check,created_at,updated_at
    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
      taskId,rowId,value.target_state,canonical(value.inputs),value.action_path,value.execution_class,value.permission_state,
      value.idempotency_key,bool(value.checkpoint_before),bool(value.checkpoint_after),value.retry_limit,value.evidence_id,
      value.failure_recovery,value.next_check,stamp,stamp
    );
    const insert = db.prepare('INSERT INTO dependencies VALUES(?,?,?)');
    for (const dependency of value.dependencies) insert.run(taskId, rowId, dependency);
    return { task_id: taskId, row_id: rowId, status: 'pending' };
  });
}

function commandActivate(db, args) {
  const taskId = requireValue(args, 'task_id');
  const rowId = requireValue(args, 'row_id');
  const ownerId = requireValue(args, 'owner_id');
  const attemptId = args.attempt_id || generatedId(args, 'attempt');
  const leaseSeconds = integer(args.lease_seconds ?? 900, 'lease-seconds', 1);
  const input = { taskId, rowId, ownerId, attemptId, leaseSeconds };
  return mutate(db, options(args, 'activate', taskId, rowId, input), () => {
    const row = getRow(db, taskId, rowId);
    if (!['pending', 'failed'].includes(row.status)) fail(`cannot activate from ${row.status}`, 'invalid_transition');
    if (row.permission_state !== 'granted') fail('row permission is not granted', 'permission_denied');
    const missing = db.prepare(`SELECT d.depends_on FROM dependencies d JOIN task_rows r
      ON r.task_id=d.task_id AND r.row_id=d.depends_on WHERE d.task_id=? AND d.row_id=? AND r.status!='passed'`).all(taskId, rowId);
    if (missing.length) fail(`dependencies not passed: ${missing.map(item => item.depends_on).join(', ')}`, 'not_ready');
    const retryCount = row.retry_count + (row.status === 'failed' ? 1 : 0);
    if (retryCount > row.retry_limit) fail('retry limit exceeded', 'retry_exhausted');
    const fence = row.fencing_token + 1;
    const expiry = after(leaseSeconds);
    db.prepare(`UPDATE task_rows SET status='active',attempt_id=?,owner_id=?,lease_expires_at=?,fencing_token=?,
      retry_count=?,updated_at=? WHERE task_id=? AND row_id=?`).run(attemptId,ownerId,expiry,fence,retryCount,utcNow(),taskId,rowId);
    return { task_id: taskId, row_id: rowId, status: 'active', attempt_id: attemptId, owner_id: ownerId, lease_expires_at: expiry, fencing_token: fence };
  });
}

function commandRenewLease(db, args) {
  const taskId = requireValue(args, 'task_id');
  const rowId = requireValue(args, 'row_id');
  const identity = attemptIdentity(args);
  const leaseSeconds = integer(args.lease_seconds ?? 900, 'lease-seconds', 1);
  const input = { taskId, rowId, ...identity, leaseSeconds };
  return mutate(db, options(args, 'renew-lease', taskId, rowId, input), () => {
    requireAttempt(getRow(db, taskId, rowId), identity);
    const expiry = after(leaseSeconds);
    db.prepare('UPDATE task_rows SET lease_expires_at=?,updated_at=? WHERE task_id=? AND row_id=?').run(expiry,utcNow(),taskId,rowId);
    return { task_id: taskId, row_id: rowId, lease_expires_at: expiry };
  });
}

function commandRecordEvidence(db, args) {
  const taskId = requireValue(args, 'task_id');
  const rowId = requireValue(args, 'row_id');
  const evidenceId = requireValue(args, 'evidence_id');
  const identity = attemptIdentity(args);
  const content = args.input_file ? readText(args.input_file) : (args.text ?? null);
  const pathOrId = args.path_or_id ?? null;
  const input = { taskId, rowId, evidenceId, ...identity, pathOrId, content, artifactDigest: artifactDigest(pathOrId) };
  const evidenceDigest = digest(input);
  return mutate(db, options(args, 'record-evidence', taskId, evidenceId, input), () => {
    const row = getRow(db, taskId, rowId);
    requireAttempt(row, identity);
    if (row.expected_evidence_id && row.expected_evidence_id !== evidenceId) fail('evidence_id does not match row expectation', 'evidence_mismatch');
    const existing = db.prepare('SELECT row_id,digest FROM evidence WHERE task_id=? AND evidence_id=?').get(taskId, evidenceId);
    if (existing) {
      if (existing.row_id === rowId && existing.digest === evidenceDigest) return { task_id: taskId, row_id: rowId, evidence_id: evidenceId, duplicate: true };
      fail('evidence_id already binds different evidence', 'evidence_conflict');
    }
    db.prepare('INSERT INTO evidence VALUES(?,?,?,?,?,?,?,?,?,?,?)').run(
      taskId,evidenceId,rowId,identity.attemptId,identity.ownerId,identity.fencingToken,utcNow(),pathOrId,content,input.artifactDigest,evidenceDigest
    );
    return { task_id: taskId, row_id: rowId, evidence_id: evidenceId, digest: evidenceDigest, duplicate: false };
  });
}

function commandTransition(db, args) {
  const taskId = requireValue(args, 'task_id');
  const rowId = requireValue(args, 'row_id');
  const status = requireValue(args, 'status');
  const input = { taskId, rowId, status, ownerId: args.owner_id ?? null, attemptId: args.attempt_id ?? null, fencingToken: args.fencing_token ?? null };
  return mutate(db, options(args, 'transition', taskId, rowId, input), () => {
    const row = getRow(db, taskId, rowId);
    if (!TRANSITIONS[row.status]?.has(status)) fail(`invalid transition ${row.status} -> ${status}`, 'invalid_transition');
    let identity = null;
    if (row.status === 'active') {
      identity = attemptIdentity(args);
      requireAttempt(row, identity);
    }
    if (status === 'passed') {
      const found = db.prepare('SELECT evidence_id FROM evidence WHERE task_id=? AND row_id=? AND attempt_id=? AND fencing_token=?').all(taskId,rowId,identity.attemptId,identity.fencingToken);
      if (!found.length) fail('passed requires evidence from the active attempt', 'evidence_required');
      if (row.expected_evidence_id && !found.some(item => item.evidence_id === row.expected_evidence_id)) fail('expected evidence is missing', 'evidence_required');
    }
    db.prepare('UPDATE task_rows SET status=?,lease_expires_at=NULL,updated_at=? WHERE task_id=? AND row_id=?').run(status,utcNow(),taskId,rowId);
    return { task_id: taskId, row_id: rowId, from: row.status, status };
  });
}

function textSource(args) {
  if (args.input_file) return readText(args.input_file);
  if (args.text !== undefined && args.text !== true) return args.text;
  fail('provide --text or --input-file', 'invalid_input');
}

function commandAppendEvent(db, args) {
  const taskId = requireValue(args, 'task_id');
  const input = { taskId, kind: requireValue(args, 'kind'), importance: integer(args.importance ?? 3, 'importance', 1), text: textSource(args) };
  if (input.importance > 5) fail('importance must be <= 5', 'invalid_input');
  return mutate(db, options(args, 'append-event', taskId, null, input), () => {
    requireTask(db, taskId);
    const eventDigest = digest(input);
    const result = db.prepare('INSERT INTO events(task_id,kind,importance,text,digest,created_at) VALUES(?,?,?,?,?,?)').run(taskId,input.kind,input.importance,input.text,eventDigest,utcNow());
    return { task_id: taskId, event_id: Number(result.lastInsertRowid), digest: eventDigest };
  });
}

function commandWriteCheckpoint(db, args) {
  const taskId = requireValue(args, 'task_id');
  const checkpointId = args.checkpoint_id || generatedId(args, 'checkpoint');
  const input = { taskId, checkpointId, parentId: args.parent_id ?? null, text: textSource(args) };
  return mutate(db, options(args, 'write-checkpoint', taskId, checkpointId, input), () => {
    requireTask(db, taskId);
    if (input.parentId) {
      const parent = db.prepare('SELECT task_id FROM checkpoints WHERE checkpoint_id=?').get(input.parentId);
      if (!parent || parent.task_id !== taskId) fail('checkpoint parent not found in task', 'not_found');
    }
    const checkpointDigest = digest(input);
    db.prepare('INSERT INTO checkpoints VALUES(?,?,?,?,?,?,?)').run(checkpointId,taskId,input.parentId,revision(db)+1,input.text,checkpointDigest,utcNow());
    return { task_id: taskId, checkpoint_id: checkpointId, digest: checkpointDigest };
  });
}

function commandBuildContext(db, args) {
  const taskId = requireValue(args, 'task_id');
  const contextId = args.context_id || generatedId(args, 'context');
  const maxChars = integer(args.max_chars ?? 8000, 'max-chars', 128);
  const input = { taskId, contextId, maxChars };
  return mutate(db, options(args, 'build-context', taskId, contextId, input), () => {
    requireTask(db, taskId);
    const checkpoint = db.prepare('SELECT checkpoint_id,text,digest,revision FROM checkpoints WHERE task_id=? ORDER BY revision DESC LIMIT 1').get(taskId);
    const items = [];
    let used = 0;
    const include = block => {
      const size = canonical(block).length;
      if (used + size <= maxChars) { items.push(block); used += size; }
    };
    if (checkpoint) include({ type: 'checkpoint', ...plain(checkpoint) });
    for (const event of db.prepare('SELECT event_id,kind,importance,text,digest,created_at FROM events WHERE task_id=? ORDER BY importance DESC,event_id DESC').all(taskId)) {
      include({ type: 'event', ...plain(event) });
    }
    const content = { task_id: taskId, items };
    const contextDigest = digest(content);
    db.prepare('INSERT INTO contexts VALUES(?,?,?,?,?,?,?,?,?)').run(contextId,taskId,checkpoint?.checkpoint_id ?? null,revision(db)+1,maxChars,used,canonical(content),contextDigest,utcNow());
    return { task_id: taskId, context_id: contextId, used_chars: used, content, digest: contextDigest };
  });
}

function commandEnqueueOutbox(db, args) {
  const taskId = requireValue(args, 'task_id');
  const rowId = requireValue(args, 'row_id');
  const idempotencyKey = requireValue(args, 'idempotency_key');
  const outboxId = args.outbox_id || generatedId(args, 'outbox');
  const actionValue = readJson(requireValue(args, 'input_file'));
  const input = { taskId, rowId, outboxId, idempotencyKey, action: actionValue };
  return mutate(db, options(args, 'enqueue-outbox', taskId, outboxId, input), () => {
    getRow(db, taskId, rowId);
    const existing = db.prepare('SELECT outbox_id,action_json FROM outbox WHERE idempotency_key=?').get(idempotencyKey);
    if (existing) {
      if (canonical(JSON.parse(existing.action_json)) === canonical(actionValue)) return { outbox_id: existing.outbox_id, duplicate: true };
      fail('outbox idempotency key conflict', 'idempotency_conflict');
    }
    const stamp = utcNow();
    db.prepare(`INSERT INTO outbox(outbox_id,task_id,row_id,idempotency_key,action_json,available_at,created_at,updated_at)
      VALUES(?,?,?,?,?,?,?,?)`).run(outboxId,taskId,rowId,idempotencyKey,canonical(actionValue),stamp,stamp,stamp);
    return { outbox_id: outboxId, status: 'pending', duplicate: false };
  });
}

function commandClaimOutbox(db, args) {
  const ownerId = requireValue(args, 'owner_id');
  const leaseSeconds = integer(args.lease_seconds ?? 300, 'lease-seconds', 1);
  const input = { ownerId, leaseSeconds };
  return mutate(db, options(args, 'claim-outbox', null, null, input), () => {
    const stamp = utcNow();
    const item = db.prepare(`SELECT * FROM outbox WHERE available_at<=? AND
      (status IN ('pending','failed') OR (status='processing' AND lease_expires_at<=?)) ORDER BY created_at LIMIT 1`).get(stamp,stamp);
    if (!item) return { claimed: false };
    const fence = item.fencing_token + 1;
    const expiry = after(leaseSeconds);
    db.prepare(`UPDATE outbox SET status='processing',lease_owner=?,lease_expires_at=?,fencing_token=?,
      attempt_count=attempt_count+1,updated_at=? WHERE outbox_id=?`).run(ownerId,expiry,fence,stamp,item.outbox_id);
    return { claimed: true, outbox_id: item.outbox_id, task_id: item.task_id, row_id: item.row_id, idempotency_key: item.idempotency_key, action: JSON.parse(item.action_json), owner_id: ownerId, lease_expires_at: expiry, fencing_token: fence };
  });
}

function commandCompleteOutbox(db, args) {
  const outboxId = requireValue(args, 'outbox_id');
  const ownerId = requireValue(args, 'owner_id');
  const fencingToken = integer(requireValue(args, 'fencing_token'), 'fencing-token', 1);
  const status = requireValue(args, 'status');
  if (!['done', 'failed'].includes(status)) fail('outbox status must be done or failed', 'invalid_input');
  const resultValue = args.input_file ? readJson(args.input_file) : { message: requireValue(args, 'message') };
  const input = { outboxId, ownerId, fencingToken, status, result: resultValue };
  const prior = db.prepare('SELECT task_id FROM outbox WHERE outbox_id=?').get(outboxId);
  return mutate(db, options(args, 'complete-outbox', prior?.task_id ?? null, outboxId, input), () => {
    const item = db.prepare('SELECT * FROM outbox WHERE outbox_id=?').get(outboxId);
    if (!item) fail('outbox item not found', 'not_found');
    if (item.status !== 'processing' || item.lease_owner !== ownerId || item.fencing_token !== fencingToken) fail('outbox claim is stale', 'stale_fence');
    db.prepare('UPDATE outbox SET status=?,result_json=?,lease_expires_at=NULL,updated_at=? WHERE outbox_id=?').run(status,canonical(resultValue),utcNow(),outboxId);
    return { outbox_id: outboxId, status };
  });
}

function commandNextReady(db, args) {
  const taskId = requireValue(args, 'task_id');
  requireTask(db, taskId);
  const ready = db.prepare(`SELECT r.row_id,r.target_state,r.execution_class FROM task_rows r
    WHERE r.task_id=? AND r.status='pending' AND r.permission_state='granted' AND NOT EXISTS(
      SELECT 1 FROM dependencies d JOIN task_rows p ON p.task_id=d.task_id AND p.row_id=d.depends_on
      WHERE d.task_id=r.task_id AND d.row_id=r.row_id AND p.status!='passed'
    ) ORDER BY r.created_at,r.row_id`).all(taskId).map(plain);
  const stale = db.prepare(`SELECT row_id,attempt_id,owner_id,lease_expires_at,fencing_token FROM task_rows
    WHERE task_id=? AND status='active' AND lease_expires_at<=?`).all(taskId,utcNow()).map(plain);
  return { ok: true, operation: 'next-ready', revision: revision(db), ready, stale_active: stale };
}

function findCycles(db, taskId) {
  const graph = new Map(db.prepare('SELECT row_id FROM task_rows WHERE task_id=?').all(taskId).map(row => [row.row_id, []]));
  for (const edge of db.prepare('SELECT row_id,depends_on FROM dependencies WHERE task_id=?').all(taskId)) graph.get(edge.row_id).push(edge.depends_on);
  const visiting = new Set(), visited = new Set(), cycles = new Set();
  const visit = node => {
    if (visiting.has(node)) { cycles.add(node); return; }
    if (visited.has(node)) return;
    visiting.add(node);
    for (const child of graph.get(node) ?? []) visit(child);
    visiting.delete(node); visited.add(node);
  };
  for (const node of graph.keys()) visit(node);
  return [...cycles].sort();
}

function commandVerify(db, args) {
  const taskId = requireValue(args, 'task_id');
  requireTask(db, taskId);
  const errors = [];
  for (const issue of db.prepare('PRAGMA foreign_key_check').all()) errors.push(`foreign key violation: ${canonical(plain(issue))}`);
  const cycles = findCycles(db, taskId);
  if (cycles.length) errors.push(`dependency cycle includes: ${cycles.join(', ')}`);
  const badPassed = db.prepare(`SELECT r.row_id FROM task_rows r WHERE r.task_id=? AND r.status='passed' AND NOT EXISTS(
    SELECT 1 FROM evidence e WHERE e.task_id=r.task_id AND e.row_id=r.row_id AND e.attempt_id=r.attempt_id AND e.fencing_token=r.fencing_token)`).all(taskId);
  errors.push(...badPassed.map(row => `passed row lacks attempt-bound evidence: ${row.row_id}`));
  const malformed = db.prepare(`SELECT row_id FROM task_rows WHERE task_id=? AND status='active' AND
    (attempt_id IS NULL OR owner_id IS NULL OR lease_expires_at IS NULL OR fencing_token<1)`).all(taskId);
  errors.push(...malformed.map(row => `active row has incomplete lease identity: ${row.row_id}`));
  const invalidOps = db.prepare('SELECT operation_id FROM operation_log WHERE revision>?').all(revision(db));
  errors.push(...invalidOps.map(row => `operation revision exceeds state revision: ${row.operation_id}`));
  const integrity = db.prepare('PRAGMA integrity_check').get().integrity_check;
  if (integrity !== 'ok') errors.push(`integrity_check: ${integrity}`);
  const count = table => Number(db.prepare(`SELECT count(*) AS total FROM ${table} WHERE task_id=?`).get(taskId).total);
  return { ok: !errors.length, operation: 'verify', task_id: taskId, revision: revision(db), counts: {
    rows: count('task_rows'), evidence: count('evidence'), events: count('events'), checkpoints: count('checkpoints'), outbox: count('outbox')
  }, errors };
}

function commandInspect(db, args) {
  const taskId = requireValue(args, 'task_id');
  requireTask(db, taskId);
  const task = plain(db.prepare('SELECT * FROM tasks WHERE task_id=?').get(taskId));
  const rows = db.prepare('SELECT * FROM task_rows WHERE task_id=? ORDER BY created_at,row_id').all(taskId).map(item => {
    const row = plain(item);
    row.inputs = JSON.parse(row.inputs_json); delete row.inputs_json;
    row.dependencies = db.prepare('SELECT depends_on FROM dependencies WHERE task_id=? AND row_id=? ORDER BY depends_on').all(taskId,row.row_id).map(edge => edge.depends_on);
    return row;
  });
  return { ok: true, operation: 'inspect', revision: revision(db), task, rows };
}

function options(args, operation, taskId, targetId, input) {
  return { operation, taskId, targetId, input, operationId: args.operation_id === true ? null : (args.operation_id ?? null), faultPoint: args.fault_point === true ? null : (args.fault_point ?? null) };
}

const HANDLERS = {
  init: commandInit, 'add-row': commandAddRow, activate: commandActivate, 'renew-lease': commandRenewLease,
  'record-evidence': commandRecordEvidence, transition: commandTransition, 'append-event': commandAppendEvent,
  'write-checkpoint': commandWriteCheckpoint, 'build-context': commandBuildContext, 'enqueue-outbox': commandEnqueueOutbox,
  'claim-outbox': commandClaimOutbox, 'complete-outbox': commandCompleteOutbox, 'next-ready': commandNextReady,
  inspect: commandInspect, verify: commandVerify
};

function main() {
  const args = parseArguments(process.argv.slice(2));
  const dbPath = resolve(requireValue(args, 'db'));
  const timeout = integer(args.timeout_ms ?? 30000, 'timeout-ms', 1);
  mkdirSync(dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath, { timeout, enableForeignKeyConstraints: true });
  try {
    db.exec(`PRAGMA busy_timeout=${timeout}; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;`);
    initializeSchema(db);
    const result = HANDLERS[args.command](db, args);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result.ok ? 0 : 2;
  } finally {
    db.close();
  }
}

try {
  process.exitCode = main();
} catch (error) {
  const code = error instanceof RuntimeFailure ? error.code : 'runtime_error';
  process.stderr.write(`${JSON.stringify({ ok: false, code, error: error.message })}\n`);
  process.exitCode = 2;
}
