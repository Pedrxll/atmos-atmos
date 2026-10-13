-- Coordinated application cutover: apply only with the v1 frontend/API rollout.
-- No legacy title is silently adopted and no financial event is backfilled.
BEGIN;
-- Catalogue edits must never reprice saved negotiated snapshots.
DROP TRIGGER IF EXISTS trg_sync_product_to_drafts ON public.products;
CREATE FUNCTION finance_private.authorize_command(action text,p jsonb) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE segment text;
BEGIN
 IF action='supplier.link' THEN RETURN finance_private.require_module('cadastros');END IF;
 IF action IN ('proposal.save','prospect.create','proposal.transition') THEN
  IF action IN ('proposal.save','proposal.transition') AND p->>'proposal_id' IS NOT NULL THEN
   SELECT x.segment INTO segment FROM public.proposals x WHERE id=(p->>'proposal_id')::uuid;
   IF segment IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
   IF NOT public.has_admin_segment(segment) THEN RAISE EXCEPTION 'MODULE_FORBIDDEN' USING ERRCODE='42501';END IF;
  END IF;
  segment:=coalesce(CASE WHEN action='prospect.create' THEN p->>'segment' ELSE p#>>'{proposal,segment}' END,segment,'b2c');
  IF auth.uid() IS NULL OR NOT public.has_admin_segment(segment) THEN RAISE EXCEPTION 'MODULE_FORBIDDEN' USING ERRCODE='42501';END IF;
  RETURN auth.uid();
 END IF;
 RETURN finance_private.require_module();
END $$;
DO $$ DECLARE def text;r record;BEGIN
 def:=pg_get_functiondef('public.finance_command_v1(text,jsonb,text)'::regprocedure);
 def:=replace(def,'actor:=finance_private.require_module(CASE WHEN p_action=''supplier.link'' THEN ''cadastros'' ELSE ''financeiro'' END);','actor:=finance_private.authorize_command(p_action,p_payload);');EXECUTE def;
 REVOKE INSERT,UPDATE,DELETE ON public.financial_transactions,public.bank_reconciliation_lines,public.chart_of_accounts,public.bank_accounts FROM authenticated;
 FOR r IN SELECT oid::regprocedure AS signature FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('save_proposal_bundle','save_proposal_cost_checks','generate_proposal_receivable') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',r.signature);
 END LOOP;
END $$;
CREATE FUNCTION finance_private.commercial_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public AS $$
BEGIN
 IF TG_TABLE_NAME='proposal_day_items' THEN
  IF NOT(NEW.value>=0 AND NEW.value<100000000 AND NEW.cost_price>=0 AND NEW.cost_price<100000000 AND NEW.commission_percent BETWEEN 0 AND 100 AND NEW.quantity BETWEEN 1 AND 99999) THEN RAISE EXCEPTION 'INVALID_REQUEST: commercial numbers' USING ERRCODE='22023';END IF;
 ELSIF TG_TABLE_NAME='proposal_costs' THEN
  IF NOT(NEW.amount>=0 AND NEW.amount<100000000 AND NEW.amount=round(NEW.amount,2)) THEN RAISE EXCEPTION 'INVALID_REQUEST: cost' USING ERRCODE='22023';END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER finance_commercial_guard BEFORE INSERT OR UPDATE ON public.proposal_day_items FOR EACH ROW EXECUTE FUNCTION finance_private.commercial_guard();
CREATE TRIGGER finance_commercial_guard BEFORE INSERT OR UPDATE ON public.proposal_costs FOR EACH ROW EXECUTE FUNCTION finance_private.commercial_guard();
CREATE FUNCTION finance_private.accommodation_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public AS $$
BEGIN
 IF current_user<>pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid=TG_RELID)) AND EXISTS(SELECT 1 FROM public.finance_accommodation_checks WHERE entity_id=OLD.id AND released_at IS NULL) THEN
  IF TG_OP='DELETE' OR finance_private.hotel_identity(NEW) IS DISTINCT FROM finance_private.hotel_identity(OLD) THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: release accommodation check' USING ERRCODE='55000';END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
REVOKE INSERT,UPDATE,DELETE ON public.proposal_day_items,public.proposal_costs,public.proposal_days,public.proposal_accommodations,public.proposal_cost_checks FROM authenticated;
CREATE TRIGGER finance_accommodation_guard BEFORE UPDATE OR DELETE ON public.proposal_accommodations FOR EACH ROW EXECUTE FUNCTION finance_private.accommodation_guard();
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
