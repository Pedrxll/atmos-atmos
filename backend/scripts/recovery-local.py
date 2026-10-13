#!/usr/bin/env python3
"""Restore synthetic app/Auth/storage/ACL in another fixed LOCAL database.
The cluster-bound pg_cron extension is excluded; no business object is omitted.
"""
import json,os,pathlib,subprocess,time,urllib.parse
import psycopg
from psycopg import sql
ROOT=pathlib.Path(__file__).resolve().parents[2];LOCAL=ROOT/'backend/.local';C='supabase_db_atmos_finance_backend'
status=json.loads(subprocess.run(['supabase','status','--workdir',str(LOCAL/'runtime'),'-o','json'],text=True,capture_output=True,check=True).stdout)
assert status['API_URL']=='http://127.0.0.1:55321';dsn=status['DB_URL'];assert '@127.0.0.1:55322/' in dsn
restore_dsn=dsn.rsplit('/',1)[0]+'/atmos_finance_restore_qa'
password=urllib.parse.unquote(urllib.parse.urlsplit(dsn).password or '')
restore_env=dict(os.environ,PGPASSWORD=password)
dump=LOCAL/'synthetic-recovery.dump'
with dump.open('wb') as f:subprocess.run(['docker','exec',C,'pg_dump','-U','postgres','-d','postgres','-Fc'],stdout=f,check=True)
subprocess.run(['docker','exec',C,'dropdb','-U','postgres','--if-exists','--force','atmos_finance_restore_qa'],check=True,capture_output=True)
subprocess.run(['docker','exec',C,'createdb','-U','postgres','atmos_finance_restore_qa'],check=True,capture_output=True)
with dump.open('rb') as f:toc=subprocess.run(['docker','exec','-i',C,'pg_restore','--list'],stdin=f,capture_output=True,check=True).stdout.decode()
excluded_patterns=[' EXTENSION - pg_cron',' COMMENT - EXTENSION pg_cron',' TABLE DATA cron ',' SEQUENCE SET cron ',' ACL cron ',' ACL - SCHEMA cron ']
omitted=[line for line in toc.splitlines() if any(pattern in line for pattern in excluded_patterns)]
filtered='\n'.join(line for line in toc.splitlines() if line not in omitted)+'\n'
subprocess.run(['docker','exec','-i',C,'sh','-c','cat > /tmp/atmos-restore-toc.list'],input=filtered.encode(),check=True)
wrapper_acl=[line for line in filtered.splitlines() if ' ACL graphql_public FUNCTION graphql(' in line]
assert len(wrapper_acl)==1,'Expected the platform GraphQL bootstrap ACL'
predata='\n'.join(line for line in filtered.splitlines() if line not in wrapper_acl)+'\n'
subprocess.run(['docker','exec','-i',C,'sh','-c','cat > /tmp/atmos-restore-predata.list'],input=predata.encode(),check=True)
subprocess.run(['docker','exec','-i',C,'sh','-c','cat > /tmp/atmos-restore-wrapper.list'],input=('\n'.join(wrapper_acl)+'\n').encode(),check=True)
def section(name):
    with dump.open('rb') as f:
        toc_path='/tmp/atmos-restore-predata.list' if name=='pre-data' else '/tmp/atmos-restore-wrapper.list' if name=='wrapper-acl' else '/tmp/atmos-restore-toc.list'
        sections=[] if name=='wrapper-acl' else ['--section='+name]
        result=subprocess.run(['docker','exec','-i','-e','PGPASSWORD',C,'pg_restore','-U','supabase_admin','-d','atmos_finance_restore_qa','--exit-on-error','--use-list='+toc_path,*sections],stdin=f,capture_output=True,env=restore_env)
    if result.returncode:
        (LOCAL/'recovery-restore-error.log').write_bytes(result.stderr)
        raise RuntimeError('Isolated restore failed; inspect backend/.local/recovery-restore-error.log')
start=time.monotonic();section('pre-data')
# Supabase's GraphQL wrapper is an extension member created by platform bootstrap,
# so pg_dump contains its ACL but not its definition. Reproduce that bootstrap
# from this exact local source before restoring post-data grants.
with psycopg.connect(dsn,autocommit=True) as original, psycopg.connect(restore_dsn,user='supabase_admin',password=password,autocommit=True) as recovered:
    definition,owner=original.execute("SELECT pg_get_functiondef(p.oid),pg_get_userbyid(p.proowner) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='graphql_public' AND p.proname='graphql'").fetchone()
    recovered.execute(definition)
    recovered.execute(sql.SQL('ALTER FUNCTION graphql_public.graphql(text,text,jsonb,jsonb) OWNER TO {}').format(sql.Identifier(owner)))
section('wrapper-acl');section('data');section('post-data')
queries=[
 "SELECT count(*),sum(amount) FROM public.financial_transactions",
 "SELECT count(*),sum(amount) FROM public.finance_settlements",
 "SELECT count(*) FROM public.finance_audit_events",
 "SELECT count(*) FROM public.finance_export_parts",
 "SELECT count(*) FROM auth.users",
 "SELECT count(*) FROM storage.buckets",
 "SELECT has_function_privilege('anon','public.finance_command_v1(text,jsonb,text)','EXECUTE'),has_table_privilege('authenticated','public.financial_transactions','UPDATE'),has_schema_privilege('authenticated','finance_private','USAGE')",
 "SELECT count(*),md5(string_agg(tablename||policyname||coalesce(qual,'')||coalesce(with_check,''),'|' ORDER BY tablename,policyname)) FROM pg_policies WHERE schemaname='public' AND (tablename LIKE 'finance_%' OR tablename='financial_transactions')",
 "SELECT extname,extversion FROM pg_extension WHERE extname<>'pg_cron' ORDER BY extname",
]
with psycopg.connect(dsn,autocommit=True) as original, psycopg.connect(restore_dsn,autocommit=True) as recovered:
    for query in queries:assert original.execute(query).fetchall()==recovered.execute(query).fetchall(),query
    assert recovered.execute(queries[6]).fetchone()==(False,False,False)
    source_cron_jobs=original.execute('SELECT count(*) FROM cron.job').fetchone()[0]
output={'passed':True,'dump_bytes':dump.stat().st_size,'restore_seconds':round(time.monotonic()-start,3),'counts_sums_audit_parts_auth_storage_acl_rls_extensions_match':True,'runtime_extension_excluded':'pg_cron; cluster cron.database_name differs','source_cron_jobs':source_cron_jobs,'excluded_toc_entries':len(omitted),'bootstrap':'GraphQL extension wrapper copied from exact local source before ACL restore'}
(LOCAL/'recovery-result.json').write_text(json.dumps(output,indent=2)+'\n');print(json.dumps(output))
