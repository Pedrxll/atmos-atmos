-- LOCAL disposable database, run as postgres. Everything rolls back.
BEGIN;
INSERT INTO auth.users(id,email) VALUES
 ('aa170000-0000-4000-8000-000000000001','team-full1@example.invalid'),
 ('aa170000-0000-4000-8000-000000000002','team-full2@example.invalid'),
 ('aa170000-0000-4000-8000-000000000003','team-restricted@example.invalid'),
 ('aa170000-0000-4000-8000-000000000004','team-client@example.invalid'),
 ('aa170000-0000-4000-8000-000000000005','team-target@example.invalid');
INSERT INTO public.user_roles(user_id,role) VALUES
 ('aa170000-0000-4000-8000-000000000001','admin'),
 ('aa170000-0000-4000-8000-000000000002','admin'),
 ('aa170000-0000-4000-8000-000000000003','admin');
INSERT INTO public.admin_permissions(user_id,allowed_modules) VALUES
 ('aa170000-0000-4000-8000-000000000002','{}'),
 ('aa170000-0000-4000-8000-000000000003','{configuracoes}');
-- Isolate the last-full assertions from any existing fixture admins, within rollback.
INSERT INTO public.admin_permissions(user_id,allowed_modules)
 SELECT user_id,'{site}' FROM public.user_roles WHERE role='admin'
 AND user_id NOT IN ('aa170000-0000-4000-8000-000000000001','aa170000-0000-4000-8000-000000000002')
 ON CONFLICT(user_id) DO UPDATE SET allowed_modules=EXCLUDED.allowed_modules;
UPDATE public.admin_permissions SET allowed_modules='{configuracoes}' WHERE user_id='aa170000-0000-4000-8000-000000000003';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','aa170000-0000-4000-8000-000000000003',true);
DO $$ BEGIN
 IF public.is_full_admin(auth.uid()) THEN RAISE EXCEPTION 'Settings module became full admin'; END IF;
 IF (SELECT count(*) FROM public.admin_permissions)<>1 OR (SELECT count(*) FROM public.user_roles)<>1 THEN RAISE EXCEPTION 'Restricted own-read scope failed'; END IF;
 BEGIN UPDATE public.admin_permissions SET allowed_modules='{}' WHERE user_id=auth.uid(); RAISE EXCEPTION 'Self escalation accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN DELETE FROM public.admin_permissions WHERE user_id=auth.uid(); RAISE EXCEPTION 'Delete restrictions accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN INSERT INTO public.user_roles(user_id,role) VALUES('aa170000-0000-4000-8000-000000000004','admin'); RAISE EXCEPTION 'Restricted role grant accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN UPDATE public.user_roles SET user_id='aa170000-0000-4000-8000-000000000004' WHERE user_id=auth.uid(); RAISE EXCEPTION 'Restricted role update accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM public.manage_admin_team('add','aa170000-0000-4000-8000-000000000004','{}'); RAISE EXCEPTION 'Restricted team add accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM public.manage_admin_team('remove','aa170000-0000-4000-8000-000000000002'); RAISE EXCEPTION 'Restricted team remove accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN TRUNCATE public.user_roles; RAISE EXCEPTION 'TRUNCATE accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('request.jwt.claim.sub','aa170000-0000-4000-8000-000000000004',true);
DO $$ BEGIN
 IF public.is_full_admin(auth.uid()) OR (SELECT count(*) FROM public.admin_permissions)<>0 THEN RAISE EXCEPTION 'Client full/read access'; END IF;
 BEGIN INSERT INTO public.admin_permissions(user_id,allowed_modules) VALUES(auth.uid(),'{}'); RAISE EXCEPTION 'Client permission insert accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM public.manage_admin_team('add',auth.uid(),'{}'); RAISE EXCEPTION 'Client team accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SET LOCAL ROLE anon;
DO $$ BEGIN
 -- Effective ACL assertions avoid a cached-call/role-switch crash in the
 -- local PostgreSQL 17.6 platform while retaining the denial checks.
 ASSERT NOT has_function_privilege('anon','public.is_full_admin(uuid)','EXECUTE');
 ASSERT NOT has_function_privilege('anon','public.manage_admin_team(text,uuid,text[])','EXECUTE');
END $$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','aa170000-0000-4000-8000-000000000001',true);
DO $$ BEGIN
 IF NOT public.is_full_admin(auth.uid()) OR NOT public.is_full_admin('aa170000-0000-4000-8000-000000000002') THEN RAISE EXCEPTION 'Absent/empty permissions not full'; END IF;
 PERFORM public.manage_admin_team('add','aa170000-0000-4000-8000-000000000005','{configuracoes}');
 IF NOT public.has_role('aa170000-0000-4000-8000-000000000005','admin') OR public.is_full_admin('aa170000-0000-4000-8000-000000000005') THEN RAISE EXCEPTION 'Restricted atomic add failed'; END IF;
 PERFORM public.manage_admin_team('remove','aa170000-0000-4000-8000-000000000005');
 IF EXISTS(SELECT 1 FROM public.admin_permissions WHERE user_id='aa170000-0000-4000-8000-000000000005') OR public.has_role('aa170000-0000-4000-8000-000000000005','admin') THEN RAISE EXCEPTION 'Remove failed'; END IF;
 BEGIN PERFORM public.manage_admin_team('add','aa170000-0000-4000-8000-000000000005',NULL); RAISE EXCEPTION 'Implicit full grant accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM public.manage_admin_team('remove','aa170000-0000-4000-8000-000000000005'); RAISE EXCEPTION 'Absent removal reported success'; EXCEPTION WHEN no_data_found THEN NULL; END;
 -- Upsert also restricts a legacy full admin whose permission row is missing.
 PERFORM public.manage_admin_team('add',auth.uid(),'{configuracoes}');
 IF public.is_full_admin(auth.uid()) THEN RAISE EXCEPTION 'Existing self-admin restriction failed'; END IF;
 PERFORM set_config('request.jwt.claim.sub','aa170000-0000-4000-8000-000000000002',true);
 INSERT INTO public.admin_permissions(user_id,allowed_modules) VALUES('aa170000-0000-4000-8000-000000000001','{}')
 ON CONFLICT(user_id) DO UPDATE SET allowed_modules=EXCLUDED.allowed_modules;
 PERFORM set_config('request.jwt.claim.sub','aa170000-0000-4000-8000-000000000001',true);
 DELETE FROM public.admin_permissions WHERE user_id=auth.uid();
 -- Authenticated upsert used by TeamTab (not a definer call).
 INSERT INTO public.admin_permissions(user_id,allowed_modules) VALUES(auth.uid(),'{configuracoes}')
 ON CONFLICT(user_id) DO UPDATE SET allowed_modules=EXCLUDED.allowed_modules;
 IF public.is_full_admin(auth.uid()) THEN RAISE EXCEPTION 'Legacy direct upsert did not restrict'; END IF;
 PERFORM set_config('request.jwt.claim.sub','aa170000-0000-4000-8000-000000000002',true);
 DELETE FROM public.admin_permissions WHERE user_id='aa170000-0000-4000-8000-000000000001';
 PERFORM set_config('request.jwt.claim.sub','aa170000-0000-4000-8000-000000000001',true);
 -- Full direct UPDATE remains compatible with TeamTab.
 UPDATE public.admin_permissions SET allowed_modules='{configuracoes}' WHERE user_id='aa170000-0000-4000-8000-000000000002';
 IF public.is_full_admin('aa170000-0000-4000-8000-000000000002') THEN RAISE EXCEPTION 'Full direct update failed'; END IF;
 BEGIN INSERT INTO public.admin_permissions(user_id,allowed_modules) VALUES(auth.uid(),'{configuracoes}'); RAISE EXCEPTION 'Last full restriction accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN DELETE FROM public.user_roles WHERE user_id=auth.uid() AND role='admin'; RAISE EXCEPTION 'Last full removal accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN UPDATE public.user_roles SET role='user' WHERE user_id=auth.uid() AND role='admin'; RAISE EXCEPTION 'Last full role change accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN UPDATE public.user_roles SET user_id='aa170000-0000-4000-8000-000000000004' WHERE user_id=auth.uid() AND role='admin'; RAISE EXCEPTION 'Last full identity change accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
 -- Restore second full, then try removing both in one SQL statement.
 UPDATE public.admin_permissions SET allowed_modules='{}' WHERE user_id='aa170000-0000-4000-8000-000000000002';
 BEGIN DELETE FROM public.user_roles WHERE user_id IN (auth.uid(),'aa170000-0000-4000-8000-000000000002') AND role='admin'; RAISE EXCEPTION 'Multirow last full removal accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
RESET ROLE;
-- Cascades from Auth must not silently delete the final full administrator.
DELETE FROM public.user_roles WHERE user_id='aa170000-0000-4000-8000-000000000002' AND role='admin';
DO $$ BEGIN
 BEGIN DELETE FROM auth.users WHERE id='aa170000-0000-4000-8000-000000000001'; RAISE EXCEPTION 'Auth cascade removed last full'; EXCEPTION WHEN check_violation THEN NULL; END;
 IF NOT public.is_full_admin('aa170000-0000-4000-8000-000000000001') THEN RAISE EXCEPTION 'Last full was lost'; END IF;
END $$;
ROLLBACK;
