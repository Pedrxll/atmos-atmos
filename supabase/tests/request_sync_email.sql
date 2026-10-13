-- Local disposable DB only. The form keeps the original email spelling.
BEGIN;
CREATE TEMP TABLE sync_context(admin_id uuid);
INSERT INTO sync_context VALUES(gen_random_uuid());
INSERT INTO auth.users(id,email) SELECT admin_id,admin_id::text||'@example.invalid' FROM sync_context;
INSERT INTO public.user_roles(user_id,role) SELECT admin_id,'admin' FROM sync_context;
SET LOCAL ROLE anon;
INSERT INTO public.quote_requests(user_name,user_email,answers)
VALUES('Email sync fixture',' Mixed.Sync@Example.Invalid ','{"groupSize":"1"}');
INSERT INTO public.imersao_leads(nome,email,telefone,empresa,cargo,tipo_grupo,num_participantes,quando)
VALUES('Email sync fixture',' MIXED.Sync@Example.Invalid ','','Fixture','Organizer','corporate','1','flexible');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',(SELECT admin_id::text FROM sync_context),true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE p record; r jsonb; BEGIN
  FOR p IN SELECT id,segment FROM public.prospects WHERE email='mixed.sync@example.invalid' LOOP
    r:=public.finance_command_v1('proposal.save',jsonb_build_object('proposal',jsonb_build_object(
      'title','Email sync fixture','segment',p.segment,'prospect_id',p.id,'language','pt',
      'num_people',3,'num_days',2,'start_date','2027-01-02','end_date','2027-01-03'),
      'items','[]'::jsonb,'costs','[]'::jsonb,'days','[]'::jsonb,'accommodations','[]'::jsonb),
      'email-sync:'||p.id);
    IF r ? 'error' THEN RAISE EXCEPTION 'V1 proposal sync failed: %',r; END IF;
  END LOOP;
  IF NOT EXISTS(SELECT 1 FROM public.quote_requests WHERE user_email=' Mixed.Sync@Example.Invalid '
    AND answers->>'groupSize'='3' AND answers->>'numDays'='2' AND answers->>'startDate'='2027-01-02') THEN
    RAISE EXCEPTION 'B2C mixed-case request was not synchronized';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.imersao_leads WHERE email=' MIXED.Sync@Example.Invalid '
    AND num_participantes='3' AND data_especifica='2027-01-02'::date AND data_especifica_fim='2027-01-03'::date) THEN
    RAISE EXCEPTION 'B2B mixed-case request was not synchronized';
  END IF;
END $$;
RESET ROLE;
ROLLBACK;
