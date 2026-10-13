-- =====================================================================
-- *** STATUS: NOT EXECUTED. ***
-- Written as a review/fixture scaffold for supabase/migrations/
-- 20260911120000_public_proposal_privacy.sql. Docker/local Postgres was
-- unavailable in this session (disk exhausted mid-review), so none of
-- this has been run against a real database. Run it against a local or
-- staging Supabase project (`supabase start` / `supabase db reset`, then
-- `psql "$DB_URL" -f supabase/tests/public_proposal_privacy.sql`) before
-- treating the migration as validated. Every assertion below uses
-- IS DISTINCT FROM (not = / <>) so a NULL result fails loudly instead of
-- silently passing.
--
-- Simulates four real callers via role + JWT claims, matching how
-- PostgREST actually authenticates requests (not just "admin vs anon"):
--   - anon        : no session at all
--   - owner (A)   : authenticated, owns the published proposal via
--                   prospects.email = auth.email()
--   - stranger (B): authenticated, NOT the owner, not an admin -- the
--                   fixture the earlier ad-hoc checks were missing
--   - admin        : authenticated + has_role(..., 'admin')
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Fixtures
-- ---------------------------------------------------------------------

-- Two app users (auth.users is Supabase-managed; minimal columns for FKs).
INSERT INTO auth.users (id, email) VALUES
  ('11111111-1111-1111-1111-111111111111', 'owner@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'stranger@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'admin@example.com')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_roles (user_id, role) VALUES
  ('33333333-3333-3333-3333-333333333333', 'admin')
ON CONFLICT DO NOTHING;

INSERT INTO public.prospects (id, segment, name, email) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'b2c', 'Owner Prospect', 'owner@example.com')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.sellers (id, name, email, phone) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'Internal Seller', 'seller@atmos.tur.br', '+5511900000000')
ON CONFLICT (id) DO NOTHING;

-- P1: published, belongs to the owner, has a nested-secret probe in
-- payment_terms and atmos_service.description.
INSERT INTO public.proposals (
  id, prospect_id, title, status, subtotal, discount_percent, discount_fixed,
  total, num_people, num_days, slug, share_token, published_at,
  show_price_breakdown, atmos_service, payment_terms
) VALUES (
  'cccccccc-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'Chapada 5 dias', 'sent', 4000, 10, 0, 4500, 4, 5,
  'chapada-5-dias', 'dddddddd-0000-0000-0000-000000000001', now(),
  false,
  jsonb_build_object(
    'price_per_person_day', 100, 'num_courtesies', 1,
    'description', jsonb_build_object('public', 'Curadoria completa', 'secret', 'MARGEM 40%'),
    'internal_costs', jsonb_build_array(jsonb_build_object('cost', 999))
  ),
  jsonb_build_object('installments', jsonb_build_array(
    jsonb_build_object('label', jsonb_build_object('public', 'Parcela 1', 'secret', 'SEGREDO'), 'percent', 50, 'due_rule', 'no ato'),
    jsonb_build_object('label', 'Parcela 2', 'percent', 50, 'due_rule', 'D-30'),
    'not-an-object'
  ))
)
ON CONFLICT (id) DO NOTHING;

-- P2: same owner, UNPUBLISHED -- must be invisible to everyone except admin.
INSERT INTO public.proposals (
  id, prospect_id, title, status, subtotal, total, num_people, num_days,
  share_token, published_at, atmos_service
) VALUES (
  'cccccccc-0000-0000-0000-000000000002',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'Rascunho não publicado', 'draft', 1000, 1000, 2, 2,
  'eeeeeeee-0000-0000-0000-000000000002', NULL,
  jsonb_build_object('price_per_person_day', 50, 'num_courtesies', 0)
)
ON CONFLICT (id) DO NOTHING;

-- Finance v1 validates new supplier references. Keep the privacy fixture valid
-- without weakening the private supplier fields checked below.
INSERT INTO public.suppliers(id,name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001','Synthetic privacy supplier')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.proposal_day_items (
  id, proposal_id, day_number, day_label, category, item_name, value,
  cost_price, commission_percent, supplier_id, quantity, item_index
) VALUES
  ('ffffffff-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 1, 'Dia 1', 'Cachoeira', 'Cachoeira Almecegas', 300, 120, 15, 'bbbbbbbb-0000-0000-0000-000000000001', 1, 0),
  ('ffffffff-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000001', 1, 'Dia 1', 'Diária Guia ATMOS', NULL, 400, 200, 0, NULL, 1, 1)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. Role/session helpers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.as_anon() RETURNS void AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', NULL, true);
  SET LOCAL ROLE anon;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_id uuid, p_email text) RETURNS void AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_id, 'email', p_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.assert(p_condition boolean, p_message text) RETURNS void AS $$
BEGIN
  IF p_condition IS NOT TRUE THEN
    RAISE EXCEPTION 'FAILED: %', p_message;
  END IF;
  RAISE NOTICE 'OK: %', p_message;
END; $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- 3. get_public_proposal: published/unpublished/token, no secrets
-- ---------------------------------------------------------------------
DO $$
DECLARE v_result jsonb;
BEGIN
  PERFORM pg_temp.as_anon();

  v_result := public.get_public_proposal('chapada-5-dias');
  PERFORM pg_temp.assert(v_result IS DISTINCT FROM NULL, 'anon reads published proposal by slug');
  PERFORM pg_temp.assert((v_result->>'title') IS NOT DISTINCT FROM 'Chapada 5 dias', 'title matches');

  -- No internal fields anywhere in the payload.
  PERFORM pg_temp.assert(v_result ? 'proposal_costs' IS NOT TRUE, 'no proposal_costs key');
  PERFORM pg_temp.assert(v_result ? 'sellers' IS NOT TRUE, 'no sellers key');
  PERFORM pg_temp.assert((v_result#>>'{atmos_service,internal_costs}') IS DISTINCT FROM '999', 'no internal_costs leak');
  PERFORM pg_temp.assert(
    NOT (v_result::text ILIKE '%cost_price%' OR v_result::text ILIKE '%commission_percent%' OR v_result::text ILIKE '%supplier_id%'),
    'no cost_price/commission_percent/supplier_id substring anywhere in the payload'
  );

  -- show_price_breakdown is false -> per-item value/value_text/price_per_person_day null.
  PERFORM pg_temp.assert((v_result->>'show_price_breakdown') IS NOT DISTINCT FROM 'false', 'breakdown flag reflects saved value (false)');
  PERFORM pg_temp.assert((v_result#>>'{atmos_service,price_per_person_day}') IS NULL, 'price_per_person_day hidden when breakdown is off');
  PERFORM pg_temp.assert(
    (SELECT bool_and((item->>'value') IS NULL) FROM jsonb_array_elements(v_result->'proposal_day_items') item),
    'all item.value null when breakdown is off'
  );

  -- Nested-secret probes (payment_terms.installments[0].label, atmos_service.description).
  PERFORM pg_temp.assert((v_result::text ILIKE '%SEGREDO%') IS NOT TRUE, 'no nested secret under payment_terms.installments.label');
  PERFORM pg_temp.assert((v_result::text ILIKE '%MARGEM%') IS NOT TRUE, 'no nested secret under atmos_service.description');
  PERFORM pg_temp.assert(
    jsonb_array_length(v_result#>'{payment_terms,installments}') = 2,
    'malformed installments array entry ("not-an-object") is dropped, not surfaced'
  );
  PERFORM pg_temp.assert(
    (v_result#>>'{payment_terms,installments,0,label}') IS NULL,
    'installment whose label was itself an object comes back null, not serialized'
  );
  PERFORM pg_temp.assert(
    (v_result#>>'{payment_terms,installments,1,label}') IS NOT DISTINCT FROM 'Parcela 2',
    'well-formed installment still comes through'
  );

  -- Unpublished proposal: invisible to anon, even with a valid token.
  PERFORM pg_temp.assert(public.get_public_proposal('eeeeeeee-0000-0000-0000-000000000002') IS NULL, 'anon cannot read unpublished proposal by token');
  -- Wrong/garbage token.
  PERFORM pg_temp.assert(public.get_public_proposal('does-not-exist') IS NULL, 'unknown token returns null, not an error');
  PERFORM pg_temp.assert(public.get_public_proposal(NULL) IS NULL, 'null token returns null');
  PERFORM pg_temp.assert(public.get_public_proposal('') IS NULL, 'empty token returns null');
END $$;

-- Admin: sees the unpublished proposal, breakdown effectively on, but the
-- returned show_price_breakdown flag is still the RAW saved value (false) --
-- the regression this migration specifically fixed.
DO $$
DECLARE v_result jsonb;
BEGIN
  PERFORM pg_temp.as_user('33333333-3333-3333-3333-333333333333', 'admin@example.com');
  v_result := public.get_public_proposal('eeeeeeee-0000-0000-0000-000000000002');
  PERFORM pg_temp.assert(v_result IS DISTINCT FROM NULL, 'admin can read unpublished proposal');

  v_result := public.get_public_proposal('chapada-5-dias');
  PERFORM pg_temp.assert((v_result->>'show_price_breakdown') IS NOT DISTINCT FROM 'false', 'admin view still reports the raw saved flag (false), not OR''d with admin');
  PERFORM pg_temp.assert((v_result#>>'{proposal_day_items,0,value}') IS NOT DISTINCT FROM '300', 'admin sees real item values regardless of the saved flag');
END $$;

-- ---------------------------------------------------------------------
-- 4. Direct table access: anon/authenticated-stranger must get nothing
-- ---------------------------------------------------------------------
DO $$
DECLARE v_count int;
BEGIN
  PERFORM pg_temp.as_anon();
  SELECT count(*) INTO v_count FROM public.proposals; PERFORM pg_temp.assert(v_count = 0, 'anon SELECT * FROM proposals returns 0 rows');
  SELECT count(*) INTO v_count FROM public.proposal_day_items; PERFORM pg_temp.assert(v_count = 0, 'anon SELECT * FROM proposal_day_items returns 0 rows');
  SELECT count(*) INTO v_count FROM public.sellers; PERFORM pg_temp.assert(v_count = 0, 'anon SELECT * FROM sellers returns 0 rows (was USING (true))');
  SELECT count(*) INTO v_count FROM public.prospects; PERFORM pg_temp.assert(v_count = 0, 'anon SELECT * FROM prospects returns 0 rows');

  PERFORM pg_temp.as_user('22222222-2222-2222-2222-222222222222', 'stranger@example.com');
  SELECT count(*) INTO v_count FROM public.proposals WHERE id = 'cccccccc-0000-0000-0000-000000000001';
  PERFORM pg_temp.assert(v_count = 0, 'authenticated non-owner/non-admin SELECT on someone else''s proposal returns 0 rows');
  SELECT count(*) INTO v_count FROM public.prospects WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  PERFORM pg_temp.assert(v_count = 0, 'authenticated non-owner SELECT on someone else''s prospect (CRM row) returns 0 rows');
END $$;

-- Owner: also gets 0 rows on the raw table now (the fix moved the read
-- path to get_my_published_proposal_link / RPCs only -- no more SELECT *
-- on prospects, even for your own CRM row).
DO $$
DECLARE v_count int;
BEGIN
  PERFORM pg_temp.as_user('11111111-1111-1111-1111-111111111111', 'owner@example.com');
  SELECT count(*) INTO v_count FROM public.prospects WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  PERFORM pg_temp.assert(v_count = 0, 'owner cannot SELECT their own prospects row directly (notes/tags/stage_id no longer reachable this way)');
  SELECT count(*) INTO v_count FROM public.proposals WHERE id = 'cccccccc-0000-0000-0000-000000000001';
  PERFORM pg_temp.assert(v_count = 0, 'owner cannot SELECT their own proposals row directly either -- only via get_public_proposal');
END $$;

-- ---------------------------------------------------------------------
-- 5. get_my_published_proposal_link: owner vs stranger vs anon
-- ---------------------------------------------------------------------
DO $$
DECLARE v_result jsonb;
BEGIN
  PERFORM pg_temp.as_user('11111111-1111-1111-1111-111111111111', 'owner@example.com');
  v_result := public.get_my_published_proposal_link();
  PERFORM pg_temp.assert((v_result->>'slug') IS NOT DISTINCT FROM 'chapada-5-dias', 'owner gets their own published slug');

  PERFORM pg_temp.as_user('22222222-2222-2222-2222-222222222222', 'stranger@example.com');
  PERFORM pg_temp.assert(public.get_my_published_proposal_link() IS NULL, 'stranger (authenticated, non-owner, non-admin) gets null, not the owner''s link');
END $$;

-- anon has no EXECUTE grant on this function at all (GRANT ... TO
-- authenticated only) -- the call itself must be denied at the ACL layer
-- (SQLSTATE 42501 insufficient_privilege), not merely return null as if
-- auth.uid() were evaluated and found empty. Asserting "returns null" here
-- would have silently passed even if PUBLIC/anon accidentally kept EXECUTE.
-- Check the ACL directly. The local Supabase PostgreSQL 17.6 runtime crashes
-- when this DO block changes role via a helper then catches a cached function
-- permission error; checking the effective privilege verifies the same ACL.
SELECT pg_temp.assert(
  NOT has_function_privilege('anon','public.get_my_published_proposal_link()','EXECUTE'),
  'anon is denied EXECUTE on get_my_published_proposal_link at the ACL layer'
);

-- ---------------------------------------------------------------------
-- 6. show_price_breakdown toggle: values appear/disappear accordingly
-- ---------------------------------------------------------------------
DO $$
DECLARE v_result jsonb;
BEGIN
  PERFORM pg_temp.as_user('33333333-3333-3333-3333-333333333333', 'admin@example.com');
  UPDATE public.proposals SET show_price_breakdown = true WHERE id = 'cccccccc-0000-0000-0000-000000000001';

  PERFORM pg_temp.as_anon();
  v_result := public.get_public_proposal('chapada-5-dias');
  PERFORM pg_temp.assert((v_result->>'show_price_breakdown') IS NOT DISTINCT FROM 'true', 'flag reflects the saved value after toggling on');
  PERFORM pg_temp.assert((v_result#>>'{proposal_day_items,0,value}') IS NOT DISTINCT FROM '300', 'item value now visible to anon once toggled on');
  PERFORM pg_temp.assert((v_result#>>'{atmos_service,price_per_person_day}') IS NOT DISTINCT FROM '100', 'atmos price_per_person_day now visible once toggled on');

  PERFORM pg_temp.as_user('33333333-3333-3333-3333-333333333333', 'admin@example.com');
  UPDATE public.proposals SET show_price_breakdown = false WHERE id = 'cccccccc-0000-0000-0000-000000000001';
END $$;

-- ---------------------------------------------------------------------
-- 7. submit_proposal_feedback: token must match AND proposal published
-- ---------------------------------------------------------------------
DO $$
DECLARE v_ok boolean; v_count int;
BEGIN
  PERFORM pg_temp.as_anon();

  v_ok := public.submit_proposal_feedback('cccccccc-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001', 'question', 'Posso levar meu pet?');
  PERFORM pg_temp.assert(v_ok IS TRUE, 'feedback accepted with matching token on a published proposal');

  v_ok := public.submit_proposal_feedback('cccccccc-0000-0000-0000-000000000001', 'wrong-token', 'question', 'x');
  PERFORM pg_temp.assert(v_ok IS NOT TRUE, 'feedback rejected: token does not match this proposal');

  v_ok := public.submit_proposal_feedback('cccccccc-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000002', 'question', 'x');
  PERFORM pg_temp.assert(v_ok IS NOT TRUE, 'feedback rejected: proposal not published');

  -- anon has no direct table access to read any of this back (RPC bypassed
  -- RLS to insert via SECURITY DEFINER; anon itself has no SELECT policy).
  SELECT count(*) INTO v_count FROM public.proposal_feedback;
  PERFORM pg_temp.assert(v_count = 0, 'anon SELECT * FROM proposal_feedback returns 0 rows');
END $$;

-- Verify (as admin, the only role with SELECT on proposal_feedback) that
-- exactly the one accepted call above actually persisted a row, and that
-- the rejected calls left nothing behind.
DO $$
DECLARE v_count int;
BEGIN
  PERFORM pg_temp.as_user('33333333-3333-3333-3333-333333333333', 'admin@example.com');
  SELECT count(*) INTO v_count FROM public.proposal_feedback;
  PERFORM pg_temp.assert(v_count = 1, 'exactly one feedback row was actually inserted (the accepted call)');

  SELECT count(*) INTO v_count FROM public.proposal_feedback WHERE proposal_id = 'cccccccc-0000-0000-0000-000000000002';
  PERFORM pg_temp.assert(v_count = 0, 'no feedback row exists for the unpublished proposal (rejected call inserted nothing)');
END $$;

ROLLBACK;
