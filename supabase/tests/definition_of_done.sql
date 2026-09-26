-- Definition-of-Done checks for the Coordinator Ledger.
-- Paste into the Supabase SQL editor (or psql) and run. Everything happens
-- inside a transaction that is rolled back, so no data is left behind.
-- Success: the last line reads "ALL LEDGER CHECKS PASSED".
-- Failure: an error names the check that failed.

begin;

do $$
declare
  n   integer;
  ts  timestamptz;
  rls boolean;
begin
  -- 1. Unknown status is rejected
  begin
    insert into public.requests (source_agent, source_ref, title, duration_min, status)
    values ('personal', 'dod-banana', 'Banana', 30, 'banana');
    raise exception 'FAIL 1: status = banana was accepted';
  exception when check_violation then
    raise notice 'PASS 1: status = banana rejected (%)', sqlerrm;
  end;

  -- 2. Re-posting the same source_agent + source_ref leaves one row
  insert into public.requests (source_agent, source_ref, title, duration_min)
  values ('prntcode', 'dod-dup', 'First post', 30)
  on conflict (source_agent, source_ref) do update set title = excluded.title;
  insert into public.requests (source_agent, source_ref, title, duration_min)
  values ('prntcode', 'dod-dup', 'Second post', 30)
  on conflict (source_agent, source_ref) do update set title = excluded.title;
  select count(*) into n from public.requests
   where source_agent = 'prntcode' and source_ref = 'dod-dup';
  if n <> 1 then raise exception 'FAIL 2: expected 1 row, found %', n; end if;
  raise notice 'PASS 2: duplicate post upserted, 1 row';

  -- A plain insert (no upsert) of a duplicate is refused outright
  begin
    insert into public.requests (source_agent, source_ref, title, duration_min)
    values ('prntcode', 'dod-dup', 'Third post', 30);
    raise exception 'FAIL 2b: plain duplicate insert was accepted';
  exception when unique_violation then
    raise notice 'PASS 2b: plain duplicate insert rejected (%)', sqlerrm;
  end;

  -- 3. updated_at is set automatically on edit (requests and rules).
  -- Force an old value, edit another column, and check the trigger replaced it.
  update public.requests set updated_at = '2000-01-01' where source_ref = 'dod-dup';
  update public.requests set context = 'edited' where source_ref = 'dod-dup';
  select updated_at into ts from public.requests where source_ref = 'dod-dup';
  if ts <= '2000-01-01' then raise exception 'FAIL 3: requests.updated_at not refreshed'; end if;

  insert into public.rules (owner_agent, rule, kind) values ('personal', 'dod rule', 'soft');
  update public.rules set updated_at = '2000-01-01' where rule = 'dod rule';
  update public.rules set active = false where rule = 'dod rule';
  select updated_at into ts from public.rules where rule = 'dod rule';
  if ts <= '2000-01-01' then raise exception 'FAIL 3: rules.updated_at not refreshed'; end if;
  raise notice 'PASS 3: updated_at refreshed on edit';

  -- 4. Bumped / declined require a decision_note
  begin
    update public.requests set status = 'bumped', decision_note = null where source_ref = 'dod-dup';
    raise exception 'FAIL 4: bumped without decision_note was accepted';
  exception when check_violation then
    raise notice 'PASS 4: bumped without a decision_note rejected';
  end;

  -- 5. RLS is on for both tables
  select bool_and(relrowsecurity) into rls from pg_class
   where oid in ('public.requests'::regclass, 'public.rules'::regclass);
  if not rls then raise exception 'FAIL 5: RLS is off on a ledger table'; end if;
  raise notice 'PASS 5: RLS enabled on requests and rules';

  -- 6. The public roles have no access at all
  if has_table_privilege('anon', 'public.requests', 'SELECT')
     or has_table_privilege('anon', 'public.rules', 'SELECT')
     or has_table_privilege('anon', 'public.this_week_proposed', 'SELECT')
     or has_table_privilege('authenticated', 'public.requests', 'SELECT')
     or has_table_privilege('authenticated', 'public.rules', 'SELECT')
     or has_table_privilege('authenticated', 'public.this_week_proposed', 'SELECT') then
    raise exception 'FAIL 6: anon/authenticated can read a ledger table';
  end if;
  raise notice 'PASS 6: anon and authenticated have no read access';

  raise notice 'ALL LEDGER CHECKS PASSED';
end;
$$;

-- Only reached if every check above passed (a failure stops the script).
select 'ALL LEDGER CHECKS PASSED' as result;

-- 6b. Act as the anonymous API role and try to read (expected: permission denied).
-- Uncomment one at a time to see the error for yourself:
-- set local role anon; select * from public.requests;
-- set local role anon; select * from public.rules;

rollback;
