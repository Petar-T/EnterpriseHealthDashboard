#!/usr/bin/env python3
"""
Invoke-EhdSql.py - minimal sqlcmd replacement for Azure SQL with Entra token auth.

WHY THIS EXISTS
---------------
On some workstations neither standard client works:

  * the SqlServer PowerShell module fails with
        "The type initializer for 'Microsoft.Data.SqlClient.TdsParser' threw an exception"
    because its native SNI library has no build for the host architecture (ARM64).

  * sqlcmd -G defaults to ActiveDirectoryIntegrated, which fails for cloud-managed
    (non-federated) accounts with
        "WIA can only be used for federated accounts, but this account was Managed".

  * sqlcmd 17.x has no flag to accept a pre-minted access token.

This script sidesteps all three: it asks the already-authenticated Azure CLI for a
database.windows.net token and hands it to ODBC Driver 18 via SQL_COPT_SS_ACCESS_TOKEN.

WHAT IT SUPPORTS
----------------
  * GO batch separators (case-insensitive, must be alone on a line)
  * sqlcmd-style $(Variable) substitution via -v Name=Value
  * PRINT / RAISERROR(...,10,...) informational output, which our deploy scripts
    use heavily for operator guidance
  * result sets printed as aligned tables
  * a non-zero exit code on any SQL error, so callers can stop on failure

USAGE
-----
  python Invoke-EhdSql.py -S <server> -d <database> -Q "SELECT 1"
  python Invoke-EhdSql.py -S <server> -d <database> -i script.sql -v CentralServer=foo.database.windows.net
  python Invoke-EhdSql.py -S <server> -d <database> -i script.sql --no-stop-on-error
"""

import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

try:
    import pyodbc
except ImportError:
    sys.exit("pyodbc is required:  pip install pyodbc")

SQL_COPT_SS_ACCESS_TOKEN = 1256
_token_cache = {}


def get_token(resource="https://database.windows.net/"):
    """Mint an access token using the Azure CLI's existing login."""
    if resource in _token_cache:
        return _token_cache[resource]
    proc = subprocess.run(
        ["az", "account", "get-access-token", "--resource", resource, "-o", "json"],
        capture_output=True, text=True, shell=(os.name == "nt"),
    )
    if proc.returncode != 0:
        sys.exit("Could not get an access token. Run 'az login' first.\n" + proc.stderr)
    return _token_cache.setdefault(resource, json.loads(proc.stdout)["accessToken"])


def connect(server, database, timeout=120):
    if not server.endswith(".database.windows.net") and "." not in server:
        server += ".database.windows.net"
    raw = get_token().encode("utf-16-le")
    packed = struct.pack("<i", len(raw)) + raw
    cs = (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER=tcp:{server},1433;DATABASE={database};"
        "Encrypt=yes;TrustServerCertificate=no;"
        f"Connection Timeout={timeout};"
    )
    cn = pyodbc.connect(cs, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: packed}, autocommit=True)
    cn.timeout = timeout
    return cn


def substitute(text, variables):
    """sqlcmd-style $(Name) replacement."""
    for k, v in variables.items():
        text = text.replace(f"$({k})", v)
    return text


def split_batches(text):
    """
    Split on GO when it is alone on a line. Deliberately simple: our scripts never
    place GO inside a string literal or comment, and a full T-SQL lexer here would be
    more risk than it removes.
    """
    parts, current = [], []
    for line in text.splitlines():
        if re.match(r"^\s*GO\s*(--.*)?$", line, re.IGNORECASE):
            parts.append("\n".join(current))
            current = []
        else:
            current.append(line)
    parts.append("\n".join(current))
    return [p for p in parts if p.strip()]


def print_rows(cursor):
    """Print every result set the batch produced.

    An EMPTY result set is announced rather than skipped. Printing nothing for
    zero rows makes "the query returned nothing" indistinguishable from "the
    query never ran" - which is precisely how a purge that deleted nothing, and
    a deployment log with no entries, were both mistaken for broken tooling.
    """
    while True:
        if cursor.description:
            cols = [d[0] if d[0] else "(no name)" for d in cursor.description]
            rows = cursor.fetchall()
            if not rows:
                print("  (0 rows)  columns: " + ", ".join(cols))
                print()
            if rows:
                widths = [len(c) for c in cols]
                shown = rows[:200]
                for r in shown:
                    for i, val in enumerate(r):
                        widths[i] = max(widths[i], len("" if val is None else str(val)))
                widths = [min(w, 60) for w in widths]
                print("  " + "  ".join(c[:widths[i]].ljust(widths[i]) for i, c in enumerate(cols)))
                print("  " + "  ".join("-" * w for w in widths))
                for r in shown:
                    cells = []
                    for i, val in enumerate(r):
                        s = "NULL" if val is None else str(val).replace("\n", " ")
                        cells.append(s[:widths[i]].ljust(widths[i]))
                    print("  " + "  ".join(cells))
                if len(rows) > len(shown):
                    print(f"  ... {len(rows) - len(shown)} more row(s)")
                print()
        if not cursor.nextset():
            break


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-S", "--server", required=True)
    ap.add_argument("-d", "--database", default="master")
    ap.add_argument("-i", "--input-file")
    ap.add_argument("-Q", "--query")
    ap.add_argument("-v", "--var", action="append", default=[],
                    help="sqlcmd-style variable, e.g. -v CentralServer=foo.database.windows.net")
    ap.add_argument("-t", "--timeout", type=int, default=300)
    ap.add_argument("--no-stop-on-error", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="suppress result sets, show messages only")
    args = ap.parse_args()

    if not args.input_file and not args.query:
        sys.exit("Supply -i <file> or -Q <query>.")

    variables = {}
    for v in args.var:
        if "=" not in v:
            sys.exit(f"Bad -v value '{v}'. Expected Name=Value.")
        k, _, val = v.partition("=")
        variables[k] = val

    if args.input_file:
        with open(args.input_file, "rb") as fh:
            raw = fh.read()
        sql = raw.decode("utf-8-sig")
        label = os.path.basename(args.input_file)
        file_sha = hashlib.sha256(raw).hexdigest()
        file_bytes = len(raw)
    else:
        sql, label = args.query, "(inline)"
        file_sha, file_bytes = None, None

    sql = substitute(sql, variables)
    unresolved = sorted(set(re.findall(r"\$\((\w+)\)", sql)))
    if unresolved:
        print(f"  !! unresolved sqlcmd variables: {', '.join(unresolved)}", file=sys.stderr)

    batches = split_batches(sql)
    cn = connect(args.server, args.database, args.timeout)
    cur = cn.cursor()

    errors = 0
    for n, batch in enumerate(batches, 1):
        try:
            cur.execute(batch)
            # Capture messages IMMEDIATELY. pyodbc repopulates cursor.messages as
            # result sets are consumed, so reading them after print_rows() loses the
            # PRINT output our deploy scripts use to instruct the operator.
            captured = list(getattr(cur, "messages", None) or [])
            for msg in captured:
                text = msg[1] if isinstance(msg, (tuple, list)) and len(msg) > 1 else str(msg)
                # strip every leading "[driver][component]" prefix, not just the first
                text = re.sub(r"^(\[[^\]]*\])+\s*", "", str(text)).strip()
                if text:
                    print("  " + text)
            if not args.quiet:
                print_rows(cur)
        except pyodbc.Error as exc:
            errors += 1
            first = str(exc.args[1] if len(exc.args) > 1 else exc)
            first = re.sub(r"\[Microsoft\]\[ODBC Driver 18 for SQL Server\]\[SQL Server\]", "", first)
            print(f"  !! {label} batch {n} FAILED: {first.strip()}", file=sys.stderr)
            head = "\n".join(batch.strip().splitlines()[:3])
            print(f"     near: {head}", file=sys.stderr)
            if not args.no_stop_on_error:
                cn.close()
                sys.exit(1)

    if errors:
        cn.close()
        print(f"  {label}: completed with {errors} error(s)", file=sys.stderr)
        sys.exit(1)

    # ---------------------------------------------------------------------
    # Record WHAT was deployed, so "is the database running the file I have
    # on disk?" is a fact rather than a guess.
    #
    # Checking a procedure's definition for a marker string is unreliable -
    # the marker usually also appears in a comment describing it, which is
    # how a stale deployment was reported as current. A SHA-256 of the exact
    # bytes executed cannot be fooled that way.
    #
    # Degrades silently when cfg.DeployLog does not exist yet, because this
    # tool has to work on an empty database before 00-schemas-and-config.sql
    # has ever run.
    # ---------------------------------------------------------------------
    if file_sha:
        try:
            cur.execute("""
                IF OBJECT_ID('cfg.DeployLog') IS NOT NULL
                MERGE cfg.DeployLog AS t
                USING (SELECT ScriptName = ?, FileSha256 = ?, FileBytes = ?,
                              DeployedBy = SUSER_SNAME()) AS s
                   ON t.ScriptName = s.ScriptName
                WHEN MATCHED THEN UPDATE SET FileSha256 = s.FileSha256,
                                             FileBytes  = s.FileBytes,
                                             DeployedUtc = SYSUTCDATETIME(),
                                             DeployedBy = s.DeployedBy
                WHEN NOT MATCHED THEN
                    INSERT (ScriptName, FileSha256, FileBytes, DeployedUtc, DeployedBy)
                    VALUES (s.ScriptName, s.FileSha256, s.FileBytes, SYSUTCDATETIME(), s.DeployedBy);
            """, label, file_sha, file_bytes)
            print(f"  recorded in cfg.DeployLog: {label}  sha256 {file_sha[:16]}...")
        except pyodbc.Error as exc:
            print(f"  (deploy log not updated: {exc.args[-1] if exc.args else exc})",
                  file=sys.stderr)

    cn.close()


if __name__ == "__main__":
    main()
