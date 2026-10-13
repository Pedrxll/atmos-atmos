#!/usr/bin/env python3
"""Local concurrency, load and isolated restore rehearsal. Synthetic data only."""
import concurrent.futures, json, math, pathlib, statistics, subprocess, threading, time, uuid
import psycopg
ROOT=pathlib.Path(__file__).resolve().parents[2]; LOCAL=ROOT/'backend/.local'; C='supabase_db_atmos_finance_backend'
status=json.loads(subprocess.run(['supabase','status','--workdir',str(LOCAL/'runtime'),'-o','json'],text=True,capture_output=True,check=True).stdout)
assert status['API_URL']=='http://127.0.0.1:55321'
dsn=status['DB_URL']; assert '@127.0.0.1:55322/' in dsn
ids={k:str(uuid.uuid4()) for k in ['a','b','c','p','customer','supplier','bank','account']}
def connect(actor=None):
    c=psycopg.connect(dsn,autocommit=True)
    if actor:
        c.execute("SELECT set_config('request.jwt.claim.sub',%s,false)",(actor,));c.execute('SET ROLE authenticated')
    return c
with connect() as c:
    for actor in [ids['a'],ids['b'],ids['c']]:
        c.execute("INSERT INTO auth.users(id,email) VALUES(%s,%s)",(actor,actor+'@example.invalid'));c.execute("INSERT INTO public.user_roles(user_id,role) VALUES(%s,'admin')",(actor,))
    c.execute("INSERT INTO public.prospects(id,name,segment) VALUES(%s,'Synthetic concurrency customer','b2c')",(ids['customer'],))
    c.execute("INSERT INTO public.suppliers(id,name) VALUES(%s,'Synthetic concurrency supplier')",(ids['supplier'],))
    c.execute("INSERT INTO public.bank_accounts(id,name) VALUES(%s,'Synthetic performance bank')",(ids['bank'],))
    c.execute("INSERT INTO public.chart_of_accounts(id,code,name,type) VALUES(%s,%s,'Synthetic performance account','income')",(ids['account'],'PERF.'+ids['a'][:8]))
    c.execute("INSERT INTO public.proposals(id,prospect_id,title,status,total,subtotal,num_people,num_days,atmos_service) VALUES(%s,%s,'Synthetic concurrency proposal','approved',2500,2500,1,1,'{\"price_per_person_day\":0,\"internal_costs\":[]}')",(ids['p'],ids['customer']))
    item=c.execute("INSERT INTO public.proposal_day_items(proposal_id,category,item_name,value,cost_price,supplier_id) VALUES(%s,'Transfer','Synthetic concurrency transfer',2500,2000,%s) RETURNING id",(ids['p'],ids['supplier'])).fetchone()[0]
def command(actor,action,payload,key):
    with connect(actor) as c:return c.execute('SELECT public.finance_command_v1(%s,%s::jsonb,%s)',(action,json.dumps(payload),key)).fetchone()[0]
assert 'data' in command(ids['a'],'settings.configure',{'manual_plan_confirmation':True,'settlement_partials':True,'decision_reference':'SYNTHETIC CONCURRENCY ONLY'},'concurrency-policy')
with connect() as c:version=c.execute('SELECT finance_version FROM public.proposals WHERE id=%s',(ids['p'],)).fetchone()[0]
conditions=[{'origin':origin,'installments':[{'number':1,'amount':amount,'due_date':'2026-11-10'}]} for origin,amount in [('customer_principal','2500.00'),('service_cost:'+str(item),'2000.00')]]
preview=command(ids['a'],'plan.preview',{'proposal_id':ids['p'],'expected_version':version,'conditions':conditions},'concurrency-preview')['data']
barrier=threading.Barrier(20)
def parallel(actor,action,payload,key):
    def run(n):
        barrier.wait(timeout=20);return command(actor(n) if callable(actor) else actor,action,payload,key if isinstance(key,str) else key(n))
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:return list(pool.map(run,range(20)))
start=time.monotonic()
results=parallel(ids['a'],'plan.confirm',{'preview_id':preview['preview_id'],'plan_hash':preview['plan_hash'],'expected_version':version},lambda n:'concurrency-confirm-'+str(n))
assert all('data' in r for r in results),results
assert all(r['data']['transaction_ids']==results[0]['data']['transaction_ids'] for r in results)
with connect() as c:
    assert c.execute('SELECT count(*) FROM public.financial_transactions WHERE proposal_id=%s',(ids['p'],)).fetchone()[0]==2
    title,ver=c.execute("SELECT id,finance_version FROM public.financial_transactions WHERE proposal_id=%s AND type='receivable'",(ids['p'],)).fetchone()
first={'transaction_id':str(title),'expected_version':ver,'amount':'1000.00','effective_date':'2026-11-10','bank_account_id':ids['bank'],'payment_method':'synthetic'}
results=parallel(ids['b'],'settlement.create',first,'concurrency-same-payment-key')
assert all('data' in r for r in results),results
assert len({r['data']['settlement_id'] for r in results})==1
second={**first,'expected_version':results[0]['data']['version'],'amount':'1500.00'}
results=parallel(ids['c'],'settlement.create',second,lambda n:'concurrency-distinct-payment-'+str(n))
assert sum('data' in r for r in results)==1,results
assert all('data' in r or r.get('error',{}).get('code')=='VERSION_CONFLICT' for r in results)
with connect() as c:
    assert c.execute('SELECT sum(amount),count(*) FROM public.finance_settlements WHERE transaction_id=%s',(title,)).fetchone()==(2500,2)
    assert c.execute('SELECT status FROM public.financial_transactions WHERE id=%s',(title,)).fetchone()[0]=='paid'
concurrency={'sessions_per_case':20,'cases':['distinct-key plan confirmation unique obligations','same-key payment one event','distinct-key competing payment version conflict, no overpayment'],'passed':True,'duration_seconds':round(time.monotonic()-start,3)}
# Worst-case bounded plan:200 origins /500 parcels /20 independent users.
large_id=str(uuid.uuid4());actors=[str(uuid.uuid4()) for _ in range(20)]
with connect() as c:
    for actor in actors:
        c.execute("INSERT INTO auth.users(id,email) VALUES(%s,%s)",(actor,actor+'@example.invalid'));c.execute("INSERT INTO public.user_roles(user_id,role) VALUES(%s,'admin')",(actor,))
    c.execute("INSERT INTO public.proposals(id,prospect_id,title,status,total,subtotal,num_people,num_days,atmos_service) VALUES(%s,%s,'Synthetic maximum plan','approved',199,199,1,1,'{\"price_per_person_day\":0,\"internal_costs\":[]}')",(large_id,ids['customer']))
    c.execute("INSERT INTO public.proposal_day_items(proposal_id,day_number,item_index,category,item_name,value,cost_price,supplier_id) SELECT %s,1,n,'Transfer','Synthetic max item',1,1,%s FROM generate_series(1,199) n",(large_id,ids['supplier']))
    large_version=c.execute('SELECT finance_version FROM public.proposals WHERE id=%s',(large_id,)).fetchone()[0]
    item_ids=[str(r[0]) for r in c.execute('SELECT id FROM public.proposal_day_items WHERE proposal_id=%s ORDER BY id',(large_id,))]
large_conditions=[]
for n,(origin,cents) in enumerate([('customer_principal',19900)]+[('service_cost:'+item,100) for item in item_ids]):
    count=3 if n<100 else 2; installments=[]
    for part in range(count):
        value=cents//count+(cents%count if part==count-1 else 0)
        installments.append({'number':part+1,'amount':f'{value//100}.{value%100:02d}','due_date':'2026-11-10'})
    large_conditions.append({'origin':origin,'installments':installments})
large_preview=command(actors[0],'plan.preview',{'proposal_id':large_id,'expected_version':large_version,'conditions':large_conditions},'max-plan-preview')['data']
latencies=[];latency_lock=threading.Lock()
def max_run(n):
    barrier.wait(timeout=20);start=time.monotonic()
    r=command(actors[n],'plan.confirm',{'preview_id':large_preview['preview_id'],'plan_hash':large_preview['plan_hash'],'expected_version':large_version},'max-plan-confirm-'+str(n))
    with latency_lock:latencies.append((time.monotonic()-start)*1000)
    return r
with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:max_results=list(pool.map(max_run,range(20)))
assert all('data' in r and len(r['data']['transaction_ids'])==500 for r in max_results),max_results
assert all(r['data']['transaction_ids']==max_results[0]['data']['transaction_ids'] for r in max_results)
concurrency['maximum_plan']={'users':20,'origins':200,'titles':500,'p50_ms':round(statistics.median(latencies),2),'p95_ms':round(sorted(latencies)[18],2),'unique_obligation_set':True}

# Exactly100k additional titles and200k events; no production fixtures/credentials.
with connect() as c:
    c.execute("INSERT INTO public.financial_transactions(type,description,amount,due_date,competence_date,status,finance_managed,bank_account_id,account_id,invoice_number,origin_type,origin_id) SELECT CASE WHEN n%%2=0 THEN 'receivable' ELSE 'payable' END,'Synthetic performance',100,'2026-11-10','2026-11-01','paid',true,%s,%s,'000123','load_fixture',%s FROM generate_series(1,100000) n",(ids['bank'],ids['account'],ids['a']))
    c.execute("INSERT INTO public.finance_settlements(transaction_id,amount,bank_account_id,effective_date,payment_method,created_by) SELECT t.id,50,%s,'2026-11-10','synthetic',%s FROM public.financial_transactions t CROSS JOIN generate_series(1,2) WHERE t.origin_id=%s",(ids['bank'],ids['a'],ids['a']))
metrics={}
with connect(ids['a']) as c:
    for name,action,payload in [('titles200','transactions',{'limit':200}),('report_due','report',{'basis':'due','from':'2026-11-01','to':'2026-11-30'}),('report_cash','report',{'basis':'cash','from':'2026-11-01','to':'2026-11-30'})]:
        samples=[]
        for n in range(11):
            start=time.monotonic();r=c.execute('SELECT public.finance_query_v1(%s,%s::jsonb)',(action,json.dumps(payload))).fetchone()[0];elapsed=(time.monotonic()-start)*1000
            assert 'data' in r
            if n:samples.append(elapsed)
        metrics[name]={'samples':len(samples),'p50_ms':round(statistics.median(samples),2),'p95_ms':round(sorted(samples)[math.ceil(.95*len(samples))-1],2)}
    r=c.execute('SELECT public.finance_command_v1(%s,%s::jsonb,%s)',('export.create',json.dumps({'format':'json','filters':{'basis':'cash','from':'2026-11-01','to':'2026-11-30'}}),'load-export-'+ids['a'])).fetchone()[0]
    assert 'data' in r;r=c.execute('SELECT public.finance_export_run_v1(%s)',(r['data']['id'],)).fetchone()[0];assert 'data' in r and r['data']['row_count']>=200000,r
    metrics['large_export']={'rows':r['data']['row_count'],'parts':r['data']['part_count'],'passed':True}
# Preserve measurements even if the independent restore rehearsal fails.
(LOCAL/'load-metrics.json').write_text(json.dumps({'concurrency':concurrency,'metrics':metrics},indent=2)+'\n')
# Restore application data/ACL in an independent rehearsal.
recovery=subprocess.run([__import__('sys').executable,str(ROOT/'backend/scripts/recovery-local.py')],text=True,capture_output=True,check=True)
output={'suite':'finance-local-concurrency-load-recovery','passed':True,'concurrency':concurrency,'envelope':{'synthetic_titles':100000,'synthetic_settlement_events':200000},'metrics':metrics,'recovery':json.loads(recovery.stdout),'scope':'isolated local synthetic PostgreSQL; database RPC latency, not production HTTP SLA'}
(LOCAL/'load-concurrency-result.json').write_text(json.dumps(output,indent=2)+'\n');print(json.dumps(output))
