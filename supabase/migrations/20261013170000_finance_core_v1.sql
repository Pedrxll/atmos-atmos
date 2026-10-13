-- Incremental finance v1 foundation. No real data is backfilled or settled.
BEGIN;
CREATE SCHEMA finance_private;
REVOKE ALL ON SCHEMA finance_private FROM PUBLIC, anon, authenticated;

ALTER TABLE public.proposals ADD COLUMN finance_version bigint NOT NULL DEFAULT 1;
ALTER TABLE public.proposal_day_items ADD COLUMN finance_snapshot jsonb;
ALTER TABLE public.proposal_accommodations ADD COLUMN supplier_id uuid REFERENCES public.suppliers(id) ON DELETE RESTRICT;
ALTER TABLE public.proposal_accommodations ADD COLUMN finance_snapshot jsonb;
ALTER TABLE public.financial_transactions
 ADD COLUMN finance_managed boolean NOT NULL DEFAULT false,
 ADD COLUMN finance_scope text NOT NULL DEFAULT 'legacy_unclassified' CHECK(finance_scope IN ('operation','corporate','unclassified','legacy_unclassified')),
 ADD COLUMN finance_version bigint NOT NULL DEFAULT 1,
 ADD COLUMN origin_type text,
 ADD COLUMN origin_id text,
 ADD COLUMN source_snapshot jsonb,
 ADD COLUMN cancelled_at timestamptz;


ALTER TABLE public.financial_transactions DROP CONSTRAINT financial_transactions_account_id_fkey,
 ADD CONSTRAINT financial_transactions_account_id_fkey FOREIGN KEY(account_id) REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT;
ALTER TABLE public.financial_transactions DROP CONSTRAINT financial_transactions_seller_id_fkey,
 ADD CONSTRAINT financial_transactions_seller_id_fkey FOREIGN KEY(seller_id) REFERENCES public.sellers(id) ON DELETE RESTRICT;
ALTER TABLE public.financial_transactions DROP CONSTRAINT financial_transactions_proposal_id_fkey,
 ADD CONSTRAINT financial_transactions_proposal_id_fkey FOREIGN KEY(proposal_id) REFERENCES public.proposals(id) ON DELETE RESTRICT;
ALTER TABLE public.financial_transactions DROP CONSTRAINT financial_transactions_prospect_id_fkey,
 ADD CONSTRAINT financial_transactions_prospect_id_fkey FOREIGN KEY(prospect_id) REFERENCES public.prospects(id) ON DELETE RESTRICT;
ALTER TABLE public.proposal_day_items ADD CONSTRAINT proposal_day_items_supplier_v1_fkey FOREIGN KEY(supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.proposal_costs DROP CONSTRAINT proposal_costs_supplier_id_fkey,
 ADD CONSTRAINT proposal_costs_supplier_id_fkey FOREIGN KEY(supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT;

CREATE TABLE public.product_suppliers (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
 supplier_id uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
 label text NOT NULL DEFAULT '', is_active boolean NOT NULL DEFAULT true,
 reference_cost numeric CHECK(reference_cost >= 0 AND reference_cost < 100000000),
 reference_sale numeric CHECK(reference_sale >= 0 AND reference_sale < 100000000),
 payment_terms text, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(product_id,supplier_id,label)
);

CREATE TABLE public.finance_plans (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 proposal_id uuid NOT NULL REFERENCES public.proposals(id) ON DELETE RESTRICT,
 proposal_version bigint NOT NULL, snapshot_hash text NOT NULL,
 source_snapshot jsonb NOT NULL, lines jsonb NOT NULL,
 pending_items jsonb NOT NULL DEFAULT '[]',
 state text NOT NULL DEFAULT 'preview' CHECK(state IN ('preview','confirmed','superseded')),
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
 created_at timestamptz NOT NULL DEFAULT now(), confirmed_at timestamptz
);
CREATE INDEX finance_plans_proposal_idx ON public.finance_plans(proposal_id,created_at);

CREATE TABLE public.finance_settlements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 transaction_id uuid NOT NULL REFERENCES public.financial_transactions(id) ON DELETE RESTRICT,
 amount numeric(18,2) NOT NULL CHECK(amount > 0 AND amount < 100000000),
 kind text NOT NULL DEFAULT 'payment' CHECK(kind IN ('payment','correction')),
 reverses_id uuid REFERENCES public.finance_settlements(id) ON DELETE RESTRICT,
 bank_account_id uuid NOT NULL REFERENCES public.bank_accounts(id) ON DELETE RESTRICT,
 effective_date date NOT NULL, payment_method text NOT NULL,
 reference text, reason text,
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((kind='payment' AND reverses_id IS NULL) OR (kind='correction' AND reverses_id IS NOT NULL AND length(btrim(reason))>0))
);
CREATE INDEX finance_settlements_title_idx ON public.finance_settlements(transaction_id,effective_date,id);
CREATE INDEX finance_settlements_reversal_idx ON public.finance_settlements(reverses_id);
CREATE INDEX finance_settlements_bank_date_idx ON public.finance_settlements(bank_account_id,effective_date,id);

CREATE TABLE public.finance_audit_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id uuid NOT NULL,
 action text NOT NULL, entity_id uuid, request_key text NOT NULL,
 before_value jsonb, after_value jsonb, reason text,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX finance_audit_entity_idx ON public.finance_audit_events(entity_id,created_at);
CREATE TABLE finance_private.receipts (
 actor_id uuid NOT NULL, action text NOT NULL, request_key text NOT NULL,
 payload_hash text NOT NULL, result jsonb, created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(actor_id,action,request_key)
);
CREATE TABLE finance_private.rate_buckets (
 actor_id uuid NOT NULL, bucket text NOT NULL, minute timestamptz NOT NULL,
 calls integer NOT NULL, PRIMARY KEY(actor_id,bucket,minute)
);
CREATE TABLE finance_private.settings (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 automatic_generation boolean NOT NULL DEFAULT false,
 settlement_partials boolean NOT NULL DEFAULT false,
 manual_plan_confirmation boolean NOT NULL DEFAULT false,
 unpaid_adjustments boolean NOT NULL DEFAULT false,
 decision_reference text,
 updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO finance_private.settings(singleton) VALUES(true);

CREATE FUNCTION finance_private.require_module(p_module text DEFAULT 'financeiro') RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.has_admin_module(p_module) THEN
  RAISE EXCEPTION 'MODULE_FORBIDDEN' USING ERRCODE='42501';
 END IF;
 RETURN auth.uid();
END $$;

CREATE FUNCTION finance_private.fields(p jsonb, allowed text[]) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
BEGIN
 IF p IS NULL OR jsonb_typeof(p) <> 'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(p) k WHERE NOT(k=ANY(allowed))) THEN
  RAISE EXCEPTION 'INVALID_REQUEST: unknown field or invalid object' USING ERRCODE='22023';
 END IF;
END $$;

CREATE FUNCTION finance_private.money(p text, allow_zero boolean DEFAULT false) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE n numeric;
BEGIN
 IF p IS NULL OR p !~ '^(0|[1-9][0-9]{0,7})(\.[0-9]{1,2})?$' THEN
  RAISE EXCEPTION 'INVALID_REQUEST: canonical decimal required' USING ERRCODE='22023';
 END IF;
 n:=p::numeric;
 IF (NOT allow_zero AND n=0) OR n>=100000000 THEN
  RAISE EXCEPTION 'INVALID_REQUEST: invalid amount' USING ERRCODE='22023';
 END IF;
 RETURN n;
END $$;

CREATE FUNCTION finance_private.iso_date(p text) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE d date;
BEGIN
 IF p IS NULL OR p !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
  RAISE EXCEPTION 'FINANCIAL_DATA_REQUIRED: valid date required' USING ERRCODE='22023';
 END IF;
 BEGIN d:=p::date; EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
  RAISE EXCEPTION 'INVALID_REQUEST: invalid calendar date' USING ERRCODE='22023';
 END;
 RETURN d;
END $$;

CREATE FUNCTION finance_private.rate_limit(p_bucket text,p_limit integer DEFAULT 60) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE n integer; a uuid:=auth.uid();
BEGIN
 IF a IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE='42501'; END IF;
 INSERT INTO finance_private.rate_buckets(actor_id,bucket,minute,calls)
 VALUES(a,p_bucket,date_trunc('minute',now()),1)
 ON CONFLICT(actor_id,bucket,minute) DO UPDATE SET calls=rate_buckets.calls+1 RETURNING calls INTO n;
 IF n>p_limit THEN RAISE EXCEPTION 'RATE_LIMITED' USING ERRCODE='P0429'; END IF;
END $$;

CREATE FUNCTION finance_private.command_only() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog AS $$
BEGIN
 IF current_user <> pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid=TG_RELID)) THEN
  RAISE EXCEPTION 'Use authorized finance command' USING ERRCODE='42501';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;

-- A separate definer trigger locks the parent before the invoker guard. This
-- keeps the original caller visible to command_only checks while serializing
-- legacy INSERT with plan confirmation (including the FK wait/TOCTOU window).
CREATE FUNCTION finance_private.lock_title_parent() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF NEW.proposal_id IS NOT NULL THEN PERFORM 1 FROM public.proposals WHERE id=NEW.proposal_id FOR UPDATE; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER finance_00_title_parent_lock BEFORE INSERT OR UPDATE ON public.financial_transactions
FOR EACH ROW EXECUTE FUNCTION finance_private.lock_title_parent();

CREATE FUNCTION finance_private.title_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public AS $$
DECLARE owner_name text:=pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid=TG_RELID));
BEGIN
 IF TG_OP<>'DELETE' AND NOT NEW.finance_managed AND NEW.proposal_id IS NOT NULL
  AND EXISTS(SELECT 1 FROM public.finance_plans WHERE proposal_id=NEW.proposal_id AND state='confirmed') THEN
  RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: proposal uses finance v1; legacy synchronization disabled' USING ERRCODE='55000';
 END IF;
 IF TG_OP<>'DELETE' AND NOT NEW.finance_managed AND NEW.source_key LIKE 'finance_v1:%' THEN
  RAISE EXCEPTION 'INVALID_REQUEST: reserved financial origin' USING ERRCODE='22023';
 END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.finance_managed AND current_user<>owner_name THEN RAISE EXCEPTION 'Use finance command' USING ERRCODE='42501'; END IF;
  RETURN NEW;
 END IF;
 IF OLD.finance_managed AND current_user<>owner_name THEN RAISE EXCEPTION 'Managed financial title requires finance command' USING ERRCODE='42501'; END IF;
 IF TG_OP='DELETE' THEN
  IF OLD.finance_managed OR OLD.status='paid' OR EXISTS(SELECT 1 FROM public.finance_settlements WHERE transaction_id=OLD.id) THEN
   RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: financial history cannot be deleted' USING ERRCODE='55000';
  END IF;
  RETURN OLD;
 END IF;
 IF NEW.id<>OLD.id OR NEW.finance_managed<>OLD.finance_managed AND current_user<>owner_name THEN
  RAISE EXCEPTION 'INVALID_REQUEST: immutable identity' USING ERRCODE='22023';
 END IF;
 IF NEW.finance_managed THEN
  IF NOT(NEW.amount>0 AND NEW.amount<100000000 AND NEW.amount=round(NEW.amount,2))
   OR NEW.type NOT IN ('receivable','payable','commission_in','commission_out') THEN
   RAISE EXCEPTION 'INVALID_REQUEST: invalid title' USING ERRCODE='22023';
  END IF;
 END IF;
 NEW.finance_version:=OLD.finance_version+1;
 RETURN NEW;
END $$;
CREATE TRIGGER finance_title_guard BEFORE INSERT OR UPDATE OR DELETE ON public.financial_transactions
FOR EACH ROW EXECUTE FUNCTION finance_private.title_guard();

CREATE FUNCTION finance_private.bump_proposal() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public AS $$
BEGIN NEW.finance_version:=OLD.finance_version+1; RETURN NEW; END $$;
CREATE TRIGGER finance_proposal_version BEFORE UPDATE ON public.proposals
FOR EACH ROW EXECUTE FUNCTION finance_private.bump_proposal();

CREATE FUNCTION finance_private.child_version() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE pid uuid;
BEGIN
 IF TG_OP='DELETE' THEN pid:=OLD.proposal_id; ELSE pid:=NEW.proposal_id; END IF;
 UPDATE public.proposals SET updated_at=now() WHERE id=pid;
 IF TG_OP='UPDATE' AND OLD.proposal_id IS DISTINCT FROM NEW.proposal_id THEN
  RAISE EXCEPTION 'INVALID_REQUEST: cannot move proposal child' USING ERRCODE='22023';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['proposal_day_items','proposal_costs','proposal_accommodations','proposal_days'] LOOP
  EXECUTE format('CREATE TRIGGER finance_child_version BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION finance_private.child_version()',t);
 END LOOP;
END $$;

CREATE FUNCTION finance_private.paid_amount(p_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT coalesce(sum(CASE WHEN kind='payment' THEN amount ELSE -amount END),0)
 FROM public.finance_settlements WHERE transaction_id=p_id;
$$;

DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['finance_plans','finance_settlements','finance_audit_events'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM anon,authenticated',t);
  EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t);
  EXECUTE format('CREATE POLICY finance_read ON public.%I FOR SELECT TO authenticated USING(public.has_admin_module(''financeiro''))',t);
  EXECUTE format('CREATE TRIGGER finance_command_only BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION finance_private.command_only()',t);
 END LOOP;
END $$;
ALTER TABLE public.product_suppliers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_suppliers FROM anon,authenticated;
GRANT SELECT ON public.product_suppliers TO authenticated;
CREATE POLICY supplier_options_read ON public.product_suppliers FOR SELECT TO authenticated
USING(public.has_admin_module('cadastros') OR public.has_admin_module('financeiro') OR public.has_admin_module('b2b') OR public.has_admin_module('b2c'));
CREATE TRIGGER product_supplier_command_only BEFORE INSERT OR UPDATE OR DELETE ON public.product_suppliers
FOR EACH ROW EXECUTE FUNCTION finance_private.command_only();

-- Remove all default function execution from the private implementation schema.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
CREATE INDEX financial_transactions_v1_due_idx ON public.financial_transactions(type,status,due_date,id);
CREATE INDEX financial_transactions_v1_proposal_idx ON public.financial_transactions(proposal_id,origin_type,origin_id);
COMMIT;
