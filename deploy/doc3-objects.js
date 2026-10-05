/* Document 3 - Object Reference, generated from docs/inventory.json */
const L = require('./doc-lib');
const { H1, H2, H3, P, RICH, RUN, BULLET, CODE, CALLOUT, TBL, SPACER, BREAK, docShell, save, inv } = L;
const WRITTEN = require('./doc-descriptions');
/* Prefer the object's own source comment; fall back to a written description for
   objects whose source comment covers a whole section rather than one object. */
function described(o) {
  const own = (o.comment || '').trim();
  if (own) return own;
  return WRITTEN[(o.schema + '.' + o.name).toLowerCase()] || '';
}
const c = [];

/* trim an extracted comment block down to a usable description */
function desc(txt, max) {
  if (!txt) return '';
  let t = txt.replace(/\r/g, '');
  t = t.split('\n').filter(l => !/^\s*(File|Run in|Tier)\s*:/.test(l)).join('\n');
  t = t.replace(/^\s*ENTERPRISE HEALTH DASHBOARD\s*$/mi, '');
  t = t.replace(/\n{2,}/g, '\n').trim();
  if (max && t.length > max) {
    const cut = t.slice(0, max);
    const stop = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('\n'));
    t = (stop > max * 0.5 ? cut.slice(0, stop + 1) : cut) + ' ...';
  }
  return t;
}
function paras(txt) {
  if (!txt) return [];
  /* Reflow. Source comments are hard-wrapped at ~78 columns; preserving those
     breaks as separate paragraphs looks like broken prose in Word. Join runs of
     non-empty lines, and treat a blank line as a real paragraph break. Lines
     that are clearly structural - list markers, indented code - are kept. */
  const out = [];
  let buf = [];
  const flush = () => { if (buf.length) { out.push(P(buf.join(' '), { after: 80 })); buf = []; } };
  txt.split('\n').forEach(raw => {
    const line = raw.replace(/\s+$/, '');
    if (!line.trim()) { flush(); return; }
    if (/^\s{2,}\S/.test(line) || /^\s*[*\-]\s/.test(line)) { flush(); out.push(P(line.trim(), { after: 60 })); return; }
    buf.push(line.trim());
  });
  flush();
  return out;
}

/* ------------------------------------------------------------------ intro */
c.push(H1('1. How to read this document'));
c.push(P('A complete reference for every object the Enterprise Health Dashboard creates in the central repository, generated directly from the deployment scripts and reconciled against the live database. If the scripts change, regenerate this document rather than editing it:'));
c.push(...CODE(['python deploy\\Export-Inventory.py', 'node   deploy\\doc3-objects.js']));

c.push(TBL(['Object type', 'Count'],
  [['Tables', String(inv.tables.length)],
   ['Columns across those tables', String(inv.tables.reduce((a, t) => a + t.columns.length, 0))],
   ['Views', String(inv.views.length)],
   ['Stored procedures', String(inv.procedures.length)],
   ['Functions', String(inv.functions.length)],
   ['Explicit indexes', String(inv.indexes.length)],
   ['Configuration settings', String(inv.settings.length)],
   ['Elastic jobs / job steps', inv.jobs.length + ' / ' + inv.jobs.reduce((a, j) => a + j.steps.length, 0)],
   ['Collection feeds', String(inv.feeds.length)]], [60, 40]));

c.push(H2('Schemas'));
c.push(TBL(['Schema', 'Owner', 'Purpose'],
  [
    ['cfg', 'this system', 'Configuration and the target registry. Small, hand-editable, read constantly'],
    ['stg', 'this system, written by the agent', 'Landing zone. Tables are CREATED BY ELASTIC JOBS on first run, never by you. Rows are transient and purged on a retention window'],
    ['core', 'this system', 'The modelled, de-duplicated, queryable data and the views over it'],
    ['jobs', 'the Elastic Job Agent', 'The agent\'s own control plane. READ it; never write to it. The collector identity is explicitly denied every form of write here'],
    ['jobs_internal', 'the Elastic Job Agent', 'Agent internals. Nothing in this system touches it, and the collector identity is denied all access']
  ], [14, 22, 64]));
c.push(SPACER());

c.push(CALLOUT('Never pre-create a stg.* table',
  ['Elastic Jobs creates the output table itself on first run, deriving the columns from the result set and adding exactly one column of its own: internal_execution_id (uniqueidentifier), plus a nonclustered index on it.',
   'If a table already exists with a different shape, the insert fails with "The given ColumnMapping does not match up with any column in the source or destination". If a collection query\'s output columns change, DROP the staging table so the agent rebuilds it.'], 'C00000'));

c.push(BREAK());

/* ------------------------------------------------------------- data flow */
c.push(H1('2. The data flow'));
c.push(P('Each feed is a read-only query executed inside a monitored database. Elastic Jobs lands the result in a staging table; core.usp_Normalize promotes it into one or more modelled tables; core.usp_RecordArrival records that it arrived; core.usp_PurgeStaging ages the staging rows out.'));
c.push(P('Every collection query emits its own identity and timestamp, because the agent supplies neither:'));
c.push(...CODE(['ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),',
                'DatabaseName = DB_NAME(),',
                'SnapshotUtc  = <the feed timestamp>,']));
c.push(P('Those column names are read through cfg.Setting (Staging.ServerColumn, Staging.DatabaseColumn), so they can be renamed without touching the 65 call sites inside the normalizer.'));

c.push(TBL(['Feed', 'Tier', 'Staging table', 'Promoted into'],
  inv.feeds.map(f => [f.feed, f.tier, f.staging, f.coreTables.join('\n') || '(none)']),
  [18, 12, 25, 45]));

c.push(H3('Guard columns'));
c.push(P('core.fn_StagingReady checks these columns exist before the normalizer touches a feed. A missing column means that feed is SKIPPED - deliberately silent at the row level, but counted and reported by usp_Normalize.'));
c.push(TBL(['Feed', 'Required columns'],
  inv.feeds.map(f => [f.feed, f.requiredColumns || '(server, database and a timestamp)']), [24, 76]));

c.push(BREAK());

/* ---------------------------------------------------------------- tables */
c.push(H1('3. Tables'));
const bySchema = {};
inv.tables.forEach(t => { (bySchema[t.schema] = bySchema[t.schema] || []).push(t); });

Object.keys(bySchema).sort().forEach(schema => {
  c.push(H2('3.' + (schema === 'cfg' ? '1' : '2') + '  Schema: ' + schema));
  bySchema[schema].forEach(t => {
    c.push(H3(t.schema + '.' + t.name));
    const d = desc(described(t), 700);
    if (d) paras(d).forEach(p => c.push(p));
    c.push(P('Defined in ' + t.file, { italics: true, after: 80 }));
    c.push(TBL(['Column', 'Type', 'Null', 'Notes'],
      t.columns.map(col => [col.name, col.type, col.nullable || '-', col.notes || '']),
      [28, 20, 8, 44]));
    const cons = (t.constraints || []).filter(x => x && x.length < 400);
    if (cons.length) {
      c.push(P('Constraints', { bold: true, after: 60 }));
      cons.forEach(x => c.push(BULLET(x)));
    }
    const idx = inv.indexes.filter(i => i.schema.toLowerCase() === t.schema.toLowerCase() &&
                                        i.table.toLowerCase() === t.name.toLowerCase());
    if (idx.length) {
      c.push(P('Indexes', { bold: true, after: 60 }));
      idx.forEach(i => c.push(BULLET(i.name + '  (' + i.keys + ')' + (i.extra ? '  ' + i.extra : ''))));
    }
    c.push(SPACER());
  });
});

c.push(BREAK());

/* ----------------------------------------------------------------- views */
c.push(H1('4. Views'));
c.push(P('All views live in the core schema. They are the intended query surface: the tables hold cumulative or snapshot data, and the views turn it into rates, deltas, rankings and verdicts.'));
inv.views.forEach(v => {
  c.push(H3(v.schema + '.' + v.name));
  const d = desc(described(v), 900);
  if (d) paras(d).forEach(p => c.push(p));
  c.push(P('Defined in ' + v.file, { italics: true, after: 140 }));
});

c.push(BREAK());

/* ------------------------------------------------------------ procedures */
c.push(H1('5. Stored procedures'));
inv.procedures.forEach(p => {
  c.push(H3(p.schema + '.' + p.name));
  const d = desc(described(p), 900);
  if (d) paras(d).forEach(x => c.push(x));
  if (p.params && p.params.trim()) {
    c.push(P('Parameters', { bold: true, after: 50 }));
    c.push(...CODE(p.params.replace(/,\s*/g, ',\n').split('\n')));
  }
  c.push(P('Defined in ' + p.file, { italics: true, after: 140 }));
});

c.push(H1('6. Functions'));
inv.functions.forEach(f => {
  c.push(H3(f.schema + '.' + f.name));
  const d = desc(described(f), 700);
  if (d) paras(d).forEach(x => c.push(x));
  c.push(TBL(['Parameters', 'Returns'], [[f.params || '(none)', f.returns || '']], [60, 40]));
  c.push(P('Defined in ' + f.file, { italics: true, after: 140 }));
});

c.push(BREAK());

/* -------------------------------------------------------------- settings */
c.push(H1('7. Configuration settings'));
c.push(P('All behaviour is tuned through cfg.Setting. Changes take effect on the next run of the relevant procedure - no redeployment is needed. Keys are read through cfg.fn_Int and cfg.fn_Dec, which fall back to a hard-coded default if a key is missing, so a typo silently uses the default rather than failing.'));
c.push(...CODE([
  "UPDATE cfg.Setting SET SettingValue = N'<value>', ModifiedUtc = SYSUTCDATETIME()",
  " WHERE SettingKey = '<key>';",
  '',
  '-- verify every key the code reads is actually defined',
  '.\\tests\\Test-SettingKeys.ps1']));

const groups = {};
inv.settings.forEach(s => {
  const g = s.key.split('.')[0];
  (groups[g] = groups[g] || []).push(s);
});
Object.keys(groups).sort().forEach(g => {
  c.push(H3(g + '.*'));
  c.push(TBL(['Key', 'Default', 'Meaning'],
    groups[g].map(s => [s.key, s.default, s.description]), [26, 12, 62]));
  c.push(SPACER());
});

c.push(BREAK());

/* ------------------------------------------------------------------ jobs */
c.push(H1('8. Elastic jobs'));
c.push(P('Six jobs. The three collect jobs run read-only queries against every member of EHD_AllTargets. The two process jobs run inside the repository only, against EHD_Central. The setup job is the single exception to the read-only rule and is created disabled.'));

c.push(TBL(['Job', 'Enabled', 'Schedule', 'Target group', 'Steps'],
  inv.jobs.map(j => [
    j.name,
    j.enabled === '0' ? '0' : '1',
    j.intervalType === '(none)' ? 'manual only' : (j.intervalType + ' ' + j.intervalCount + (j.startTime ? '\nfrom ' + j.startTime : '')),
    (j.steps[0] && j.steps[0].targetGroup) ? (j.steps[0].targetGroup === '@Group' ? 'EHD_AllTargets' : j.steps[0].targetGroup) : '',
    String(j.steps.length)
  ]), [26, 11, 24, 25, 14]));
c.push(SPACER());

c.push(CALLOUT('A failed step aborts the rest of its job',
  ['If step 3 fails, steps 4 through 7 never run and their staging tables never appear. It looks like several independent problems and is one. Always diagnose by step_id order, fixing the FIRST failure.'], 'C00000'));
c.push(SPACER());

inv.jobs.forEach(j => {
  c.push(H3(j.name));
  if (j.description) c.push(P(j.description));
  c.push(TBL(['#', 'Step', 'Output table', 'Retries', 'Timeout (s)'],
    j.steps.map((s, i) => [String(i + 1), s.name,
      s.outputTable ? ((s.outputSchema || 'stg') + '.' + s.outputTable) : '(no output)',
      s.retries || '-', s.timeout || '-']),
    [6, 30, 36, 14, 14]));
  c.push(P('Defined in ' + j.file, { italics: true, after: 140 }));
});

c.push(H2('Target groups'));
c.push(TBL(['Group', 'Purpose'],
  [['EHD_AllTargets', 'Every monitored database. The three collect jobs run against this group'],
   ['EHD_Central', 'Exactly one member - the repository itself. The two process jobs run against this group'],
   ['EHD_Prod', 'Optional. A narrower group for production-only scheduling, unused by default']], [22, 78]));
c.push(P('EHD_Central is kept disjoint from EHD_AllTargets on purpose. If the repository ended up in a collection group by accident the read-only queries would run against it too - harmless, but it would add the monitoring database to the fleet scorecard as noise. Disjoint groups make that mistake visible.'));
c.push(P('In this deployment the repository IS deliberately a member of both, because it is itself a monitored database.'));

c.push(BREAK());

/* ----------------------------------------------------------- index list */
c.push(H1('9. Explicit indexes'));
c.push(P('Beyond the primary keys declared inline with each table.'));
c.push(TBL(['Index', 'On', 'Keys', 'Filter / includes'],
  inv.indexes.map(i => [i.name, i.schema + '.' + i.table, i.keys, i.extra || '']),
  [30, 20, 26, 24]));

c.push(H1('10. Files'));
c.push(TBL(['File', 'Lines'],
  inv.files.map(f => [f.path, String(f.lines)]), [72, 28]));

(async () => {
  await save(docShell('Enterprise Health Dashboard', 'Object Reference', c),
             'EHD-03-Object-Reference.docx');
})();
