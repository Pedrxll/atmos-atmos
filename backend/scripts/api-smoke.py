#!/usr/bin/env python3
"""Exercise the real HTTP/Auth/PostgREST stack with synthetic data only.
Local ports/project are fixed; no remote URL or user credential is accepted.
"""
import json, os, pathlib, secrets, subprocess, time, urllib.request, urllib.error, uuid
ROOT = pathlib.Path(__file__).resolve().parents[2]
LOCAL = ROOT / 'backend/.local'
API = 'http://127.0.0.1:55280/v1'
SUPABASE = 'http://127.0.0.1:55321'
CONTAINER = 'supabase_db_atmos_finance_backend'

def sql(text):
    result = subprocess.run(['docker','exec','-i',CONTAINER,'psql','-X','-q','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'], input=text, text=True, capture_output=True)
    if result.returncode: raise RuntimeError('Local fixture SQL failed: '+result.stderr[-500:])
    return result.stdout.strip()

def send(url, method='GET', body=None, token=None, apikey=None, raw=None, expected=200, key=None):
    headers = {}
    if token: headers['Authorization'] = 'Bearer '+token
    if apikey: headers['apikey'] = apikey
    if method != 'GET': headers['Idempotency-Key'] = key or 'smoke-'+str(uuid.uuid4())
    if raw is None and body is not None: raw = json.dumps(body).encode(); headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(url, data=raw, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=65) as response: status, data = response.status, response.read()
    except urllib.error.HTTPError as error: status, data = error.code, error.read()
    if status != expected:
        try: code = json.loads(data).get('error',{}).get('code','unclassified')
        except (ValueError,AttributeError): code = 'unclassified'
        raise AssertionError(f'{method} local endpoint expected {expected}, got {status} ({code})')
    if '/download' in url: return data
    return json.loads(data) if data else {}

status = subprocess.run(['supabase','status','--workdir',str(LOCAL/'runtime'),'-o','json'],text=True,capture_output=True,check=True)
keys = json.loads(status.stdout)
assert keys['API_URL'] == SUPABASE, 'Local project URL mismatch'
anon = keys['ANON_KEY']
admin = send(SUPABASE+'/auth/v1/signup','POST',{'email':f'synthetic-finance-{uuid.uuid4()}@example.invalid','password':secrets.token_urlsafe(32)}, apikey=anon)
viewer = send(SUPABASE+'/auth/v1/signup','POST',{'email':f'synthetic-viewer-{uuid.uuid4()}@example.invalid','password':secrets.token_urlsafe(32)}, apikey=anon)
uid, token, viewer_token = admin['user']['id'], admin['access_token'], viewer['access_token']
product = str(uuid.uuid4())
sql(f"INSERT INTO public.user_roles(user_id,role) VALUES('{uid}','admin'); INSERT INTO public.products(id,name,type,cost_price,unit_price) VALUES('{product}','Synthetic HTTP transfer','service',2000,2500); INSERT INTO public.pipeline_stages(name,segment,position) SELECT 'Synthetic HTTP start','b2c',0 WHERE NOT EXISTS(SELECT 1 FROM public.pipeline_stages WHERE segment='b2c'); NOTIFY pgrst,'reload schema';")
env = dict(os.environ, SUPABASE_URL=SUPABASE, SUPABASE_ANON_KEY=anon)
log = (LOCAL/'api-server.log').open('w')
server = subprocess.Popen(['deno','run','--config',str(ROOT/'supabase/functions/finance-api/deno.json'),'--allow-read','--allow-net=127.0.0.1:55280,127.0.0.1:55321','--allow-env=SUPABASE_URL,SUPABASE_ANON_KEY,READABLE_STREAM,NODE_DEBUG,GRACEFUL_FS_PLATFORM,TEST_GRACEFUL_FS_GLOBAL_PATCH,TEST_GRACEFUL_FS_DEBUG,BLUEBIRD_DEBUG,BLUEBIRD_WARNINGS,BLUEBIRD_LONG_STACK_TRACES,BLUEBIRD_W_FORGOTTEN_RETURN,NODE_ENV',str(ROOT/'backend/scripts/server-local.ts')],cwd=ROOT,env=env,stdout=log,stderr=log)
checks = []
def call(path, method='GET', body=None, expected=200, key=None, raw=None, actor=token):
    value = send(API+path,method,body,token=actor,expected=expected,key=key,raw=raw)
    if isinstance(value,dict) and 'error' in value and expected==200: raise AssertionError('Unexpected local domain error: '+value['error']['code'])
    return value.get('data',value) if isinstance(value,dict) else value
try:
    for attempt in range(50):
        if server.poll() is not None: raise RuntimeError('Local API server exited; inspect backend/.local/api-server.log')
        try: call('/transactions', expected=401, actor=None); break
        except (urllib.error.URLError,ConnectionError): time.sleep(.1)
    call('/transactions',expected=403,actor=viewer_token); checks.append('JWT and financial module enforced through actual Auth and PostgREST')
    account = call('/chart-of-accounts','POST',{'code':'HTTP.'+uid[:8],'name':'Synthetic HTTP income','type':'income'})['id']
    bank = call('/bank-accounts','POST',{'name':'Synthetic HTTP bank'})['id']
    link_payload = {'product_id':product,'supplier':{'name':'Synthetic HTTP supplier B'},'reference_cost':'2000.00','reference_sale':'2500.00'}
    supplier = call('/suppliers/with-product-link','POST',link_payload,key='http-supplier-'+uid)['supplier_id']
    assert call('/suppliers/with-product-link','POST',link_payload,key='http-supplier-'+uid)['supplier_id']==supplier
    assert len(call('/products/'+product+'/suppliers')['rows'])==1
    checks.append('Atomic supplier creation/link and retry')
    prospect = call('/prospects','POST',{'name':'Synthetic HTTP client','segment':'b2c'})
    assert prospect['stage_id']; checks.append('Manual prospect assigned to a configured segment stage')
    call('/settings','POST',{'manual_plan_confirmation':True,'settlement_partials':True,'unpaid_adjustments':True,'decision_reference':'SYNTHETIC HTTP FIXTURE ONLY'})
    proposal_payload = {'proposal':{'title':'Synthetic HTTP proposal','segment':'b2c','prospect_id':prospect['id'],'num_people':1,'num_days':1,'atmos_service':{'price_per_person_day':'0.00','internal_costs':[]}},'items':[{'day_number':1,'item_index':0,'category':'Transfer','item_name':'Synthetic HTTP transfer','catalog_item_id':product,'supplier_id':supplier,'quantity':1,'cost_price':'2000.00','value':'2500.00','commission_percent':0}],'costs':[],'days':[],'accommodations':[]}
    proposal = call('/proposals','POST',proposal_payload,key='http-proposal-'+uid)
    assert call('/proposals','POST',proposal_payload,key='http-proposal-'+uid)['id']==proposal['id']
    pid = proposal['id']; ctx = call('/proposals/'+pid+'/context'); assert ctx['proposal']['total']==2500
    # Catalogue updates are reference fixture changes, never repairs to business state.
    sql(f"UPDATE public.products SET unit_price=9999,cost_price=8888 WHERE id='{product}';")
    assert call('/proposals/'+pid+'/context')['items'][0]['value']==2500
    checks.append('Saved negotiated prices survive catalogue change')
    state = call('/proposals/'+pid+'/transitions','POST',{'expected_version':ctx['proposal']['version'],'operation':'publish'})
    state = call('/proposals/'+pid+'/transitions','POST',{'expected_version':state['version'],'operation':'approve_manual','reason':'Synthetic technical acceptance'})
    result = call('/operations/'+pid+'/result')
    conditions = [{'origin':o['key'],'account_id':account,'competence_date':'2026-11-01','installments':[{'number':1,'amount':o['amount'],'due_date':'2026-11-10'}]} for o in result['financial_origins']['origins']]
    preview = call('/proposals/'+pid+'/financial-preview','POST',{'expected_version':state['version'],'conditions':conditions})
    assert preview['ready']
    confirm_payload = {'expected_version':state['version'],'preview_id':preview['preview_id'],'plan_hash':preview['plan_hash']}
    confirmation = call('/proposals/'+pid+'/financial-confirmation','POST',confirm_payload,key='http-confirm-'+uid)
    assert len(confirmation['transaction_ids'])==2
    repeated = call('/proposals/'+pid+'/financial-confirmation','POST',confirm_payload)
    assert repeated['transaction_ids']==confirmation['transaction_ids']; checks.append('Explicit plan confirmation generates one principal and one supplier obligation; different-key repeat stable')
    titles = call('/transactions?proposal_id='+pid)['rows']; title = next(t for t in titles if t['type']=='receivable'); tid = title['id']
    paid = call('/transactions/'+tid+'/settlements','POST',{'expected_version':title['version'],'amount':'1000.00','effective_date':'2026-11-10','bank_account_id':bank,'payment_method':'synthetic'},key='http-partial-'+uid)
    assert paid['balance']=='1500.00'
    second = call('/transactions/'+tid+'/settlements','POST',{'expected_version':paid['version'],'amount':'1500.00','effective_date':'2026-12-01','bank_account_id':bank,'payment_method':'synthetic'})
    assert second['balance']=='0.00'
    corrected = call('/settlements/'+paid['settlement_id']+'/corrections','POST',{'expected_version':second['version'],'amount':'1000.00','reason':'Synthetic record correction'})
    assert corrected['balance']=='1000.00'
    call('/transactions/'+tid,'PATCH',{'expected_version':corrected['version'],'invoice_number':'000123'})
    checks.append('1000+1500 settlement, correction, derived balance and textual invoice')
    for typ, amount in [('receivable','50.00'),('payable','100.00')]:
        call('/transactions','POST',{'type':typ,'description':'Synthetic operation extra','amount':amount,'due_date':'2026-11-10','competence_date':'2026-11-01','proposal_id':pid,'account_id':account,'counterparty_label':'Synthetic counterparty'})
    due = call('/reports/dre?basis=due&from=2026-11-01&to=2026-11-30&proposal_id='+pid)
    cash = call('/reports/cash-flow?from=2026-11-01&to=2026-12-31&proposal_id='+pid)
    assert due['totals']['result']=='450.00' and cash['totals']['result']=='1500.00'
    for fmt in ['json','csv']:
        job = call('/exports','POST',{'format':fmt,'filters':{'basis':'due','from':'2026-11-01','to':'2026-11-30','proposal_id':pid}})
        for attempt in range(60):
            status = call('/exports/'+job['id'])
            if status['state']=='completed': break
            assert status['state']!='failed'; time.sleep(.1)
        assert status['state']=='completed'
        output = call('/exports/'+job['id']+'/download')
        assert b'000123' in output
        if fmt=='json':
            content=json.loads(output); assert len(content['rows'])==4 and content['metadata']['report']['totals']['result']=='450.00'
        else: assert b'finance-v1' in output
        call('/exports/'+job['id'],expected=403,actor=viewer_token)
    checks.append('Due450/cash1500, private CSV/JSON export and invoice roundtrip')
    csv = b'Data;Descricao;Valor;ID\n31/02/2026;Invalid;1;\n01/12/2026;Synthetic bank receipt;1500,00;TEST-HTTP\n01/12/2026;Legitimate repeated;1500,00;\n01/12/2026;Legitimate repeated;1500,00;'
    batch = call('/bank-imports/file-preview?filename=synthetic.csv&bank_account_id='+bank,'POST',raw=csv)
    assert len(batch['rows'])==3 and len(batch['rejected'])==1 and batch['rows'][0]['source_row']==3
    saved = call('/bank-imports/'+batch['batch_id']); assert len(saved['rejected'])==1
    imported = call('/bank-imports/'+batch['batch_id']+'/confirm','POST',{})
    for attempt in range(100):
        imported=call('/bank-imports/'+batch['batch_id']+'/status')
        if imported['state']=='confirmed': break
        assert imported['state']!='failed'; time.sleep(.1)
    assert imported['imported']==3
    lines = call('/bank-lines?bank_account_id='+bank)['rows']; line=next(l for l in lines if l['source_row']==3)
    candidates=call('/bank-lines/'+line['id']+'/candidates'); assert any(c['settlement_id']==second['settlement_id'] for c in candidates['candidates'])
    match=call('/bank-lines/'+line['id']+'/matches','POST',{'expected_version':line['version'],'allocations':[{'transaction_id':tid,'settlement_id':second['settlement_id'],'amount':'1500.00'}]})
    assert not match['settlement_created']; call('/matches/'+match['match_ids'][0]+'/undo','POST',{'reason':'Synthetic undo'})
    checks.append('CSV rejection persisted/source row preserved, exact reconciliation and undo without new settlement')
    matrix=[]
    all_modules=['site','cadastros','b2c','b2b','financeiro','ferramentas','configuracoes']
    for label in all_modules+['all7']:
        password=secrets.token_urlsafe(32);email=f'synthetic-module-{uuid.uuid4()}@example.invalid'
        user=send(SUPABASE+'/auth/v1/admin/users','POST',{'email':email,'password':password,'email_confirm':True},token=keys['SERVICE_ROLE_KEY'],apikey=anon)
        module_uid=user['id'];modules=all_modules if label=='all7' else [label]
        sql("INSERT INTO public.user_roles(user_id,role) VALUES('"+module_uid+"','admin'); INSERT INTO public.admin_permissions(user_id,allowed_modules) VALUES('"+module_uid+"',ARRAY["+','.join("'"+m+"'" for m in modules)+"]);")
        signed=send(SUPABASE+'/auth/v1/token?grant_type=password','POST',{'email':email,'password':password},apikey=anon);actor=signed['access_token']
        financial=label in ['financeiro','all7'];commercial=label in ['b2c','all7'];catalogue=label in ['cadastros','b2c','b2b','financeiro','all7']
        call('/transactions',expected=200 if financial else 403,actor=actor)
        call('/proposals/'+pid+'/context',expected=200 if financial or commercial else 403,actor=actor)
        call('/products/'+product+'/suppliers',expected=200 if catalogue else 403,actor=actor)
        call('/exports/'+job['id'],expected=404 if financial else 403,actor=actor)
        call('/exports/'+job['id']+'/download',expected=404 if financial else 403,actor=actor)
        call('/settings','POST',{'settlement_partials':True,'decision_reference':'SYNTHETIC DENIED CONFIG'},expected=403,actor=actor)
        matrix.append({'module':label,'checks':6,'passed':True})
    checks.append('HTTP module matrix all7singlemodules, record scope, private downloads and configuration privilege')
    large = ('Data;Descricao;Valor;ID\n'+'\n'.join('01/12/2026;Synthetic bulk '+str(n)+' '+('x'*420)+';1,00;BULK-'+str(n) for n in range(20000))).encode()
    assert len(large)<10*1024*1024
    start=time.monotonic(); bulk=call('/bank-imports/file-preview?filename=synthetic-large.csv&bank_account_id='+bank,'POST',raw=large)
    assert len(bulk['rows'])==20000 and not bulk['rejected']
    call('/bank-imports/'+bulk['batch_id']+'/confirm','POST',{})
    for attempt in range(60):
        progress=call('/bank-imports/'+bulk['batch_id']+'/status')
        if progress['state']=='confirmed':break
        assert progress['state']!='failed',progress;time.sleep(1)
    assert progress['state']=='confirmed' and progress['imported']==20000
    import_metrics={'input_bytes':len(large),'rows':20000,'preview_and_import_seconds':round(time.monotonic()-start,3),'job_state':progress['state']}
    checks.append('Large CSV preview and asynchronous atomic import20000rows, persisted progress and counts')
    output={'suite':'finance-api-real-http','passed':True,'checks':checks,'checks_count':len(checks),'large_import':import_metrics,'module_matrix':matrix,'fixture_scope':'isolated synthetic local database','completed_at_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
    (LOCAL/'api-smoke-result.json').write_text(json.dumps(output,indent=2)+'\n'); print(json.dumps(output))
finally:
    server.terminate()
    try: server.wait(timeout=10)
    except subprocess.TimeoutExpired: server.kill();server.wait()
    log.close()
