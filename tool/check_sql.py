#!/usr/bin/env python3
"""Parse-check migrations without a database.

Validates two layers that a plain text editor cannot:
  1. the outer SQL statements, via the real PostgreSQL grammar (libpg_query);
  2. the PL/pgSQL bodies of CREATE FUNCTION, which the outer parser only sees
     as opaque dollar-quoted strings.

Usage: check_sql.py [file-or-dir ...]   (defaults to supabase/migrations)
"""

import sys
from pathlib import Path

from pglast import parse_sql, split
from pglast.parser import ParseError, parse_plpgsql_json

# libpg_query's standalone plpgsql parser has no type context for DECLARE'd
# scalars, so it misreads every `SELECT a, b INTO x, y`. The pattern is all over
# already-shipped migrations, so treat it as a parser limitation, not a defect.
KNOWN_PARSER_LIMITATIONS = ("record variable cannot be part of multiple-item INTO list",)

# Same class of limitation, but the message is one a real typo could also
# produce, so these are pinned per function instead of suppressed globally.
# Both need the catalog: `%ROWTYPE` fields and user-defined enum types.
BASELINE = {
    ("00001_initial.sql", "active_buckets_for_user"),
    ("00002_harden_rls.sql", "active_buckets_for_user"),
    ("00005_ai_quota_gate.sql", "ai_gate_consume"),
    ("00017_ai_gate_credit_intent.sql", "ai_gate_consume"),
    ("00045_limits_relaxed_paywall_bypass.sql", "ai_gate_consume"),
}

DEFAULT_TARGET = Path(__file__).resolve().parent.parent / "supabase" / "migrations"


def check(path: Path) -> list[str]:
    sql = path.read_text()
    try:
        parse_sql(sql)
    except ParseError as exc:
        return [f"{path.name}: SQL syntax: {exc}"]

    # parse_plpgsql needs one CREATE FUNCTION at a time.
    errors = []
    for stmt in split(sql):
        lowered = stmt.lower()
        if "language plpgsql" not in lowered:
            continue
        if "create or replace function" not in lowered and "create function" not in lowered:
            continue
        try:
            # Only the parse matters; pglast's JSON decode of the result is
            # unreliable for bodies containing quotes, so we skip loads().
            parse_plpgsql_json(stmt)
        except ParseError as exc:
            if any(k in str(exc) for k in KNOWN_PARSER_LIMITATIONS):
                continue
            if (path.name, function_name(stmt)) in BASELINE:
                continue
            errors.append(f"{path.name}: plpgsql in {function_name(stmt)}: {exc}")
    return errors


def function_name(stmt: str) -> str:
    lowered = stmt.lower()
    idx = lowered.find("function")
    return stmt[idx + 8 : idx + 60].strip().split("(")[0] if idx != -1 else "?"


def main() -> int:
    targets = [Path(a) for a in sys.argv[1:]] or [DEFAULT_TARGET]
    files: list[Path] = []
    for t in targets:
        files.extend(sorted(t.glob("*.sql")) if t.is_dir() else [t])

    failures = []
    for f in files:
        failures.extend(check(f))

    for msg in failures:
        print(f"FAIL  {msg}")
    print(f"\n{len(files) - len({m.split(':')[0] for m in failures})}/{len(files)} files parsed clean")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
