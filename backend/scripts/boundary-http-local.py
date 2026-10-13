#!/usr/bin/env python3
"""Exercise denied legacy/direct PostgREST writes on the fixed local stack."""
import json,pathlib,secrets,subprocess,urllib.request,urllib.error,uuid
ROOT=pathlib.Path(__file__).resolve().parents[2];LOCAL=ROOT/'backend/.local';BASE='http://127.0.0.1:55321'
keys=json.loads(subprocess.run(['supabase','status','--workdir',str(LOCAL/'runtime'),'-o','json'],text=True,capture_output=True,check=True).stdout)
assert keys['API_URL']==BASE
def request(path,payload,token=None):
    headers={'apikey':keys['ANON_KEY'],'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,data=json.dumps(payload).encode(),headers=headers,method='POST')
    try:
        with urllib.request.urlopen(req,timeout=15) as r:return r.status,json.loads(r.read())
    except urllib.error.HTTPError as e:return e.code,json.loads(e.read())
status,user=request('/auth/v1/signup',{'email':f'synthetic-boundary-{uuid.uuid4()}@example.invalid','password':secrets.token_urlsafe(32)})
assert status==200
uid=user['user']['id'];token=user['access_token']
subprocess.run(['docker','exec','-i','supabase_db_atmos_finance_backend','psql','-X','-q','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],input=f"INSERT INTO public.user_roles(user_id,role) VALUES('{uid}','admin');",text=True,capture_output=True,check=True)
cases=[('anon finance command','/rest/v1/rpc/finance_command_v1',{'p_action':'transaction.create','p_payload':{},'p_idempotency_key':'denied-anon-key'},None),
       ('authenticated legacy bundle','/rest/v1/rpc/save_proposal_bundle',{'p_id':None,'p_proposal':{},'p_items':[],'p_costs':[],'p_days':[],'p_accommodations':[],'p_commissions':[]},token),
       ('authenticated legacy receivable','/rest/v1/rpc/generate_proposal_receivable',{'p_proposal_id':str(uuid.uuid4())},token),
       ('authenticated direct financial insert','/rest/v1/financial_transactions',{'type':'receivable','description':'Synthetic denied write','amount':1,'due_date':'2026-11-10'},token),
       ('authenticated direct bank insert','/rest/v1/bank_reconciliation_lines',{},token)]
results=[]
for name,path,payload,actor in cases:
    status,body=request(path,payload,actor)
    assert status in (401,403) and body.get('code') == '42501',(name,status,body.get('code'))
    results.append({'case':name,'status':status,'code':body['code'],'passed':True})
probe=subprocess.run(['docker','exec','supabase_db_atmos_finance_backend','psql','-X','-q','-U','postgres','-d','postgres','-At','-c','SELECT 1'],capture_output=True,text=True,check=True)
assert probe.stdout.strip()=='1'
output={'passed':True,'cases':results,'database_healthy_after_denials':True,'scope':'actual local Auth/PostgREST; denied calls, no business mutation'}
(LOCAL/'boundary-http-result.json').write_text(json.dumps(output,indent=2)+'\n');print(json.dumps(output))
