BEGIN;
CREATE FUNCTION finance_private.directory_list(p jsonb,kind text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_rows jsonb;v_last uuid;v_limit integer:=coalesce((p->>'limit')::integer,50);v_cursor uuid:=(p->>'cursor')::uuid;
BEGIN
 PERFORM finance_private.fields(p,CASE WHEN kind='product' THEN ARRAY['product_id','limit','cursor'] ELSE ARRAY['limit','cursor'] END);
 IF v_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'INVALID_REQUEST: directory page limit' USING ERRCODE='22023';END IF;
 IF kind='chart' THEN
  WITH page AS(SELECT id,code,name,type,parent_id,is_active,finance_version AS version FROM public.chart_of_accounts WHERE v_cursor IS NULL OR id>v_cursor ORDER BY id LIMIT v_limit)
  SELECT coalesce(jsonb_agg(to_jsonb(page) ORDER BY id),'[]'),(array_agg(id ORDER BY id DESC))[1] INTO v_rows,v_last FROM page;
 ELSIF kind='bank' THEN
  WITH page AS(SELECT id,name,bank,account_type,is_active,finance_version AS version FROM public.bank_accounts WHERE v_cursor IS NULL OR id>v_cursor ORDER BY id LIMIT v_limit)
  SELECT coalesce(jsonb_agg(to_jsonb(page) ORDER BY id),'[]'),(array_agg(id ORDER BY id DESC))[1] INTO v_rows,v_last FROM page;
 ELSIF kind='branch' THEN
  WITH page AS(SELECT id,name,is_active FROM public.branches WHERE v_cursor IS NULL OR id>v_cursor ORDER BY id LIMIT v_limit)
  SELECT coalesce(jsonb_agg(to_jsonb(page) ORDER BY id),'[]'),(array_agg(id ORDER BY id DESC))[1] INTO v_rows,v_last FROM page;
 ELSE
  IF p->>'product_id' IS NULL THEN RAISE EXCEPTION 'INVALID_REQUEST: product' USING ERRCODE='22023';END IF;
  WITH page AS(SELECT ps.id,ps.supplier_id,s.name,ps.label,ps.is_active AND s.is_active AS is_active,ps.reference_cost::text AS reference_cost,ps.reference_sale::text AS reference_sale
   FROM public.product_suppliers ps JOIN public.suppliers s ON s.id=ps.supplier_id WHERE ps.product_id=(p->>'product_id')::uuid AND (v_cursor IS NULL OR ps.id>v_cursor) ORDER BY ps.id LIMIT v_limit)
  SELECT coalesce(jsonb_agg(to_jsonb(page) ORDER BY id),'[]'),(array_agg(id ORDER BY id DESC))[1] INTO v_rows,v_last FROM page;
 END IF;
 RETURN jsonb_build_object('rows',v_rows,'next_cursor',CASE WHEN jsonb_array_length(v_rows)=v_limit THEN v_last END);
END $$;
DO $$ DECLARE def text;a integer;b integer;BEGIN
 def:=pg_get_functiondef('public.finance_query_v1(text,jsonb)'::regprocedure);
 a:=strpos(def,'WHEN ''chart.accounts''');b:=strpos(def,'WHEN ''pending.items''');
 IF a=0 OR b<=a THEN RAISE EXCEPTION 'Unexpected finance query router';END IF;
 def:=substring(def from 1 for a-1)||E'WHEN ''chart.accounts'' THEN v_result:=finance_private.directory_list(p_payload,''chart'');\n  WHEN ''bank.accounts'' THEN v_result:=finance_private.directory_list(p_payload,''bank'');\n  WHEN ''branches'' THEN v_result:=finance_private.directory_list(p_payload,''branch'');\n  WHEN ''product.suppliers'' THEN v_result:=finance_private.directory_list(p_payload,''product'');\n  '||substring(def from b);
 def:=replace(def,'ELSE PERFORM finance_private.require_module(); END IF;', E'ELSIF p_action=''proposal.context'' THEN\n  PERFORM finance_private.fields(p_payload,ARRAY[''proposal_id'']);\n  IF NOT public.admin_can_access_proposal((p_payload->>''proposal_id'')::uuid,false) THEN RAISE EXCEPTION ''RECORD_FORBIDDEN'' USING ERRCODE=''42501'';END IF;\n ELSE PERFORM finance_private.require_module(); END IF;');
 def:=replace(def,'v_result:=finance_private.proposal_snapshot((p_payload->>''proposal_id'')::uuid);',E'v_result:=finance_private.proposal_snapshot((p_payload->>''proposal_id'')::uuid);IF v_result IS NULL THEN RAISE EXCEPTION ''NOT_FOUND'' USING ERRCODE=''P0002'';END IF;');
 EXECUTE def;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA finance_private FROM PUBLIC,anon,authenticated;
COMMIT;
