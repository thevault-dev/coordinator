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
  r   public.requests;
  e   text;
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

  -- 7. agent_withdraw: new -> declined with note; refuses scheduled and missing rows
  insert into public.requests (source_agent, sub_agent, source_ref, title, duration_min)
  values ('prntcode', 'chief_of_staff', 'dod-withdraw', 'dod withdraw', 30);
  r := public.agent_withdraw('prntcode', 'dod-withdraw', 'task marked done');
  if r.status <> 'declined' or r.decision_note <> 'withdrawn by prntcode: task marked done' then
    raise exception 'FAIL 7: agent_withdraw did not decline with the right note';
  end if;
  insert into public.requests (source_agent, source_ref, title, duration_min, status,
                               slot_start, slot_end, calendar_event_id, decided_at)
  values ('prntcode', 'dod-withdraw-booked', 'dod booked', 30, 'scheduled',
          now() + interval '1 day', now() + interval '1 day 30 minutes', 'evt_dod', now());
  begin perform public.agent_withdraw('prntcode', 'dod-withdraw-booked', 'x'); e := 'ok';
  exception when others then e := 'refused'; end;
  if e <> 'refused' then raise exception 'FAIL 7: agent_withdraw accepted a scheduled row'; end if;
  begin perform public.agent_withdraw('prntcode', 'dod-missing', 'x'); e := 'ok';
  exception when others then e := 'refused'; end;
  if e <> 'refused' then raise exception 'FAIL 7: agent_withdraw accepted a missing row'; end if;
  raise notice 'PASS 7: agent_withdraw declines new rows, refuses booked and missing ones';

  -- 8. resolution / tracker_closed_at / agent_mark_tracker_closed
  insert into public.requests (source_agent, sub_agent, source_ref, title, duration_min, updated_at)
  values ('prntcode', 'chief_of_staff', 'dod-close', 'dod close', 30, '2000-01-01')
  returning * into r;
  update public.requests set resolution = 'not_needed' where id = r.id;
  r := public.agent_mark_tracker_closed(r.id);
  if r.tracker_closed_at is null then raise exception 'FAIL 8: tracker_closed_at not stamped'; end if;
  if r.updated_at <> '2000-01-01' then raise exception 'FAIL 8: resolution/stamp bumped updated_at'; end if;
  if (public.agent_mark_tracker_closed(r.id)).tracker_closed_at <> r.tracker_closed_at then
    raise exception 'FAIL 8: second stamp changed tracker_closed_at';
  end if;
  begin update public.requests set resolution = 'banana' where id = r.id; e := 'ok';
  exception when check_violation then e := 'refused'; end;
  if e <> 'refused' then raise exception 'FAIL 8: resolution = banana accepted'; end if;
  insert into public.requests (source_agent, source_ref, title, duration_min)
  values ('personal', 'dod-close-personal', 'dod personal', 30) returning * into r;
  begin perform public.agent_mark_tracker_closed(r.id); e := 'ok';
  exception when others then e := 'refused'; end;
  if e <> 'refused' then raise exception 'FAIL 8: agent_mark_tracker_closed stamped a personal row'; end if;
  raise notice 'PASS 8: resolution checked, stamp is prntcode-only, idempotent and leaves updated_at alone';

  -- 9. Domain-agent functions are service_role only

  if exists (
    select 1 from information_schema.routine_privileges
     where routine_schema = 'public'
       and routine_name in ('agent_withdraw', 'agent_mark_tracker_closed')
       and grantee in ('anon', 'authenticated', 'PUBLIC')) then
    raise exception 'FAIL 9: an agent_* function is executable beyond service_role';
  end if;
  raise notice 'PASS 9: agent_* functions are service_role only';

  -- 10. v2 activities: types, add-from-chat, duplicate refusal, nudge timing, last_done
  declare
    a public.recurring; b public.plan_blocks; p public.plans; q1 public.requests; q2 public.requests;
    mon date := public.recurring_week_monday() + 14;   -- a Monday two weeks out
  begin
    a := public.intake_add_activity('dod piano', 'coached', 60, 1::smallint, 'any evening', 1::smallint, 'Piano teacher');
    if a.activity_type <> 'coached' or a.booked_with <> 'Piano teacher' or a.sessions_per_week <> 1 then
      raise exception 'FAIL 10: coached activity not added as asked';
    end if;
    begin perform public.intake_add_activity('DOD Piano', 'coached', 60, 1::smallint); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 10: duplicate activity accepted'; end if;
    begin perform public.intake_add_activity('dod swim2', 'flexible', 60); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 10: flexible activity without sessions accepted'; end if;
    begin update public.recurring set activity_type = 'banana' where id = a.id; e := 'ok';
    exception when check_violation then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 10: activity_type banana accepted'; end if;

    a := public.intake_add_activity('dod barber', 'nudge', 30, null, null, 2::smallint);
    if a.sessions_per_week is not null or public.activity_next_due(a) <> a.anchor_week then
      raise exception 'FAIL 10: new nudge not due at its anchor';
    end if;
    a := public.activity_mark_done(a.id, '2026-10-04');
    if a.last_done <> '2026-10-04' or public.activity_next_due(a) <> '2026-10-18' then
      raise exception 'FAIL 10: nudge not re-timed from last_done';
    end if;
    a := public.activity_mark_done(a.id, '2026-10-01');
    if a.last_done <> '2026-10-04' then raise exception 'FAIL 10: last_done moved backwards'; end if;
    raise notice 'PASS 10: activities add, refuse duplicates/bad types, nudges time from last_done';

    -- 11. plan blocks: hard rule, overlaps, focus block covers several requests, unbook, housekeeping
    if not public.in_work_hours((mon + time '10:00') at time zone 'Asia/Dubai', (mon + time '11:00') at time zone 'Asia/Dubai')
       or public.in_work_hours((mon + time '07:30') at time zone 'Asia/Dubai', (mon + time '08:30') at time zone 'Asia/Dubai')
       or public.in_work_hours((mon + 4 + time '10:00') at time zone 'Asia/Dubai', (mon + 4 + time '11:00') at time zone 'Asia/Dubai') then
      raise exception 'FAIL 11: in_work_hours wrong (Mon 10:00 / Mon 07:30 / Fri 10:00)';
    end if;
    insert into public.plans (half_week_start, half_week_end) values (mon, mon + 2) returning * into p;
    begin perform public.coordinator_book_block(p.id, 'activity', 'dod gym',
        (mon + time '10:00') at time zone 'Asia/Dubai', (mon + time '11:00') at time zone 'Asia/Dubai', 'evt_dod_w', a.id); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 11: block in fund hours accepted'; end if;

    insert into public.requests (source_agent, sub_agent, source_ref, title, duration_min, due_by)
    values ('prntcode', 'chief_of_staff', 'dod-v2-a', 'dod focus a', 90, (mon + 3) at time zone 'Asia/Dubai') returning * into q1;
    insert into public.requests (source_agent, sub_agent, source_ref, title, duration_min, due_by)
    values ('prntcode', 'chief_of_staff', 'dod-v2-b', 'dod focus b', 60, (mon + 3) at time zone 'Asia/Dubai') returning * into q2;
    b := public.coordinator_book_block(p.id, 'prntcode', 'PRNTCODE focus',
        (mon + time '19:00') at time zone 'Asia/Dubai', (mon + time '20:30') at time zone 'Asia/Dubai', 'evt_dod_f', null,
        array[q1.id, q2.id]);
    select * into q1 from public.requests where id = q1.id;
    if q1.status <> 'scheduled' or q1.calendar_event_id <> 'evt_dod_f' or q1.slot_start <> b.slot_start then
      raise exception 'FAIL 11: covered request not scheduled into the focus block';
    end if;
    begin perform public.coordinator_book_block(p.id, 'activity', 'dod clash',
        (mon + time '20:00') at time zone 'Asia/Dubai', (mon + time '21:00') at time zone 'Asia/Dubai', 'evt_dod_c', a.id); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 11: overlapping block accepted'; end if;
    begin perform public.coordinator_book_block(p.id, 'prntcode', 'dod empty',
        (mon + 1 + time '19:00') at time zone 'Asia/Dubai', (mon + 1 + time '20:00') at time zone 'Asia/Dubai', 'evt_dod_e'); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 11: focus block with no requests accepted'; end if;
    begin perform public.coordinator_unbook_block(b.id, 'wrong_event'); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 11: unbook without the right event id accepted'; end if;
    b := public.coordinator_unbook_block(b.id, 'evt_dod_f', 'dod');
    select * into q1 from public.requests where id = q1.id;
    if b.status <> 'removed' or q1.status <> 'new' or q1.slot_start is not null then
      raise exception 'FAIL 11: unbook did not free the block and its requests';
    end if;
    -- a block that already ended becomes done and sets the activity's last_done
    a := public.intake_add_activity('dod run2', 'flexible', 45, 1::smallint);
    insert into public.plan_blocks (plan_id, kind, activity_id, title, slot_start, slot_end, calendar_event_id)
    values (p.id, 'activity', a.id, 'dod past', now() - interval '2 days', now() - interval '2 days' + interval '45 minutes', 'evt_dod_p')
    returning * into b;
    perform public.coordinator_plan_housekeeping();
    select * into a from public.recurring where id = a.id;
    select * into b from public.plan_blocks where id = b.id;
    if b.status <> 'done' or a.last_done <> ((now() - interval '2 days') at time zone 'Asia/Dubai')::date then
      raise exception 'FAIL 11: housekeeping did not mark the past block done and move last_done';
    end if;
    raise notice 'PASS 11: plan blocks keep fund hours, refuse overlaps, cover several requests, unbook cleanly';

    -- 12. resolve and release (v1.5 replies inside the planning chat)
    q2 := public.coordinator_resolve(q2.id, 'not_needed', 'her visa came through');
    if q2.status <> 'declined' or q2.resolution <> 'not_needed'
       or q2.decision_note <> 'Not needed (Khaled): her visa came through' then
      raise exception 'FAIL 12: resolve not_needed wrong: % %', q2.status, q2.decision_note;
    end if;
    q1 := public.coordinator_resolve(q1.id, 'done_elsewhere', null);
    if q1.status <> 'done' or q1.decision_note <> 'Done elsewhere (Khaled): no reason given' then
      raise exception 'FAIL 12: resolve done_elsewhere wrong';
    end if;
    begin perform public.coordinator_resolve(q1.id, 'not_needed'); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 12: resolving a closed request accepted'; end if;
    insert into public.requests (source_agent, source_ref, title, duration_min, status, slot_start, slot_end, decided_at)
    values ('prntcode', 'dod-v2-rel', 'dod release', 30, 'proposed', now() + interval '3 days', now() + interval '3 days 30 minutes', now())
    returning * into q1;
    q1 := public.coordinator_release(q1.id);
    if q1.status <> 'new' or q1.slot_start is not null then raise exception 'FAIL 12: release did not reset'; end if;
    raise notice 'PASS 12: resolve keeps the reason after ": ", release resets old proposals';
  end;

  -- 14-16. v2.1 human-shaped planning: places, travel, rules, focus limits
  declare
    pl1 public.places; pl2 public.places; tr public.travel_minutes; ru public.rules;
    a public.recurring; b public.plan_blocks; p public.plans; g public.recurring;
    mon date := public.recurring_week_monday() + 21;   -- a Monday three weeks out
  begin
    -- 14. places and travel
    pl1 := public.place_add('dod tennis club', 'Saadiyat, Abu Dhabi');
    pl2 := public.place_add('dod home AD', 'Abu Dhabi');
    begin perform public.place_add('DOD Tennis Club'); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 14: duplicate place accepted'; end if;
    a := public.intake_add_activity('dod tennis2', 'coached', 60, 1::smallint);
    a := public.activity_set_place(a.id, pl1.id);
    if a.place_id <> pl1.id then raise exception 'FAIL 14: activity place not stored'; end if;
    if public.travel_between(pl1.id, pl2.id) is not null then raise exception 'FAIL 14: unknown travel not null'; end if;
    tr := public.travel_set(pl2.id, pl1.id, 25);
    if public.travel_between(pl1.id, pl2.id) <> 25 or public.travel_between(pl2.id, pl1.id) <> 25
       or public.travel_between(pl1.id, pl1.id) <> 0 then
      raise exception 'FAIL 14: travel is not symmetric or same-place is not 0';
    end if;
    tr := public.travel_set(pl1.id, pl2.id, 30);
    if public.travel_between(pl2.id, pl1.id) <> 30 or (select count(*) from public.travel_minutes
        where place_a = least(pl1.id, pl2.id) and place_b = greatest(pl1.id, pl2.id)) <> 1 then
      raise exception 'FAIL 14: re-estimate did not replace the single pair row';
    end if;
    raise notice 'PASS 14: places are unique, activities keep a default place, travel is one symmetric row per pair';

    -- 15. editable rules ("dinner at 20:00 from now on")
    ru := public.coordinator_set_rule('meal_dinner',
      'Dinner is protected for 1 hour at 20:00 (window 19:30-21:00).', 'hard',
      '{"duration_min": 60, "window_start": "19:30", "window_end": "21:00", "fixed_start": "20:00"}');
    if (select count(*) from public.rules where key = 'meal_dinner' and active) <> 1
       or public.coordinator_rule_params('meal_dinner')->>'fixed_start' <> '20:00' then
      raise exception 'FAIL 15: dinner rule not replaced cleanly';
    end if;
    if not exists (select 1 from public.rules where key = 'meal_dinner' and not active) then
      raise exception 'FAIL 15: old dinner rule not kept as history';
    end if;
    begin perform public.coordinator_set_rule('meal_dinner', 'x', 'hard',
      '{"duration_min": 60, "window_start": "19:30", "window_end": "21:00", "fixed_start": "20:30"}'); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 15: dinner outside its window accepted'; end if;
    raise notice 'PASS 15: rules are edited by key, history kept, a dinner outside its window is refused';

    -- 16. coordinator_book_block enforces the human-time rules
    insert into public.plans (half_week_start, half_week_end, summary) values (mon, mon + 2, 'dod v2.1') returning * into p;
    g := public.intake_add_activity('dod study', 'protected', 90, 3::smallint);
    begin perform public.coordinator_book_block(p.id, 'activity', 'dod study 2h',
        (mon + time '18:30') at time zone 'Asia/Dubai', (mon + time '20:30') at time zone 'Asia/Dubai', 'evt_dod21_x', g.id); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 16: 2h focus block accepted'; end if;
    b := public.coordinator_book_block(p.id, 'activity', 'dod study',
        (mon + time '18:30') at time zone 'Asia/Dubai', (mon + time '20:00') at time zone 'Asia/Dubai', 'evt_dod21_1', g.id,
        '{}', null, pl2.id);
    if b.place_id <> pl2.id then raise exception 'FAIL 16: block place not stored'; end if;
    begin perform public.coordinator_book_block(p.id, 'activity', 'dod study back-to-back',
        (mon + time '20:00') at time zone 'Asia/Dubai', (mon + time '21:30') at time zone 'Asia/Dubai', 'evt_dod21_x', g.id); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 16: focus block with no break accepted'; end if;
    b := public.coordinator_book_block(p.id, 'meal', 'Dinner',
        (mon + time '20:00') at time zone 'Asia/Dubai', (mon + time '20:15') at time zone 'Asia/Dubai', 'evt_dod21_m');
    b := public.coordinator_book_block(p.id, 'activity', 'dod study 2',
        (mon + time '20:15') at time zone 'Asia/Dubai', (mon + time '21:45') at time zone 'Asia/Dubai', 'evt_dod21_2', g.id);
    begin perform public.coordinator_book_block(p.id, 'activity', 'dod study 3',
        (mon + 1 + time '05:00') at time zone 'Asia/Dubai', (mon + 1 + time '06:00') at time zone 'Asia/Dubai', 'evt_dod21_x', g.id); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'ok' then raise exception 'FAIL 16: a morning focus block was refused by the evening limit'; end if;
    begin perform public.coordinator_book_block(p.id, 'activity', 'dod study 3',
        (mon + time '06:00') at time zone 'Asia/Dubai', (mon + time '07:00') at time zone 'Asia/Dubai', 'evt_dod21_y', g.id); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'ok' then raise exception 'FAIL 16: morning focus block refused'; end if;
    begin perform public.coordinator_book_block(p.id, 'activity', 'dod run late',
        (mon + 2 + time '21:15') at time zone 'Asia/Dubai', (mon + 2 + time '22:15') at time zone 'Asia/Dubai', 'evt_dod21_z', a.id); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 16: weeknight block ending 22:15 accepted'; end if;
    b := public.coordinator_book_block(p.id, 'fixed', 'dod late dinner (Khaled fixed it)',
        (mon + 2 + time '21:00') at time zone 'Asia/Dubai', (mon + 2 + time '23:00') at time zone 'Asia/Dubai', 'evt_dod21_f');
    b := public.coordinator_book_block(p.id, 'travel', 'Travel home',
        (mon + 2 + time '23:00') at time zone 'Asia/Dubai', (mon + 2 + time '23:30') at time zone 'Asia/Dubai', 'evt_dod21_t',
        null, '{}', null, pl2.id);
    -- third focus block on one weekday evening
    b := public.coordinator_book_block(p.id, 'activity', 'dod eve 1',
        (mon + 1 + time '18:30') at time zone 'Asia/Dubai', (mon + 1 + time '19:30') at time zone 'Asia/Dubai', 'evt_dod21_e1', g.id);
    b := public.coordinator_book_block(p.id, 'activity', 'dod eve 2',
        (mon + 1 + time '19:45') at time zone 'Asia/Dubai', (mon + 1 + time '20:15') at time zone 'Asia/Dubai', 'evt_dod21_e2', g.id);
    begin perform public.coordinator_book_block(p.id, 'activity', 'dod eve 3',
        (mon + 1 + time '20:30') at time zone 'Asia/Dubai', (mon + 1 + time '21:00') at time zone 'Asia/Dubai', 'evt_dod21_e3', g.id); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 16: third focus block on a weekday evening accepted'; end if;
    begin perform public.coordinator_book_block_v2_0(p.id, 'fixed', 'old', now() + interval '30 days', now() + interval '30 days 1 hour', 'evt_old'); e := 'ok';
    exception when others then e := 'refused'; end;
    if e <> 'refused' then raise exception 'FAIL 16: retired v2.0 book_block still works'; end if;
    raise notice 'PASS 16: focus <= 90 min with breaks, max 2 per weekday evening, wind-down 22:00, meals/travel/places';
  end;

  if exists (
    select 1 from information_schema.routine_privileges
     where routine_schema = 'public'
       and routine_name in ('intake_add_activity', 'intake_update_activity', 'activity_mark_done',
                            'coordinator_book_block', 'coordinator_unbook_block', 'coordinator_plan_housekeeping',
                            'coordinator_resolve', 'coordinator_release',
                            'place_add', 'place_retire', 'activity_set_place', 'travel_set', 'travel_between',
                            'coordinator_rule_params', 'coordinator_set_rule', 'plan_block_is_focus',
                            'coordinator_book_block_v2_0')
       and grantee in ('anon', 'authenticated', 'PUBLIC')) then
    raise exception 'FAIL 13: a v2/v2.1 function is executable beyond service_role';
  end if;
  raise notice 'PASS 13: v2 and v2.1 functions are service_role only';

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
