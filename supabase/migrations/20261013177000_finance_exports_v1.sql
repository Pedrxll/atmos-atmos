BEGIN;
CREATE TABLE public.finance_export_jobs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
 format text NOT NULL CHECK(format IN ('csv','json')),filters jsonb NOT NULL,
 state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','completed','failed')),error_code text,
 snapshot_at timestamptz,row_count bigint,part_count integer,report jsonb,
 created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL DEFAULT now()+interval '24 hours'
);
CREATE TABLE public.finance_export_parts (
 job_id uuid NOT NULL REFERENCES public.finance_export_jobs(id) ON DELETE CASCADE,part_number integer NOT NULL CHECK(part_number>=0),rows jsonb NOT NULL,
 PRIMARY KEY(job_id,part_number)
);
ALTER TABLE public.finance_export_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_export_parts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_export_jobs,public.finance_export_parts FROM anon,authenticated;
GRANT SELECT ON public.finance_export_jobs,public.finance_export_parts TO authenticated;
CREATE POLICY finance_export_owner ON public.finance_export_jobs FOR SELECT TO authenticated USING(created_by=auth.uid() AND public.has_admin_module('financeiro'));
CREATE POLICY finance_export_part_owner ON public.finance_export_parts FOR SELECT TO authenticated USING(public.has_admin_module('financeiro') AND EXISTS(SELECT 1 FROM public.finance_export_jobs j WHERE j.id=job_id AND j.created_by=auth.uid() AND j.expires_at>now()));
CREATE TRIGGER finance_export_job_command_only BEFORE INSERT OR UPDATE OR DELETE ON public.finance_export_jobs FOR EACH ROW EXECUTE FUNCTION finance_private.command_only();
CREATE TRIGGER finance_export_part_command_only BEFORE INSERT OR UPDATE OR DELETE ON public.finance_export_parts FOR EACH ROW EXECUTE FUNCTION finance_private.command_only();

CREATE FUNCTION finance_private.export_create(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_id uuid;v_filters jsonb:=p->'filters';
BEGIN
 PERFORM finance_private.fields(p,ARRAY['format','filters']);
 IF p->>'format' IS NULL OR p->>'format' NOT IN ('csv','json') THEN RAISE EXCEPTION 'INVALID_REQUEST: export format' USING ERRCODE='22023';END IF;
 PERFORM finance_private.fields(v_filters,ARRAY['from','to','basis','proposal_id']);
 PERFORM finance_private.iso_date(v_filters->>'from');PERFORM finance_private.iso_date(v_filters->>'to');
 IF v_filters->>'basis' IS NULL OR v_filters->>'basis' NOT IN ('due','cash','competence') OR (v_filters->>'from')::date>(v_filters->>'to')::date OR (v_filters->>'to')::date-(v_filters->>'from')::date>3660 THEN RAISE EXCEPTION 'INVALID_REQUEST: export basis and period' USING ERRCODE='22023';END IF;
 IF v_filters->>'proposal_id' IS NOT NULL AND NOT public.admin_can_access_proposal((v_filters->>'proposal_id')::uuid,false) THEN RAISE EXCEPTION 'RECORD_FORBIDDEN' USING ERRCODE='42501';END IF;
 PERFORM finance_private.rate_limit('export.create',5);
 INSERT INTO public.finance_export_jobs(created_by,format,filters) VALUES(auth.uid(),p->>'format',v_filters) RETURNING id INTO v_id;
 RETURN jsonb_build_object('id',v_id,'state','queued','expires_in_seconds',86400,'run_required',true);
END $$;

CREATE FUNCTION finance_private.export_read(p jsonb,part boolean) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE j public.finance_export_jobs;v_rows jsonb;v_n integer;
BEGIN
 PERFORM finance_private.fields(p,CASE WHEN part THEN ARRAY['job_id','part_number'] ELSE ARRAY['job_id'] END);
 SELECT * INTO j FROM public.finance_export_jobs WHERE id=(p->>'job_id')::uuid AND created_by=auth.uid();
 IF j.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
 IF part THEN
  IF j.expires_at<=now() THEN RAISE EXCEPTION 'EXPORT_EXPIRED' USING ERRCODE='55000';END IF;
  IF j.state<>'completed' THEN RAISE EXCEPTION 'EXPORT_NOT_READY' USING ERRCODE='55000';END IF;
  v_n:=(p->>'part_number')::integer;
  IF v_n IS NULL OR v_n NOT BETWEEN 0 AND j.part_count-1 THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
  SELECT rows INTO v_rows FROM public.finance_export_parts WHERE job_id=j.id AND part_number=v_n;
  RETURN jsonb_build_object('job_id',j.id,'part_number',v_n,'rows',v_rows);
 END IF;
 RETURN jsonb_build_object('id',j.id,'format',j.format,'state',CASE WHEN j.expires_at<=now() THEN 'expired' ELSE j.state END,
  'filters',j.filters,'snapshot_at',j.snapshot_at,'row_count',j.row_count,'part_count',j.part_count,'report',j.report,'created_at',j.created_at,'expires_at',j.expires_at,'error_code',j.error_code,'export_version','finance-v1');
END $$;

-- All report values and chunks are produced by ONE statement/snapshot. A caller
-- never stitches independently changing pages into an apparently coherent file.
CREATE FUNCTION public.finance_export_run_v1(p_job_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public SET statement_timeout='60s' SET lock_timeout='2s' AS $$
DECLARE j public.finance_export_jobs;v_result jsonb;v_code text;
BEGIN
 PERFORM finance_private.require_module();PERFORM finance_private.rate_limit('export.run',10);
 SELECT * INTO j FROM public.finance_export_jobs WHERE id=p_job_id AND created_by=auth.uid() FOR UPDATE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
 IF j.expires_at<=now() THEN RAISE EXCEPTION 'EXPORT_EXPIRED' USING ERRCODE='55000';END IF;
 IF j.state='completed' THEN RETURN jsonb_build_object('data',finance_private.export_read(jsonb_build_object('job_id',j.id),false),'replayed',true);END IF;
 BEGIN
  WITH movements AS MATERIALIZED (
   SELECT s.id AS movement_id,t.id AS transaction_id,t.type,t.description,
    CASE WHEN s.kind='correction' THEN -s.amount ELSE s.amount END AS amount,s.effective_date AS report_date,
    t.proposal_id,t.supplier_id,t.prospect_id,t.seller_id,t.account_id,t.invoice_number,s.bank_account_id,t.origin_type,t.finance_managed,t.finance_scope,t.branch_id
   FROM public.finance_settlements s JOIN public.financial_transactions t ON t.id=s.transaction_id
   WHERE j.filters->>'basis'='cash' AND s.effective_date BETWEEN (j.filters->>'from')::date AND (j.filters->>'to')::date AND (j.filters->>'proposal_id' IS NULL OR t.proposal_id=(j.filters->>'proposal_id')::uuid)
   UNION ALL
   SELECT t.id,t.id,t.type,t.description,t.amount,CASE WHEN j.filters->>'basis'='due' THEN t.due_date ELSE t.competence_date END,
    t.proposal_id,t.supplier_id,t.prospect_id,t.seller_id,t.account_id,t.invoice_number,t.bank_account_id,t.origin_type,t.finance_managed,t.finance_scope,t.branch_id
   FROM public.financial_transactions t WHERE j.filters->>'basis'<>'cash' AND t.status NOT IN ('cancelled','canceled') AND t.type IN ('receivable','payable','commission_in','commission_out')
    AND CASE WHEN j.filters->>'basis'='due' THEN t.due_date ELSE t.competence_date END BETWEEN (j.filters->>'from')::date AND (j.filters->>'to')::date
    AND (j.filters->>'proposal_id' IS NULL OR t.proposal_id=(j.filters->>'proposal_id')::uuid)
  ), numbered AS MATERIALIZED (
   SELECT (row_number() OVER(ORDER BY m.movement_id)-1)/500 AS part_number,m.movement_id,
    to_jsonb(m)||jsonb_build_object('amount',m.amount::text,'account_code',a.code,'account_name',a.name,'proposal_code',p.code,'proposal_title',p.title,'supplier_name',s.name,'bank_name',b.name) AS data
   FROM movements m LEFT JOIN public.chart_of_accounts a ON a.id=m.account_id LEFT JOIN public.proposals p ON p.id=m.proposal_id LEFT JOIN public.suppliers s ON s.id=m.supplier_id LEFT JOIN public.bank_accounts b ON b.id=m.bank_account_id
  ), inserted AS (
   INSERT INTO public.finance_export_parts(job_id,part_number,rows) SELECT j.id,part_number,jsonb_agg(data ORDER BY movement_id) FROM numbered GROUP BY part_number RETURNING part_number
  ), completed AS (
   UPDATE public.finance_export_jobs SET state='completed',error_code=NULL,snapshot_at=statement_timestamp(),row_count=(SELECT count(*) FROM movements),part_count=(SELECT count(*) FROM inserted),report=finance_private.report(j.filters) WHERE id=j.id RETURNING *
  ) SELECT jsonb_build_object('id',id,'state',state,'snapshot_at',snapshot_at,'row_count',row_count,'part_count',part_count,'report',report) INTO v_result FROM completed;
  INSERT INTO public.finance_audit_events(actor_id,action,entity_id,request_key,after_value) VALUES(auth.uid(),'export.run',j.id,'export-run:'||j.id,jsonb_build_object('row_count',v_result->'row_count','format',j.format));
  RETURN jsonb_build_object('data',v_result,'replayed',false);
 EXCEPTION WHEN query_canceled THEN
  UPDATE public.finance_export_jobs SET state='failed',error_code='TIMEOUT' WHERE id=j.id;
  RETURN jsonb_build_object('error',jsonb_build_object('code','TIMEOUT','retryable',true));
 WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_code=RETURNED_SQLSTATE;
  UPDATE public.finance_export_jobs SET state='failed',error_code=CASE WHEN v_code='57014' THEN 'TIMEOUT' ELSE 'EXPORT_FAILED' END WHERE id=j.id;
  RETURN jsonb_build_object('error',jsonb_build_object('code','DEPENDENCY_UNAVAILABLE','retryable',true));
 END;
END $$;
REVOKE ALL ON FUNCTION public.finance_export_run_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.finance_export_run_v1(uuid) TO authenticated;

CREATE FUNCTION public.finance_export_cleanup_v1() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE n integer;
BEGIN DELETE FROM public.finance_export_parts p USING public.finance_export_jobs j WHERE j.id=p.job_id AND j.expires_at<=now();GET DIAGNOSTICS n=ROW_COUNT;RETURN n;END $$;
REVOKE ALL ON FUNCTION public.finance_export_cleanup_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.finance_export_cleanup_v1() TO service_role;
DO $$ DECLARE def text;BEGIN
 def:=pg_get_functiondef('public.finance_command_v1(text,jsonb,text)'::regprocedure);
 def:=replace(def,'WHEN ''settings.configure''', E'WHEN ''export.create'' THEN v_result:=finance_private.export_create(p_payload);\n   WHEN ''settings.configure''');EXECUTE def;
 def:=pg_get_functiondef('public.finance_query_v1(text,jsonb)'::regprocedure);
 def:=replace(def,'WHEN ''transactions''', E'WHEN ''export.job'' THEN v_result:=finance_private.export_read(p_payload,false);\n  WHEN ''export.part'' THEN v_result:=finance_private.export_read(p_payload,true);\n  WHEN ''transactions''');EXECUTE def;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
