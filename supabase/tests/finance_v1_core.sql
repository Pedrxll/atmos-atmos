-- Disposable LOCAL database only. All fixture changes roll back.
BEGIN;
CREATE FUNCTION pg_temp.check_true(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'ASSERT: %',message; END IF; END $$;
CREATE TEMP TABLE finance_fixture (admin_id uuid, viewer_id uuid, prospect_id uuid, supplier_id uuid, product_id uuid, proposal_id uuid, bank_id uuid, account_id uuid, preview jsonb, confirmed jsonb);
INSERT INTO finance_fixture SELECT gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),null,null;
INSERT INTO auth.users(id,email) SELECT admin_id,admin_id::text||'@example.invalid' FROM finance_fixture UNION ALL SELECT viewer_id,viewer_id::text||'@example.invalid' FROM finance_fixture;
INSERT INTO public.user_roles(user_id,role) SELECT admin_id,'admin' FROM finance_fixture;
INSERT INTO public.prospects(id,name,segment) SELECT prospect_id,'Synthetic finance client','b2c' FROM finance_fixture;
INSERT INTO public.suppliers(id,name) SELECT supplier_id,'Synthetic supplier B' FROM finance_fixture;
INSERT INTO public.products(id,name,type) SELECT product_id,'Synthetic transfer','service' FROM finance_fixture;
INSERT INTO public.bank_accounts(id,name) SELECT bank_id,'Synthetic bank' FROM finance_fixture;
INSERT INTO public.chart_of_accounts(id,code,name,type) SELECT account_id,'TEST.1','Synthetic account','income' FROM finance_fixture;
INSERT INTO public.proposals(id,prospect_id,title,status,total,subtotal,num_people,num_days,atmos_service)
SELECT proposal_id,prospect_id,'Synthetic transfer proposal','approved',2500,2500,1,1,'{"price_per_person_day":0,"internal_costs":[]}' FROM finance_fixture;
INSERT INTO public.proposal_day_items(proposal_id,day_number,item_index,category,item_name,value,quantity,cost_price,commission_percent,supplier_id)
SELECT proposal_id,1,0,'Transfer','Synthetic transfer',2500,1,2000,0,supplier_id FROM finance_fixture;
GRANT SELECT,UPDATE ON finance_fixture TO authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT admin_id::text FROM finance_fixture),true);
SELECT set_config('request.jwt.claims',(SELECT jsonb_build_object('sub',admin_id,'role','authenticated')::text FROM finance_fixture),true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE f record; v bigint; r jsonb; r2 jsonb; conditions jsonb; title uuid; sid uuid; ver bigint; batch uuid; line_id uuid; matches jsonb; second_settlement uuid; BEGIN
 SELECT * INTO f FROM finance_fixture;
 r:=public.finance_command_v1('settings.configure','{"manual_plan_confirmation":true,"settlement_partials":true,"unpaid_adjustments":true,"decision_reference":"SYNTHETIC FIXTURE ONLY"}','test-initial-policies');
 PERFORM pg_temp.check_true(r->'error' IS NULL,'explicit synthetic policies');
 SELECT finance_version INTO v FROM public.proposals WHERE id=f.proposal_id;
 conditions:=jsonb_build_array(jsonb_build_object('origin','customer_principal','competence_date','2026-11-01','account_id',f.account_id,
  'installments',jsonb_build_array(jsonb_build_object('number',1,'amount','2500.00','due_date','2026-11-10'))),
  jsonb_build_object('origin','service_cost:'||(SELECT id FROM public.proposal_day_items WHERE proposal_id=f.proposal_id),
  'competence_date','2026-11-01','installments',jsonb_build_array(jsonb_build_object('number',1,'amount','2000.00','due_date','2026-11-12'))));
 r:=public.finance_command_v1('plan.preview',jsonb_build_object('proposal_id',f.proposal_id,'expected_version',v,'conditions',conditions),'test-preview-01');
 PERFORM pg_temp.check_true(r->'error' IS NULL,'preview succeeds: '||r::text);
 PERFORM pg_temp.check_true((r#>>'{data,ready}')::boolean,'complete preview is ready');
 UPDATE finance_fixture SET preview=r->'data';
 r2:=public.finance_command_v1('plan.preview',jsonb_build_object('proposal_id',f.proposal_id,'expected_version',v,'conditions',conditions),'test-preview-01');
 PERFORM pg_temp.check_true((r2->>'replayed')::boolean AND r2->'data'=r->'data','preview idempotency');
 r:=public.finance_command_v1('plan.confirm',jsonb_build_object('preview_id',r#>>'{data,preview_id}','plan_hash',r#>>'{data,plan_hash}','expected_version',v),'test-confirm-01');
 PERFORM pg_temp.check_true(r->'error' IS NULL,'confirmation succeeds: '||r::text);
 PERFORM pg_temp.check_true(jsonb_array_length(r#>'{data,transaction_ids}')=2,'one receivable and one payable');
 UPDATE finance_fixture SET confirmed=r->'data';
 PERFORM pg_temp.check_true((SELECT count(*)=2 FROM public.financial_transactions WHERE proposal_id=f.proposal_id),'no duplicate title');
 SELECT id,finance_version INTO title,ver FROM public.financial_transactions WHERE proposal_id=f.proposal_id AND type='receivable';
 r:=public.finance_command_v1('settings.configure','{"settlement_partials":true,"decision_reference":"SYNTHETIC FIXTURE ONLY"}','test-settings-01');
 PERFORM pg_temp.check_true(r->'error' IS NULL,'test partial policy explicit');
 r:=public.finance_command_v1('settlement.create',jsonb_build_object('transaction_id',title,'expected_version',ver,'amount','1000.00','effective_date','2026-11-10','bank_account_id',f.bank_id,'payment_method','test'),'test-payment-01');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND (r#>>'{data,balance}')::numeric=1500,'partial settlement: '||r::text);
 sid:=(r#>>'{data,settlement_id}')::uuid;ver:=(r#>>'{data,version}')::bigint;
 r2:=public.finance_command_v1('settlement.create',jsonb_build_object('transaction_id',title,'expected_version',ver-1,'amount','1000.00','effective_date','2026-11-10','bank_account_id',f.bank_id,'payment_method','test'),'test-payment-01');
 PERFORM pg_temp.check_true((r2->>'replayed')::boolean,'payment replay does not settle twice');
 r:=public.finance_command_v1('settlement.create',jsonb_build_object('transaction_id',title,'expected_version',ver,'amount','1500.00','effective_date','2026-12-01','bank_account_id',f.bank_id,'payment_method','test'),'test-payment-02');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND (r#>>'{data,balance}')::numeric=0 AND r#>>'{data,status}'='paid','full settlement: '||r::text);
 ver:=(r#>>'{data,version}')::bigint;second_settlement:=(r#>>'{data,settlement_id}')::uuid;
 r:=public.finance_command_v1('settlement.correct',jsonb_build_object('settlement_id',sid,'expected_version',ver,'amount','1000.00','reason','Synthetic entry correction'),'test-correction-01');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND (r#>>'{data,balance}')::numeric=1000,'correction reopens balance: '||r::text);
 r:=public.finance_command_v1('transaction.patch',jsonb_build_object('transaction_id',title,'expected_version',(r#>>'{data,version}')::bigint,'invoice_number','000123'),'test-invoice-01');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND r#>>'{data,invoice_number}'='000123','invoice keeps leading zeroes');
 r:=public.finance_query_v1('report',jsonb_build_object('from','2026-11-01','to','2026-12-31','basis','cash','proposal_id',f.proposal_id));
 PERFORM pg_temp.check_true((r#>>'{data,totals,income}')::numeric=1500,'cash uses net settlements only');
 r:=public.finance_query_v1('report',jsonb_build_object('from','2026-11-01','to','2026-11-30','basis','due','proposal_id',f.proposal_id));
 PERFORM pg_temp.check_true((r#>>'{data,totals,result}')::numeric=500,'due report title result');
 r:=public.finance_query_v1('report.detail',jsonb_build_object('from','2026-11-01','to','2026-12-31','basis','cash','proposal_id',f.proposal_id,'limit',2));
 PERFORM pg_temp.check_true(jsonb_array_length(r#>'{data,rows}')=2 AND r#>>'{data,next_cursor}' IS NOT NULL,'report detail paginated');
 r:=public.finance_command_v1('bank.preview',jsonb_build_object('bank_account_id',f.bank_id,'file_sha256',repeat('a',64),'source_name','synthetic.csv',
  'rows',jsonb_build_array(
   jsonb_build_object('date','2026-12-01','amount','1500.00','direction','credit','description','Synthetic settlement','external_id','TEST-1'),
   jsonb_build_object('date','2026-12-01','amount','1500.00','direction','credit','description','Legitimate identical row'),
   jsonb_build_object('date','2026-12-01','amount','1500.00','direction','credit','description','Legitimate identical row'),
   jsonb_build_object('date','2026-02-31','amount','1500.00','direction','credit','description','Invalid date'))),'test-bank-preview');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND jsonb_array_length(r#>'{data,rows}')=3 AND jsonb_array_length(r#>'{data,rejected}')=1,'bank row validation: '||r::text);
 batch:=(r#>>'{data,batch_id}')::uuid;
 r:=public.finance_command_v1('bank.confirm',jsonb_build_object('batch_id',batch),'test-bank-confirm');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND (r#>>'{data,imported}')::integer=3,'bank import preserves identical legitimate rows: '||r::text);
 r:=public.finance_command_v1('bank.confirm',jsonb_build_object('batch_id',batch),'test-bank-confirm-again');
 PERFORM pg_temp.check_true((SELECT count(*)=3 FROM public.bank_reconciliation_lines WHERE batch_id=batch),'bank repeat creates no duplicate');
 SELECT id INTO line_id FROM public.bank_reconciliation_lines WHERE batch_id=batch AND external_id='TEST-1';
 r:=public.finance_command_v1('bank.match',jsonb_build_object('line_id',line_id,'expected_version',1,'allocations',
  jsonb_build_array(jsonb_build_object('transaction_id',title,'settlement_id',second_settlement,'amount','1500.00'))),'test-bank-match');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND NOT(r#>>'{data,settlement_created}')::boolean,'reconciliation never settles: '||r::text);
 matches:=r#>'{data,match_ids}';
 PERFORM pg_temp.check_true((SELECT count(*)=3 FROM public.finance_settlements WHERE transaction_id=title),'match does not create payment');
 r:=public.finance_command_v1('bank.undo',jsonb_build_object('match_id',matches->>0,'reason','Synthetic undo'),'test-bank-undo');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND (r#>>'{data,undone}')::boolean,'match undo preserves history');
 PERFORM pg_temp.check_true((SELECT undone_at IS NOT NULL FROM public.finance_bank_matches WHERE id=(matches->>0)::uuid),'match history retained');
 BEGIN UPDATE public.financial_transactions SET amount=1 WHERE id=title; RAISE EXCEPTION 'Direct managed title update allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN DELETE FROM public.financial_transactions WHERE id=title; RAISE EXCEPTION 'Direct managed title deletion allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 r:=public.finance_command_v1('transaction.create',jsonb_build_object('type','receivable','description','Invalid date','amount','50.00','due_date','2026-02-31','counterparty_label','test'),'test-invalid-date');
 PERFORM pg_temp.check_true(r#>>'{error,code}'='INVALID_REQUEST','calendar validation');
 r:=public.finance_command_v1('transaction.create','{"type":"receivable","amount":"NaN","description":"test","due_date":"2026-11-10","counterparty_label":"test"}','test-invalid-money');
 PERFORM pg_temp.check_true(r#>>'{error,code}'='INVALID_REQUEST','finite canonical money validation');
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',(SELECT viewer_id::text FROM finance_fixture),true);
SELECT set_config('request.jwt.claims',(SELECT jsonb_build_object('sub',viewer_id,'role','authenticated')::text FROM finance_fixture),true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 PERFORM pg_temp.check_true((SELECT count(*)=0 FROM public.finance_settlements),'non admin cannot read settlements');
 BEGIN PERFORM public.finance_command_v1('transaction.create','{}','test-denied-01'); RAISE EXCEPTION 'Non admin command allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
 PERFORM pg_temp.check_true(NOT has_function_privilege('anon','public.finance_command_v1(text,jsonb,text)','EXECUTE'),'anonymous RPC ACL');
END $$;
RESET ROLE;
ROLLBACK;
SELECT 'PASS finance_v1_core';
