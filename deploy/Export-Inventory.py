"""Extract a structured inventory of every object in the solution, straight from
the deployment scripts. Source of truth is the scripts, not a live database, so
the documentation describes the product rather than one deployment.

Emits docs/inventory.json
"""
import json, os, re, io

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def read(rel):
    with io.open(os.path.join(ROOT, rel), 'r', encoding='utf-8-sig', errors='replace') as fh:
        return fh.read()

def sql_files():
    """Deployed objects only. tests\\ contains scaffolding (demo seed data, the
    pipeline self-test) that never ships to a monitored estate, so including it
    would overstate the object count."""
    out = []
    for d in ('01-central', '02-targets', '03-elasticjobs'):
        p = os.path.join(ROOT, d)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            if f.lower().endswith('.sql'):
                out.append(os.path.join(d, f))
    return out

def strip_block_comments(t):
    return re.sub(r'/\*.*?\*/', '', t, flags=re.S)

def leading_comment(text, idx, maxchars=2600):
    """The /* ... */ block immediately preceding position idx, cleaned up.

    'Immediately' tolerates the benign guards that sit between a comment and the
    statement it documents - IF OBJECT_ID(...) IS NULL, GO, blank lines. Without
    that tolerance almost every CREATE TABLE in this solution loses its
    description, because they are all written as existence-guarded DDL."""
    head = text[:idx]
    m = None
    for m in re.finditer(r'/\*(.*?)\*/', head, flags=re.S):
        pass
    if not m:
        return ''
    between = head[m.end():]
    benign = re.sub(r"(?i)\bIF\s+(NOT\s+)?EXISTS\s*\(.*?\)", '', between, flags=re.S)
    benign = re.sub(r"(?i)\bIF\s+OBJECT_ID\s*\([^)]*\)\s*IS\s+(NOT\s+)?NULL", '', benign)
    benign = re.sub(r"(?i)^\s*GO\s*$", '', benign, flags=re.M)
    if benign.strip():                       # a real statement intervened
        return ''
    body = m.group(1)
    lines = []
    for ln in body.split('\n'):
        ln = ln.rstrip()
        ln = re.sub(r'^\s*[=\-]{4,}\s*$', '', ln)
        ln = re.sub(r'^\s{0,4}', '', ln)
        lines.append(ln)
    txt = '\n'.join(lines).strip()
    txt = re.sub(r'\n{3,}', '\n\n', txt)
    return txt[:maxchars]

# ---------------------------------------------------------------- tables
COLTYPES = (r'bigint|int\b|smallint|tinyint|bit|decimal|numeric|money|float|real|'
            r'datetime2|datetimeoffset|datetime|date|time|char|varchar|nchar|nvarchar|'
            r'binary|varbinary|uniqueidentifier|sysname|xml|geography')

def parse_table(body):
    """Split a CREATE TABLE body into column / constraint entries."""
    depth, cur, parts = 0, [], []
    for ch in body:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(''.join(cur)); cur = []
        else:
            cur.append(ch)
    if ''.join(cur).strip():
        parts.append(''.join(cur))

    cols, cons = [], []
    for raw in parts:
        s = ' '.join(raw.split())
        if not s:
            continue
        if re.match(r'^(CONSTRAINT|PRIMARY\s+KEY|UNIQUE|FOREIGN\s+KEY|CHECK|INDEX)\b', s, re.I):
            cons.append(s)
            continue
        m = re.match(r'^\[?([A-Za-z_][\w]*)\]?\s+(.*)$', s)
        if not m:
            continue
        name, rest = m.group(1), m.group(2)
        computed = bool(re.match(r'^AS\b', rest, re.I))
        tm = re.match(r'^((?:%s)(?:\s*\([^)]*\))?)' % COLTYPES, rest, re.I)
        dtype = 'computed' if computed else (tm.group(1) if tm else rest.split(' ')[0])
        nullable = 'no' if re.search(r'\bNOT\s+NULL\b', rest, re.I) else (
                   'yes' if re.search(r'\bNULL\b', rest, re.I) else '')
        dm = re.search(r'\bDEFAULT\s*\((.*?)\)\s*(?:,|$)', rest, re.I)
        notes = []
        if re.search(r'\bIDENTITY\b', rest, re.I):      notes.append('IDENTITY')
        if re.search(r'\bPRIMARY\s+KEY\b', rest, re.I): notes.append('PK')
        if computed:                                     notes.append('computed: ' + rest[2:].strip()[:120])
        if dm:                                           notes.append('default ' + dm.group(1)[:60])
        cols.append({'name': name, 'type': dtype, 'nullable': nullable,
                     'notes': '; '.join(notes)})
    return cols, cons

inv = {'tables': [], 'views': [], 'procedures': [], 'functions': [],
       'settings': [], 'jobs': [], 'indexes': [], 'files': []}

for rel in sql_files():
    text = read(rel)
    inv['files'].append({'path': rel.replace('/', '\\'),
                         'lines': text.count('\n') + 1,
                         'purpose': (re.search(r'^\s*(.*?)$', '', re.M) and '')})

    for m in re.finditer(r'CREATE\s+TABLE\s+(\[?\w+\]?)\.(\[?\w+\]?)\s*\((.*?)\n\)\s*;', text, re.S | re.I):
        schema, name = m.group(1).strip('[]'), m.group(2).strip('[]')
        cols, cons = parse_table(m.group(3))
        inv['tables'].append({'schema': schema, 'name': name, 'file': rel,
                              'comment': leading_comment(text, m.start()),
                              'columns': cols, 'constraints': cons})

    for m in re.finditer(r'CREATE\s+(?:OR\s+ALTER\s+)?VIEW\s+(\[?\w+\]?)\.(\[?\w+\]?)', text, re.I):
        inv['views'].append({'schema': m.group(1).strip('[]'), 'name': m.group(2).strip('[]'),
                             'file': rel, 'comment': leading_comment(text, m.start())})

    for m in re.finditer(r'CREATE\s+(?:OR\s+ALTER\s+)?PROCEDURE\s+(\[?\w+\]?)\.(\[?\w+\]?)(.*?)\bAS\b', text, re.S | re.I):
        params = ' '.join(m.group(3).split())[:400]
        inv['procedures'].append({'schema': m.group(1).strip('[]'), 'name': m.group(2).strip('[]'),
                                  'file': rel, 'params': params,
                                  'comment': leading_comment(text, m.start())})

    for m in re.finditer(r'CREATE\s+(?:OR\s+ALTER\s+)?FUNCTION\s+(\[?\w+\]?)\.(\[?\w+\]?)(.*?)\bRETURNS\b\s*([^\n]*)', text, re.S | re.I):
        inv['functions'].append({'schema': m.group(1).strip('[]'), 'name': m.group(2).strip('[]'),
                                 'file': rel, 'params': ' '.join(m.group(3).split())[:300],
                                 'returns': m.group(4).strip()[:120],
                                 'comment': leading_comment(text, m.start())})

    for m in re.finditer(r"CREATE\s+(?:UNIQUE\s+)?(?:NONCLUSTERED|CLUSTERED)?\s*INDEX\s+(\w+)\s*\n?\s*ON\s+(\w+)\.(\w+)\s*\(([^)]*)\)([^;]*)", text, re.I):
        inv['indexes'].append({'name': m.group(1), 'schema': m.group(2), 'table': m.group(3),
                               'keys': ' '.join(m.group(4).split()),
                               'extra': ' '.join(m.group(5).split())[:160], 'file': rel})

# ---------------------------------------------------------------- settings
for rel in ('01-central\\00-schemas-and-config.sql', '01-central\\02-normalize.sql'):
    try:
        text = read(rel)
    except OSError:
        continue
    for m in re.finditer(r"\(\s*'([A-Za-z][\w.]*)'\s*,\s*N'([^']*)'\s*,\s*N'((?:[^']|'')*)'\s*\)", text):
        inv['settings'].append({'key': m.group(1), 'default': m.group(2),
                                'description': m.group(3).replace("''", "'"), 'file': rel})

seen, uniq = set(), []
for s in inv['settings']:
    if s['key'] in seen:
        continue
    seen.add(s['key']); uniq.append(s)
inv['settings'] = sorted(uniq, key=lambda x: x['key'])

# 04-job-health.sql defines core.vw_JobExecution TWICE on purpose - an empty stub
# when the [jobs] schema does not exist yet, and the real one when it does. Only
# one survives deployment, so keep the last definition of any repeated object.
def dedupe(items):
    keep = {}
    for it in items:
        keep[(it['schema'].lower(), it['name'].lower())] = it
    return sorted(keep.values(), key=lambda x: (x['schema'].lower(), x['name'].lower()))

for k in ('tables', 'views', 'procedures', 'functions'):
    inv[k] = dedupe(inv[k])
inv['indexes'] = sorted(inv['indexes'], key=lambda x: (x['schema'].lower(), x['table'].lower(), x['name'].lower()))

# ---------------------------------------------------------------- jobs + steps
def block_at2(text, pos):
    """Everything from pos up to the next EXEC jobs.sp_* call (or end of file).
    Used instead of 'up to the first semicolon', which breaks on @command string
    literals that contain semicolons."""
    nxt = [m.start() for m in re.finditer(r"EXEC\s+jobs\.sp_\w+", text, re.I) if m.start() > pos]
    return text[pos:(nxt[0] if nxt else len(text))]

for rel in sorted(os.listdir(os.path.join(ROOT, '03-elasticjobs'))):
    if not rel.endswith('.sql'):
        continue
    relp = '03-elasticjobs\\' + rel
    text = read(relp)
    jobs = {}
    # (?!step) matters: "sp_add_job" is a prefix of "sp_add_jobstep", so without it
    # every step is also counted as a job and the step totals come out inflated.
    for m in re.finditer(r"sp_add_job(?!step)\b", text, re.I):
        blk = block_at2(text, m.start())
        nm = re.search(r"@job_name\s*=\s*(?:N'([^']+)'|@Job)", blk)
        name = nm.group(1) if (nm and nm.group(1)) else None
        if name is None:
            jm = re.search(r"DECLARE\s+@Job\s+nvarchar\(\d+\)\s*=\s*N'([^']+)'", text)
            name = jm.group(1) if jm else '(unresolved)'
        def g(pat, default=''):
            r = re.search(pat, blk, re.I)
            return r.group(1).strip().strip("'N") if r else default
        jobs[name] = {
            'name': name, 'file': relp,
            'description': g(r"@description\s*=\s*N'([^']*)'"),
            'enabled': g(r"@enabled\s*=\s*(\d)", '1'),
            'intervalType': g(r"@schedule_interval_type\s*=\s*N'([^']*)'", '(none)'),
            'intervalCount': g(r"@schedule_interval_count\s*=\s*(\d+)", ''),
            'startTime': g(r"@schedule_start_time\s*=\s*'([^']*)'"),
            'steps': []
        }
    cur = list(jobs.keys())[0] if len(jobs) == 1 else None
    # Block boundaries: NOT the first ';'. A step's @command is a string literal
    # that routinely contains semicolons ("EXEC core.usp_Normalize;"), which
    # truncates the parameter block before @target_group_name and silently
    # mis-reports which group a step runs against. Cut at the next EXEC jobs.sp_
    # call instead.
    starts = [m.start() for m in re.finditer(r"EXEC\s+jobs\.sp_\w+", text, re.I)]
    def block_at(pos):
        nxt = [s for s in starts if s > pos]
        return text[pos:(nxt[0] if nxt else len(text))]

    for m in re.finditer(r"sp_add_jobstep\b", text, re.I):
        blk = block_at(m.start())
        def g(pat, default=''):
            r = re.search(pat, blk, re.I)
            if not r:
                return default
            return (r.group(1) or '').strip()
        jn = g(r"@job_name\s*=\s*N'([^']+)'", None) or None
        if jn is None:
            jn = cur if cur else (list(jobs.keys())[0] if jobs else None)
        if jn not in jobs:
            jobs[jn] = {'name': jn, 'file': relp, 'description': '', 'enabled': '',
                        'intervalType': '', 'intervalCount': '', 'startTime': '', 'steps': []}
        step_name = g(r"@step_name\s*=\s*N'([^']+)'")
        if not step_name:
            continue                       # a match with no resolvable step name
        jobs[jn]['steps'].append({
            'name': step_name,
            'outputTable': g(r"@output_table_name\s*=\s*N'([^']+)'"),
            'outputSchema': g(r"@output_schema_name\s*=\s*N'([^']+)'"),
            'targetGroup': g(r"@target_group_name\s*=\s*(?:N'([^']+)'|@Group)") or '@Group',
            'retries': g(r"@retry_attempts\s*=\s*(\d+)"),
            'timeout': g(r"@step_timeout_seconds\s*=\s*(\d+)"),
        })
    for j in jobs.values():
        # 20-agent-setup.sql carries a commented-out example; it defines no real job.
        if j['name'] in (None, '(unresolved)') or not j['steps']:
            continue
        inv['jobs'].append(j)

# ---------------------------------------------------------------- feeds
# Map each feed to the staging table it lands in and the core tables the
# normalizer promotes it into. Derived from 02-normalize.sql so the document
# cannot drift from the code.
inv['feeds'] = []
try:
    ntext = read('01-central\\02-normalize.sql')
except OSError:
    ntext = ''
if ntext:
    calls = list(re.finditer(
        r"EXEC\s+core\.usp_RecordArrival\s+'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'", ntext))
    for i, m in enumerate(calls):
        start = calls[i - 1].end() if i else 0
        block = ntext[start:m.start()]
        targets = sorted(set(re.findall(r'INSERT\s+INTO\s+(core\.\w+)', block, re.I)))
        # core.ProcessRun is the normalizer's own run log, not a destination for
        # any feed - it only appears in the first block because usp_Normalize
        # opens by recording its own run.
        targets = [t for t in targets if t.lower() != 'core.processrun']
        guard = re.search(r"fn_StagingReady\('%s',\s*@srv\s*\+\s*','\s*\+\s*@db\s*\+\s*',([^']*)'" % re.escape(m.group(1)), block)
        inv['feeds'].append({
            'feed': m.group(1), 'tier': m.group(2), 'staging': 'stg.' + m.group(3),
            'coreTables': targets,
            'requiredColumns': ('ServerName, DatabaseName, ' + guard.group(1)) if guard else ''
        })

os.makedirs(os.path.join(ROOT, 'docs'), exist_ok=True)
with io.open(os.path.join(ROOT, 'docs', 'inventory.json'), 'w', encoding='utf-8') as fh:
    json.dump(inv, fh, indent=1)

print('tables     : %d' % len(inv['tables']))
print('views      : %d' % len(inv['views']))
print('procedures : %d' % len(inv['procedures']))
print('functions  : %d' % len(inv['functions']))
print('indexes    : %d' % len(inv['indexes']))
print('settings   : %d' % len(inv['settings']))
print('jobs       : %d  (steps %d)' % (len(inv['jobs']), sum(len(j['steps']) for j in inv['jobs'])))
print('columns    : %d' % sum(len(t['columns']) for t in inv['tables']))
