-- Run only against a disposable local DB after migrations. Always rollback.
BEGIN;
INSERT INTO auth.users(id) VALUES ('a1000000-0000-0000-0000-000000000001'),('a1000000-0000-0000-0000-000000000002'),('a1000000-0000-0000-0000-000000000003'),('a1000000-0000-0000-0000-000000000004');
INSERT INTO public.user_roles(user_id,role) VALUES ('a1000000-0000-0000-0000-000000000003','admin');
INSERT INTO public.guides(id,name,user_id) VALUES
('b1000000-0000-0000-0000-000000000001','Guide A','a1000000-0000-0000-0000-000000000001'),
('b1000000-0000-0000-0000-000000000002','Guide B','a1000000-0000-0000-0000-000000000002');
INSERT INTO public.proposals(id,title,guide_id,status,code,total,notes) VALUES
('c1000000-0000-0000-0000-000000000001','PRIVATE CLIENT A','b1000000-0000-0000-0000-000000000001','approved','GUIDE-TEST-A',12345,'PRIVATE NOTES'),
('c1000000-0000-0000-0000-000000000002','PRIVATE CLIENT B','b1000000-0000-0000-0000-000000000002','approved','GUIDE-TEST-B',54321,'PRIVATE NOTES');
INSERT INTO public.proposal_day_items(proposal_id,day_number,category,item_name,value,description,start_time,end_time) VALUES
('c1000000-0000-0000-0000-000000000001',1,'Atrativo','Waterfall',999,'PRIVATE ITEM NOTE','08:30','10:30');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000001',true);
DO $$ DECLARE v jsonb; BEGIN
  IF public.get_guide_portal_context()->>'guide_id' IS DISTINCT FROM 'b1000000-0000-0000-0000-000000000001' THEN RAISE EXCEPTION 'wrong guide'; END IF;
  v:=public.get_guide_portal_proposals();
  IF jsonb_array_length(v) IS DISTINCT FROM 1 OR v->0->>'code' IS DISTINCT FROM 'GUIDE-TEST-A' THEN RAISE EXCEPTION 'assignment leaked or absent'; END IF;
  IF (v->0) - ARRAY['id','code','status','start_date','end_date','num_people','items'] IS DISTINCT FROM '{}'::jsonb THEN RAISE EXCEPTION 'unexpected projection field'; END IF;
  IF v->0->'items'->0->>'start_time' IS DISTINCT FROM '08:30' OR v->0->'items'->0->>'item_name' IS DISTINCT FROM 'Waterfall' THEN RAISE EXCEPTION 'itinerary absent'; END IF;
  IF (v->0->'items'->0) - ARRAY['day_number','category','item_name','start_time','end_time'] IS DISTINCT FROM '{}'::jsonb THEN RAISE EXCEPTION 'private item fields exposed'; END IF;
  IF EXISTS(SELECT 1 FROM public.guides) THEN RAISE EXCEPTION 'guides table exposed'; END IF;
  BEGIN
    PERFORM public.get_guide_portal_proposals('b1000000-0000-0000-0000-000000000002');
    RAISE EXCEPTION 'nonadmin preview allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  INSERT INTO public.guide_trip_costs(id,guide_id,proposal_id,description,amount) VALUES ('d1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','Meal',123.45);
  IF (SELECT amount FROM public.guide_trip_costs WHERE id='d1000000-0000-0000-0000-000000000001') IS DISTINCT FROM 123.45 THEN RAISE EXCEPTION 'amount corrupted'; END IF;
  BEGIN
    UPDATE public.guide_trip_costs SET proposal_id='c1000000-0000-0000-0000-000000000002' WHERE id='d1000000-0000-0000-0000-000000000001';
    RAISE EXCEPTION 'cost reassignment allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000002',true);
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM public.guide_trip_costs WHERE id='d1000000-0000-0000-0000-000000000001') THEN RAISE EXCEPTION 'other guide costs exposed'; END IF;
END $$;
SELECT set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000004',true);
DO $$ BEGIN
  IF public.get_guide_portal_context()->>'guide_id' IS NOT NULL THEN RAISE EXCEPTION 'unlinked account authorized'; END IF;
  BEGIN PERFORM public.get_guide_portal_proposals(); RAISE EXCEPTION 'unlinked proposals exposed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000003',true);
DO $$ BEGIN
  BEGIN PERFORM public.get_guide_portal_proposals(); RAISE EXCEPTION 'implicit admin preview'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  IF public.get_guide_portal_proposals('b1000000-0000-0000-0000-000000000002')->0->>'code' IS DISTINCT FROM 'GUIDE-TEST-B' THEN RAISE EXCEPTION 'explicit admin preview failed'; END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $$ BEGIN
  -- Avoid the PostgreSQL 17.6 local runtime cached-call/role-switch crash;
  -- assert effective EXECUTE privileges without invoking a cached denied call.
  ASSERT NOT has_function_privilege('anon','public.get_guide_portal_context(uuid)','EXECUTE');
  ASSERT NOT has_function_privilege('anon','public.get_guide_portal_proposals(uuid)','EXECUTE');
END $$;
RESET ROLE;
ROLLBACK;
