#!/usr/bin/env python3
"""Run transactional finance and preserved-contract regressions, LOCAL only."""
import hashlib
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
LOCAL = ROOT / 'backend/.local'
CONTAINER = 'supabase_db_atmos_finance_backend'
label = subprocess.run(['docker','inspect',CONTAINER,'--format','{{index .Config.Labels "com.supabase.cli.project"}}'],text=True,capture_output=True,check=True)
assert label.stdout.strip() == 'atmos_finance_backend'
names = ['finance_v1_core','finance_v1_operations','finance_v1_safety',
         'approve_proposal_atomic','clicksign_webhook_atomic','request_pipeline_segments',
         'public_proposal_privacy','public_catalog_projection',
         'guide_portal','prospects_city','admin_team_authorization','request_sync_email']
results = []
for name in names:
    path = ROOT / 'supabase/tests' / (name + '.sql')
    start = time.monotonic()
    r = subprocess.run(['docker','exec','-i',CONTAINER,'psql','-X','-q','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-f','-'],input=path.read_text(),text=True,capture_output=True)
    (LOCAL / ('sql-' + name + '.log')).write_text(r.stdout + r.stderr)
    results.append({'test':name,'passed':r.returncode == 0,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'seconds':round(time.monotonic()-start,3)})
    print(('PASS ' if r.returncode == 0 else 'FAIL ') + name,flush=True)
    if r.returncode:
        print(r.stderr[-3000:])
        break
output = {'suite':'finance-and-preserved-contracts-sql','passed':len(results)==len(names) and all(r['passed'] for r in results),'tests':results,'scope':'isolated synthetic database; transaction rollback per suite','legacy_rpc_compatibility':'old bundle/cost-check/receivable RPCs deliberately revoked; exercised by v1 suites, not claimed backward compatible'}
(LOCAL / 'sql-regressions-result.json').write_text(json.dumps(output,indent=2)+'\n')
raise SystemExit(0 if output['passed'] else 1)
