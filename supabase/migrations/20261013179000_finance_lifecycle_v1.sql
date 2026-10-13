BEGIN;
CREATE FUNCTION finance_private.proposal_transition(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_p public.proposals;v_status text;
BEGIN
 PERFORM finance_private.fields(p,ARRAY['proposal_id','expected_version','operation','reason']);
 SELECT * INTO v_p FROM public.proposals WHERE id=(p->>'proposal_id')::uuid FOR UPDATE;
 IF v_p.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND' USING ERRCODE='P0002';END IF;
 IF NOT public.has_admin_segment(v_p.segment) THEN RAISE EXCEPTION 'MODULE_FORBIDDEN' USING ERRCODE='42501';END IF;
 IF (p->>'expected_version')::bigint IS DISTINCT FROM v_p.finance_version THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001';END IF;
 IF p->>'operation'='publish' AND v_p.status IN ('draft','negotiating','sent') THEN
  IF v_p.valid_until IS NOT NULL AND v_p.valid_until<(now() AT TIME ZONE 'America/Sao_Paulo')::date THEN RAISE EXCEPTION 'INVALID_TRANSITION: expired proposal' USING ERRCODE='55000';END IF;
  v_status:='sent';
 ELSIF p->>'operation'='approve_manual' AND v_p.status IN ('sent','negotiating') THEN
  IF NOT public.is_full_admin(auth.uid()) OR length(btrim(coalesce(p->>'reason','')))=0 THEN RAISE EXCEPTION 'MODULE_FORBIDDEN: full admin and manual approval reason required' USING ERRCODE='42501';END IF;
  v_status:='approved';
 ELSE RAISE EXCEPTION 'INVALID_TRANSITION' USING ERRCODE='55000';END IF;
 UPDATE public.proposals SET status=v_status,published_at=CASE WHEN v_status='sent' THEN coalesce(published_at,now()) ELSE published_at END WHERE id=v_p.id;
 IF v_status='approved' AND v_p.prospect_id IS NOT NULL THEN INSERT INTO public.prospect_interactions(prospect_id,type,content) VALUES(v_p.prospect_id,'approval','Aprovação manual administrativa registrada. Motivo: '||(p->>'reason'));END IF;
 RETURN jsonb_build_object('id',v_p.id,'version',(SELECT finance_version FROM public.proposals WHERE id=v_p.id),'status',v_status,'financial_generation','explicit_plan_only','signature_unchanged',true);
END $$;
DO $$ DECLARE def text;BEGIN
 def:=pg_get_functiondef('public.finance_command_v1(text,jsonb,text)'::regprocedure);
 def:=replace(def,'WHEN ''settings.configure''',E'WHEN ''proposal.transition'' THEN v_result:=finance_private.proposal_transition(p_payload);\n   WHEN ''settings.configure''');EXECUTE def;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
