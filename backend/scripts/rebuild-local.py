#!/usr/bin/env python3
"""Rebuild only the isolated Atmos test schema. Never accepts a remote target."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
container = "supabase_db_atmos_finance_backend"
check = subprocess.run(["docker", "inspect", container, "--format", '{{index .Config.Labels "com.supabase.cli.project"}}'], text=True, capture_output=True)
if check.returncode or check.stdout.strip() != "atmos_finance_backend":
    sys.exit("Refusing rebuild: local Supabase project label does not match.")
runtime = root / "backend/.local/runtime"
for command in [
    ["supabase", "stop", "--workdir", str(runtime), "--no-backup"],
    ["supabase", "start", "--workdir", str(runtime), "--exclude", "realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor"],
]:
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        sys.exit("Isolated runtime recreation failed; inspect local CLI state.")
print("Rebuilt isolated local schema; applying the full migration sequence.", flush=True)
sys.exit(subprocess.call([sys.executable, str(root / "backend/scripts/apply-local.py")], cwd=root))
