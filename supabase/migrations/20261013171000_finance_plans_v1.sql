BEGIN;
CREATE FUNCTION finance_private.hash(p jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT encode(sha256(convert_to(p::text,'UTF8')),'hex');
$$;

CREATE FUNCTION finance_private.proposal_snapshot(pid uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT jsonb_build_object('proposal',jsonb_build_object('id',p.id,'version',p.finance_version,
 'title',p.title,'status',p.status,'segment',p.segment,'prospect_id',p.prospect_id,'seller_id',p.seller_id,
 'guide_id',p.guide_id,'total',p.total,'subtotal',p.subtotal,'num_people',p.num_people,'num_days',p.num_days,
 'discount_percent',p.discount_percent,'discount_fixed',p.discount_fixed,'tax_percent',p.tax_percent,'atmos_service',p.atmos_service,
 'notes',p.notes,'valid_until',p.valid_until,'start_date',p.start_date,'end_date',p.end_date,'language',p.language,'slug',p.slug,
 'payment_terms',p.payment_terms,'show_price_breakdown',p.show_price_breakdown,'contract_status',p.contract_status,'payment_status',p.payment_status),
 'days',coalesce((SELECT jsonb_agg(to_jsonb(d)-'created_at' ORDER BY d.day_number,d.id) FROM public.proposal_days d WHERE d.proposal_id=p.id),'[]'),
 'items',coalesce((SELECT jsonb_agg((to_jsonb(i)-'created_at')||jsonb_build_object('review_identity',public.cost_item_identity(i)) ORDER BY i.id) FROM public.proposal_day_items i WHERE i.proposal_id=p.id),'[]'),
 'costs',coalesce((SELECT jsonb_agg(to_jsonb(c)-'created_at' ORDER BY c.id) FROM public.proposal_costs c WHERE c.proposal_id=p.id),'[]'),
 'accommodations',coalesce((SELECT jsonb_agg((to_jsonb(a)-'created_at')||jsonb_build_object('review_identity',jsonb_build_object('id',a.id,'product_id',a.product_id,'supplier_id',a.supplier_id,'checkin_date',a.checkin_date,'checkout_date',a.checkout_date,'is_selected',a.is_selected,'num_nights',a.num_nights,'payment_type',a.payment_type,'rooms',a.rooms)) ORDER BY a.id) FROM public.proposal_accommodations a WHERE a.proposal_id=p.id),'[]'))
 FROM public.proposals p WHERE id=pid;
$$;

CREATE FUNCTION finance_private.accommodation_amounts(rooms jsonb,nights integer) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE units jsonb; u jsonb; r jsonb; rev numeric:=0; cost numeric:=0; comm numeric:=0;
 qty numeric; cap numeric; c numeric; pct numeric; missing integer:=0;
BEGIN
 IF nights IS NULL OR nights<0 OR nights>3660 THEN RAISE EXCEPTION 'INVALID_REQUEST: nights' USING ERRCODE='22023'; END IF;
 IF jsonb_typeof(rooms)='array' AND jsonb_array_length(rooms)>100 THEN RAISE EXCEPTION 'INVALID_REQUEST: too many room units' USING ERRCODE='22023';END IF;
 IF jsonb_typeof(rooms)='object' THEN units:=jsonb_build_array(jsonb_build_object('rooms',rooms->'modalities'));
 ELSIF jsonb_typeof(rooms)='array' THEN
  IF jsonb_array_length(rooms)=0 OR rooms->0 ? 'rooms' THEN units:=rooms;
  ELSE units:=jsonb_build_array(jsonb_build_object('rooms',rooms)); END IF;
 ELSE RAISE EXCEPTION 'INVALID_REQUEST: accommodation rooms' USING ERRCODE='22023'; END IF;
 FOR u IN SELECT value FROM jsonb_array_elements(units) LOOP
  IF jsonb_typeof(u->'rooms') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'INVALID_REQUEST: room modalities' USING ERRCODE='22023'; END IF;
  IF jsonb_array_length(u->'rooms')>100 THEN RAISE EXCEPTION 'INVALID_REQUEST: too many modalities' USING ERRCODE='22023';END IF;
  FOR r IN SELECT value FROM jsonb_array_elements(u->'rooms') LOOP
   IF NOT(coalesce((r->>'units')::numeric,0)>=0 AND coalesce((r->>'units')::numeric,0)<100000 AND coalesce((r->>'units')::numeric,0)=trunc(coalesce((r->>'units')::numeric,0))) THEN RAISE EXCEPTION 'INVALID_REQUEST: room quantity' USING ERRCODE='22023';END IF;
   IF coalesce((r->>'available')::boolean,true) AND coalesce((r->>'units')::numeric,0)>0 THEN
    qty:=(r->>'units')::numeric; cap:=CASE WHEN r->>'pricing_type'='per_person' THEN (r->>'capacity')::numeric ELSE 1 END;
    IF qty<>trunc(qty) OR cap IS NULL OR cap<=0 OR cap<>trunc(cap)
     OR NOT(coalesce((r->>'price')::numeric,-1)>=0 AND coalesce((r->>'cost')::numeric,-1)>=0)
     OR qty>=100000 OR cap>=100000 OR (r->>'price')::numeric>=100000000 OR (r->>'cost')::numeric>=100000000 THEN
     RAISE EXCEPTION 'INVALID_REQUEST: room values or occupancy' USING ERRCODE='22023';
    END IF;
    c:=round((r->>'cost')::numeric*qty*nights*cap,2);
    cost:=cost+c; rev:=rev+round((r->>'price')::numeric*qty*nights*cap,2);
    pct:=(r->>'commission_percent')::numeric;
    IF pct IS NULL THEN missing:=missing+1;
    ELSIF NOT(pct BETWEEN 0 AND 100) THEN RAISE EXCEPTION 'INVALID_REQUEST: commission percent' USING ERRCODE='22023';
    ELSE comm:=comm+c*pct/100; END IF;
   END IF;
  END LOOP;
 END LOOP;
 RETURN jsonb_build_object('revenue',rev,'cost',cost,'commission',round(comm,2),'missing_commissions',missing);
END $$;

CREATE FUNCTION finance_private.origins(pid uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE p public.proposals; i record; a record; c record; amounts jsonb; expected jsonb;
 origins jsonb:='[]'; pending jsonb:='[]'; n numeric; pct numeric;
BEGIN
 SELECT * INTO STRICT p FROM public.proposals WHERE id=pid;
 expected:=public.proposal_pricing_from_bundle(to_jsonb(p),
  coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM public.proposal_day_items x WHERE proposal_id=pid),'[]'),
  coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM public.proposal_accommodations x WHERE proposal_id=pid),'[]'));
 IF (expected->>'total')::numeric IS DISTINCT FROM p.total THEN
  pending:=pending||jsonb_build_array(jsonb_build_object('code','TOTAL_REVIEW_REQUIRED','origin','customer_principal'));
 END IF;
 IF p.total>0 THEN
  origins:=origins||jsonb_build_array(jsonb_build_object('key','customer_principal','type','receivable','origin_type','customer_principal','origin_id',pid,
   'amount',p.total::text,'prospect_id',p.prospect_id,'supplier_id',null,'seller_id',null,'description','Proposta '||coalesce(p.code,p.title)));
  IF p.prospect_id IS NULL THEN pending:=pending||jsonb_build_array(jsonb_build_object('code','PAYER_REQUIRED','origin','customer_principal')); END IF;
 END IF;
 FOR i IN SELECT * FROM public.proposal_day_items WHERE proposal_id=pid AND category<>'Hospedagens' ORDER BY id LOOP
  n:=round(i.cost_price*coalesce(i.quantity,1),2);
  IF n IS NULL OR NOT(n>=0 AND n<100000000) THEN RAISE EXCEPTION 'INVALID_REQUEST: item cost' USING ERRCODE='22023'; END IF;
  IF n>0 THEN
   origins:=origins||jsonb_build_array(jsonb_build_object('key','service_cost:'||i.id,'type','payable','origin_type','service_cost','origin_id',i.id,
    'amount',n::text,'supplier_id',i.supplier_id,'prospect_id',null,'seller_id',null,'description',coalesce(i.item_name,'Serviço')));
   IF i.supplier_id IS NULL THEN pending:=pending||jsonb_build_array(jsonb_build_object('code','SUPPLIER_REQUIRED','origin','service_cost:'||i.id)); END IF;
  END IF;
  pct:=i.commission_percent;
  IF pct IS NULL OR pct NOT BETWEEN 0 AND 100 THEN
   pending:=pending||jsonb_build_array(jsonb_build_object('code','COMMISSION_REVIEW_REQUIRED','origin','service_commission:'||i.id));
  ELSIF round(n*pct/100,2)>0 THEN
   origins:=origins||jsonb_build_array(jsonb_build_object('key','service_commission:'||i.id,'type','commission_in','origin_type','service_commission','origin_id',i.id,
    'amount',round(n*pct/100,2)::text,'supplier_id',i.supplier_id,'prospect_id',null,'seller_id',null,'description','Comissão '||coalesce(i.item_name,'Serviço')));
   IF i.supplier_id IS NULL THEN pending:=pending||jsonb_build_array(jsonb_build_object('code','SUPPLIER_REQUIRED','origin','service_commission:'||i.id)); END IF;
  END IF;
 END LOOP;
 FOR c IN SELECT * FROM public.proposal_costs WHERE proposal_id=pid ORDER BY id LOOP
  IF c.amount>0 THEN
   origins:=origins||jsonb_build_array(jsonb_build_object('key','operating_cost:'||c.id,'type','payable','origin_type','operating_cost','origin_id',c.id,
    'amount',c.amount::text,'supplier_id',c.supplier_id,'prospect_id',null,'seller_id',null,'account_id',c.account_id,'description',c.description));
   IF c.supplier_id IS NULL THEN pending:=pending||jsonb_build_array(jsonb_build_object('code','SUPPLIER_REQUIRED','origin','operating_cost:'||c.id)); END IF;
  END IF;
 END LOOP;
 FOR a IN SELECT * FROM public.proposal_accommodations WHERE proposal_id=pid AND is_selected ORDER BY id LOOP
  amounts:=finance_private.accommodation_amounts(a.rooms,a.num_nights);
  IF (amounts->>'missing_commissions')::integer>0 THEN
   pending:=pending||jsonb_build_array(jsonb_build_object('code','COMMISSION_REVIEW_REQUIRED','origin','accommodation:'||a.id));
  END IF;
  IF a.payment_type NOT IN ('atmos','hospedagem') THEN RAISE EXCEPTION 'INVALID_REQUEST: payment path' USING ERRCODE='22023'; END IF;
  IF a.payment_type='atmos' AND (amounts->>'cost')::numeric>0 THEN
   origins:=origins||jsonb_build_array(jsonb_build_object('key','accommodation_cost:'||a.id,'type','payable','origin_type','accommodation_cost','origin_id',a.id,
    'amount',amounts->>'cost','supplier_id',a.supplier_id,'prospect_id',null,'seller_id',null,'description','Hospedagem '||a.id));
  END IF;
  IF (amounts->>'commission')::numeric>0 THEN
   origins:=origins||jsonb_build_array(jsonb_build_object('key','accommodation:'||a.id,'type','commission_in','origin_type','accommodation_commission','origin_id',a.id,
    'amount',amounts->>'commission','supplier_id',a.supplier_id,'prospect_id',null,'seller_id',null,'description','Comissão hospedagem '||a.id));
  END IF;
  IF a.supplier_id IS NULL AND ((amounts->>'commission')::numeric>0 OR a.payment_type='atmos' AND (amounts->>'cost')::numeric>0) THEN
   pending:=pending||jsonb_build_array(jsonb_build_object('code','SUPPLIER_REQUIRED','origin','accommodation:'||a.id));
  END IF;
 END LOOP;
 pct:=coalesce((p.atmos_service->>'seller_commission_percent')::numeric,0);
 IF pct NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'INVALID_REQUEST: seller commission' USING ERRCODE='22023'; END IF;
 IF round(p.total*pct/100,2)>0 THEN
  origins:=origins||jsonb_build_array(jsonb_build_object('key','seller_commission','type','commission_out','origin_type','seller_commission','origin_id',pid,
   'amount',round(p.total*pct/100,2)::text,'seller_id',p.seller_id,'supplier_id',null,'prospect_id',null,'description','Comissão vendedor'));
  IF p.seller_id IS NULL THEN pending:=pending||jsonb_build_array(jsonb_build_object('code','SELLER_REQUIRED','origin','seller_commission')); END IF;
 END IF;
 -- Internal costs need a stable identity and actual beneficiary, never a fake supplier.
 FOR c IN SELECT value AS data FROM jsonb_array_elements(coalesce(p.atmos_service->'internal_costs','[]')) LOOP
  IF coalesce((c.data->>'amount')::numeric,0)>0 THEN
   IF c.data->>'id' IS NULL OR c.data->>'supplier_id' IS NULL THEN
    pending:=pending||jsonb_build_array(jsonb_build_object('code','INTERNAL_COST_REQUIRES_OBLIGATION_MAPPING','description',c.data->>'description'));
   ELSE
    origins:=origins||jsonb_build_array(jsonb_build_object('key','internal_cost:'||(c.data->>'id'),'type','payable','origin_type','internal_cost','origin_id',c.data->>'id','amount',c.data->>'amount','supplier_id',c.data->>'supplier_id','account_id',c.data->>'account_id','description',c.data->>'description'));
   END IF;
  END IF;
 END LOOP;
 RETURN jsonb_build_object('origins',origins,'pending_items',pending,'calculation_version','atmos-2026-09-v1');
END $$;

CREATE FUNCTION finance_private.preview(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE pid uuid; ver bigint; snap jsonb; derived jsonb; origin jsonb; cond jsonb; inst jsonb;
 lines jsonb:='[]'; pending jsonb; seen text[]:='{}'; nums integer[]; n integer; total numeric; expected numeric; planid uuid;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['proposal_id','expected_version','conditions']);
 pid:=(p->>'proposal_id')::uuid;
 SELECT finance_version INTO ver FROM public.proposals WHERE id=pid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF (p->>'expected_version')::bigint IS DISTINCT FROM ver THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
 IF jsonb_typeof(p->'conditions') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'conditions')>200 THEN RAISE EXCEPTION 'INVALID_REQUEST: conditions' USING ERRCODE='22023'; END IF;
 snap:=finance_private.proposal_snapshot(pid); derived:=finance_private.origins(pid); pending:=derived->'pending_items';
 IF NOT(SELECT manual_plan_confirmation FROM finance_private.settings WHERE singleton) THEN pending:=pending||jsonb_build_array(jsonb_build_object('code','DECISION_REQUIRED','decision','D01/D04','field','manual_plan_confirmation'));END IF;
 FOR cond IN SELECT value FROM jsonb_array_elements(p->'conditions') LOOP
  PERFORM finance_private.fields(cond,ARRAY['origin','installments','competence_date','account_id']);
  IF cond->>'origin' IS NULL OR cond->>'origin'=ANY(seen) THEN RAISE EXCEPTION 'INVALID_REQUEST: repeated origin' USING ERRCODE='22023'; END IF;
  seen:=array_append(seen,cond->>'origin');
  SELECT value INTO origin FROM jsonb_array_elements(derived->'origins') WHERE value->>'key'=cond->>'origin';
  IF origin IS NULL THEN RAISE EXCEPTION 'INVALID_REQUEST: unknown financial origin' USING ERRCODE='22023'; END IF;
  IF jsonb_typeof(cond->'installments') IS DISTINCT FROM 'array' OR jsonb_array_length(cond->'installments') NOT BETWEEN 1 AND 100 THEN
   RAISE EXCEPTION 'FINANCIAL_DATA_REQUIRED: installments required' USING ERRCODE='22023'; END IF;
  total:=0; nums:='{}'; n:=jsonb_array_length(cond->'installments');
  FOR inst IN SELECT value FROM jsonb_array_elements(cond->'installments') LOOP
   PERFORM finance_private.fields(inst,ARRAY['number','amount','due_date']);
   IF jsonb_typeof(inst->'number') IS DISTINCT FROM 'number' OR (inst->>'number')::numeric<>trunc((inst->>'number')::numeric)
    OR (inst->>'number')::integer NOT BETWEEN 1 AND n OR (inst->>'number')::integer=ANY(nums) THEN RAISE EXCEPTION 'INVALID_REQUEST: installment number' USING ERRCODE='22023'; END IF;
   nums:=array_append(nums,(inst->>'number')::integer);
   expected:=finance_private.money(inst->>'amount');total:=total+expected;
   IF inst->>'due_date' IS NULL THEN pending:=pending||jsonb_build_array(jsonb_build_object('code','DUE_DATE_REQUIRED','origin',origin->>'key','installment',inst->'number'));
   ELSE PERFORM finance_private.iso_date(inst->>'due_date'); END IF;
   IF cond->>'competence_date' IS NOT NULL THEN PERFORM finance_private.iso_date(cond->>'competence_date'); END IF;
   IF cond->>'account_id' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.chart_of_accounts WHERE id=(cond->>'account_id')::uuid AND is_active) THEN
    RAISE EXCEPTION 'INVALID_REQUEST: inactive or missing account' USING ERRCODE='22023'; END IF;
   lines:=lines||jsonb_build_array(origin||jsonb_build_object('installment_number',inst->'number','installment_total',n,
    'amount',expected::text,'due_date',inst->>'due_date','competence_date',cond->>'competence_date','account_id',cond->>'account_id'));
  END LOOP;
  IF total<>(origin->>'amount')::numeric THEN pending:=pending||jsonb_build_array(jsonb_build_object('code','INSTALLMENT_TOTAL_MISMATCH','origin',origin->>'key','expected',origin->>'amount','received',total::text)); END IF;
 END LOOP;
 FOR origin IN SELECT value FROM jsonb_array_elements(derived->'origins') LOOP
  IF NOT(origin->>'key'=ANY(seen)) THEN pending:=pending||jsonb_build_array(jsonb_build_object('code','CONDITIONS_REQUIRED','origin',origin->>'key')); END IF;
 END LOOP;
 IF jsonb_array_length(lines)>500 THEN RAISE EXCEPTION 'INVALID_REQUEST: too many titles' USING ERRCODE='22023'; END IF;
 INSERT INTO public.finance_plans(proposal_id,proposal_version,snapshot_hash,source_snapshot,lines,pending_items,created_by)
 VALUES(pid,ver,finance_private.hash(snap),snap,lines,pending,auth.uid()) RETURNING id INTO planid;
 RETURN jsonb_build_object('preview_id',planid,'proposal_version',ver,'plan_hash',finance_private.hash(snap||jsonb_build_object('lines',lines)),
  'lines',lines,'pending_items',pending,'ready',pending='[]'::jsonb);
END $$;

CREATE FUNCTION finance_private.confirm_plan(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE plan public.finance_plans; prop public.proposals; line jsonb; snap jsonb; tx public.financial_transactions;
 ids jsonb:='[]'; v_id uuid; key text;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['preview_id','plan_hash','expected_version','proposal_id']);
 -- Lock parent first, consistent with proposal saves and repeated confirmations.
 SELECT proposal_id INTO v_id FROM public.finance_plans WHERE finance_plans.id=(p->>'preview_id')::uuid;
 IF v_id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF p->>'proposal_id' IS NOT NULL AND (p->>'proposal_id')::uuid<>v_id THEN RAISE EXCEPTION 'INVALID_REQUEST: plan belongs to another proposal' USING ERRCODE='22023'; END IF;
 SELECT * INTO STRICT prop FROM public.proposals WHERE proposals.id=v_id FOR UPDATE;
 SELECT * INTO STRICT plan FROM public.finance_plans WHERE finance_plans.id=(p->>'preview_id')::uuid FOR UPDATE;
 IF plan.state='superseded' THEN RAISE EXCEPTION 'INVALID_TRANSITION' USING ERRCODE='55000'; END IF;
 snap:=finance_private.proposal_snapshot(prop.id);
 IF plan.snapshot_hash<>finance_private.hash(snap) OR plan.proposal_version<>prop.finance_version
  OR (p->>'expected_version')::bigint IS DISTINCT FROM prop.finance_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
 IF p->>'plan_hash' IS DISTINCT FROM finance_private.hash(snap||jsonb_build_object('lines',plan.lines)) THEN RAISE EXCEPTION 'INVALID_REQUEST: plan hash' USING ERRCODE='22023'; END IF;
 IF NOT(SELECT manual_plan_confirmation FROM finance_private.settings WHERE singleton) THEN RAISE EXCEPTION 'DECISION_REQUIRED: D01/D04 manual confirmation policy' USING ERRCODE='55000';END IF;
 IF prop.status NOT IN ('approved','accepted') THEN RAISE EXCEPTION 'INVALID_TRANSITION: approval required' USING ERRCODE='55000'; END IF;
 IF plan.pending_items<>'[]'::jsonb THEN RAISE EXCEPTION 'FINANCIAL_DATA_REQUIRED' USING ERRCODE='22023'; END IF;
 -- Null source identities are never guessed from matching descriptions/amounts.
 IF EXISTS(SELECT 1 FROM public.financial_transactions WHERE proposal_id=prop.id AND NOT finance_managed) THEN
  RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED' USING ERRCODE='55000'; END IF;
 IF EXISTS(SELECT 1 FROM public.financial_transactions t WHERE proposal_id=prop.id AND finance_managed AND source_key LIKE 'finance_v1:%' AND origin_type<>'manual' AND status NOT IN ('cancelled','canceled') AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(plan.lines) l WHERE t.source_key='finance_v1:'||(l->>'key')||':'||(l->>'installment_number'))) THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: removed obligation' USING ERRCODE='55000';END IF;
 IF plan.state='confirmed' THEN
  -- Repeated confirmations validate the complete set in one query, rather
  -- than issuing one SQL round trip per parcel while holding the parent.
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(plan.lines) l LEFT JOIN public.financial_transactions t ON t.proposal_id=prop.id AND t.source_key='finance_v1:'||(l->>'key')||':'||(l->>'installment_number')
   WHERE t.id IS NULL OR NOT t.finance_managed OR t.status IN ('cancelled','canceled')
    OR ROW(t.type,t.origin_type,t.origin_id,t.amount,t.due_date,t.supplier_id,t.prospect_id,t.seller_id,t.account_id,t.competence_date,t.installment_number,t.installment_total)
     IS DISTINCT FROM ROW(l->>'type',l->>'origin_type',l->>'origin_id',(l->>'amount')::numeric,(l->>'due_date')::date,(l->>'supplier_id')::uuid,(l->>'prospect_id')::uuid,(l->>'seller_id')::uuid,(l->>'account_id')::uuid,(l->>'competence_date')::date,(l->>'installment_number')::integer,(l->>'installment_total')::integer)) THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED' USING ERRCODE='55000';END IF;
  SELECT jsonb_agg(t.id ORDER BY l.ordinality) INTO ids FROM jsonb_array_elements(plan.lines) WITH ORDINALITY l(value,ordinality) JOIN public.financial_transactions t ON t.proposal_id=prop.id AND t.source_key='finance_v1:'||(l.value->>'key')||':'||(l.value->>'installment_number');
  RETURN jsonb_build_object('plan_id',plan.id,'transaction_ids',coalesce(ids,'[]'),'confirmed',true);
 END IF;
 FOR line IN SELECT value FROM jsonb_array_elements(plan.lines) LOOP
  key:='finance_v1:'||(line->>'key')||':'||(line->>'installment_number');
  SELECT * INTO tx FROM public.financial_transactions WHERE proposal_id=prop.id AND source_key=key FOR UPDATE;
  IF FOUND THEN
   IF NOT tx.finance_managed OR tx.origin_type IS DISTINCT FROM line->>'origin_type' OR tx.origin_id IS DISTINCT FROM line->>'origin_id'
    OR tx.status IN ('cancelled','canceled') OR tx.amount<>(line->>'amount')::numeric OR tx.due_date<>(line->>'due_date')::date
    OR tx.supplier_id IS DISTINCT FROM (line->>'supplier_id')::uuid OR tx.prospect_id IS DISTINCT FROM (line->>'prospect_id')::uuid
    OR tx.seller_id IS DISTINCT FROM (line->>'seller_id')::uuid
    OR tx.type IS DISTINCT FROM line->>'type' OR tx.account_id IS DISTINCT FROM (line->>'account_id')::uuid
    OR tx.competence_date IS DISTINCT FROM (line->>'competence_date')::date
    OR tx.installment_number IS DISTINCT FROM (line->>'installment_number')::integer
    OR tx.installment_total IS DISTINCT FROM (line->>'installment_total')::integer THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED' USING ERRCODE='55000'; END IF;
   v_id:=tx.id;
  ELSE
   -- Legacy keyed obligations must be explicitly mapped instead of duplicated.
   IF EXISTS(SELECT 1 FROM public.financial_transactions WHERE proposal_id=prop.id AND NOT finance_managed
    AND (source_key=line->>'key' OR line->>'key'='customer_principal' AND source_key='proposal_approval')) THEN
    RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED' USING ERRCODE='55000'; END IF;
   INSERT INTO public.financial_transactions(type,description,amount,due_date,competence_date,status,proposal_id,supplier_id,prospect_id,seller_id,
    account_id,source_key,installment_number,installment_total,finance_managed,origin_type,origin_id,source_snapshot,finance_scope)
   VALUES(line->>'type',line->>'description',(line->>'amount')::numeric,(line->>'due_date')::date,(line->>'competence_date')::date,'pending',prop.id,
    (line->>'supplier_id')::uuid,(line->>'prospect_id')::uuid,(line->>'seller_id')::uuid,(line->>'account_id')::uuid,key,
    (line->>'installment_number')::integer,(line->>'installment_total')::integer,true,line->>'origin_type',line->>'origin_id',line,'operation')
   RETURNING financial_transactions.id INTO v_id;
  END IF;
  ids:=ids||jsonb_build_array(v_id);
 END LOOP;
 IF EXISTS(SELECT 1 FROM public.financial_transactions t WHERE proposal_id=prop.id AND finance_managed AND source_key LIKE 'finance_v1:%'
  AND origin_type<>'manual' AND NOT(t.id::text IN (SELECT jsonb_array_elements_text(ids))) AND t.status NOT IN ('cancelled','canceled')) THEN
  RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: removed obligation' USING ERRCODE='55000'; END IF;
 UPDATE public.finance_plans SET state='confirmed',confirmed_at=coalesce(confirmed_at,now()) WHERE finance_plans.id=plan.id;
 RETURN jsonb_build_object('plan_id',plan.id,'transaction_ids',ids,'confirmed',true);
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
