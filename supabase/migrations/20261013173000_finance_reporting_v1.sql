BEGIN;
CREATE FUNCTION finance_private.report(p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_from date; v_to date; v_basis text; v_pid uuid; v_rows jsonb; v_totals jsonb; v_missing jsonb;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['from','to','basis','proposal_id']);
 v_from:=finance_private.iso_date(p->>'from');v_to:=finance_private.iso_date(p->>'to');v_basis:=p->>'basis';v_pid:=(p->>'proposal_id')::uuid;
 IF v_from>v_to OR v_to-v_from>3660 OR v_basis IS NULL OR v_basis NOT IN ('cash','due','competence') THEN RAISE EXCEPTION 'INVALID_REQUEST: explicit report basis and period required' USING ERRCODE='22023'; END IF;
 IF v_pid IS NOT NULL AND NOT public.admin_can_access_proposal(v_pid,false) THEN RAISE EXCEPTION 'RECORD_FORBIDDEN' USING ERRCODE='42501'; END IF;
 WITH movements AS (
  SELECT t.id AS transaction_id,s.id AS event_id,t.type,t.description,
   CASE WHEN s.kind='correction' THEN -s.amount ELSE s.amount END AS amount,
   s.effective_date AS report_date,t.proposal_id,t.account_id,t.supplier_id,t.invoice_number,s.bank_account_id,t.finance_managed
  FROM public.finance_settlements s JOIN public.financial_transactions t ON t.id=s.transaction_id
  WHERE v_basis='cash' AND s.effective_date BETWEEN v_from AND v_to AND (v_pid IS NULL OR t.proposal_id=v_pid)
  UNION ALL
  SELECT t.id,NULL::uuid,t.type,t.description,t.amount,
   CASE WHEN v_basis='due' THEN t.due_date ELSE t.competence_date END,t.proposal_id,t.account_id,t.supplier_id,t.invoice_number,t.bank_account_id,t.finance_managed
  FROM public.financial_transactions t WHERE v_basis<>'cash' AND t.status NOT IN ('cancelled','canceled')
   AND t.type IN ('receivable','payable','commission_in','commission_out')
   AND CASE WHEN v_basis='due' THEN t.due_date ELSE t.competence_date END BETWEEN v_from AND v_to
   AND (v_pid IS NULL OR t.proposal_id=v_pid)
 ), grouped AS (
  SELECT m.account_id,a.code,a.name,a.type AS account_type,
   sum(CASE WHEN m.type IN ('receivable','commission_in') THEN m.amount ELSE 0 END) AS income,
   sum(CASE WHEN m.type IN ('payable','commission_out') THEN m.amount ELSE 0 END) AS expense,
   count(*) AS count
  FROM movements m LEFT JOIN public.chart_of_accounts a ON a.id=m.account_id GROUP BY m.account_id,a.code,a.name,a.type
 )
 SELECT coalesce(jsonb_agg(jsonb_build_object('account_id',account_id,'code',code,'name',coalesce(name,'Sem classificação'),'account_type',account_type,
  'income',income::text,'expense',expense::text,'result',(income-expense)::text,'movement_count',count) ORDER BY code NULLS LAST),'[]'),
  jsonb_build_object('income',coalesce(sum(income),0)::text,'expense',coalesce(sum(expense),0)::text,'result',(coalesce(sum(income),0)-coalesce(sum(expense),0))::text,'movement_count',coalesce(sum(count),0))
 INTO v_rows,v_totals FROM grouped;
 SELECT jsonb_build_object('missing_basis_date',count(*) FILTER(WHERE v_basis='competence' AND competence_date IS NULL),
  'legacy_cash_unverified',count(*) FILTER(WHERE v_basis='cash' AND NOT finance_managed AND status='paid'),
  'unclassified',count(*) FILTER(WHERE account_id IS NULL),
  'unlinked_operation',count(*) FILTER(WHERE proposal_id IS NULL AND finance_scope<>'corporate')) INTO v_missing
 FROM public.financial_transactions WHERE status NOT IN ('cancelled','canceled') AND (v_pid IS NULL OR proposal_id=v_pid);
 RETURN jsonb_build_object('report_version','finance-v1','basis',v_basis,'from',v_from,'to',v_to,'proposal_id',v_pid,
  'accounts',v_rows,'totals',v_totals,'pending_counts',v_missing,'complete',NOT EXISTS(SELECT 1 FROM jsonb_each_text(v_missing) WHERE value::bigint>0));
END $$;

CREATE FUNCTION finance_private.report_detail(p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_from date;v_to date;v_basis text;v_pid uuid;v_cursor uuid;v_limit integer;v_rows jsonb;v_last uuid;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['from','to','basis','proposal_id','cursor','limit']);
 v_from:=finance_private.iso_date(p->>'from');v_to:=finance_private.iso_date(p->>'to');v_basis:=p->>'basis';v_pid:=(p->>'proposal_id')::uuid;
 v_cursor:=(p->>'cursor')::uuid;v_limit:=coalesce((p->>'limit')::integer,50);
 IF v_from>v_to OR v_to-v_from>3660 OR v_basis IS NULL OR v_basis NOT IN ('cash','due','competence') OR v_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023'; END IF;
 WITH rows AS (
  SELECT s.id AS movement_id,t.id AS transaction_id,t.type,t.description,
   (CASE WHEN s.kind='correction' THEN -s.amount ELSE s.amount END)::text AS amount,s.effective_date AS report_date,
   t.proposal_id,t.account_id,t.supplier_id,t.invoice_number,s.bank_account_id
  FROM public.finance_settlements s JOIN public.financial_transactions t ON t.id=s.transaction_id
  WHERE v_basis='cash' AND s.effective_date BETWEEN v_from AND v_to AND (v_pid IS NULL OR t.proposal_id=v_pid) AND (v_cursor IS NULL OR s.id>v_cursor)
  UNION ALL
  SELECT t.id,t.id,t.type,t.description,t.amount::text,CASE WHEN v_basis='due' THEN t.due_date ELSE t.competence_date END,
   t.proposal_id,t.account_id,t.supplier_id,t.invoice_number,t.bank_account_id
  FROM public.financial_transactions t WHERE v_basis<>'cash' AND t.status NOT IN ('cancelled','canceled')
   AND t.type IN ('receivable','payable','commission_in','commission_out')
   AND CASE WHEN v_basis='due' THEN t.due_date ELSE t.competence_date END BETWEEN v_from AND v_to
   AND (v_pid IS NULL OR t.proposal_id=v_pid) AND (v_cursor IS NULL OR t.id>v_cursor)
 ), page AS (SELECT * FROM rows ORDER BY movement_id LIMIT v_limit)
 SELECT coalesce(jsonb_agg(to_jsonb(page) ORDER BY movement_id),'[]'),(array_agg(movement_id ORDER BY movement_id DESC))[1] INTO v_rows,v_last FROM page;
 RETURN jsonb_build_object('rows',v_rows,'next_cursor',CASE WHEN jsonb_array_length(v_rows)=v_limit THEN v_last ELSE NULL END,'basis',v_basis,'from',v_from,'to',v_to);
END $$;

CREATE FUNCTION finance_private.list_titles(p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_limit integer:=coalesce((p->>'limit')::integer,50);v_cursor uuid:=(p->>'cursor')::uuid;v_rows jsonb;v_last uuid;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['limit','cursor','type','status','proposal_id','supplier_id','account_id','from','to','prospect_id','seller_id','bank_account_id','branch_id','scope','overdue']);
 IF v_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'INVALID_REQUEST: page limit' USING ERRCODE='22023'; END IF;
 IF p ? 'overdue' AND jsonb_typeof(p->'overdue') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'INVALID_REQUEST: overdue boolean' USING ERRCODE='22023';END IF;
 IF p->>'from' IS NOT NULL AND p->>'to' IS NOT NULL AND (p->>'from')::date>(p->>'to')::date THEN RAISE EXCEPTION 'INVALID_REQUEST: date range' USING ERRCODE='22023';END IF;
 IF p->>'from' IS NOT NULL THEN PERFORM finance_private.iso_date(p->>'from'); END IF;
 IF p->>'to' IS NOT NULL THEN PERFORM finance_private.iso_date(p->>'to'); END IF;
 WITH page AS (
  SELECT t.id,t.type,t.description,t.amount::text AS amount,t.due_date,t.competence_date,t.paid_date,t.status,t.proposal_id,t.supplier_id,t.prospect_id,t.seller_id,
   t.account_id,t.bank_account_id,t.branch_id,t.finance_scope AS scope,t.invoice_number,t.counterparty_label,t.finance_version AS version,t.finance_managed,t.origin_type,t.origin_id,t.installment_number,t.installment_total,
   CASE WHEN t.finance_managed THEN finance_private.paid_amount(t.id)::text END AS paid_amount,
   CASE WHEN t.finance_managed THEN (t.amount-finance_private.paid_amount(t.id))::text END AS balance,
   (t.status NOT IN ('paid','cancelled','canceled') AND t.due_date<(now() AT TIME ZONE 'America/Sao_Paulo')::date) AS overdue
  FROM public.financial_transactions t
  WHERE (v_cursor IS NULL OR t.id>v_cursor) AND (p->>'type' IS NULL OR t.type=p->>'type') AND (p->>'status' IS NULL OR t.status=p->>'status')
   AND (p->>'proposal_id' IS NULL OR t.proposal_id=(p->>'proposal_id')::uuid)
   AND (p->>'supplier_id' IS NULL OR t.supplier_id=(p->>'supplier_id')::uuid)
   AND (p->>'account_id' IS NULL OR t.account_id=(p->>'account_id')::uuid)
   AND (p->>'prospect_id' IS NULL OR t.prospect_id=(p->>'prospect_id')::uuid) AND (p->>'seller_id' IS NULL OR t.seller_id=(p->>'seller_id')::uuid)
   AND (p->>'bank_account_id' IS NULL OR t.bank_account_id=(p->>'bank_account_id')::uuid) AND (p->>'branch_id' IS NULL OR t.branch_id=(p->>'branch_id')::uuid)
   AND (p->>'scope' IS NULL OR t.finance_scope=p->>'scope') AND (p->>'overdue' IS NULL OR (t.status NOT IN ('paid','cancelled','canceled') AND t.due_date<(now() AT TIME ZONE 'America/Sao_Paulo')::date)=(p->>'overdue')::boolean)
   AND (p->>'from' IS NULL OR t.due_date>=(p->>'from')::date) AND (p->>'to' IS NULL OR t.due_date<=(p->>'to')::date)
  ORDER BY t.id LIMIT v_limit
 ) SELECT coalesce(jsonb_agg(to_jsonb(page) ORDER BY id),'[]'),(array_agg(id ORDER BY id DESC))[1] INTO v_rows,v_last FROM page;
 RETURN jsonb_build_object('rows',v_rows,'next_cursor',CASE WHEN jsonb_array_length(v_rows)=v_limit THEN v_last ELSE NULL END);
END $$;

CREATE FUNCTION finance_private.proposal_result(pid uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_p public.proposals;v_item record;v_acc record;v_amt jsonb;v_profit numeric:=0;v_cost numeric:=0;v_comm numeric:=0;v_service numeric;v_discount numeric;v_missing integer:=0;v_origins jsonb;v_extras numeric;v_title_result numeric;v_cash numeric;v_open numeric;
BEGIN
 SELECT * INTO v_p FROM public.proposals WHERE id=pid;
 IF v_p.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
 FOR v_item IN SELECT * FROM public.proposal_day_items WHERE proposal_id=pid AND category<>'Hospedagens' LOOP
  v_cost:=round(v_item.cost_price*coalesce(v_item.quantity,1),2);
  v_comm:=CASE WHEN v_item.commission_percent BETWEEN 0 AND 100 THEN round(v_cost*v_item.commission_percent/100,2) ELSE 0 END;
  IF v_item.commission_percent IS NULL OR v_item.commission_percent NOT BETWEEN 0 AND 100 THEN v_missing:=v_missing+1;END IF;
  v_profit:=v_profit+round(v_item.value*coalesce(v_item.quantity,1),2)-v_cost+v_comm;
 END LOOP;
 FOR v_acc IN SELECT * FROM public.proposal_accommodations WHERE proposal_id=pid AND is_selected LOOP
  v_amt:=finance_private.accommodation_amounts(v_acc.rooms,v_acc.num_nights);
  v_profit:=v_profit+(CASE WHEN v_acc.payment_type='atmos' THEN (v_amt->>'revenue')::numeric-(v_amt->>'cost')::numeric ELSE 0 END)+(v_amt->>'commission')::numeric;
  v_missing:=v_missing+(v_amt->>'missing_commissions')::integer;
 END LOOP;
 v_service:=round(coalesce((v_p.atmos_service->>'price_per_person_day')::numeric,0)*coalesce(v_p.num_people,1)*coalesce(v_p.num_days,1),2);
 v_discount:=round(v_p.subtotal*v_p.discount_percent/100+v_p.discount_fixed,2);
 v_profit:=v_profit+v_service-v_discount-round(v_p.total*coalesce((v_p.atmos_service->>'seller_commission_percent')::numeric,0)/100,2)
  -coalesce((SELECT sum((x->>'amount')::numeric) FROM jsonb_array_elements(coalesce(v_p.atmos_service->'internal_costs','[]')) x),0)
  -coalesce((SELECT sum(amount) FROM public.proposal_costs WHERE proposal_id=pid),0);
 v_origins:=finance_private.origins(pid);
 SELECT coalesce(sum(CASE WHEN type IN ('receivable','commission_in') THEN amount ELSE -amount END) FILTER(WHERE origin_type IN ('manual','legacy_reviewed_extra')),0),coalesce(sum(CASE WHEN type IN ('receivable','commission_in') THEN amount ELSE -amount END),0),coalesce(sum(amount-finance_private.paid_amount(id)) FILTER(WHERE finance_managed),0) INTO v_extras,v_title_result,v_open FROM public.financial_transactions WHERE proposal_id=pid AND status NOT IN ('cancelled','canceled');
 SELECT coalesce(sum((CASE WHEN t.type IN ('receivable','commission_in') THEN 1 ELSE -1 END)*(CASE WHEN s.kind='correction' THEN -s.amount ELSE s.amount END)),0) INTO v_cash FROM public.finance_settlements s JOIN public.financial_transactions t ON t.id=s.transaction_id WHERE t.proposal_id=pid;
 RETURN jsonb_build_object('proposal_id',pid,'version',v_p.finance_version,'calculation_version','atmos-2026-09-v1',
  'planned_revenue',v_p.total::text,'planned_profit',v_profit::text,'manual_extras_result',v_extras::text,'forecast_profit_with_extras',(v_profit+v_extras)::text,'title_result_lifetime',v_title_result::text,'cash_result_lifetime',v_cash::text,'open_amount_lifetime',v_open::text,'planned_margin_percent',CASE WHEN v_p.total>0 THEN v_profit/v_p.total*100 ELSE 0 END,
  'result_incomplete',v_missing>0 OR jsonb_array_length(v_origins->'pending_items')>0,'missing_commissions',v_missing,'financial_origins',v_origins);
END $$;

CREATE FUNCTION finance_private.account_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public AS $$
BEGIN
 IF TG_OP='DELETE' THEN
  IF EXISTS(SELECT 1 FROM public.financial_transactions WHERE account_id=OLD.id) OR EXISTS(SELECT 1 FROM public.proposal_costs WHERE account_id=OLD.id) THEN
   RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: deactivate referenced account' USING ERRCODE='55000'; END IF;
  RETURN OLD;
 END IF;
 IF NEW.parent_id IS NOT NULL AND (NEW.parent_id=NEW.id OR EXISTS(
  WITH RECURSIVE parents AS (
   SELECT id,parent_id,ARRAY[id] AS visited FROM public.chart_of_accounts WHERE id=NEW.parent_id
   UNION ALL SELECT a.id,a.parent_id,p.visited||a.id FROM public.chart_of_accounts a JOIN parents p ON p.parent_id=a.id WHERE NOT a.id=ANY(p.visited)
  ) SELECT 1 FROM parents WHERE id=NEW.id
 )) THEN RAISE EXCEPTION 'INVALID_REQUEST: account hierarchy cycle' USING ERRCODE='22023'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER finance_account_guard BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts FOR EACH ROW EXECUTE FUNCTION finance_private.account_guard();

CREATE FUNCTION public.finance_query_v1(p_action text,p_payload jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public SET statement_timeout='10s' AS $$
DECLARE v_result jsonb;
BEGIN
 IF p_action='product.suppliers' THEN
  IF auth.uid() IS NULL OR NOT(public.has_admin_module('cadastros') OR public.has_admin_module('financeiro') OR public.has_admin_module('b2c') OR public.has_admin_module('b2b')) THEN RAISE EXCEPTION 'MODULE_FORBIDDEN' USING ERRCODE='42501'; END IF;
 ELSE PERFORM finance_private.require_module(); END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR octet_length(p_payload::text)>65536 THEN RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023';END IF;
 PERFORM finance_private.rate_limit(CASE WHEN p_action='export.part' THEN 'export.download' ELSE 'query' END,CASE WHEN p_action='export.part' THEN 1000 ELSE 120 END);
 CASE p_action
  WHEN 'upload.authorize' THEN PERFORM finance_private.fields(p_payload,ARRAY[]::text[]);PERFORM finance_private.rate_limit('upload',5);v_result:=jsonb_build_object('authorized',true);
  WHEN 'transactions' THEN v_result:=finance_private.list_titles(p_payload);
  WHEN 'report' THEN v_result:=finance_private.report(p_payload);
  WHEN 'report.detail' THEN v_result:=finance_private.report_detail(p_payload);
  WHEN 'proposal.result' THEN PERFORM finance_private.fields(p_payload,ARRAY['proposal_id']);v_result:=finance_private.proposal_result((p_payload->>'proposal_id')::uuid);
  WHEN 'proposal.context' THEN PERFORM finance_private.fields(p_payload,ARRAY['proposal_id']);v_result:=finance_private.proposal_snapshot((p_payload->>'proposal_id')::uuid);
  WHEN 'chart.accounts' THEN
   SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY code),'[]') INTO v_result FROM public.chart_of_accounts a;
  WHEN 'bank.accounts' THEN
   SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'is_active',is_active) ORDER BY name),'[]') INTO v_result FROM public.bank_accounts;
  WHEN 'product.suppliers' THEN
   PERFORM finance_private.fields(p_payload,ARRAY['product_id']);
   SELECT coalesce(jsonb_agg(jsonb_build_object('id',ps.id,'supplier_id',s.id,'name',s.name,'label',ps.label,'is_active',ps.is_active AND s.is_active,
    'reference_cost',ps.reference_cost::text,'reference_sale',ps.reference_sale::text) ORDER BY s.name,ps.id),'[]') INTO v_result
   FROM public.product_suppliers ps JOIN public.suppliers s ON s.id=ps.supplier_id WHERE product_id=(p_payload->>'product_id')::uuid;
  WHEN 'pending.items' THEN
   PERFORM finance_private.fields(p_payload,ARRAY[]::text[]);
   SELECT jsonb_build_object('legacy_titles',count(*) FILTER(WHERE NOT finance_managed),'missing_competence',count(*) FILTER(WHERE competence_date IS NULL),
    'unclassified',count(*) FILTER(WHERE account_id IS NULL),'unlinked_operation',count(*) FILTER(WHERE proposal_id IS NULL AND finance_scope<>'corporate')) INTO v_result
   FROM public.financial_transactions WHERE status NOT IN ('cancelled','canceled');
  ELSE RAISE EXCEPTION 'INVALID_REQUEST: unknown query' USING ERRCODE='22023';
 END CASE;
 RETURN jsonb_build_object('data',v_result);
END $$;
REVOKE ALL ON FUNCTION public.finance_query_v1(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.finance_query_v1(text,jsonb) TO authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
