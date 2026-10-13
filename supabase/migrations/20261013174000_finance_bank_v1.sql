BEGIN;
CREATE TABLE public.finance_bank_batches (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), bank_account_id uuid NOT NULL REFERENCES public.bank_accounts(id) ON DELETE RESTRICT,
 file_sha256 text NOT NULL CHECK(file_sha256 ~ '^[0-9a-f]{64}$'), source_name text NOT NULL,
 imported_count integer,duplicate_count integer,error_code text,
 rows jsonb NOT NULL, rejected jsonb NOT NULL, overlap_candidates jsonb NOT NULL DEFAULT '[]', state text NOT NULL DEFAULT 'preview' CHECK(state IN ('preview','confirmed')),
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(bank_account_id,file_sha256)
);
CREATE POLICY finance_bank_module ON public.bank_reconciliation_lines AS RESTRICTIVE FOR ALL TO authenticated USING(public.has_admin_module('financeiro')) WITH CHECK(public.has_admin_module('financeiro'));
ALTER TABLE public.bank_reconciliation_lines ADD COLUMN batch_id uuid REFERENCES public.finance_bank_batches(id) ON DELETE RESTRICT;
ALTER TABLE public.bank_reconciliation_lines ADD COLUMN source_row integer;
ALTER TABLE public.bank_reconciliation_lines ADD COLUMN finance_version bigint NOT NULL DEFAULT 1;
CREATE INDEX finance_bank_overlap_idx ON public.bank_reconciliation_lines(bank_account_id,transaction_date,amount,direction);
CREATE UNIQUE INDEX finance_bank_batch_row_idx ON public.bank_reconciliation_lines(batch_id,source_row) WHERE batch_id IS NOT NULL;
CREATE TABLE public.finance_bank_matches (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), line_id uuid NOT NULL REFERENCES public.bank_reconciliation_lines(id) ON DELETE RESTRICT,
 transaction_id uuid NOT NULL REFERENCES public.financial_transactions(id) ON DELETE RESTRICT,
 settlement_id uuid REFERENCES public.finance_settlements(id) ON DELETE RESTRICT,
 amount numeric(18,2) NOT NULL CHECK(amount>0),
 created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now(),
 undone_at timestamptz, undone_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT, undo_reason text,
 CHECK((undone_at IS NULL AND undone_by IS NULL AND undo_reason IS NULL) OR (undone_at IS NOT NULL AND undone_by IS NOT NULL AND length(btrim(undo_reason))>0))
);
CREATE UNIQUE INDEX finance_bank_active_settlement_idx ON public.finance_bank_matches(settlement_id) WHERE settlement_id IS NOT NULL AND undone_at IS NULL;
CREATE INDEX finance_bank_matches_line_idx ON public.finance_bank_matches(line_id) WHERE undone_at IS NULL;
DO $$ DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY['finance_bank_batches','finance_bank_matches'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM anon,authenticated',t);
  EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t);
  EXECUTE format('CREATE POLICY finance_bank_read ON public.%I FOR SELECT TO authenticated USING(public.has_admin_module(''financeiro''))',t);
  EXECUTE format('CREATE TRIGGER finance_bank_command_only BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION finance_private.command_only()',t);
 END LOOP;
END $$;

-- Row validation is isolated to retain rejected source rows without quadratic
-- JSONB concatenation. The batch stores exactly the content previewed.
CREATE FUNCTION finance_private.bank_normalize_row(r jsonb,n bigint) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE v_date date;v_amount numeric;v_source integer:=n;
BEGIN
 IF r ? 'source_row' THEN v_source:=(r->>'source_row')::integer;END IF;
 IF v_source IS NULL OR v_source NOT BETWEEN 1 AND 1000000 THEN RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023';END IF;
 PERFORM finance_private.fields(r,ARRAY['source_row','date','amount','direction','description','external_id']);
 v_date:=finance_private.iso_date(r->>'date');v_amount:=finance_private.money(r->>'amount');
 IF r->>'direction' IS NULL OR r->>'direction' NOT IN ('credit','debit') OR length(coalesce(r->>'description',''))>2000 OR length(coalesce(r->>'external_id',''))>200 THEN RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023';END IF;
 RETURN jsonb_build_object('row',jsonb_build_object('source_row',v_source,'date',v_date,'amount',v_amount::text,'direction',r->>'direction','description',coalesce(r->>'description',''),'external_id',nullif(btrim(r->>'external_id'),'')));
EXCEPTION WHEN invalid_parameter_value OR invalid_text_representation OR numeric_value_out_of_range OR datetime_field_overflow OR invalid_datetime_format THEN
 RETURN jsonb_build_object('rejected',jsonb_build_object('source_row',coalesce(v_source,n),'code','INVALID_BANK_ROW'));
END $$;

CREATE FUNCTION finance_private.bank_import(p jsonb,confirm boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_batch public.finance_bank_batches;v_row jsonb;v_rows jsonb;v_rejected jsonb;v_overlap jsonb;v_count integer:=0;v_duplicates integer:=0;v_external text;
BEGIN
 IF confirm THEN
  PERFORM finance_private.fields(p,ARRAY['batch_id','acknowledge_overlaps']);
  SELECT * INTO v_batch FROM public.finance_bank_batches WHERE id=(p->>'batch_id')::uuid FOR UPDATE;
  IF v_batch.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
  IF v_batch.state='confirmed' THEN RETURN jsonb_build_object('batch_id',v_batch.id,'already_imported',true,'rejected',jsonb_array_length(v_batch.rejected));END IF;
  -- Serialize overlapping imports for this bank even when external IDs occur
  -- in different files. Identical legitimate rows without an ID are retained.
  PERFORM 1 FROM public.bank_accounts WHERE id=v_batch.bank_account_id FOR UPDATE;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_batch.rows) r JOIN public.bank_reconciliation_lines l ON l.bank_account_id=v_batch.bank_account_id AND l.transaction_date=(r->>'date')::date AND l.amount=(r->>'amount')::numeric AND l.direction=r->>'direction' AND l.description=r->>'description' WHERE nullif(r->>'external_id','') IS NULL AND l.external_id IS NULL) AND p->'acknowledge_overlaps' IS DISTINCT FROM 'true'::jsonb THEN RAISE EXCEPTION 'OVERLAP_REVIEW_REQUIRED: acknowledge possible overlap between statements' USING ERRCODE='55000';END IF;
  FOR v_row IN SELECT value FROM jsonb_array_elements(v_batch.rows) LOOP
   v_external:=nullif(btrim(v_row->>'external_id'),'');
   IF v_external IS NOT NULL AND EXISTS(SELECT 1 FROM public.bank_reconciliation_lines WHERE bank_account_id=v_batch.bank_account_id AND external_id=v_external) THEN v_duplicates:=v_duplicates+1;CONTINUE;END IF;
   INSERT INTO public.bank_reconciliation_lines(bank_account_id,external_id,transaction_date,description,amount,direction,batch_id,source_row)
   VALUES(v_batch.bank_account_id,v_external,(v_row->>'date')::date,v_row->>'description',(v_row->>'amount')::numeric,v_row->>'direction',v_batch.id,(v_row->>'source_row')::integer)
   ON CONFLICT DO NOTHING;
   IF FOUND THEN v_count:=v_count+1;ELSE v_duplicates:=v_duplicates+1;END IF;
  END LOOP;
  UPDATE public.finance_bank_batches SET state='confirmed',imported_count=v_count,duplicate_count=v_duplicates,error_code=NULL WHERE id=v_batch.id;
  RETURN jsonb_build_object('batch_id',v_batch.id,'imported',v_count,'duplicates',v_duplicates,'rejected',jsonb_array_length(v_batch.rejected));
 END IF;
 PERFORM finance_private.fields(p,ARRAY['bank_account_id','file_sha256','source_name','rows','parser_rejected']);
 IF p->>'file_sha256' IS NULL OR p->>'file_sha256' !~ '^[0-9a-f]{64}$' OR length(coalesce(p->>'source_name','')) NOT BETWEEN 1 AND 200
  OR jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' OR jsonb_typeof(coalesce(p->'parser_rejected','[]')) IS DISTINCT FROM 'array'
  OR jsonb_array_length(p->'rows')+jsonb_array_length(coalesce(p->'parser_rejected','[]'))>20000 THEN RAISE EXCEPTION 'INVALID_REQUEST: bank import envelope' USING ERRCODE='22023';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.bank_accounts WHERE id=(p->>'bank_account_id')::uuid AND is_active) THEN RAISE EXCEPTION 'INVALID_REQUEST: bank account' USING ERRCODE='22023';END IF;
 FOR v_row IN SELECT value FROM jsonb_array_elements(coalesce(p->'parser_rejected','[]')) LOOP
  PERFORM finance_private.fields(v_row,ARRAY['source_row','code']);
  IF (v_row->>'source_row')::integer NOT BETWEEN 1 AND 1000000 OR v_row->>'source_row' IS NULL OR v_row->>'code' IS NULL OR v_row->>'code' !~ '^[A-Z_]{1,80}$' THEN RAISE EXCEPTION 'INVALID_REQUEST: rejected row' USING ERRCODE='22023';END IF;
 END LOOP;
 WITH normalized AS MATERIALIZED (SELECT finance_private.bank_normalize_row(value,ordinality) AS r FROM jsonb_array_elements(p->'rows') WITH ORDINALITY)
 SELECT coalesce(jsonb_agg(r->'row' ORDER BY (r->'row'->>'source_row')::integer) FILTER(WHERE r ? 'row'),'[]'),
  coalesce(jsonb_agg(r->'rejected') FILTER(WHERE r ? 'rejected'),'[]')||coalesce(p->'parser_rejected','[]') INTO v_rows,v_rejected FROM normalized;
 IF EXISTS(SELECT 1 FROM (SELECT value->>'source_row' AS n FROM jsonb_array_elements(v_rows||v_rejected)) x GROUP BY n HAVING count(*)>1) THEN RAISE EXCEPTION 'INVALID_REQUEST: duplicate source row' USING ERRCODE='22023';END IF;
 SELECT coalesce(jsonb_agg(value ORDER BY (value->>'source_row')::integer),'[]') INTO v_rejected FROM jsonb_array_elements(v_rejected);
 SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') INTO v_overlap FROM (SELECT (r->>'source_row')::integer AS source_row,l.id AS existing_line_id,'POSSIBLE_OVERLAP_WITHOUT_EXTERNAL_ID' AS code FROM jsonb_array_elements(v_rows) r JOIN LATERAL (SELECT id FROM public.bank_reconciliation_lines l WHERE l.bank_account_id=(p->>'bank_account_id')::uuid AND l.transaction_date=(r->>'date')::date AND l.amount=(r->>'amount')::numeric AND l.direction=r->>'direction' AND l.description=r->>'description' AND l.external_id IS NULL LIMIT 1) l ON true WHERE nullif(r->>'external_id','') IS NULL LIMIT 200) x;
 INSERT INTO public.finance_bank_batches(bank_account_id,file_sha256,source_name,rows,rejected,overlap_candidates,created_by)
 VALUES((p->>'bank_account_id')::uuid,p->>'file_sha256',p->>'source_name',v_rows,v_rejected,v_overlap,auth.uid())
 ON CONFLICT(bank_account_id,file_sha256) DO UPDATE SET file_sha256=EXCLUDED.file_sha256 RETURNING * INTO v_batch;
 IF v_rows IS DISTINCT FROM v_batch.rows OR v_rejected IS DISTINCT FROM v_batch.rejected THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: file identity has different normalized content' USING ERRCODE='22023';END IF;
 RETURN jsonb_build_object('batch_id',v_batch.id,'rows',v_batch.rows,'rejected',v_batch.rejected,'overlap_candidates',v_batch.overlap_candidates,'overlap_candidates_limit',200,'already_imported',v_batch.state='confirmed','parser_version','finance-v1-normalized');
END $$;

CREATE FUNCTION finance_private.bank_match(p jsonb,undo boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_line public.bank_reconciliation_lines;v_match public.finance_bank_matches;v_title public.financial_transactions;v_settle public.finance_settlements;
 v_amount numeric;v_total numeric:=0;v_alloc jsonb;v_ids jsonb:='[]';v_id uuid;v_seen uuid[]:='{}';
BEGIN
 IF undo THEN
  PERFORM finance_private.fields(p,ARRAY['match_id','reason']);
  SELECT * INTO v_match FROM public.finance_bank_matches WHERE id=(p->>'match_id')::uuid;
  IF v_match.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
  SELECT * INTO v_line FROM public.bank_reconciliation_lines WHERE id=v_match.line_id FOR UPDATE;
  SELECT * INTO v_match FROM public.finance_bank_matches WHERE id=v_match.id FOR UPDATE;
  IF length(btrim(coalesce(p->>'reason','')))=0 THEN RAISE EXCEPTION 'INVALID_REQUEST: undo reason' USING ERRCODE='22023'; END IF;
  IF v_match.undone_at IS NOT NULL THEN RETURN jsonb_build_object('id',v_match.id,'already_undone',true); END IF;
  UPDATE public.finance_bank_matches SET undone_at=now(),undone_by=auth.uid(),undo_reason=p->>'reason' WHERE id=v_match.id;
  UPDATE public.bank_reconciliation_lines SET status='unmatched',transaction_id=NULL,finance_version=finance_version+1 WHERE id=v_line.id;
  RETURN jsonb_build_object('id',v_match.id,'line_id',v_line.id,'undone',true);
 END IF;
 PERFORM finance_private.fields(p,ARRAY['line_id','expected_version','allocations']);
 IF jsonb_typeof(p->'allocations') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'allocations')<>1 THEN RAISE EXCEPTION 'UNSUPPORTED_MATCH_MODE: decision D12 required' USING ERRCODE='55000';END IF;
 -- Serialize titles in UUID order before lines, sharing the proposal/title lock
 -- order of settlements. This prevents settlement corrections during matching.
 FOR v_title IN SELECT t.* FROM public.financial_transactions t WHERE t.id IN (SELECT (value->>'transaction_id')::uuid FROM jsonb_array_elements(p->'allocations')) ORDER BY t.proposal_id NULLS LAST,t.id LOOP
  IF v_title.proposal_id IS NOT NULL THEN PERFORM 1 FROM public.proposals WHERE id=v_title.proposal_id FOR UPDATE; END IF;
  PERFORM 1 FROM public.financial_transactions WHERE id=v_title.id FOR UPDATE;
 END LOOP;
 SELECT * INTO v_line FROM public.bank_reconciliation_lines WHERE id=(p->>'line_id')::uuid FOR UPDATE;
 IF v_line.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF (p->>'expected_version')::bigint IS DISTINCT FROM v_line.finance_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
 IF v_line.status='matched' OR EXISTS(SELECT 1 FROM public.finance_bank_matches WHERE line_id=v_line.id AND undone_at IS NULL) THEN RAISE EXCEPTION 'INVALID_TRANSITION: line already matched' USING ERRCODE='55000'; END IF;
 IF jsonb_typeof(p->'allocations') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'allocations') NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'INVALID_REQUEST: allocations' USING ERRCODE='22023'; END IF;
 FOR v_alloc IN SELECT value FROM jsonb_array_elements(p->'allocations') LOOP
  PERFORM finance_private.fields(v_alloc,ARRAY['transaction_id','settlement_id','amount']);
  SELECT * INTO v_title FROM public.financial_transactions WHERE id=(v_alloc->>'transaction_id')::uuid;
  IF v_title.id IS NULL OR v_title.status IN ('cancelled','canceled') OR v_title.id=ANY(v_seen) THEN RAISE EXCEPTION 'INVALID_REQUEST: title' USING ERRCODE='22023'; END IF;
  IF NOT v_title.finance_managed THEN RAISE EXCEPTION 'LEGACY_REVIEW_REQUIRED' USING ERRCODE='55000';END IF;
  v_seen:=array_append(v_seen,v_title.id);v_amount:=finance_private.money(v_alloc->>'amount');
  IF (v_line.direction='credit') IS DISTINCT FROM (v_title.type IN ('receivable','commission_in')) THEN RAISE EXCEPTION 'INVALID_REQUEST: direction mismatch' USING ERRCODE='22023'; END IF;
  IF v_alloc->>'settlement_id' IS NOT NULL THEN
   SELECT * INTO v_settle FROM public.finance_settlements WHERE id=(v_alloc->>'settlement_id')::uuid AND transaction_id=v_title.id;
   IF v_settle.id IS NULL OR v_settle.kind<>'payment' OR v_settle.bank_account_id<>v_line.bank_account_id
    OR v_settle.amount-coalesce((SELECT sum(amount) FROM public.finance_settlements WHERE reverses_id=v_settle.id),0)<>v_amount
    OR EXISTS(SELECT 1 FROM public.finance_bank_matches WHERE transaction_id=v_title.id AND undone_at IS NULL AND (settlement_id=v_settle.id OR settlement_id IS NULL)) THEN
    RAISE EXCEPTION 'INVALID_REQUEST: settlement amount or bank mismatch' USING ERRCODE='22023'; END IF;
  ELSIF v_title.bank_account_id IS DISTINCT FROM v_line.bank_account_id OR v_title.amount<>v_amount
   OR EXISTS(SELECT 1 FROM public.finance_bank_matches WHERE transaction_id=v_title.id AND undone_at IS NULL) OR EXISTS(SELECT 1 FROM public.finance_settlements WHERE transaction_id=v_title.id) THEN
   RAISE EXCEPTION 'INVALID_REQUEST: title amount or bank mismatch' USING ERRCODE='22023';
  END IF;
  v_total:=v_total+v_amount;
  INSERT INTO public.finance_bank_matches(line_id,transaction_id,settlement_id,amount,created_by)
  VALUES(v_line.id,v_title.id,(v_alloc->>'settlement_id')::uuid,v_amount,auth.uid()) RETURNING id INTO v_id;
  v_ids:=v_ids||jsonb_build_array(v_id);
 END LOOP;
 IF v_total<>v_line.amount THEN RAISE EXCEPTION 'INVALID_REQUEST: allocation sum mismatch' USING ERRCODE='22023'; END IF;
 UPDATE public.bank_reconciliation_lines SET status='matched',transaction_id=CASE WHEN cardinality(v_seen)=1 THEN v_seen[1] ELSE NULL END,finance_version=finance_version+1 WHERE id=v_line.id;
 RETURN jsonb_build_object('line_id',v_line.id,'match_ids',v_ids,'matched',true,'settlement_created',false);
END $$;

CREATE FUNCTION finance_private.bank_line_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public AS $$
BEGIN
 IF TG_OP='DELETE' OR (TG_OP='UPDATE' AND (OLD.batch_id IS NOT NULL OR NEW.batch_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.finance_bank_matches WHERE line_id=OLD.id))) OR (TG_OP='INSERT' AND NEW.batch_id IS NOT NULL) THEN
  IF current_user<>pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid=TG_RELID)) THEN RAISE EXCEPTION 'Use finance bank command; preserve imported evidence' USING ERRCODE='42501'; END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;
CREATE TRIGGER finance_bank_line_guard BEFORE INSERT OR UPDATE OR DELETE ON public.bank_reconciliation_lines FOR EACH ROW EXECUTE FUNCTION finance_private.bank_line_guard();

CREATE FUNCTION finance_private.bank_account_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.bank_reconciliation_lines WHERE bank_account_id=OLD.id) THEN RAISE EXCEPTION 'ADJUSTMENT_REQUIRED: bank evidence exists; deactivate account' USING ERRCODE='55000'; END IF;
 RETURN OLD;
END $$;
CREATE TRIGGER finance_bank_account_guard BEFORE DELETE ON public.bank_accounts FOR EACH ROW EXECUTE FUNCTION finance_private.bank_account_guard();

-- Extend the command router without losing receipts or authorization.
DO $$ DECLARE def text;BEGIN
 def:=pg_get_functiondef('public.finance_command_v1(text,jsonb,text)'::regprocedure);
 IF strpos(def,'WHEN ''settings.configure''')=0 THEN RAISE EXCEPTION 'Unexpected finance router'; END IF;
 def:=replace(def,'WHEN ''settings.configure''', E'WHEN ''bank.preview'' THEN v_result:=finance_private.bank_import(p_payload,false);\n   WHEN ''bank.confirm'' THEN v_result:=finance_private.bank_import(p_payload,true);\n   WHEN ''bank.match'' THEN v_result:=finance_private.bank_match(p_payload,false);\n   WHEN ''bank.undo'' THEN v_result:=finance_private.bank_match(p_payload,true);\n   WHEN ''settings.configure''');
 EXECUTE def;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
