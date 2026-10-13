BEGIN;
ALTER TABLE public.financial_transactions ADD COLUMN counterparty_label text;
CREATE TABLE public.finance_adjustments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 transaction_id uuid NOT NULL REFERENCES public.financial_transactions(id) ON DELETE RESTRICT,
 before_value jsonb NOT NULL, after_value jsonb NOT NULL, reason text NOT NULL CHECK(length(btrim(reason))>0),
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.finance_adjustments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_adjustments FROM anon,authenticated;
GRANT SELECT ON public.finance_adjustments TO authenticated;
CREATE POLICY finance_adjustment_read ON public.finance_adjustments FOR SELECT TO authenticated USING(public.has_admin_module('financeiro'));
CREATE TRIGGER finance_adjustment_command_only BEFORE INSERT OR UPDATE OR DELETE ON public.finance_adjustments FOR EACH ROW EXECUTE FUNCTION finance_private.command_only();

CREATE FUNCTION finance_private.refresh_title(pid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE t public.financial_transactions; paid numeric;
BEGIN
 SELECT * INTO STRICT t FROM public.financial_transactions WHERE id=pid FOR UPDATE;
 paid:=finance_private.paid_amount(pid);
 IF paid<0 OR paid>t.amount THEN RAISE EXCEPTION 'BALANCE_INVARIANT' USING ERRCODE='23514'; END IF;
 UPDATE public.financial_transactions SET status=CASE WHEN paid=amount THEN 'paid' WHEN paid>0 THEN 'partial' ELSE 'pending' END,
  paid_date=CASE WHEN paid=amount THEN (SELECT max(s.effective_date) FROM public.finance_settlements s WHERE s.transaction_id=pid AND s.kind='payment' AND s.amount>coalesce((SELECT sum(c.amount) FROM public.finance_settlements c WHERE c.reverses_id=s.id),0)) ELSE NULL END
 WHERE id=pid;
END $$;

CREATE FUNCTION finance_private.manual_title(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_id uuid; v_amount numeric; typ text;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['type','description','amount','due_date','competence_date','proposal_id','supplier_id','prospect_id','seller_id',
  'account_id','bank_account_id','invoice_number','notes','counterparty_label','scope','branch_id']);
 v_amount:=finance_private.money(p->>'amount');typ:=p->>'type';
 IF p->>'scope' IS NOT NULL AND ((p->>'proposal_id' IS NOT NULL AND p->>'scope'<>'operation') OR (p->>'proposal_id' IS NULL AND p->>'scope' NOT IN ('corporate','unclassified'))) THEN RAISE EXCEPTION 'INVALID_REQUEST: explicit financial scope' USING ERRCODE='22023';END IF;
 IF typ IS NULL OR typ NOT IN ('receivable','payable','commission_in','commission_out') OR length(btrim(coalesce(p->>'description','')))=0
  OR length(p->>'description')>2000 THEN RAISE EXCEPTION 'INVALID_REQUEST: type and description required' USING ERRCODE='22023'; END IF;
 PERFORM finance_private.iso_date(p->>'due_date');
 IF p->>'competence_date' IS NOT NULL THEN PERFORM finance_private.iso_date(p->>'competence_date'); END IF;
 IF p->>'proposal_id' IS NOT NULL AND NOT public.admin_can_access_proposal((p->>'proposal_id')::uuid,false) THEN RAISE EXCEPTION 'RECORD_FORBIDDEN' USING ERRCODE='42501'; END IF;
 IF coalesce(p->>'supplier_id',p->>'prospect_id',p->>'seller_id',nullif(btrim(p->>'counterparty_label'),'')) IS NULL THEN
  RAISE EXCEPTION 'FINANCIAL_DATA_REQUIRED: counterparty required' USING ERRCODE='22023'; END IF;
 IF p->>'account_id' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.chart_of_accounts WHERE chart_of_accounts.id=(p->>'account_id')::uuid AND is_active) THEN RAISE EXCEPTION 'INVALID_REQUEST: account' USING ERRCODE='22023'; END IF;
 INSERT INTO public.financial_transactions(type,description,amount,due_date,competence_date,proposal_id,supplier_id,prospect_id,seller_id,account_id,
  bank_account_id,invoice_number,notes,counterparty_label,finance_managed,origin_type,origin_id,status,finance_scope,branch_id)
 VALUES(typ,p->>'description',v_amount,(p->>'due_date')::date,(p->>'competence_date')::date,(p->>'proposal_id')::uuid,(p->>'supplier_id')::uuid,
  (p->>'prospect_id')::uuid,(p->>'seller_id')::uuid,(p->>'account_id')::uuid,(p->>'bank_account_id')::uuid,p->>'invoice_number',p->>'notes',p->>'counterparty_label',
  true,'manual',gen_random_uuid()::text,'pending',CASE WHEN p->>'proposal_id' IS NOT NULL THEN 'operation' ELSE coalesce(p->>'scope','unclassified') END,(p->>'branch_id')::uuid) RETURNING financial_transactions.id INTO v_id;
 RETURN jsonb_build_object('id',v_id,'version',1,'amount',v_amount::text,'balance',v_amount::text);
END $$;

CREATE FUNCTION finance_private.settle(p jsonb,correction boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE t public.financial_transactions; original public.finance_settlements; eid uuid; v_amount numeric; paid numeric; original_net numeric;
BEGIN
 IF correction THEN
  PERFORM finance_private.fields(p,ARRAY['settlement_id','expected_version','amount','reason']);
  SELECT * INTO original FROM public.finance_settlements WHERE id=(p->>'settlement_id')::uuid;
  IF original.id IS NULL OR original.kind<>'payment' THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
  PERFORM 1 FROM public.proposals WHERE id=(SELECT proposal_id FROM public.financial_transactions WHERE id=original.transaction_id) FOR UPDATE;
  SELECT * INTO STRICT t FROM public.financial_transactions WHERE id=original.transaction_id FOR UPDATE;
 ELSE
  PERFORM finance_private.fields(p,ARRAY['transaction_id','expected_version','amount','effective_date','bank_account_id','payment_method','reference']);
  PERFORM 1 FROM public.proposals WHERE id=(SELECT proposal_id FROM public.financial_transactions WHERE id=(p->>'transaction_id')::uuid) FOR UPDATE;
  SELECT * INTO t FROM public.financial_transactions WHERE id=(p->>'transaction_id')::uuid FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
 END IF;
 IF NOT t.finance_managed THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED' USING ERRCODE='55000'; END IF;
 IF (p->>'expected_version')::bigint IS DISTINCT FROM t.finance_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
 IF t.status IN ('cancelled','canceled') THEN RAISE EXCEPTION 'INVALID_TRANSITION' USING ERRCODE='55000'; END IF;
 v_amount:=finance_private.money(p->>'amount');paid:=finance_private.paid_amount(t.id);
 IF correction THEN
  IF EXISTS(SELECT 1 FROM public.finance_bank_matches WHERE settlement_id=original.id AND undone_at IS NULL) THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: undo reconciliation before correcting settlement' USING ERRCODE='55000'; END IF;
  IF length(btrim(coalesce(p->>'reason','')))=0 THEN RAISE EXCEPTION 'INVALID_REQUEST: correction reason' USING ERRCODE='22023'; END IF;
  original_net:=original.amount-coalesce((SELECT sum(s.amount) FROM public.finance_settlements s WHERE reverses_id=original.id),0);
  IF v_amount>original_net THEN RAISE EXCEPTION 'INVALID_REQUEST: correction exceeds original settlement' USING ERRCODE='22023'; END IF;
  INSERT INTO public.finance_settlements(transaction_id,amount,kind,reverses_id,bank_account_id,effective_date,payment_method,reason,created_by)
  VALUES(t.id,v_amount,'correction',original.id,original.bank_account_id,original.effective_date,original.payment_method,p->>'reason',auth.uid()) RETURNING id INTO eid;
 ELSE
  IF EXISTS(SELECT 1 FROM public.finance_bank_matches WHERE transaction_id=t.id AND settlement_id IS NULL AND undone_at IS NULL) THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: undo title-only reconciliation before settling' USING ERRCODE='55000'; END IF;
  IF v_amount>t.amount-paid THEN RAISE EXCEPTION 'INVALID_REQUEST: amount exceeds remaining balance' USING ERRCODE='22023'; END IF;
  IF v_amount<t.amount-paid AND NOT(SELECT settlement_partials FROM finance_private.settings WHERE singleton) THEN RAISE EXCEPTION 'DECISION_REQUIRED: partial settlement policy' USING ERRCODE='55000'; END IF;
  PERFORM finance_private.iso_date(p->>'effective_date');
  IF NOT EXISTS(SELECT 1 FROM public.bank_accounts WHERE id=(p->>'bank_account_id')::uuid AND is_active) THEN RAISE EXCEPTION 'INVALID_REQUEST: active bank account required' USING ERRCODE='22023'; END IF;
  IF length(btrim(coalesce(p->>'payment_method','')))=0 OR length(p->>'payment_method')>100 THEN RAISE EXCEPTION 'INVALID_REQUEST: payment method' USING ERRCODE='22023'; END IF;
  INSERT INTO public.finance_settlements(transaction_id,amount,kind,bank_account_id,effective_date,payment_method,reference,created_by)
  VALUES(t.id,v_amount,'payment',(p->>'bank_account_id')::uuid,(p->>'effective_date')::date,p->>'payment_method',p->>'reference',auth.uid()) RETURNING id INTO eid;
 END IF;
 PERFORM finance_private.refresh_title(t.id);
 RETURN (SELECT jsonb_build_object('settlement_id',eid,'transaction_id',ft.id,'version',ft.finance_version,'amount',ft.amount::text,
  'paid_amount',finance_private.paid_amount(ft.id)::text,'balance',(ft.amount-finance_private.paid_amount(ft.id))::text,'status',ft.status)
  FROM public.financial_transactions ft WHERE ft.id=t.id);
END $$;

CREATE FUNCTION finance_private.edit_title(p jsonb,adjustment boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE t public.financial_transactions; result jsonb; n numeric;
BEGIN
 IF adjustment THEN PERFORM finance_private.fields(p,ARRAY['transaction_id','expected_version','amount','due_date','cancel','reason']);
 ELSE PERFORM finance_private.fields(p,ARRAY['transaction_id','expected_version','invoice_number','competence_date','account_id','notes']); END IF;
 PERFORM 1 FROM public.proposals WHERE id=(SELECT proposal_id FROM public.financial_transactions WHERE id=(p->>'transaction_id')::uuid) FOR UPDATE;
  SELECT * INTO t FROM public.financial_transactions WHERE id=(p->>'transaction_id')::uuid FOR UPDATE;
 IF t.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF NOT t.finance_managed THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED' USING ERRCODE='55000'; END IF;
 IF (p->>'expected_version')::bigint IS DISTINCT FROM t.finance_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
 IF adjustment THEN
  IF NOT(SELECT unpaid_adjustments FROM finance_private.settings WHERE singleton) THEN RAISE EXCEPTION 'DECISION_REQUIRED: unpaid adjustment policy' USING ERRCODE='55000';END IF;
  IF length(btrim(coalesce(p->>'reason','')))=0 THEN RAISE EXCEPTION 'INVALID_REQUEST: reason required' USING ERRCODE='22023'; END IF;
  IF EXISTS(SELECT 1 FROM public.finance_settlements WHERE transaction_id=t.id)
   OR EXISTS(SELECT 1 FROM public.bank_reconciliation_lines WHERE transaction_id=t.id AND status='matched') THEN
   RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: paid or reconciled title' USING ERRCODE='55000'; END IF;
  IF t.status IN ('cancelled','canceled') THEN RAISE EXCEPTION 'INVALID_TRANSITION: cancelled title' USING ERRCODE='55000'; END IF;
  n:=CASE WHEN p ? 'amount' THEN finance_private.money(p->>'amount') ELSE t.amount END;
  IF p ? 'due_date' THEN PERFORM finance_private.iso_date(p->>'due_date'); END IF;
  UPDATE public.financial_transactions SET amount=n,due_date=CASE WHEN p ? 'due_date' THEN (p->>'due_date')::date ELSE due_date END,
   status=CASE WHEN coalesce((p->>'cancel')::boolean,false) THEN 'cancelled' ELSE status END,
   cancelled_at=CASE WHEN coalesce((p->>'cancel')::boolean,false) THEN now() ELSE cancelled_at END WHERE id=t.id;
  SELECT to_jsonb(x)||jsonb_build_object('amount',x.amount::text,'version',x.finance_version,'paid_amount',finance_private.paid_amount(x.id)::text,'balance',(x.amount-finance_private.paid_amount(x.id))::text) INTO result FROM public.financial_transactions x WHERE id=t.id;
  INSERT INTO public.finance_adjustments(transaction_id,before_value,after_value,reason,created_by) VALUES(t.id,to_jsonb(t),result,p->>'reason',auth.uid());
 ELSE
  IF p->>'competence_date' IS NOT NULL THEN PERFORM finance_private.iso_date(p->>'competence_date'); END IF;
  IF p->>'account_id' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.chart_of_accounts WHERE id=(p->>'account_id')::uuid AND is_active) THEN RAISE EXCEPTION 'INVALID_REQUEST: account' USING ERRCODE='22023'; END IF;
  UPDATE public.financial_transactions SET invoice_number=CASE WHEN p ? 'invoice_number' THEN p->>'invoice_number' ELSE invoice_number END,
   competence_date=CASE WHEN p ? 'competence_date' THEN (p->>'competence_date')::date ELSE competence_date END,
   account_id=CASE WHEN p ? 'account_id' THEN (p->>'account_id')::uuid ELSE account_id END,
   notes=CASE WHEN p ? 'notes' THEN p->>'notes' ELSE notes END WHERE id=t.id;
  SELECT to_jsonb(x)||jsonb_build_object('amount',x.amount::text,'version',x.finance_version,'paid_amount',finance_private.paid_amount(x.id)::text,'balance',(x.amount-finance_private.paid_amount(x.id))::text) INTO result FROM public.financial_transactions x WHERE id=t.id;
 END IF;
 RETURN result;
END $$;

CREATE FUNCTION finance_private.supplier_link(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE s jsonb; sid uuid; pid uuid; linkid uuid;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['product_id','supplier_id','supplier','label','reference_cost','reference_sale','payment_terms','is_active']);
 pid:=(p->>'product_id')::uuid;
 PERFORM 1 FROM public.products WHERE id=pid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF (p->>'supplier_id' IS NOT NULL)=(p->'supplier' IS NOT NULL AND p->'supplier'<>'null') THEN RAISE EXCEPTION 'INVALID_REQUEST: choose existing or new supplier' USING ERRCODE='22023'; END IF;
 IF p->>'supplier_id' IS NOT NULL THEN
  sid:=(p->>'supplier_id')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.suppliers WHERE id=sid) THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
 ELSE
  s:=p->'supplier';PERFORM finance_private.fields(s,ARRAY['name','cnpj','contact_name','phone','email','website','pix_key','bank_name','bank_agency','bank_account','payment_terms']);
  IF length(btrim(coalesce(s->>'name','')))=0 THEN RAISE EXCEPTION 'INVALID_REQUEST: supplier name required' USING ERRCODE='22023'; END IF;
  IF nullif(btrim(s->>'cnpj'),'') IS NOT NULL THEN PERFORM pg_advisory_xact_lock(hashtextextended('supplier-document:'||lower(regexp_replace(s->>'cnpj','[^a-zA-Z0-9]','','g')),0));END IF;
  IF nullif(btrim(s->>'cnpj'),'') IS NOT NULL AND EXISTS(SELECT 1 FROM public.suppliers WHERE lower(regexp_replace(cnpj,'[^a-zA-Z0-9]','','g'))=lower(regexp_replace(s->>'cnpj','[^a-zA-Z0-9]','','g'))) THEN
   RAISE EXCEPTION 'SUPPLIER_REVIEW_REQUIRED: document already registered' USING ERRCODE='55000'; END IF;
  INSERT INTO public.suppliers(name,cnpj,contact_name,phone,email,website,pix_key,bank_name,bank_agency,bank_account,payment_terms)
  VALUES(s->>'name',s->>'cnpj',s->>'contact_name',s->>'phone',s->>'email',s->>'website',s->>'pix_key',s->>'bank_name',s->>'bank_agency',s->>'bank_account',s->>'payment_terms') RETURNING id INTO sid;
 END IF;
 INSERT INTO public.product_suppliers(product_id,supplier_id,label,reference_cost,reference_sale,payment_terms,is_active)
 VALUES(pid,sid,coalesce(p->>'label',''),CASE WHEN p->>'reference_cost' IS NOT NULL THEN finance_private.money(p->>'reference_cost',true) END,
  CASE WHEN p->>'reference_sale' IS NOT NULL THEN finance_private.money(p->>'reference_sale',true) END,p->>'payment_terms',coalesce((p->>'is_active')::boolean,true))
 ON CONFLICT(product_id,supplier_id,label) DO UPDATE SET is_active=EXCLUDED.is_active,reference_cost=EXCLUDED.reference_cost,reference_sale=EXCLUDED.reference_sale,payment_terms=EXCLUDED.payment_terms RETURNING id INTO linkid;
 RETURN jsonb_build_object('supplier_id',sid,'product_supplier_id',linkid,'product_id',pid);
END $$;

CREATE FUNCTION finance_private.configure(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE k text;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['settlement_partials','manual_plan_confirmation','unpaid_adjustments','decision_reference']);
 IF NOT public.is_full_admin(auth.uid()) THEN RAISE EXCEPTION 'MODULE_FORBIDDEN' USING ERRCODE='42501';END IF;
 IF NOT(p ?| ARRAY['settlement_partials','manual_plan_confirmation','unpaid_adjustments']) OR length(btrim(coalesce(p->>'decision_reference','')))=0 THEN RAISE EXCEPTION 'DECISION_REQUIRED: policy and decision reference required' USING ERRCODE='22023';END IF;
 FOREACH k IN ARRAY ARRAY['settlement_partials','manual_plan_confirmation','unpaid_adjustments'] LOOP IF p ? k AND jsonb_typeof(p->k) IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'INVALID_REQUEST: boolean policy' USING ERRCODE='22023';END IF;END LOOP;
 UPDATE finance_private.settings SET settlement_partials=coalesce((p->>'settlement_partials')::boolean,settlement_partials),manual_plan_confirmation=coalesce((p->>'manual_plan_confirmation')::boolean,manual_plan_confirmation),unpaid_adjustments=coalesce((p->>'unpaid_adjustments')::boolean,unpaid_adjustments),decision_reference=p->>'decision_reference',updated_at=now() WHERE singleton;
 RETURN (SELECT (to_jsonb(x)-'singleton')||jsonb_build_object('automatic_generation',false) FROM finance_private.settings x WHERE singleton);
END $$;

CREATE FUNCTION public.finance_command_v1(p_action text,p_payload jsonb,p_idempotency_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public SET statement_timeout='5s' SET lock_timeout='2s' AS $$
DECLARE actor uuid; old finance_private.receipts; v_result jsonb; phash text; code text; detail text;
BEGIN
 actor:=finance_private.require_module(CASE WHEN p_action='supplier.link' THEN 'cadastros' ELSE 'financeiro' END);
 IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 200 OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR octet_length(p_payload::text)>(CASE WHEN p_action='bank.preview' THEN 16777216 ELSE 1048576 END) THEN
  RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023'; END IF;
 PERFORM finance_private.rate_limit('command',60);
 phash:=finance_private.hash(p_payload);
 BEGIN
  INSERT INTO finance_private.receipts(actor_id,action,request_key,payload_hash) VALUES(actor,p_action,p_idempotency_key,phash) ON CONFLICT DO NOTHING;
  SELECT * INTO STRICT old FROM finance_private.receipts WHERE actor_id=actor AND action=p_action AND request_key=p_idempotency_key FOR UPDATE;
  IF old.payload_hash<>phash THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='40001'; END IF;
  IF old.result IS NOT NULL THEN RETURN jsonb_build_object('data',old.result,'replayed',true); END IF;
  CASE p_action
   WHEN 'plan.preview' THEN v_result:=finance_private.preview(p_payload);
   WHEN 'plan.confirm' THEN v_result:=finance_private.confirm_plan(p_payload);
   WHEN 'transaction.create' THEN v_result:=finance_private.manual_title(p_payload);
   WHEN 'transaction.patch' THEN v_result:=finance_private.edit_title(p_payload,false);
   WHEN 'transaction.adjust' THEN v_result:=finance_private.edit_title(p_payload,true);
   WHEN 'settlement.create' THEN v_result:=finance_private.settle(p_payload,false);
   WHEN 'settlement.correct' THEN v_result:=finance_private.settle(p_payload,true);
   WHEN 'supplier.link' THEN v_result:=finance_private.supplier_link(p_payload);
   WHEN 'settings.configure' THEN v_result:=finance_private.configure(p_payload);
   ELSE RAISE EXCEPTION 'INVALID_REQUEST: unknown operation' USING ERRCODE='22023';
  END CASE;
  INSERT INTO public.finance_audit_events(actor_id,action,entity_id,request_key,after_value,reason)
  VALUES(actor,p_action,coalesce((v_result->>'id')::uuid,(v_result->>'transaction_id')::uuid,(v_result->>'plan_id')::uuid,(v_result->>'preview_id')::uuid),p_idempotency_key,
   -- Audit references and state only, never supplier bank data or arbitrary input.
   CASE WHEN p_action='settings.configure' THEN v_result ELSE jsonb_build_object('id',coalesce(v_result->'id',v_result->'transaction_id',v_result->'plan_id',v_result->'preview_id'),'version',v_result->'version','status',v_result->'status') END,p_payload->>'reason');
  UPDATE finance_private.receipts SET result=v_result WHERE actor_id=actor AND action=p_action AND request_key=p_idempotency_key;
  RETURN jsonb_build_object('data',v_result,'replayed',false);
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS code=RETURNED_SQLSTATE,detail=MESSAGE_TEXT;
  RETURN jsonb_build_object('error',jsonb_build_object('code',CASE
   WHEN split_part(detail,':',1) IN ('VERSION_CONFLICT','IDEMPOTENCY_CONFLICT','LEGACY_REVIEW_REQUIRED','ADJUSTMENT_REQUIRED','DECISION_REQUIRED','INVALID_TRANSITION','NOT_FOUND','MODULE_FORBIDDEN','RECORD_FORBIDDEN','SUPPLIER_REVIEW_REQUIRED','FINANCIAL_DATA_REQUIRED','INVALID_REQUEST') THEN split_part(detail,':',1)
   WHEN code IN ('22023','22P02','22007','22008','23503','23514','23502') THEN 'INVALID_REQUEST'
   WHEN code IN ('40001','40P01','55P03') THEN 'VERSION_CONFLICT'
   WHEN code='42501' THEN 'MODULE_FORBIDDEN' ELSE 'INTERNAL_ERROR' END,
   'sqlstate',code,'retryable',code IN ('40P01','55P03','57014')));
 END;
END $$;
REVOKE ALL ON FUNCTION public.finance_command_v1(text,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.finance_command_v1(text,jsonb,text) TO authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
