BEGIN;
ALTER TABLE public.chart_of_accounts ADD COLUMN finance_version bigint NOT NULL DEFAULT 1;
ALTER TABLE public.bank_accounts ADD COLUMN finance_version bigint NOT NULL DEFAULT 1;
CREATE FUNCTION finance_private.directory_version() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN NEW.finance_version:=OLD.finance_version+1;RETURN NEW;END $$;
CREATE TRIGGER finance_directory_version BEFORE UPDATE ON public.chart_of_accounts FOR EACH ROW EXECUTE FUNCTION finance_private.directory_version();
CREATE TRIGGER finance_directory_version BEFORE UPDATE ON public.bank_accounts FOR EACH ROW EXECUTE FUNCTION finance_private.directory_version();

CREATE FUNCTION finance_private.directory_save(p jsonb,kind text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_id uuid:=(p->>'id')::uuid;v_version bigint;v_row jsonb;
BEGIN
 IF kind='chart' THEN
  PERFORM finance_private.fields(p,ARRAY['id','expected_version','code','name','type','parent_id','is_active']);
  -- Hierarchy edits share a lock to prevent A->B / B->A concurrent cycles.
  PERFORM pg_advisory_xact_lock(20261013,760);
  IF v_id IS NOT NULL THEN
   SELECT to_jsonb(a),finance_version INTO v_row,v_version FROM public.chart_of_accounts a WHERE id=v_id FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
   IF (p->>'expected_version')::bigint IS DISTINCT FROM v_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001';END IF;
  ELSE v_row:=jsonb_build_object('type','expense','is_active',true);END IF;
  v_row:=v_row||p;
  IF length(btrim(coalesce(v_row->>'name',''))) NOT BETWEEN 1 AND 200 OR length(coalesce(v_row->>'code','')) NOT BETWEEN 1 AND 40 OR v_row->>'type' NOT IN ('income','expense') OR jsonb_typeof(v_row->'is_active') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'INVALID_REQUEST: chart account' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT 1 FROM public.chart_of_accounts WHERE code=v_row->>'code' AND id IS DISTINCT FROM v_id) THEN RAISE EXCEPTION 'INVALID_REQUEST: duplicate code' USING ERRCODE='22023';END IF;
  IF v_id IS NULL THEN
   INSERT INTO public.chart_of_accounts(code,name,type,parent_id,is_active) VALUES(v_row->>'code',v_row->>'name',v_row->>'type',(v_row->>'parent_id')::uuid,(v_row->>'is_active')::boolean) RETURNING id INTO v_id;
  ELSE
   IF v_row->>'type' IS DISTINCT FROM (SELECT type FROM public.chart_of_accounts WHERE id=v_id) AND EXISTS(SELECT 1 FROM public.financial_transactions WHERE account_id=v_id) THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: referenced account nature' USING ERRCODE='55000';END IF;
   UPDATE public.chart_of_accounts SET code=v_row->>'code',name=v_row->>'name',type=v_row->>'type',parent_id=(v_row->>'parent_id')::uuid,is_active=(v_row->>'is_active')::boolean WHERE id=v_id;
  END IF;
  RETURN (SELECT to_jsonb(a)||jsonb_build_object('version',finance_version) FROM public.chart_of_accounts a WHERE id=v_id);
 ELSIF kind='bank' THEN
  PERFORM finance_private.fields(p,ARRAY['id','expected_version','name','bank','agency','account_number','account_type','is_active']);
  IF v_id IS NOT NULL THEN
   SELECT to_jsonb(a),finance_version INTO v_row,v_version FROM public.bank_accounts a WHERE id=v_id FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
   IF (p->>'expected_version')::bigint IS DISTINCT FROM v_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001';END IF;
  ELSE v_row:=jsonb_build_object('bank','','agency','','account_number','','account_type','checking','is_active',true);END IF;
  v_row:=v_row||p;
  IF length(btrim(coalesce(v_row->>'name',''))) NOT BETWEEN 1 AND 200 OR length(v_row->>'bank')>100 OR length(v_row->>'agency')>40 OR length(v_row->>'account_number')>80 OR v_row->>'account_type' NOT IN ('checking','savings','cash','investment') OR jsonb_typeof(v_row->'is_active') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'INVALID_REQUEST: bank account' USING ERRCODE='22023';END IF;
  IF v_id IS NULL THEN
   INSERT INTO public.bank_accounts(name,bank,agency,account_number,account_type,is_active) VALUES(v_row->>'name',v_row->>'bank',v_row->>'agency',v_row->>'account_number',v_row->>'account_type',(v_row->>'is_active')::boolean) RETURNING id INTO v_id;
  ELSE UPDATE public.bank_accounts SET name=v_row->>'name',bank=v_row->>'bank',agency=v_row->>'agency',account_number=v_row->>'account_number',account_type=v_row->>'account_type',is_active=(v_row->>'is_active')::boolean WHERE id=v_id;END IF;
  RETURN (SELECT jsonb_build_object('id',id,'name',name,'bank',bank,'account_type',account_type,'is_active',is_active,'version',finance_version) FROM public.bank_accounts WHERE id=v_id);
 END IF;
 RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023';
END $$;

CREATE FUNCTION finance_private.legacy_adopt(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE t public.financial_transactions;o jsonb;v_origin text:=p->>'origin';v_payment jsonb;v_before jsonb;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['transaction_id','expected_version','origin','installment_number','installment_total','supplier_id','prospect_id','seller_id','counterparty_label','account_id','bank_account_id','competence_date','due_date','reason','historical_payment','mapped_type','decision_reference','independent_obligation','scope','preserve_cancelled']);
 PERFORM 1 FROM public.proposals WHERE id=(SELECT proposal_id FROM public.financial_transactions WHERE id=(p->>'transaction_id')::uuid) FOR UPDATE;
 SELECT * INTO t FROM public.financial_transactions WHERE id=(p->>'transaction_id')::uuid FOR UPDATE;
 IF t.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
 IF t.finance_managed OR t.status NOT IN ('pending','overdue','paid','cancelled','canceled') OR (p->>'expected_version')::bigint IS DISTINCT FROM t.finance_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001';END IF;
 IF t.status IN ('cancelled','canceled') AND (p->'preserve_cancelled' IS DISTINCT FROM 'true'::jsonb OR length(btrim(coalesce(p->>'decision_reference','')))=0) THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED: explicitly preserve reviewed cancellation' USING ERRCODE='55000';END IF;
 IF t.status IN ('cancelled','canceled') AND t.paid_date IS NOT NULL THEN RAISE EXCEPTION 'DECISION_REQUIRED: review historical cash/cancellation policy' USING ERRCODE='55000';END IF;
 IF length(btrim(coalesce(p->>'reason','')))=0 OR EXISTS(SELECT 1 FROM public.bank_reconciliation_lines WHERE transaction_id=t.id AND status='matched') OR EXISTS(SELECT 1 FROM public.finance_bank_matches WHERE transaction_id=t.id) THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED: reason and unconciled evidence required' USING ERRCODE='55000';END IF;
 PERFORM finance_private.money(t.amount::text);PERFORM finance_private.iso_date(p->>'due_date');PERFORM finance_private.iso_date(p->>'competence_date');
 IF v_origin IS NULL AND p->'independent_obligation' IS DISTINCT FROM 'true'::jsonb THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED: explicitly classify independent obligation or map origin' USING ERRCODE='55000';END IF;
 IF p->>'scope' IS NOT NULL AND ((t.proposal_id IS NOT NULL AND p->>'scope'<>'operation') OR (t.proposal_id IS NULL AND p->>'scope' NOT IN ('corporate','unclassified'))) THEN RAISE EXCEPTION 'INVALID_REQUEST: legacy scope' USING ERRCODE='22023';END IF;
 IF t.source_key IS NOT NULL AND v_origin IS NULL THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED: preserve and map known financial identity' USING ERRCODE='55000';END IF;
 v_before:=to_jsonb(t);
 IF t.status='paid' AND ((p->>'supplier_id' IS NOT NULL AND t.supplier_id IS NOT NULL AND (p->>'supplier_id')::uuid<>t.supplier_id) OR (p->>'prospect_id' IS NOT NULL AND t.prospect_id IS NOT NULL AND (p->>'prospect_id')::uuid<>t.prospect_id) OR (p->>'seller_id' IS NOT NULL AND t.seller_id IS NOT NULL AND (p->>'seller_id')::uuid<>t.seller_id)) THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: paid counterparty is immutable' USING ERRCODE='55000';END IF;
 t.supplier_id:=coalesce((p->>'supplier_id')::uuid,t.supplier_id);t.prospect_id:=coalesce((p->>'prospect_id')::uuid,t.prospect_id);t.seller_id:=coalesce((p->>'seller_id')::uuid,t.seller_id);
 IF coalesce(t.supplier_id,t.prospect_id,t.seller_id) IS NULL AND nullif(btrim(p->>'counterparty_label'),'') IS NULL THEN RAISE EXCEPTION 'FINANCIAL_DATA_REQUIRED: beneficiary' USING ERRCODE='22023';END IF;
 IF v_origin IS NOT NULL THEN
  IF t.proposal_id IS NULL THEN RAISE EXCEPTION 'INVALID_REQUEST: mapped origin needs proposal' USING ERRCODE='22023';END IF;
  SELECT value INTO o FROM jsonb_array_elements(finance_private.origins(t.proposal_id)->'origins') WHERE value->>'key'=v_origin;
  IF p->>'mapped_type' IS NOT NULL THEN
   IF NOT public.is_full_admin(auth.uid()) OR length(btrim(coalesce(p->>'decision_reference','')))=0 OR t.type<>'receivable' OR p->>'mapped_type'<>'commission_in' OR t.source_key IS DISTINCT FROM v_origin OR o->>'origin_type'<>'accommodation_commission' OR t.seller_id IS NOT NULL OR ((v_before->>'prospect_id')::uuid IS NOT NULL AND (v_before->>'prospect_id')::uuid IS DISTINCT FROM (SELECT prospect_id FROM public.proposals WHERE id=t.proposal_id)) THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED: explicit historical commission classification' USING ERRCODE='55000';END IF;
   t.type:='commission_in';
   -- The historical bundle recorded the customer on a supplier commission.
   -- Reclassify only this recognized artifact, retaining the original snapshot.
   t.prospect_id:=NULL;
  END IF;
  IF o IS NULL OR o->>'type' IS DISTINCT FROM t.type OR (o->>'supplier_id')::uuid IS DISTINCT FROM t.supplier_id OR (o->>'prospect_id')::uuid IS DISTINCT FROM t.prospect_id OR (o->>'seller_id')::uuid IS DISTINCT FROM t.seller_id OR (p->>'installment_number')::integer NOT BETWEEN 1 AND 120 OR (p->>'installment_total')::integer NOT BETWEEN (p->>'installment_number')::integer AND 120 OR p->>'installment_number' IS NULL OR p->>'installment_total' IS NULL THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED: origin/beneficiary/installments mismatch' USING ERRCODE='55000';END IF;
 END IF;
 IF t.status='paid' THEN
  v_payment:=p->'historical_payment';PERFORM finance_private.fields(v_payment,ARRAY['amount','effective_date','bank_account_id','payment_method','reference']);
  IF finance_private.money(v_payment->>'amount')<>t.amount OR length(btrim(coalesce(v_payment->>'payment_method','')))=0 THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED: verified full historical payment required' USING ERRCODE='55000';END IF;
  PERFORM finance_private.iso_date(v_payment->>'effective_date');
 ELSIF p ? 'historical_payment' THEN RAISE EXCEPTION 'INVALID_REQUEST: unpaid historical title' USING ERRCODE='22023';END IF;
 UPDATE public.financial_transactions SET type=t.type,finance_managed=true,status=CASE WHEN t.status IN ('cancelled','canceled') THEN 'cancelled' ELSE 'pending' END,paid_date=NULL,
  supplier_id=t.supplier_id,prospect_id=t.prospect_id,seller_id=t.seller_id,counterparty_label=p->>'counterparty_label',
  due_date=(p->>'due_date')::date,competence_date=(p->>'competence_date')::date,account_id=coalesce((p->>'account_id')::uuid,t.account_id),bank_account_id=coalesce((p->>'bank_account_id')::uuid,t.bank_account_id),
  finance_scope=CASE WHEN t.proposal_id IS NOT NULL THEN 'operation' ELSE coalesce(p->>'scope','unclassified') END,origin_type=coalesce(o->>'origin_type','legacy_reviewed_extra'),origin_id=coalesce(o->>'origin_id',t.id::text),
  source_key=CASE WHEN o IS NOT NULL THEN 'finance_v1:'||v_origin||':'||(p->>'installment_number') ELSE NULL END,
  installment_number=coalesce((p->>'installment_number')::integer,1),installment_total=coalesce((p->>'installment_total')::integer,1),source_snapshot=jsonb_build_object('legacy_before',v_before,'review_reason',p->>'reason','decision_reference',p->>'decision_reference','independent_obligation',p->'independent_obligation','preserve_cancelled',p->'preserve_cancelled') WHERE id=t.id;
 IF v_payment IS NOT NULL THEN
  IF NOT EXISTS(SELECT 1 FROM public.bank_accounts WHERE id=(v_payment->>'bank_account_id')::uuid) THEN RAISE EXCEPTION 'INVALID_REQUEST: historical bank' USING ERRCODE='22023';END IF;
  INSERT INTO public.finance_settlements(transaction_id,amount,bank_account_id,effective_date,payment_method,reference,created_by) VALUES(t.id,t.amount,(v_payment->>'bank_account_id')::uuid,(v_payment->>'effective_date')::date,v_payment->>'payment_method',v_payment->>'reference',auth.uid());
  PERFORM finance_private.refresh_title(t.id);
 END IF;
 INSERT INTO public.finance_adjustments(transaction_id,before_value,after_value,reason,created_by) SELECT t.id,v_before,to_jsonb(x),p->>'reason',auth.uid() FROM public.financial_transactions x WHERE id=t.id;
 RETURN (SELECT jsonb_build_object('id',id,'version',finance_version,'status',status,'legacy_adopted',true) FROM public.financial_transactions WHERE id=t.id);
END $$;

CREATE FUNCTION finance_private.bank_read(p jsonb,kind text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_line public.bank_reconciliation_lines;v_rows jsonb;v_last uuid;v_limit integer:=coalesce((p->>'limit')::integer,50);
BEGIN
 IF kind='batch' THEN
  PERFORM finance_private.fields(p,ARRAY['batch_id']);
  SELECT jsonb_build_object('id',id,'bank_account_id',bank_account_id,'source_name',source_name,'file_sha256',file_sha256,'rows',rows,'rejected',rejected,'overlap_candidates',overlap_candidates,'state',state,'created_at',created_at) INTO v_rows FROM public.finance_bank_batches WHERE id=(p->>'batch_id')::uuid;
  IF v_rows IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;RETURN v_rows;
 ELSIF kind='candidates' THEN
  PERFORM finance_private.fields(p,ARRAY['line_id','limit']);
  IF v_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023';END IF;
  SELECT * INTO v_line FROM public.bank_reconciliation_lines WHERE id=(p->>'line_id')::uuid;
  IF v_line.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
  WITH candidates AS (
   SELECT t.id AS transaction_id,s.id AS settlement_id,t.description,s.effective_date AS candidate_date,
    s.amount-coalesce((SELECT sum(c.amount) FROM public.finance_settlements c WHERE c.reverses_id=s.id),0) AS amount,'settlement' AS kind
   FROM public.finance_settlements s JOIN public.financial_transactions t ON t.id=s.transaction_id
   WHERE s.kind='payment' AND s.bank_account_id=v_line.bank_account_id AND t.finance_managed AND (t.type IN ('receivable','commission_in'))=(v_line.direction='credit')
    AND NOT EXISTS(SELECT 1 FROM public.finance_bank_matches m WHERE m.transaction_id=t.id AND m.undone_at IS NULL AND (m.settlement_id IS NULL OR m.settlement_id=s.id))
   UNION ALL
   SELECT t.id,NULL::uuid,t.description,t.due_date,t.amount,'title' FROM public.financial_transactions t
   WHERE t.finance_managed AND t.status NOT IN ('cancelled','canceled') AND t.bank_account_id=v_line.bank_account_id AND (t.type IN ('receivable','commission_in'))=(v_line.direction='credit')
    AND NOT EXISTS(SELECT 1 FROM public.finance_settlements s WHERE s.transaction_id=t.id) AND NOT EXISTS(SELECT 1 FROM public.finance_bank_matches m WHERE m.transaction_id=t.id AND m.undone_at IS NULL)
  ), page AS (SELECT *,abs(candidate_date-v_line.transaction_date) AS date_difference_days,'EXACT_VALUE_DIRECTION_ACCOUNT' AS explanation FROM candidates WHERE amount=v_line.amount ORDER BY abs(candidate_date-v_line.transaction_date),transaction_id LIMIT v_limit)
  SELECT coalesce(jsonb_agg(to_jsonb(page)||jsonb_build_object('amount',amount::text)),'[]') INTO v_rows FROM page;
  RETURN jsonb_build_object('line_id',v_line.id,'version',v_line.finance_version,'candidates',v_rows,'automatic_match',false);
 END IF;
 PERFORM finance_private.fields(p,ARRAY['bank_account_id','status','from','to','limit','cursor']);
 IF v_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023';END IF;
 IF p->>'from' IS NOT NULL THEN PERFORM finance_private.iso_date(p->>'from');END IF;IF p->>'to' IS NOT NULL THEN PERFORM finance_private.iso_date(p->>'to');END IF;
 WITH page AS (SELECT l.id,l.bank_account_id,l.transaction_date,l.description,l.amount::text AS amount,l.direction,l.status,l.transaction_id,l.batch_id,l.source_row,l.finance_version AS version,
  coalesce((SELECT jsonb_agg(jsonb_build_object('id',m.id,'transaction_id',m.transaction_id,'settlement_id',m.settlement_id,'amount',m.amount::text,'undone_at',m.undone_at,'undo_reason',m.undo_reason)) FROM public.finance_bank_matches m WHERE line_id=l.id),'[]') AS matches
 FROM public.bank_reconciliation_lines l WHERE (p->>'cursor' IS NULL OR l.id>(p->>'cursor')::uuid) AND (p->>'bank_account_id' IS NULL OR l.bank_account_id=(p->>'bank_account_id')::uuid) AND (p->>'status' IS NULL OR l.status=p->>'status') AND (p->>'from' IS NULL OR transaction_date>=(p->>'from')::date) AND (p->>'to' IS NULL OR transaction_date<=(p->>'to')::date) ORDER BY l.id LIMIT v_limit)
 SELECT coalesce(jsonb_agg(to_jsonb(page) ORDER BY id),'[]'),(array_agg(id ORDER BY id DESC))[1] INTO v_rows,v_last FROM page;
 RETURN jsonb_build_object('rows',v_rows,'next_cursor',CASE WHEN jsonb_array_length(v_rows)=v_limit THEN v_last END);
END $$;

CREATE FUNCTION finance_private.prospect_create(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_stage uuid;v_id uuid;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['segment','name','email','phone','company_name','stage_id','notes']);
 IF p->>'segment' IS NULL OR p->>'segment' NOT IN ('b2b','b2c') OR NOT public.has_admin_segment(p->>'segment') THEN RAISE EXCEPTION 'MODULE_FORBIDDEN' USING ERRCODE='42501';END IF;
 IF length(btrim(coalesce(p->>'name',''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'INVALID_REQUEST: name' USING ERRCODE='22023';END IF;
 SELECT id INTO v_stage FROM public.pipeline_stages WHERE segment=p->>'segment' AND (p->>'stage_id' IS NULL OR id=(p->>'stage_id')::uuid) ORDER BY position,id LIMIT 1;
 IF v_stage IS NULL THEN RAISE EXCEPTION 'PIPELINE_STAGE_REQUIRED: configure stage for segment' USING ERRCODE='55000';END IF;
 INSERT INTO public.prospects(name,segment,stage_id,email,phone,company_name,notes,source) VALUES(p->>'name',p->>'segment',v_stage,p->>'email',p->>'phone',p->>'company_name',p->>'notes','manual') RETURNING id INTO v_id;
 RETURN jsonb_build_object('id',v_id,'stage_id',v_stage,'segment',p->>'segment');
END $$;

DO $$ DECLARE def text;BEGIN
 def:=pg_get_functiondef('public.finance_command_v1(text,jsonb,text)'::regprocedure);
 def:=replace(def,'WHEN ''settings.configure''', E'WHEN ''chart.save'' THEN v_result:=finance_private.directory_save(p_payload,''chart'');\n   WHEN ''bank.account.save'' THEN v_result:=finance_private.directory_save(p_payload,''bank'');\n   WHEN ''legacy.adopt'' THEN v_result:=finance_private.legacy_adopt(p_payload);\n   WHEN ''prospect.create'' THEN v_result:=finance_private.prospect_create(p_payload);\n   WHEN ''settings.configure''');
 def:=replace(def,'''FINANCIAL_DATA_REQUIRED'',''INVALID_REQUEST''', '''FINANCIAL_DATA_REQUIRED'',''INVALID_REQUEST'',''UNSUPPORTED_MATCH_MODE'',''PIPELINE_STAGE_REQUIRED'',''EXPORT_EXPIRED'',''EXPORT_NOT_READY'',''OVERLAP_REVIEW_REQUIRED''');
 EXECUTE def;
 def:=pg_get_functiondef('public.finance_query_v1(text,jsonb)'::regprocedure);
 def:=replace(def,'WHEN ''transactions''', E'WHEN ''bank.lines'' THEN v_result:=finance_private.bank_read(p_payload,''lines'');\n  WHEN ''bank.candidates'' THEN v_result:=finance_private.bank_read(p_payload,''candidates'');\n  WHEN ''bank.batch'' THEN v_result:=finance_private.bank_read(p_payload,''batch'');\n  WHEN ''settings'' THEN SELECT jsonb_build_object(''automatic_generation'',false,''settlement_partials'',settlement_partials,''manual_plan_confirmation'',manual_plan_confirmation,''unpaid_adjustments'',unpaid_adjustments,''decision_reference'',decision_reference) INTO v_result FROM finance_private.settings WHERE singleton;\n  WHEN ''transaction.detail'' THEN\n   PERFORM finance_private.fields(p_payload,ARRAY[''transaction_id'']);\n   SELECT jsonb_build_object(''title'',(to_jsonb(t)-''source_snapshot'')||jsonb_build_object(''amount'',t.amount::text,''version'',t.finance_version),''settlements'',coalesce((SELECT jsonb_agg(to_jsonb(s)||jsonb_build_object(''amount'',s.amount::text) ORDER BY s.created_at,s.id) FROM public.finance_settlements s WHERE s.transaction_id=t.id),''[]''),''adjustments'',coalesce((SELECT jsonb_agg(jsonb_build_object(''id'',a.id,''reason'',a.reason,''created_at'',a.created_at)) FROM public.finance_adjustments a WHERE a.transaction_id=t.id),''[]'')) INTO v_result FROM public.financial_transactions t WHERE t.id=(p_payload->>''transaction_id'')::uuid;\n   IF v_result IS NULL THEN RAISE EXCEPTION ''NOT_FOUND'' USING ERRCODE=''P0002'';END IF;\n  WHEN ''transactions''');
 EXECUTE def;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
