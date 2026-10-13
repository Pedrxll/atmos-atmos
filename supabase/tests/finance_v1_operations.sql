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
DO $$ DECLARE f record;r jsonb;ctx jsonb;pid uuid;iid uuid;aid uuid;v bigint;bundle jsonb;room jsonb;job uuid;parts jsonb;other uuid;BEGIN
 SELECT * INTO f FROM finance_fixture;
 r:=public.finance_command_v1('settings.configure','{"manual_plan_confirmation":true,"settlement_partials":true,"unpaid_adjustments":true,"decision_reference":"SYNTHETIC ONLY"}','ops-policy-01');
 PERFORM pg_temp.check_true(r->'error' IS NULL,'test policy');
 room:='[{"unit_label":"Negotiated without catalogue units","rooms":[{"type":"double","capacity":2,"units":1,"price":"300.00","cost":"200.00","commission_percent":10,"pricing_type":"per_room","available":true}]}]';
 bundle:=jsonb_build_object('proposal',jsonb_build_object('title','Synthetic API composition','segment','b2c','prospect_id',f.prospect_id,'num_people',2,'num_days',2,'atmos_service',jsonb_build_object('price_per_person_day',0,'internal_costs','[]'::jsonb)),
 'items',jsonb_build_array(jsonb_build_object('day_number',1,'item_index',0,'category','Transfer','item_name','Transfer B','catalog_item_id',f.product_id,'value','2500.00','cost_price','2000.00','commission_percent',0,'quantity',1,'supplier_id',f.supplier_id)),
 'costs','[]'::jsonb,'days','[]'::jsonb,'accommodations',jsonb_build_array(jsonb_build_object('product_id',f.product_id,'supplier_id',f.supplier_id,'num_nights',2,'checkin_date','2026-11-01','checkout_date','2026-11-03','is_selected',true,'payment_type','hospedagem','rooms',room)));
 r:=public.finance_command_v1('proposal.save',bundle,'ops-create-proposal');
 PERFORM pg_temp.check_true(r->'error' IS NULL,'save complete composition: '||r::text);pid:=(r#>>'{data,id}')::uuid;
 PERFORM pg_temp.check_true((SELECT total=2500 FROM public.proposals WHERE id=pid),'direct hotel excludes customer principal');
 ctx:=public.finance_query_v1('proposal.context',jsonb_build_object('proposal_id',pid));iid:=(ctx#>>'{data,items,0,id}')::uuid;aid:=(ctx#>>'{data,accommodations,0,id}')::uuid;
 PERFORM pg_temp.check_true(ctx::text NOT LIKE '%share_token%','private context does not expose share token');
 PERFORM pg_temp.check_true(ctx#>'{data,proposal,guide_id}' IS NOT NULL AND ctx#>'{data,days}' IS NOT NULL AND ctx#>'{data,proposal,payment_terms}' IS NOT NULL AND ctx#>>'{data,proposal,language}'='pt','context includes full editable composition without privileged fields');
 r:=public.finance_command_v1('proposal.review',jsonb_build_object('proposal_id',pid,'expected_version',(ctx#>>'{data,proposal,version}')::bigint,'entity_kind','item','entity_id',iid,'expected_snapshot',ctx#>'{data,items,0,review_identity}','unit_cost','1900.00','unit_sale','2400.00','reason','Synthetic negotiation'),'ops-review-item');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND (r#>>'{data,result,planned_revenue}')::numeric=2400,'review cost and sale atomically: '||r::text);
 ctx:=public.finance_query_v1('proposal.context',jsonb_build_object('proposal_id',pid));
 r:=public.finance_command_v1('proposal.review',jsonb_build_object('proposal_id',pid,'expected_version',(ctx#>>'{data,proposal,version}')::bigint,'entity_kind','accommodation','entity_id',aid,'expected_snapshot',ctx#>'{data,accommodations,0,review_identity}','rooms',room,'reason','Synthetic hotel review'),'ops-review-hotel');
 PERFORM pg_temp.check_true(r->'error' IS NULL AND (SELECT count(*)=1 FROM public.finance_accommodation_checks WHERE entity_id=aid AND released_at IS NULL),'hotel active check: '||r::text);
 ctx:=public.finance_query_v1('proposal.context',jsonb_build_object('proposal_id',pid));
 r:=public.finance_command_v1('proposal.save',bundle||jsonb_build_object('proposal_id',pid,'expected_version',(ctx#>>'{data,proposal,version}')::bigint,'items',jsonb_build_array((bundle#>'{items,0}')||jsonb_build_object('id',iid,'cost_price','1900.00','value','2400.00')),'accommodations',jsonb_build_array((bundle#>'{accommodations,0}')||jsonb_build_object('id',aid,'checkout_date','2026-11-04'))),'ops-change-reviewed-hotel-dates');PERFORM pg_temp.check_true(r#>>'{error,code}'='ADJUSTMENT_REQUIRED','reviewed hotel dates protected');
 bundle:=bundle||jsonb_build_object('proposal_id',pid,'expected_version',(ctx#>>'{data,proposal,version}')::bigint,'items',jsonb_build_array((bundle#>'{items,0}')||jsonb_build_object('id',iid,'cost_price','1900.00','value','2400.00')),'accommodations','[]'::jsonb);
 r:=public.finance_command_v1('proposal.save',bundle,'ops-remove-reviewed-hotel');PERFORM pg_temp.check_true(r#>>'{error,code}'='ADJUSTMENT_REQUIRED','reviewed hotel removal denied');
 r:=public.finance_command_v1('proposal.review.release',jsonb_build_object('proposal_id',pid,'expected_version',(ctx#>>'{data,proposal,version}')::bigint,'entity_kind','accommodation','entity_id',aid,'reason','Synthetic explicit release'),'ops-release-hotel');
 PERFORM pg_temp.check_true(r->'error' IS NULL,'hotel release');bundle:=bundle||jsonb_build_object('expected_version',(r#>>'{data,version}')::bigint);
 r:=public.finance_command_v1('proposal.save',bundle,'ops-remove-after-release');PERFORM pg_temp.check_true(r->'error' IS NULL,'remove after release: '||r::text);
 v:=(r#>>'{data,version}')::bigint;
 r:=public.finance_command_v1('proposal.save',bundle||jsonb_build_object('expected_version',v,'costs',jsonb_build_array(jsonb_build_object('description','Invalid','amount','-100'))),'ops-negative-cost');PERFORM pg_temp.check_true(r#>>'{error,code}'='INVALID_REQUEST','negative cost rejected');
 r:=public.finance_command_v1('proposal.save',bundle||jsonb_build_object('expected_version',v,'items',jsonb_build_array((bundle#>'{items,0}')||jsonb_build_object('cost_price','NaN'))),'ops-nan-cost');PERFORM pg_temp.check_true(r#>>'{error,code}'='INVALID_REQUEST','nonfinite cost rejected');
 r:=public.finance_command_v1('chart.save',jsonb_build_object('code','SYN.2','name','Synthetic second account','type','expense','parent_id',f.account_id),'ops-chart-create');PERFORM pg_temp.check_true(r->'error' IS NULL,'chart create: '||r::text);other:=(r#>>'{data,id}')::uuid;
 r:=public.finance_command_v1('chart.save',jsonb_build_object('id',f.account_id,'expected_version',1,'parent_id',other),'ops-chart-cycle');PERFORM pg_temp.check_true(r#>>'{error,code}'='INVALID_REQUEST','hierarchy cycle rejected');
 r:=public.finance_command_v1('transaction.create',jsonb_build_object('type','receivable','description','=SYNTHETIC FORMULA','amount','50.00','due_date','2026-11-01','competence_date','2026-11-01','proposal_id',f.proposal_id,'prospect_id',f.prospect_id,'account_id',f.account_id,'invoice_number','000123'),'ops-extra-income');PERFORM pg_temp.check_true(r->'error' IS NULL,'extra income');
 r:=public.finance_command_v1('transaction.create',jsonb_build_object('type','payable','description','Synthetic extra cost','amount','100.00','due_date','2026-11-01','competence_date','2026-11-01','proposal_id',f.proposal_id,'supplier_id',f.supplier_id,'account_id',f.account_id),'ops-extra-cost');PERFORM pg_temp.check_true(r->'error' IS NULL,'extra cost');
 r:=public.finance_query_v1('proposal.result',jsonb_build_object('proposal_id',f.proposal_id));PERFORM pg_temp.check_true((r#>>'{data,forecast_profit_with_extras}')::numeric=450,'500+50-100 forecast without duplicate principal');
 r:=public.finance_command_v1('export.create',jsonb_build_object('format','json','filters',jsonb_build_object('from','2026-11-01','to','2026-11-30','basis','due','proposal_id',f.proposal_id)),'ops-export-create');PERFORM pg_temp.check_true(r->'error' IS NULL,'export create: '||r::text);job:=(r#>>'{data,id}')::uuid;
 r:=public.finance_export_run_v1(job);PERFORM pg_temp.check_true(r->'error' IS NULL AND (r#>>'{data,row_count}')::integer=2,'export run: '||r::text);
 parts:=public.finance_query_v1('export.part',jsonb_build_object('job_id',job,'part_number',0));PERFORM pg_temp.check_true(jsonb_array_length(parts#>'{data,rows}')=2 AND parts::text LIKE '%000123%','snapshot parts preserve invoice');
 SELECT sum((value->>'amount')::numeric*(CASE WHEN value->>'type'='receivable' THEN 1 ELSE -1 END)) INTO v FROM jsonb_array_elements(parts#>'{data,rows}');PERFORM pg_temp.check_true(v=(r#>>'{data,report,totals,result}')::numeric,'export detail equals report total');
 r:=public.finance_export_run_v1(job);PERFORM pg_temp.check_true((r->>'replayed')::boolean,'export replay');
END $$;
RESET ROLE;
ROLLBACK;
SELECT 'PASS finance_v1_operations';
