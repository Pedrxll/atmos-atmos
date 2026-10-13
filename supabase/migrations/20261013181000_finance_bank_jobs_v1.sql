BEGIN;
ALTER TABLE public.finance_bank_batches DROP CONSTRAINT finance_bank_batches_state_check;
ALTER TABLE public.finance_bank_batches ADD CONSTRAINT finance_bank_batches_state_check CHECK(state IN ('preview','queued','confirmed','failed'));
ALTER TABLE public.finance_bank_batches ADD COLUMN run_attempt integer NOT NULL DEFAULT 0,
 ADD COLUMN acknowledge_overlaps boolean NOT NULL DEFAULT false;
CREATE FUNCTION finance_private.bank_queue(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE b public.finance_bank_batches;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['batch_id','acknowledge_overlaps']);
 SELECT * INTO b FROM public.finance_bank_batches WHERE id=(p->>'batch_id')::uuid FOR UPDATE;
 IF b.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
 IF b.state IN ('confirmed','queued') THEN RETURN jsonb_build_object('batch_id',b.id,'state',b.state,'attempt',b.run_attempt,'run_required',b.state='queued');END IF;
 IF p ? 'acknowledge_overlaps' AND jsonb_typeof(p->'acknowledge_overlaps') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'INVALID_REQUEST' USING ERRCODE='22023';END IF;
 IF jsonb_array_length(b.overlap_candidates)>0 AND p->'acknowledge_overlaps' IS DISTINCT FROM 'true'::jsonb THEN RAISE EXCEPTION 'OVERLAP_REVIEW_REQUIRED' USING ERRCODE='55000';END IF;
 UPDATE public.finance_bank_batches SET state='queued',run_attempt=run_attempt+1,acknowledge_overlaps=coalesce((p->>'acknowledge_overlaps')::boolean,false),error_code=NULL WHERE id=b.id RETURNING * INTO b;
 RETURN jsonb_build_object('batch_id',b.id,'state',b.state,'attempt',b.run_attempt,'run_required',true);
END $$;
CREATE FUNCTION public.finance_bank_run_v1(p_batch_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public SET statement_timeout='60s' SET lock_timeout='2s' AS $$
DECLARE b public.finance_bank_batches;r jsonb;
BEGIN
 PERFORM finance_private.require_module();PERFORM finance_private.rate_limit('bank.run',10);
 SELECT * INTO b FROM public.finance_bank_batches WHERE id=p_batch_id FOR UPDATE;
 IF b.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
 IF b.state='confirmed' THEN RETURN jsonb_build_object('data',jsonb_build_object('batch_id',b.id,'state','confirmed','already_imported',true));END IF;
 IF b.state<>'queued' THEN RAISE EXCEPTION 'INVALID_TRANSITION: queue import first' USING ERRCODE='55000';END IF;
 BEGIN
  r:=public.finance_command_v1('bank.confirm',jsonb_build_object('batch_id',b.id,'acknowledge_overlaps',b.acknowledge_overlaps),'bank-run:'||b.id||':'||b.run_attempt);
  IF r ? 'error' THEN UPDATE public.finance_bank_batches SET state='failed',error_code=r#>>'{error,code}' WHERE id=b.id;
  ELSE UPDATE public.finance_bank_batches SET imported_count=(r#>>'{data,imported}')::integer,duplicate_count=(r#>>'{data,duplicates}')::integer,error_code=NULL WHERE id=b.id;END IF;
  RETURN r;
 EXCEPTION WHEN query_canceled THEN
  UPDATE public.finance_bank_batches SET state='failed',error_code='TIMEOUT' WHERE id=b.id;
  RETURN jsonb_build_object('error',jsonb_build_object('code','TIMEOUT','retryable',true));
 END;
END $$;
REVOKE ALL ON FUNCTION public.finance_bank_run_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.finance_bank_run_v1(uuid) TO authenticated;
CREATE FUNCTION finance_private.bank_status(p jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r jsonb;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['batch_id']);
 SELECT jsonb_build_object('batch_id',id,'state',state,'accepted',jsonb_array_length(rows),'rejected',jsonb_array_length(rejected),'imported',imported_count,'duplicates',duplicate_count,'error_code',error_code,'attempt',run_attempt,'can_retry',state IN ('queued','failed'),'retry_action',CASE WHEN state='queued' THEN 'run' WHEN state='failed' THEN 'confirm_with_new_key' END) INTO r FROM public.finance_bank_batches WHERE id=(p->>'batch_id')::uuid;
 IF r IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;RETURN r;
END $$;
DO $$ DECLARE def text;BEGIN
 def:=pg_get_functiondef('public.finance_command_v1(text,jsonb,text)'::regprocedure);
 def:=replace(def,'WHEN ''settings.configure''',E'WHEN ''bank.queue'' THEN v_result:=finance_private.bank_queue(p_payload);\n   WHEN ''settings.configure''');EXECUTE def;
 def:=pg_get_functiondef('public.finance_query_v1(text,jsonb)'::regprocedure);
 def:=replace(def,'WHEN ''transactions''',E'WHEN ''bank.job'' THEN v_result:=finance_private.bank_status(p_payload);\n  WHEN ''transactions''');EXECUTE def;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
