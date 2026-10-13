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
CREATE TEMP TABLE safety(job uuid,cashjob uuid,hotel uuid DEFAULT gen_random_uuid(),legacy_hotel uuid DEFAULT gen_random_uuid(),legacy_paid uuid DEFAULT gen_random_uuid(),known uuid DEFAULT gen_random_uuid(),cancelled uuid DEFAULT gen_random_uuid(),second_supplier uuid DEFAULT gen_random_uuid());
INSERT INTO safety(job,cashjob) VALUES(NULL,NULL);
INSERT INTO public.user_roles(user_id,role) SELECT viewer_id,'admin' FROM finance_fixture;
INSERT INTO public.admin_permissions(user_id,allowed_modules) SELECT viewer_id,ARRAY['financeiro'] FROM finance_fixture;
INSERT INTO public.suppliers(id,name) SELECT second_supplier,'Synthetic second payee' FROM safety;
INSERT INTO public.financial_transactions(type,description,amount,due_date,competence_date,status,proposal_id,finance_managed,bank_account_id,account_id,invoice_number)
SELECT (ARRAY['receivable','payable','commission_in','commission_out'])[1+n%4],'Synthetic safety '||n,n::numeric/100,'2026-11-10','2026-11-01','pending',proposal_id,true,bank_id,account_id,'000123' FROM finance_fixture CROSS JOIN generate_series(1,600) n;
INSERT INTO public.finance_settlements(transaction_id,amount,bank_account_id,effective_date,payment_method,created_by)
SELECT t.id,t.amount,f.bank_id,'2026-11-10','synthetic',f.admin_id FROM public.financial_transactions t JOIN finance_fixture f ON t.proposal_id=f.proposal_id;
INSERT INTO public.finance_settlements(transaction_id,amount,kind,reverses_id,bank_account_id,effective_date,payment_method,reason,created_by)
SELECT s.transaction_id,0.01,'correction',s.id,s.bank_account_id,s.effective_date,'synthetic','Synthetic correction',f.admin_id FROM public.finance_settlements s JOIN public.financial_transactions t ON t.id=s.transaction_id JOIN finance_fixture f ON t.proposal_id=f.proposal_id WHERE t.amount<=1;
INSERT INTO public.proposal_accommodations(id,proposal_id,product_id,supplier_id,num_nights,is_selected,payment_type,rooms)
SELECT hotel,proposal_id,product_id,supplier_id,1,true,'hospedagem','[{"rooms":[{"units":1,"capacity":1,"price":1200,"cost":1000,"commission_percent":10,"available":true,"pricing_type":"per_room"}]}]' FROM safety CROSS JOIN finance_fixture;
INSERT INTO public.financial_transactions(id,type,description,amount,due_date,status,proposal_id,prospect_id,source_key)
SELECT legacy_hotel,'receivable','Synthetic historical hotel commission',100,'2026-11-10'::date,'pending',proposal_id,prospect_id,'accommodation:'||hotel FROM safety CROSS JOIN finance_fixture
UNION ALL SELECT known,'receivable','Synthetic known principal',2500,'2026-11-10'::date,'pending',proposal_id,prospect_id,'proposal_approval' FROM safety CROSS JOIN finance_fixture;
INSERT INTO public.financial_transactions(id,type,description,amount,due_date,status,supplier_id)
SELECT legacy_paid,'payable','Synthetic paid legacy',100,'2026-11-10','paid',supplier_id FROM safety CROSS JOIN finance_fixture;
INSERT INTO public.financial_transactions(id,type,description,amount,due_date,status,supplier_id) SELECT cancelled,'payable','Synthetic cancelled legacy',20,'2026-11-10','cancelled',supplier_id FROM safety CROSS JOIN finance_fixture;
GRANT SELECT,UPDATE ON finance_fixture,safety TO authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT admin_id::text FROM finance_fixture),true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE f record;z record;r jsonb;v uuid;basis text;total numeric;cnt bigint;BEGIN
 SELECT * INTO f FROM finance_fixture;SELECT * INTO z FROM safety;
 r:=public.finance_command_v1('settings.configure','{"manual_plan_confirmation":false,"unpaid_adjustments":false,"decision_reference":"SYNTHETIC DEFAULT GATE TEST"}','safety-disable-gates');
 PERFORM pg_temp.check_true(r->'error' IS NULL,'gate configuration');
 r:=public.finance_command_v1('transaction.adjust',jsonb_build_object('transaction_id',(SELECT id FROM public.financial_transactions WHERE proposal_id=f.proposal_id AND finance_managed LIMIT 1),'expected_version',1,'amount','1.00','reason','Synthetic'),'safety-disabled-adjust');PERFORM pg_temp.check_true(r#>>'{error,code}'='DECISION_REQUIRED','unpaid adjustment gate enforced');
 r:=public.finance_command_v1('legacy.adopt',jsonb_build_object('transaction_id',z.known,'expected_version',1,'independent_obligation',true,'due_date','2026-11-10','competence_date','2026-11-01','reason','Synthetic'),'safety-known-origin');PERFORM pg_temp.check_true(r#>>'{error,code}'='LEGACY_REVIEW_REQUIRED','known source cannot be erased');
 r:=public.finance_command_v1('legacy.adopt',jsonb_build_object('transaction_id',z.legacy_paid,'expected_version',1,'independent_obligation',true,'supplier_id',z.second_supplier,'due_date','2026-11-10','competence_date','2026-11-01','reason','Synthetic'),'safety-paid-payee');PERFORM pg_temp.check_true(r#>>'{error,code}'='ADJUSTMENT_REQUIRED','paid payee cannot be changed');
 r:=public.finance_command_v1('legacy.adopt',jsonb_build_object('transaction_id',z.legacy_paid,'expected_version',1,'independent_obligation',true,'due_date','2026-11-10','competence_date','2026-11-01','reason','Synthetic reviewed payment','historical_payment',jsonb_build_object('amount','100.00','effective_date','2026-11-10','bank_account_id',f.bank_id,'payment_method','synthetic')),'safety-adopt-paid');PERFORM pg_temp.check_true(r->'error' IS NULL AND (SELECT count(*)=1 FROM public.finance_settlements WHERE transaction_id=z.legacy_paid),'verified paid adoption creates one historical event: '||r::text);
 r:=public.finance_command_v1('legacy.adopt',jsonb_build_object('transaction_id',z.legacy_hotel,'expected_version',1,'origin','accommodation:'||z.hotel,'mapped_type','commission_in','decision_reference','SYNTHETIC CLASSIFICATION ONLY','supplier_id',f.supplier_id,'installment_number',1,'installment_total',1,'due_date','2026-11-10','competence_date','2026-11-01','reason','Synthetic known historical artifact'),'safety-adopt-hotel');PERFORM pg_temp.check_true(r->'error' IS NULL AND (SELECT type='commission_in' AND supplier_id=f.supplier_id AND prospect_id IS NULL AND source_snapshot#>>'{legacy_before,prospect_id}'=f.prospect_id::text AND source_snapshot->>'decision_reference'='SYNTHETIC CLASSIFICATION ONLY' FROM public.financial_transactions WHERE id=z.legacy_hotel),'historical hotel maps narrowly with original party preserved: '||r::text);
 r:=public.finance_command_v1('legacy.adopt',jsonb_build_object('transaction_id',z.cancelled,'expected_version',1,'independent_obligation',true,'due_date','2026-11-10','competence_date','2026-11-01','reason','Synthetic cancellation review'),'safety-cancelled-gate');PERFORM pg_temp.check_true(r#>>'{error,code}'='LEGACY_REVIEW_REQUIRED','cancelled adoption requires explicit preservation');
 r:=public.finance_command_v1('legacy.adopt',jsonb_build_object('transaction_id',z.cancelled,'expected_version',1,'independent_obligation',true,'preserve_cancelled',true,'decision_reference','SYNTHETIC CANCELLATION','due_date','2026-11-10','competence_date','2026-11-01','reason','Synthetic cancellation review'),'safety-cancelled-adopt');PERFORM pg_temp.check_true(r->'error' IS NULL AND (SELECT finance_managed AND status='cancelled' AND source_snapshot->>'decision_reference'='SYNTHETIC CANCELLATION' FROM public.financial_transactions WHERE id=z.cancelled),'cancelled history adopted without reopening: '||r::text);
 FOREACH basis IN ARRAY ARRAY['due','cash'] LOOP
  r:=public.finance_command_v1('export.create',jsonb_build_object('format','json','filters',jsonb_build_object('from','2026-11-01','to','2026-11-30','basis',basis,'proposal_id',f.proposal_id)),'safety-export-'||basis);PERFORM pg_temp.check_true(r->'error' IS NULL,'export create');v:=(r#>>'{data,id}')::uuid;
  IF basis='due' THEN UPDATE safety SET job=v;ELSE UPDATE safety SET cashjob=v;END IF;
  r:=public.finance_export_run_v1(v);PERFORM pg_temp.check_true(r->'error' IS NULL AND (r#>>'{data,part_count}')::integer=2,'multi-part export');
  SELECT sum((x->>'amount')::numeric*(CASE WHEN x->>'type' IN ('receivable','commission_in') THEN 1 ELSE -1 END)),count(*) INTO total,cnt FROM public.finance_export_parts p CROSS JOIN LATERAL jsonb_array_elements(p.rows) x WHERE p.job_id=v;
  PERFORM pg_temp.check_true(total=(r#>>'{data,report,totals,result}')::numeric AND cnt=(r#>>'{data,row_count}')::bigint,'all chunks equal report total');
  r:=public.finance_export_run_v1(v);PERFORM pg_temp.check_true((r->>'replayed')::boolean,'export replay');
 END LOOP;
END $$;
RESET ROLE;
UPDATE public.financial_transactions SET description='Synthetic changed source' WHERE proposal_id=(SELECT proposal_id FROM finance_fixture);
SELECT pg_temp.check_true(NOT EXISTS(SELECT 1 FROM public.finance_export_parts p CROSS JOIN LATERAL jsonb_array_elements(p.rows) x WHERE p.job_id=(SELECT job FROM safety) AND x->>'description'='Synthetic changed source'),'export snapshot immutable');
SELECT set_config('request.jwt.claim.sub',(SELECT viewer_id::text FROM finance_fixture),true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE z record;r jsonb;BEGIN
 SELECT * INTO z FROM safety;
 PERFORM pg_temp.check_true((SELECT count(*)=0 FROM public.finance_export_parts WHERE job_id IN(z.job,z.cashjob)),'another finance owner cannot see export');
 BEGIN PERFORM public.finance_export_run_v1(z.job);RAISE EXCEPTION 'Other owner allowed';EXCEPTION WHEN no_data_found THEN NULL;END;
 r:=public.finance_command_v1('settings.configure','{"settlement_partials":true,"decision_reference":"SYNTHETIC"}','safety-deny-settings');PERFORM pg_temp.check_true(r#>>'{error,code}'='MODULE_FORBIDDEN','finance permission does not imply configuration privilege');
 PERFORM pg_temp.check_true(NOT has_table_privilege('authenticated','public.financial_transactions','UPDATE') AND NOT has_function_privilege('authenticated','public.generate_proposal_receivable(uuid)','EXECUTE'),'legacy command boundary');
END $$;
RESET ROLE;
UPDATE public.finance_export_jobs SET expires_at=now()-interval '1 second' WHERE id=(SELECT job FROM safety);
SELECT set_config('request.jwt.claim.sub',(SELECT admin_id::text FROM finance_fixture),true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE z record;r jsonb;BEGIN
 SELECT * INTO z FROM safety;
 PERFORM pg_temp.check_true((SELECT count(*)=0 FROM public.finance_export_parts WHERE job_id=z.job),'expired raw parts denied');
 r:=public.finance_query_v1('export.job',jsonb_build_object('job_id',z.job));PERFORM pg_temp.check_true(r#>>'{data,state}'='expired','expired state');
 BEGIN PERFORM public.finance_query_v1('export.part',jsonb_build_object('job_id',z.job,'part_number',0));RAISE EXCEPTION 'Expired allowed';EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;END;
END $$;
RESET ROLE;
ROLLBACK;
SELECT 'PASS finance_v1_safety';
