#!/usr/bin/env python3
"""Start only the fixed isolated Atmos stack, without exposing generated keys."""
from pathlib import Path
import shutil, subprocess, sys
root=Path(__file__).resolve().parents[2];runtime=root/'backend/.local/runtime';cfg=runtime/'supabase'
config=(root/'supabase/config.toml').read_text()
if 'project_id = "atmos_finance_backend"' not in config:sys.exit('Refusing unexpected local project ID.')
cfg.mkdir(parents=True,exist_ok=True);(cfg/'migrations').mkdir(exist_ok=True)
if any((cfg/'migrations').iterdir()):sys.exit('Runtime migration directory must stay empty; application SQL is applied separately.')
shutil.copyfile(root/'supabase/config.toml',cfg/'config.toml')
result=subprocess.run(['supabase','start','--workdir',str(runtime),'--exclude','realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor'],text=True,capture_output=True)
if result.returncode:sys.exit('Isolated runtime did not start; confirm Docker/CLI are available.')
print('Isolated stack ready: API127.0.0.1:55321, PostgreSQL127.0.0.1:55322. No remote connection used.')
sys.exit(subprocess.call([sys.executable,str(root/'backend/scripts/apply-local.py')],cwd=root))
