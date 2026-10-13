-- Derived from the installed d8c57c2 bundle including module/identity/privacy guards.
-- Finance v1 removes automatic commission writes; plan confirmation owns them.
BEGIN;
CREATE FUNCTION finance_private.apply_bundle_v1(p_id uuid, p_proposal jsonb, p_items jsonb, p_costs jsonb, p_days jsonb, p_accommodations jsonb, p_commissions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_id uuid;
  v_final_items jsonb;
  v_final_accommodations jsonb;
  v_check public.proposal_cost_checks;
  v_before public.proposal_day_items;
  v_after public.proposal_day_items;
  v_legacy boolean;
  v_tx public.financial_transactions;
  v_comm jsonb;
  v_prospect public.prospects;
  v_name text;
  v_current public.proposals;
  v_row jsonb;
  v_ids uuid[];
  v_child_ids jsonb := '{}'::jsonb;
  v_sources text[] := '{}'::text[];
  v_source text;
  v_child_id uuid;
  v_item public.proposal_day_items;
  v_cost public.proposal_costs;
  v_day public.proposal_days;
  v_acc public.proposal_accommodations;
BEGIN
  PERFORM public.require_admin_bundle_access(p_id,p_proposal,p_commissions);
  IF NOT public.has_role(auth.uid(), 'admin'::public.app_role) THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_proposal) IS DISTINCT FROM 'object'
    OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
    OR jsonb_typeof(p_costs) IS DISTINCT FROM 'array'
    OR jsonb_typeof(p_days) IS DISTINCT FROM 'array'
    OR jsonb_typeof(p_accommodations) IS DISTINCT FROM 'array'
    OR jsonb_typeof(p_commissions) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Complete proposal bundle required';
  END IF;
  -- Explicit boolean only. Missing means leave UPDATE unchanged / use CREATE default.
  IF p_proposal ? 'show_price_breakdown' AND jsonb_typeof(p_proposal->'show_price_breakdown') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'show_price_breakdown must be boolean' USING ERRCODE = '22023';
  END IF;
  -- Validate before any writes and even when legacy financial rows suspend synchronization.
  FOR v_comm IN SELECT value FROM jsonb_array_elements(p_commissions) LOOP
    IF jsonb_typeof(v_comm) IS DISTINCT FROM 'object'
      OR jsonb_typeof(v_comm->'source_key') IS DISTINCT FROM 'string'
      OR jsonb_typeof(v_comm->'amount') IS DISTINCT FROM 'number'
      OR jsonb_typeof(v_comm->'description') IS DISTINCT FROM 'string'
      OR jsonb_typeof(v_comm->'due_date') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'Commission fields must be present and non-null' USING ERRCODE = '22023';
    END IF;
    v_source := v_comm->>'source_key';
    IF v_source !~ '^accommodation:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      OR (v_comm->>'amount')::numeric <= 0 OR btrim(v_comm->>'description') = ''
      OR (v_comm->>'due_date') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
      RAISE EXCEPTION 'Invalid commission values' USING ERRCODE = '22023';
    END IF;
    PERFORM (v_comm->>'due_date')::date;
    IF v_source = ANY(v_sources) THEN
      RAISE EXCEPTION 'Duplicate commission source_key' USING ERRCODE = '22023';
    END IF;
    v_sources := array_append(v_sources, v_source);
    IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_accommodations) a
      WHERE (a->>'id')::uuid = substring(v_source from 15)::uuid
        AND (a->>'is_selected')::boolean IS TRUE AND a->>'payment_type' = 'hospedagem') THEN
      RAISE EXCEPTION 'Commission source must identify a selected supplier-paid accommodation in this bundle' USING ERRCODE = '22023';
    END IF;
  END LOOP;
  -- Serialize with other bundle/visual saves, then inspect the persisted identity BEFORE writes.
  IF p_id IS NOT NULL THEN
    SELECT * INTO STRICT v_current FROM public.proposals WHERE id = p_id FOR UPDATE;
    PERFORM 1 FROM public.proposal_cost_checks WHERE proposal_id=p_id FOR UPDATE;
  END IF;
  -- Resolve omitted fields exactly like the upsert below; p_items is the complete final collection.
  SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_final_items
  FROM jsonb_array_elements(p_items) r
  LEFT JOIN public.proposal_day_items old ON old.proposal_id=p_id AND old.id=(r->>'id')::uuid
  CROSS JOIN LATERAL jsonb_populate_record(old, r) x;
  IF EXISTS(SELECT 1 FROM jsonb_to_recordset(v_final_items) AS x(day_number integer,item_index integer)
    GROUP BY day_number,item_index HAVING count(*) > 1)
    OR EXISTS(SELECT 1 FROM jsonb_to_recordset(v_final_items) AS x(day_number integer,item_index integer)
      WHERE day_number IS NULL OR item_index IS NULL) THEN
    RAISE EXCEPTION 'Dois itens ocupam o mesmo dia/posição ou possuem posição ausente. Desmarque eventuais conferências antes de corrigir a composição e confira novamente os itens corretos.' USING ERRCODE='22023';
  END IF;
  FOR v_check IN SELECT * FROM public.proposal_cost_checks
    WHERE proposal_id=p_id AND is_verified AND day_number >= 0 LOOP
    IF (SELECT count(*) FROM public.proposal_day_items WHERE proposal_id=p_id
      AND day_number=v_check.day_number AND item_index=v_check.item_index) IS DISTINCT FROM 1
      OR (SELECT count(*) FROM jsonb_populate_recordset(NULL::public.proposal_day_items,v_final_items)
        WHERE day_number=v_check.day_number AND item_index=v_check.item_index) IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'Item com custo conferido removido, movido ou ambíguo. Desmarque a conferência antes de alterar e confira novamente o custo do item correto.' USING ERRCODE='55000';
    END IF;
    SELECT * INTO STRICT v_before FROM public.proposal_day_items WHERE proposal_id=p_id
      AND day_number=v_check.day_number AND item_index=v_check.item_index;
    SELECT * INTO STRICT v_after FROM jsonb_populate_recordset(NULL::public.proposal_day_items,v_final_items)
      WHERE day_number=v_check.day_number AND item_index=v_check.item_index;
    IF v_check.item_id IS NOT NULL AND (v_check.item_id IS DISTINCT FROM v_before.id
      OR (v_check.identity_snapshot-'quantity') IS DISTINCT FROM (public.cost_item_identity(v_before)-'quantity')) THEN
      RAISE EXCEPTION 'Conferência com identidade antiga. Desmarque preservando histórico e confira novamente.' USING ERRCODE='55000';
    END IF;
    IF ROW(v_before.id,v_before.day_number,v_before.item_index,v_before.catalog_item_id,v_before.variation_id,v_before.category,v_before.supplier_id,coalesce(v_before.vehicle_type,'carroTurista'))
      IS DISTINCT FROM ROW(v_after.id,v_after.day_number,v_after.item_index,v_after.catalog_item_id,v_after.variation_id,v_after.category,v_after.supplier_id,coalesce(v_after.vehicle_type,'carroTurista')) THEN
      RAISE EXCEPTION 'Identidade de item com custo conferido alterada. Desmarque a conferência antes de alterar e confira novamente o custo do item correto.' USING ERRCODE='55000';
    END IF;
  END LOOP;
  -- Quantity is intentionally not identity: existing unit/total pricing semantics remain unchanged.
  -- Compute from resolved snapshot fields, under the same proposal lock.
  -- Preserve omission semantics for unrelated proposal fields (including privacy).
  SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_final_accommodations
  FROM jsonb_array_elements(p_accommodations) r
  LEFT JOIN public.proposal_accommodations old ON old.proposal_id=p_id AND old.id=(r->>'id')::uuid
  CROSS JOIN LATERAL jsonb_populate_record(old, r) x;
  p_proposal := p_proposal || public.proposal_pricing_from_bundle(
    coalesce(to_jsonb(v_current), '{}'::jsonb) || p_proposal, v_final_items, v_final_accommodations);
  IF p_id IS NULL THEN
    INSERT INTO public.proposals (title, status, segment, contract_status, payment_status, prospect_id, seller_id, guide_id, subtotal, discount_percent, discount_fixed, tax_percent, total, notes, valid_until, num_people, num_days, start_date, end_date, language, atmos_service, slug, payment_terms)
      SELECT title, status, segment, contract_status, payment_status, prospect_id, seller_id, guide_id, subtotal, discount_percent, discount_fixed, tax_percent, total, notes, valid_until, num_people, num_days, start_date, end_date, language, atmos_service, slug, payment_terms FROM jsonb_populate_record(NULL::public.proposals, p_proposal)
      RETURNING id INTO v_id;
  ELSE
    v_id := v_current.id;
    UPDATE public.proposals SET (title, status, segment, contract_status, payment_status, prospect_id, seller_id, guide_id, subtotal, discount_percent, discount_fixed, tax_percent, total, notes, valid_until, num_people, num_days, start_date, end_date, language, atmos_service, slug, payment_terms) =
      (SELECT title, status, segment, contract_status, payment_status, prospect_id, seller_id, guide_id, subtotal, discount_percent, discount_fixed, tax_percent, total, notes, valid_until, num_people, num_days, start_date, end_date, language, atmos_service, slug, payment_terms FROM jsonb_populate_record(v_current, p_proposal)) WHERE id = v_id;
  END IF;
  IF p_proposal ? 'show_price_breakdown' THEN
    IF NOT EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'proposals' AND column_name = 'show_price_breakdown') THEN
      RAISE EXCEPTION 'Apply the show_price_breakdown migration before saving this setting' USING ERRCODE = '42703';
    END IF;
    EXECUTE 'UPDATE public.proposals SET show_price_breakdown = $1 WHERE id = $2'
      USING (p_proposal->>'show_price_breakdown')::boolean, v_id;
  END IF;
  -- Upsert stable IDs; update only editor-owned fields. Public observations, flags and metadata survive.
  v_ids := '{}'::uuid[];
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_item := NULL;
    SELECT * INTO v_item FROM public.proposal_day_items WHERE proposal_id = v_id AND id = (v_row->>'id')::uuid;
    v_child_id := coalesce(v_item.id, (v_row->>'id')::uuid, gen_random_uuid());
    IF EXISTS(SELECT 1 FROM public.proposal_day_items WHERE id = v_child_id AND proposal_id <> v_id) THEN
      RAISE EXCEPTION 'Child belongs to another proposal';
    END IF;
    IF v_child_id = ANY(v_ids) THEN RAISE EXCEPTION 'Duplicate child ID'; END IF;
    INSERT INTO public.proposal_day_items(id, proposal_id, day_number, day_label, category, item_name, value, value_text, description, catalog_item_id, variation_id, item_index, vehicle_type, quantity, cost_price, commission_percent, supplier_id, start_time, end_time)
      SELECT v_child_id, v_id, x.day_number, x.day_label, x.category, x.item_name, x.value, x.value_text, x.description, x.catalog_item_id, x.variation_id, x.item_index, x.vehicle_type, x.quantity, x.cost_price, x.commission_percent, x.supplier_id, x.start_time, x.end_time
      FROM jsonb_populate_record(v_item, v_row) x
      WHERE true
      ON CONFLICT(id) DO UPDATE SET day_number = EXCLUDED.day_number, day_label = EXCLUDED.day_label, category = EXCLUDED.category, item_name = EXCLUDED.item_name, value = EXCLUDED.value, value_text = EXCLUDED.value_text, description = EXCLUDED.description, catalog_item_id = EXCLUDED.catalog_item_id, variation_id = EXCLUDED.variation_id, item_index = EXCLUDED.item_index, vehicle_type = EXCLUDED.vehicle_type, quantity = EXCLUDED.quantity, cost_price = EXCLUDED.cost_price, commission_percent = EXCLUDED.commission_percent, supplier_id = EXCLUDED.supplier_id, start_time = EXCLUDED.start_time, end_time = EXCLUDED.end_time;
    v_ids := array_append(v_ids, v_child_id);
  END LOOP;
  DELETE FROM public.proposal_day_items WHERE proposal_id = v_id AND NOT(id = ANY(v_ids));
  v_child_ids := v_child_ids || jsonb_build_object('items', to_jsonb(v_ids));
  v_ids := '{}'::uuid[];
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_costs) LOOP
    v_cost := NULL;
    SELECT * INTO v_cost FROM public.proposal_costs WHERE proposal_id = v_id AND id = (v_row->>'id')::uuid;
    v_child_id := coalesce(v_cost.id, (v_row->>'id')::uuid, gen_random_uuid());
    IF EXISTS(SELECT 1 FROM public.proposal_costs WHERE id = v_child_id AND proposal_id <> v_id) THEN
      RAISE EXCEPTION 'Child belongs to another proposal';
    END IF;
    IF v_child_id = ANY(v_ids) THEN RAISE EXCEPTION 'Duplicate child ID'; END IF;
    INSERT INTO public.proposal_costs(id, proposal_id, description, amount, account_id, supplier_id)
      SELECT v_child_id, v_id, x.description, x.amount, x.account_id, x.supplier_id
      FROM jsonb_populate_record(v_cost, v_row) x
      WHERE true
      ON CONFLICT(id) DO UPDATE SET description = EXCLUDED.description, amount = EXCLUDED.amount, account_id = EXCLUDED.account_id, supplier_id = EXCLUDED.supplier_id;
    v_ids := array_append(v_ids, v_child_id);
  END LOOP;
  DELETE FROM public.proposal_costs WHERE proposal_id = v_id AND NOT(id = ANY(v_ids));
  v_child_ids := v_child_ids || jsonb_build_object('costs', to_jsonb(v_ids));
  v_ids := '{}'::uuid[];
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_days) LOOP
    v_day := NULL;
    SELECT * INTO v_day FROM public.proposal_days WHERE proposal_id = v_id AND day_number = (v_row->>'day_number')::integer;
    v_child_id := coalesce(v_day.id, (v_row->>'id')::uuid, gen_random_uuid());
    IF EXISTS(SELECT 1 FROM public.proposal_days WHERE id = v_child_id AND proposal_id <> v_id) THEN
      RAISE EXCEPTION 'Child belongs to another proposal';
    END IF;
    IF v_child_id = ANY(v_ids) THEN RAISE EXCEPTION 'Duplicate child ID'; END IF;
    INSERT INTO public.proposal_days(id, proposal_id, day_number, description)
      SELECT v_child_id, v_id, x.day_number, x.description
      FROM jsonb_populate_record(v_day, v_row) x
      WHERE true
      ON CONFLICT(id) DO UPDATE SET day_number = EXCLUDED.day_number, description = EXCLUDED.description;
    v_ids := array_append(v_ids, v_child_id);
  END LOOP;
  DELETE FROM public.proposal_days WHERE proposal_id = v_id AND NOT(id = ANY(v_ids));
  v_child_ids := v_child_ids || jsonb_build_object('days', to_jsonb(v_ids));
  v_ids := '{}'::uuid[];
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_accommodations) LOOP
    v_acc := NULL;
    SELECT * INTO v_acc FROM public.proposal_accommodations WHERE proposal_id = v_id AND id = (v_row->>'id')::uuid;
    v_child_id := coalesce(v_acc.id, (v_row->>'id')::uuid, gen_random_uuid());
    IF EXISTS(SELECT 1 FROM public.proposal_accommodations WHERE id = v_child_id AND proposal_id <> v_id) THEN
      RAISE EXCEPTION 'Child belongs to another proposal';
    END IF;
    IF v_child_id = ANY(v_ids) THEN RAISE EXCEPTION 'Duplicate child ID'; END IF;
    INSERT INTO public.proposal_accommodations(id, proposal_id, product_id, checkin_date, checkout_date, num_nights, notes, is_selected, payment_type, rooms, supplier_id)
      SELECT v_child_id, v_id, x.product_id, x.checkin_date, x.checkout_date, x.num_nights, x.notes, x.is_selected, x.payment_type, x.rooms, x.supplier_id
      FROM jsonb_populate_record(v_acc, v_row) x
      WHERE true
      ON CONFLICT(id) DO UPDATE SET product_id = EXCLUDED.product_id, checkin_date = EXCLUDED.checkin_date, checkout_date = EXCLUDED.checkout_date, num_nights = EXCLUDED.num_nights, notes = EXCLUDED.notes, is_selected = EXCLUDED.is_selected, payment_type = EXCLUDED.payment_type, rooms = EXCLUDED.rooms, supplier_id = EXCLUDED.supplier_id;
    v_ids := array_append(v_ids, v_child_id);
  END LOOP;
  DELETE FROM public.proposal_accommodations WHERE proposal_id = v_id AND NOT(id = ANY(v_ids));
  v_child_ids := v_child_ids || jsonb_build_object('accommodations', to_jsonb(v_ids));

  -- Finance v1 saves the negotiated snapshot only. Obligations are created
  -- exclusively by explicit preview/confirmation with negotiated conditions.
  SELECT EXISTS(SELECT 1 FROM public.financial_transactions WHERE proposal_id=v_id AND NOT finance_managed) INTO v_legacy;

  -- Preserve the editor's existing related-record synchronization in this transaction.
  IF p_proposal->>'prospect_id' IS NOT NULL THEN
    SELECT * INTO v_prospect FROM public.prospects WHERE id = (p_proposal->>'prospect_id')::uuid;
    v_name := substring(p_proposal->>'title' from '^Proposta\s*[—–-]\s*(.+)$');
    IF v_name IS NOT NULL THEN UPDATE public.prospects SET name = btrim(v_name) WHERE id = v_prospect.id; END IF;
    IF v_prospect.email IS NOT NULL THEN
      IF v_prospect.segment = 'b2c' THEN
        UPDATE public.quote_requests SET answers = coalesce(answers, '{}'::jsonb) || jsonb_build_object(
          'groupSize', p_proposal->>'num_people', 'numDays', p_proposal->>'num_days',
          'startDate', coalesce(p_proposal->>'start_date', answers->>'startDate', ''),
          'endDate', coalesce(p_proposal->>'end_date', answers->>'endDate', ''))
          WHERE id = (SELECT id FROM public.quote_requests WHERE lower(btrim(user_email)) = lower(btrim(v_prospect.email)) ORDER BY created_at DESC, id DESC LIMIT 1);
      ELSE
        UPDATE public.imersao_leads SET num_participantes = p_proposal->>'num_people',
          data_especifica = (p_proposal->>'start_date')::date, data_especifica_fim = (p_proposal->>'end_date')::date
          WHERE id = (SELECT id FROM public.imersao_leads WHERE lower(btrim(email)) = lower(btrim(v_prospect.email)) ORDER BY created_at DESC, id DESC LIMIT 1);
      END IF;
    END IF;
  END IF;
  RETURN jsonb_build_object('id', v_id, 'legacy_commissions', v_legacy, 'child_ids', v_child_ids);
END;
$function$;
REVOKE ALL ON FUNCTION finance_private.apply_bundle_v1(uuid,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb) FROM PUBLIC,anon,authenticated;

CREATE TABLE public.finance_cost_reviews (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), proposal_id uuid NOT NULL REFERENCES public.proposals(id) ON DELETE RESTRICT,
 entity_kind text NOT NULL CHECK(entity_kind IN ('item','accommodation')), entity_id uuid NOT NULL,
 before_value jsonb NOT NULL, after_value jsonb NOT NULL, reason text NOT NULL,
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.finance_cost_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_cost_reviews FROM anon,authenticated;
GRANT SELECT ON public.finance_cost_reviews TO authenticated;
CREATE POLICY finance_review_read ON public.finance_cost_reviews FOR SELECT TO authenticated USING(public.has_admin_module('financeiro'));
CREATE TRIGGER finance_review_command_only BEFORE INSERT OR UPDATE OR DELETE ON public.finance_cost_reviews FOR EACH ROW EXECUTE FUNCTION finance_private.command_only();

CREATE FUNCTION finance_private.capture_snapshot() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_reference jsonb;v_snapshot jsonb;
BEGIN
 IF TG_TABLE_NAME='proposal_day_items' THEN
  IF TG_OP='INSERT' OR OLD.catalog_item_id IS DISTINCT FROM NEW.catalog_item_id THEN
   SELECT jsonb_build_object('product_id',p.id,'name',p.name,'pricing_type',p.variables->>'pricingType','catalogue_cost',p.cost_price,'catalogue_sale',p.unit_price)
    INTO v_reference FROM public.products p WHERE id=NEW.catalog_item_id;
  ELSE v_reference:=OLD.finance_snapshot->'catalogue_reference';END IF;
  v_snapshot:=jsonb_build_object('snapshot_version','finance-v1','catalogue_reference',v_reference,'catalog_item_id',NEW.catalog_item_id,
   'variation_id',NEW.variation_id,'supplier_id',NEW.supplier_id,'vehicle_type',NEW.vehicle_type,'category',NEW.category,
   'quantity',NEW.quantity,'unit_cost',NEW.cost_price,'unit_sale',NEW.value,'commission_percent',NEW.commission_percent,
   'stored_price_basis','unit_per_quantity');
 ELSE
  IF TG_OP='INSERT' OR OLD.product_id IS DISTINCT FROM NEW.product_id THEN
   SELECT jsonb_build_object('product_id',p.id,'name',p.name,'pricing_type',p.variables->>'pricingType','catalogue_cost',p.cost_price,'catalogue_sale',p.unit_price) INTO v_reference FROM public.products p WHERE id=NEW.product_id;
  ELSE v_reference:=OLD.finance_snapshot->'catalogue_reference';END IF;
  v_snapshot:=jsonb_build_object('snapshot_version','finance-v1','catalogue_reference',v_reference,'checkin_date',NEW.checkin_date,'checkout_date',NEW.checkout_date,'product_id',NEW.product_id,'supplier_id',NEW.supplier_id,
   'num_nights',NEW.num_nights,'payment_type',NEW.payment_type,'rooms',NEW.rooms,'is_selected',NEW.is_selected);
 END IF;
 NEW.finance_snapshot:=v_snapshot;RETURN NEW;
END $$;
CREATE TRIGGER finance_capture_snapshot BEFORE INSERT OR UPDATE ON public.proposal_day_items FOR EACH ROW EXECUTE FUNCTION finance_private.capture_snapshot();
CREATE TRIGGER finance_capture_snapshot BEFORE INSERT OR UPDATE ON public.proposal_accommodations FOR EACH ROW EXECUTE FUNCTION finance_private.capture_snapshot();
CREATE TRIGGER finance_check_version BEFORE INSERT OR UPDATE OR DELETE ON public.proposal_cost_checks FOR EACH ROW EXECUTE FUNCTION finance_private.child_version();

CREATE FUNCTION finance_private.unit_money(p text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
BEGIN
 IF p IS NULL OR p !~ '^(0|[1-9][0-9]{0,7})(\.[0-9]{1,8})?$' OR p::numeric>=100000000 THEN RAISE EXCEPTION 'INVALID_REQUEST: finite nonnegative unit amount required' USING ERRCODE='22023';END IF;
 RETURN p::numeric;
END $$;
CREATE FUNCTION finance_private.percent(p text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
BEGIN
 IF p IS NULL OR p !~ '^(0|[1-9][0-9]{0,2})(\.[0-9]{1,2})?$' OR p::numeric>100 THEN RAISE EXCEPTION 'INVALID_REQUEST: percent from zero to one hundred required' USING ERRCODE='22023';END IF;
 RETURN p::numeric;
END $$;
CREATE TABLE public.finance_accommodation_checks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),proposal_id uuid NOT NULL REFERENCES public.proposals(id) ON DELETE RESTRICT,
 entity_id uuid NOT NULL,identity_snapshot jsonb NOT NULL,review_id uuid NOT NULL REFERENCES public.finance_cost_reviews(id) ON DELETE RESTRICT,
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,created_at timestamptz NOT NULL DEFAULT now(),
 released_at timestamptz,released_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,release_reason text,
 CHECK((released_at IS NULL AND released_by IS NULL AND release_reason IS NULL) OR (released_at IS NOT NULL AND released_by IS NOT NULL AND length(btrim(release_reason))>0))
);
CREATE UNIQUE INDEX finance_active_accommodation_check ON public.finance_accommodation_checks(entity_id) WHERE released_at IS NULL;
ALTER TABLE public.finance_accommodation_checks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_accommodation_checks FROM anon,authenticated;
GRANT SELECT ON public.finance_accommodation_checks TO authenticated;
CREATE POLICY finance_hotel_check_read ON public.finance_accommodation_checks FOR SELECT TO authenticated USING(public.has_admin_module('financeiro'));
CREATE TRIGGER finance_hotel_check_command_only BEFORE INSERT OR UPDATE OR DELETE ON public.finance_accommodation_checks FOR EACH ROW EXECUTE FUNCTION finance_private.command_only();
CREATE TRIGGER finance_hotel_check_version BEFORE INSERT OR UPDATE OR DELETE ON public.finance_accommodation_checks FOR EACH ROW EXECUTE FUNCTION finance_private.child_version();
CREATE FUNCTION finance_private.hotel_identity(a public.proposal_accommodations) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('id',a.id,'product_id',a.product_id,'supplier_id',a.supplier_id,'checkin_date',a.checkin_date,'checkout_date',a.checkout_date,'is_selected',a.is_selected,'num_nights',a.num_nights,'payment_type',a.payment_type,'rooms',a.rooms);
$$;

CREATE FUNCTION finance_private.save_proposal(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_id uuid:=(p->>'proposal_id')::uuid;v_version bigint;v_proposal jsonb:=p->'proposal';v_row jsonb;v_child jsonb;v_key text;v_check record;v_acc public.proposal_accommodations;v_result jsonb;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['proposal_id','expected_version','proposal','items','costs','days','accommodations']);
 PERFORM finance_private.fields(v_proposal,ARRAY['title','segment','prospect_id','seller_id','guide_id','discount_percent','discount_fixed','tax_percent',
  'notes','valid_until','num_people','num_days','start_date','end_date','language','atmos_service','slug','payment_terms','show_price_breakdown']);
 IF v_id IS NOT NULL THEN
  SELECT finance_version INTO v_version FROM public.proposals WHERE id=v_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
  IF (p->>'expected_version')::bigint IS DISTINCT FROM v_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
 ELSE
  v_proposal:=jsonb_build_object('status','draft','segment','b2c','language','pt','num_people',1,'num_days',1,
   'discount_percent',0,'discount_fixed',0,'tax_percent',0,'atmos_service',jsonb_build_object('price_per_person_day',0,'internal_costs','[]'::jsonb))||v_proposal;
 END IF;
 IF jsonb_typeof(p->'items') IS DISTINCT FROM 'array' OR jsonb_typeof(p->'costs') IS DISTINCT FROM 'array'
  OR jsonb_typeof(p->'days') IS DISTINCT FROM 'array' OR jsonb_typeof(p->'accommodations') IS DISTINCT FROM 'array'
  OR jsonb_array_length(p->'days')>366 OR jsonb_array_length(p->'items')>200 OR jsonb_array_length(p->'costs')>200 OR jsonb_array_length(p->'accommodations')>100 THEN RAISE EXCEPTION 'INVALID_REQUEST: full bounded composition required' USING ERRCODE='22023'; END IF;
 FOREACH v_key IN ARRAY ARRAY['discount_percent','tax_percent'] LOOP IF v_proposal ? v_key THEN PERFORM finance_private.percent(v_proposal->>v_key);END IF;END LOOP;
 IF v_proposal ? 'discount_fixed' THEN PERFORM finance_private.money(v_proposal->>'discount_fixed',true);END IF;
 FOREACH v_key IN ARRAY ARRAY['valid_until','start_date','end_date'] LOOP IF v_proposal->>v_key IS NOT NULL THEN PERFORM finance_private.iso_date(v_proposal->>v_key);END IF;END LOOP;
 IF v_proposal ? 'atmos_service' THEN
  v_child:=v_proposal->'atmos_service';
  PERFORM finance_private.fields(v_child,ARRAY['price_per_person_day','description','num_courtesies','seller_commission_percent','internal_costs']);
  PERFORM finance_private.unit_money(v_child->>'price_per_person_day');
  IF v_child ? 'seller_commission_percent' THEN PERFORM finance_private.percent(v_child->>'seller_commission_percent');END IF;
  IF jsonb_typeof(coalesce(v_child->'internal_costs','[]')) IS DISTINCT FROM 'array' OR jsonb_array_length(coalesce(v_child->'internal_costs','[]'))>200 THEN RAISE EXCEPTION 'INVALID_REQUEST: internal costs' USING ERRCODE='22023';END IF;
  FOR v_row IN SELECT value FROM jsonb_array_elements(coalesce(v_child->'internal_costs','[]')) LOOP
   PERFORM finance_private.fields(v_row,ARRAY['id','description','amount','days','unit_amount','supplier_id','account_id']);PERFORM finance_private.money(v_row->>'amount',true);
   IF v_row ? 'unit_amount' THEN PERFORM finance_private.unit_money(v_row->>'unit_amount');END IF;
  END LOOP;
 END IF;
 FOR v_row IN SELECT value FROM jsonb_array_elements(p->'days') LOOP
  PERFORM finance_private.fields(v_row,ARRAY['id','day_number','description']);
  IF v_row->>'day_number' IS NULL OR v_row->>'day_number' !~ '^[0-9]{1,3}$' THEN RAISE EXCEPTION 'INVALID_REQUEST: day' USING ERRCODE='22023';END IF;
 END LOOP;
 FOR v_row IN SELECT value FROM jsonb_array_elements(p->'items') LOOP
  PERFORM finance_private.fields(v_row,ARRAY['id','day_number','day_label','category','item_name','value','value_text','description','catalog_item_id','variation_id','item_index',
   'vehicle_type','quantity','cost_price','commission_percent','supplier_id','start_time','end_time']);
  PERFORM finance_private.unit_money(v_row->>'value');PERFORM finance_private.unit_money(v_row->>'cost_price');PERFORM finance_private.percent(v_row->>'commission_percent');
  IF v_row->>'quantity' IS NULL OR v_row->>'quantity' !~ '^[1-9][0-9]{0,4}$' OR v_row->>'day_number' IS NULL OR v_row->>'day_number' !~ '^[0-9]{1,3}$' OR v_row->>'item_index' IS NULL OR v_row->>'item_index' !~ '^[0-9]{1,3}$' OR length(coalesce(v_row->>'category','')) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'INVALID_REQUEST: item identity/quantity' USING ERRCODE='22023';END IF;
 END LOOP;
 FOR v_row IN SELECT value FROM jsonb_array_elements(p->'costs') LOOP
  PERFORM finance_private.fields(v_row,ARRAY['id','description','amount','account_id','supplier_id']);PERFORM finance_private.money(v_row->>'amount',true);
 END LOOP;
 FOR v_row IN SELECT value FROM jsonb_array_elements(p->'accommodations') LOOP
  PERFORM finance_private.fields(v_row,ARRAY['id','product_id','supplier_id','checkin_date','checkout_date','num_nights','notes','is_selected','payment_type','rooms']);
  IF v_row->>'payment_type' IS NULL OR v_row->>'payment_type' NOT IN ('atmos','hospedagem') OR jsonb_typeof(v_row->'is_selected') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'INVALID_REQUEST: hotel path/selection' USING ERRCODE='22023';END IF;
  IF v_row->>'checkin_date' IS NOT NULL THEN PERFORM finance_private.iso_date(v_row->>'checkin_date');END IF;IF v_row->>'checkout_date' IS NOT NULL THEN PERFORM finance_private.iso_date(v_row->>'checkout_date');END IF;
  IF (v_row->>'checkout_date')::date < (v_row->>'checkin_date')::date THEN RAISE EXCEPTION 'INVALID_REQUEST: checkout precedes checkin' USING ERRCODE='22023';END IF;
  PERFORM finance_private.accommodation_amounts(v_row->'rooms',(v_row->>'num_nights')::integer);
 END LOOP;
 FOR v_check IN SELECT * FROM public.finance_accommodation_checks WHERE proposal_id=v_id AND released_at IS NULL LOOP
  SELECT value INTO v_row FROM jsonb_array_elements(p->'accommodations') WHERE (value->>'id')::uuid=v_check.entity_id;
  SELECT * INTO v_acc FROM public.proposal_accommodations WHERE id=v_check.entity_id AND proposal_id=v_id;
  IF v_row IS NULL OR v_acc.id IS NULL OR finance_private.hotel_identity(v_acc) IS DISTINCT FROM v_check.identity_snapshot OR finance_private.hotel_identity(jsonb_populate_record(v_acc,v_row)) IS DISTINCT FROM v_check.identity_snapshot THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: release accommodation check before changing identity/composition' USING ERRCODE='55000';END IF;
 END LOOP;
 v_result:=finance_private.apply_bundle_v1(v_id,v_proposal,p->'items',p->'costs',p->'days',p->'accommodations','[]');
 v_id:=(v_result->>'id')::uuid;
 IF p->>'proposal_id' IS NULL THEN UPDATE public.proposals SET created_by=auth.uid() WHERE id=v_id;END IF;
 RETURN v_result||jsonb_build_object('version',(SELECT finance_version FROM public.proposals WHERE id=v_id),'financial_generation','explicit_plan_only');
END $$;

CREATE FUNCTION finance_private.review_cost_sale(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_prop public.proposals;v_item public.proposal_day_items;v_acc public.proposal_accommodations;v_before jsonb;v_after jsonb;v_identity jsonb;v_rev uuid;v_totals jsonb;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['proposal_id','expected_version','entity_kind','entity_id','expected_snapshot','unit_cost','unit_sale','rooms','reason']);
 SELECT * INTO v_prop FROM public.proposals WHERE id=(p->>'proposal_id')::uuid FOR UPDATE;
 IF v_prop.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF NOT public.has_admin_segment(v_prop.segment) THEN RAISE EXCEPTION 'MODULE_FORBIDDEN: commercial segment required to revise costs and sale' USING ERRCODE='42501'; END IF;
 IF (p->>'expected_version')::bigint IS DISTINCT FROM v_prop.finance_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
 IF length(btrim(coalesce(p->>'reason','')))=0 THEN RAISE EXCEPTION 'INVALID_REQUEST: review reason' USING ERRCODE='22023'; END IF;
 IF p->>'entity_kind'='item' THEN
  SELECT * INTO v_item FROM public.proposal_day_items WHERE proposal_id=v_prop.id AND id=(p->>'entity_id')::uuid FOR UPDATE;
  IF v_item.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
  v_identity:=public.cost_item_identity(v_item);
  IF p->'expected_snapshot' IS DISTINCT FROM v_identity THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
  v_before:=to_jsonb(v_item);
  UPDATE public.proposal_day_items SET cost_price=finance_private.unit_money(p->>'unit_cost'),value=finance_private.unit_money(p->>'unit_sale') WHERE id=v_item.id;
  SELECT * INTO v_item FROM public.proposal_day_items WHERE id=v_item.id;
  PERFORM public.save_proposal_cost_checks(v_prop.id,jsonb_build_array(jsonb_build_object('item_id',v_item.id,'expected_snapshot',public.cost_item_identity(v_item),
   'actual_cost',v_item.cost_price,'is_verified',true,'notes',p->>'reason')),'[]');
  v_after:=to_jsonb(v_item);
 ELSIF p->>'entity_kind'='accommodation' THEN
  SELECT * INTO v_acc FROM public.proposal_accommodations WHERE proposal_id=v_prop.id AND id=(p->>'entity_id')::uuid FOR UPDATE;
  IF v_acc.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
  v_identity:=finance_private.hotel_identity(v_acc);
  IF p->'expected_snapshot' IS DISTINCT FROM v_identity THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
  PERFORM finance_private.accommodation_amounts(p->'rooms',v_acc.num_nights);
  v_before:=to_jsonb(v_acc);
  UPDATE public.proposal_accommodations SET rooms=p->'rooms' WHERE id=v_acc.id;
  SELECT to_jsonb(a) INTO v_after FROM public.proposal_accommodations a WHERE id=v_acc.id;
 ELSE RAISE EXCEPTION 'INVALID_REQUEST: review entity kind' USING ERRCODE='22023'; END IF;
 v_totals:=public.proposal_pricing_from_bundle(to_jsonb(v_prop),
  coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM public.proposal_day_items x WHERE proposal_id=v_prop.id),'[]'),
  coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM public.proposal_accommodations x WHERE proposal_id=v_prop.id),'[]'));
 UPDATE public.proposals SET subtotal=(v_totals->>'subtotal')::numeric,total=(v_totals->>'total')::numeric WHERE id=v_prop.id;
 INSERT INTO public.finance_cost_reviews(proposal_id,entity_kind,entity_id,before_value,after_value,reason,created_by)
 VALUES(v_prop.id,p->>'entity_kind',(p->>'entity_id')::uuid,v_before,v_after,p->>'reason',auth.uid()) RETURNING id INTO v_rev;
 IF p->>'entity_kind'='accommodation' THEN
  UPDATE public.finance_accommodation_checks SET released_at=now(),released_by=auth.uid(),release_reason='Superseded by review '||v_rev WHERE entity_id=v_acc.id AND released_at IS NULL;
  SELECT * INTO v_acc FROM public.proposal_accommodations WHERE id=v_acc.id;
  INSERT INTO public.finance_accommodation_checks(proposal_id,entity_id,identity_snapshot,review_id,created_by) VALUES(v_prop.id,v_acc.id,finance_private.hotel_identity(v_acc),v_rev,auth.uid());
 END IF;
 RETURN jsonb_build_object('review_id',v_rev,'proposal_id',v_prop.id,'version',(SELECT finance_version FROM public.proposals WHERE id=v_prop.id),
  'before',v_before,'after',v_after,'result',finance_private.proposal_result(v_prop.id));
END $$;

CREATE FUNCTION finance_private.release_review(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_p public.proposals;v_item public.proposal_day_items;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['proposal_id','expected_version','entity_kind','entity_id','reason']);
 SELECT * INTO v_p FROM public.proposals WHERE id=(p->>'proposal_id')::uuid FOR UPDATE;
 IF v_p.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
 IF NOT public.has_admin_segment(v_p.segment) THEN RAISE EXCEPTION 'MODULE_FORBIDDEN' USING ERRCODE='42501';END IF;
 IF (p->>'expected_version')::bigint IS DISTINCT FROM v_p.finance_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001';END IF;
 IF length(btrim(coalesce(p->>'reason','')))=0 THEN RAISE EXCEPTION 'INVALID_REQUEST: reason' USING ERRCODE='22023';END IF;
 IF p->>'entity_kind'='accommodation' THEN
  UPDATE public.finance_accommodation_checks SET released_at=now(),released_by=auth.uid(),release_reason=p->>'reason' WHERE proposal_id=v_p.id AND entity_id=(p->>'entity_id')::uuid AND released_at IS NULL;
 ELSIF p->>'entity_kind'='item' THEN
  SELECT * INTO v_item FROM public.proposal_day_items WHERE proposal_id=v_p.id AND id=(p->>'entity_id')::uuid;
  IF v_item.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
  PERFORM public.save_proposal_cost_checks(v_p.id,jsonb_build_array(jsonb_build_object('item_id',v_item.id,'expected_snapshot',public.cost_item_identity(v_item),'actual_cost',v_item.cost_price,'is_verified',false,'notes',p->>'reason')),'[]');
 ELSE RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023';END IF;
 RETURN jsonb_build_object('proposal_id',v_p.id,'version',(SELECT finance_version FROM public.proposals WHERE id=v_p.id),'released',true);
END $$;

DO $$ DECLARE def text;BEGIN
 def:=pg_get_functiondef('public.finance_command_v1(text,jsonb,text)'::regprocedure);
 IF strpos(def,'WHEN ''settings.configure''')=0 THEN RAISE EXCEPTION 'Unexpected finance router'; END IF;
 def:=replace(def,'WHEN ''settings.configure''', E'WHEN ''proposal.save'' THEN v_result:=finance_private.save_proposal(p_payload);\n   WHEN ''proposal.review'' THEN v_result:=finance_private.review_cost_sale(p_payload);\n   WHEN ''proposal.review.release'' THEN v_result:=finance_private.release_review(p_payload);\n   WHEN ''settings.configure''');
 EXECUTE def;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
