#!/usr/bin/env python3
"""Apply versioned SQL using psql, exclusively to this task's local container.

Uses psql simple-query mode because Supabase CLI 2.90's migration parser fails
on an existing multi-statement migration. No remote URL/credentials are accepted.
"""
import hashlib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTAINER = "supabase_db_atmos_finance_backend"


def sql(statement: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-X", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-At"],
        input=statement, text=True, capture_output=True,
    )


result = sql("CREATE TABLE IF NOT EXISTS public.atmos_local_migration_checksums(version text PRIMARY KEY, checksum text NOT NULL);")
if result.returncode:
    sys.exit("Local database is not available. Start the isolated runtime first.")
for migration in sorted((ROOT / "supabase/migrations").glob("*.sql")):
    content = migration.read_text()
    checksum = hashlib.sha256(content.encode()).hexdigest()
    previous = sql(f"SELECT checksum FROM public.atmos_local_migration_checksums WHERE version='{migration.name}';").stdout.strip()
    if previous:
        if previous != checksum:
            sys.exit(f"Applied migration changed: {migration.name}; create an incremental migration instead.")
        continue
    result = sql(content)
    if result.returncode:
        print(f"FAIL {migration.name}")
        # SQL errors contain schema/function context, never connection credentials.
        print(result.stderr[-4500:])
        sys.exit(1)
    result = sql(f"INSERT INTO public.atmos_local_migration_checksums VALUES('{migration.name}','{checksum}');")
    if result.returncode:
        sys.exit(f"Failed to record migration {migration.name}")
    print(f"PASS {migration.name}")
print("Local migration sequence applied.")
