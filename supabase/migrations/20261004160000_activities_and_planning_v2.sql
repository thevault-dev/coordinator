-- Coordinator v2: activities registry and twice-weekly half-week planning.
--
-- recurring (extended, not replaced) becomes the ACTIVITIES REGISTRY. Each row
-- now has a type that decides how /coordinator:plan treats it:
--   coached    booked by Khaled with someone else (booked_with); the plan only nudges
--   protected  placed early and hard to bump (GMAT)
--   flexible   placed around everything else (swim, run)
--   nudge      needs an action, not a slot (haircut); timed from last_done
--   held       time held by default, Khaled confirms (Dubai drive)
-- The v1.2 weekly window stays required: for a non-held activity it is simply
-- the span of days it may happen in (PT: Mon 06:00 -> Wed 08:30).
--
-- plans         one row per half-week plan that was booked ("book it").
-- plan_blocks   Coordinator-owned record of every block a plan booked on the
--               Coordinator calendar (fixed bookings, activities, held items and
--               PRNTCODE focus blocks). It is what the Sunday review counts and
--               what "move…" and "remove…" act on.
-- PRNTCODE requests are no longer placed one by one: a focus block covers
-- several of them (request_ids), and each covered request is marked
-- scheduled with the block's span and event id. The top half is never touched.
--
-- Also lands the v1.5 pieces v2 depends on, which were never applied:
--   coordinator_resolve   "2 done" / "not needed" -> resolution + status,
--                         reason kept after ": " for the PRNTCODE safety net
--   coordinator_release   retires an old v1 digest proposal back to new
-- Weekdays are ISO (1 = Mon). Times shown to Khaled are Asia/Dubai.

-- ---------------------------------------------------------------------------
-- 1. Activities registry
-- ---------------------------------------------------------------------------
-- activity_type defaults to 'held' so the v1.2 intake_add_recurring (which
-- only ever creates time-window items like the Dubai drive) keeps working.
alter table public.recurring
  add column activity_type     text not null default 'held',
  add column sessions_per_week smallint,
  add column preferred_time    text,
  add column booked_with       text,
  add column last_done         date;

comment on table public.recurring is
  'Activities registry (v2). activity_type decides how /coordinator:plan treats each one. The weekly window is the span of days each one may happen in.';
comment on column public.recurring.activity_type is 'coached | protected | flexible | nudge | held (default, for v1.2 window items).';
comment on column public.recurring.sessions_per_week is 'Sessions per week. Null for nudge items; null on a held item means once a week.';
comment on column public.recurring.preferred_time is 'Free text the planner honours, e.g. "Mon–Wed, before work, finish by 08:30".';
comment on column public.recurring.booked_with is 'Coached items: who it is booked with (free text).';
comment on column public.recurring.last_done is 'Last date it happened (or, for a nudge, was booked). Nudges are timed from it.';

alter table public.recurring
  add constraint recurring_activity_type_check
    check (activity_type in ('coached', 'protected', 'flexible', 'nudge', 'held')),
  add constraint recurring_sessions_check
    check (sessions_per_week is null or sessions_per_week between 1 and 14),
  add constraint recurring_sessions_required
    check (activity_type in ('nudge', 'held') or sessions_per_week is not null);

-- The old daily posting (retired with the digest) only ever applies to held items.
create or replace function public.coordinator_post_recurring()
returns setof public.requests
language plpgsql
set search_path = ''
as $$
declare
  t public.recurring;
  wk date;
  w_start timestamptz;
  w_end timestamptz;
  r public.requests;
begin
  for t in select * from public.recurring
            where active and activity_type = 'held' loop
    foreach wk in array array[public.recurring_week_monday(), public.recurring_week_monday() + 7] loop
      continue when not public.recurring_week_matches(t, wk);
      w_start := ((wk + (t.window_start_dow - 1)) + t.window_start_time) at time zone 'Asia/Dubai';
      w_end   := ((wk + (t.window_end_dow - 1))   + t.window_end_time)   at time zone 'Asia/Dubai';
      continue when w_end - make_interval(mins => t.duration_min) <= now();

      insert into public.requests
        (source_agent, sub_agent, source_ref, title, context, duration_min,
         earliest_start, due_by, flexibility, priority)
      values
        (t.source_agent, 'recurring', public.recurring_source_ref(t.id, wk), t.title, t.context,
         t.duration_min, greatest(w_start, now()), w_end, t.flexibility, t.priority)
      on conflict (source_agent, source_ref) do nothing
      returning * into r;

      if r.id is not null then
        return next r;
        r := null;
      end if;
    end loop;
  end loop;
end;
$$;

-- When is a nudge next due? last_done + interval, else the anchor week.
create or replace function public.activity_next_due(p_activity public.recurring)
returns date
language sql
immutable
set search_path = ''
as $$
  select case
    when p_activity.activity_type <> 'nudge' then null
    when p_activity.last_done is not null then p_activity.last_done + (p_activity.interval_weeks * 7)
    else p_activity.anchor_week
  end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Chat: add / edit an activity, mark one done
-- ---------------------------------------------------------------------------
create or replace function public.intake_add_activity(
  p_title text, p_activity_type text, p_duration_min integer,
  p_sessions_per_week smallint default null, p_preferred_time text default null,
  p_interval_weeks smallint default 1, p_booked_with text default null,
  p_source_agent text default 'personal', p_context text default null,
  p_last_done date default null,
  p_start_dow smallint default 1, p_start_time time default '06:00',
  p_end_dow smallint default 7, p_end_time time default '22:00')
returns public.recurring
language plpgsql
set search_path = ''
as $$
declare
  t public.recurring;
  wk date := public.recurring_week_monday();
begin
  if p_duration_min is null then
    raise exception 'duration_min is required: ask Khaled how long it takes';
  end if;
  if p_activity_type = 'held' then
    raise exception 'held items are set up with intake_add_recurring (a time window and a priority)';
  end if;
  if p_activity_type <> 'nudge' and p_sessions_per_week is null then
    raise exception '% activities need sessions_per_week', p_activity_type;
  end if;
  if exists (select 1 from public.recurring
              where active and lower(btrim(title)) = lower(btrim(p_title))) then
    raise exception 'an active activity called "%" already exists', btrim(p_title);
  end if;

  insert into public.recurring
    (source_agent, title, context, duration_min, flexibility, priority, starts_on,
     interval_weeks, anchor_week, activity_type, sessions_per_week, preferred_time,
     booked_with, last_done, window_start_dow, window_start_time, window_end_dow, window_end_time)
  values
    (coalesce(p_source_agent, 'personal'), btrim(p_title), nullif(btrim(p_context), ''),
     p_duration_min, 'flexible', case when p_activity_type = 'protected' then 2 else 3 end, wk,
     coalesce(p_interval_weeks, 1), wk, p_activity_type,
     case when p_activity_type = 'nudge' then null else p_sessions_per_week end,
     nullif(btrim(p_preferred_time), ''),
     case when p_activity_type = 'coached' then nullif(btrim(p_booked_with), '') end,
     p_last_done,
     coalesce(p_start_dow, 1), coalesce(p_start_time, '06:00'),
     coalesce(p_end_dow, 7), coalesce(p_end_time, '22:00'))
  returning * into t;
  return t;
end;
$$;

create or replace function public.intake_update_activity(
  p_id uuid,
  p_activity_type text default null,
  p_duration_min integer default null,
  p_sessions_per_week smallint default null,
  p_preferred_time text default null,
  p_interval_weeks smallint default null,
  p_booked_with text default null,
  p_title text default null)
returns public.recurring
language plpgsql
set search_path = ''
as $$
declare
  t public.recurring;
begin
  update public.recurring
     set activity_type     = coalesce(p_activity_type, activity_type),
         duration_min      = coalesce(p_duration_min, duration_min),
         sessions_per_week = case when coalesce(p_activity_type, activity_type) = 'nudge' then null
                                  else coalesce(p_sessions_per_week, sessions_per_week) end,
         preferred_time    = coalesce(nullif(btrim(p_preferred_time), ''), preferred_time),
         interval_weeks    = coalesce(p_interval_weeks, interval_weeks),
         booked_with       = coalesce(nullif(btrim(p_booked_with), ''), booked_with),
         title             = coalesce(nullif(btrim(p_title), ''), title)
   where id = p_id and active
  returning * into t;
  if not found then
    raise exception 'activity % not found or stopped', p_id;
  end if;
  return t;
end;
$$;

-- "Booked the haircut", "did my run", "done": last_done moves forward only.
create or replace function public.activity_mark_done(p_id uuid, p_on date default null)
returns public.recurring
language plpgsql
set search_path = ''
as $$
declare
  t public.recurring;
  d date := coalesce(p_on, (now() at time zone 'Asia/Dubai')::date);
begin
  if d > (now() at time zone 'Asia/Dubai')::date + 60 then
    raise exception 'date % is too far ahead', d;
  end if;
  update public.recurring
     set last_done = greatest(coalesce(last_done, d), d)
   where id = p_id and active
  returning * into t;
  if not found then
    raise exception 'activity % not found or stopped', p_id;
  end if;
  return t;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. plan_blocks: what a plan booked on the Coordinator calendar
-- ---------------------------------------------------------------------------
create table public.plans (
  id               uuid primary key default gen_random_uuid(),
  half_week_start  date        not null,
  half_week_end    date        not null,
  summary          text,
  detail           jsonb,
  created_at       timestamptz not null default now(),

  constraint plans_half_week_order check (half_week_end >= half_week_start)
);

comment on table public.plans is
  'One row per half-week plan Khaled booked with "book it" (Mon–Wed or Thu–Sun, Abu Dhabi dates). detail holds the booked overview.';

alter table public.plans enable row level security;
revoke all on table public.plans from anon, authenticated;
create policy plans_no_client_access on public.plans
  for all to anon, authenticated using (false) with check (false);

create table public.plan_blocks (
  id                uuid primary key default gen_random_uuid(),
  plan_id           uuid references public.plans (id),
  kind              text        not null,
  activity_id       uuid references public.recurring (id),
  title             text        not null,
  slot_start        timestamptz not null,
  slot_end          timestamptz not null,
  calendar_event_id text        not null,
  status            text        not null default 'booked',
  request_ids       uuid[]      not null default '{}',
  note              text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint plan_blocks_kind_check   check (kind in ('fixed', 'activity', 'held', 'prntcode')),
  constraint plan_blocks_status_check check (status in ('booked', 'done', 'removed')),
  constraint plan_blocks_slot_order   check (slot_end > slot_start),
  constraint plan_blocks_title_not_blank check (length(btrim(title)) > 0),
  constraint plan_blocks_activity_kind check (kind not in ('activity', 'held') or activity_id is not null),
  constraint plan_blocks_requests_kind check (kind = 'prntcode' or cardinality(request_ids) = 0)
);

comment on table public.plan_blocks is
  'Blocks booked by /coordinator:plan on the Coordinator calendar. Coordinator-owned. Written only through coordinator_book_block / coordinator_unbook_block / coordinator_plan_housekeeping.';

create index plan_blocks_slot_idx on public.plan_blocks (slot_start) where status <> 'removed';
create unique index plan_blocks_event_unique on public.plan_blocks (calendar_event_id) where status <> 'removed';

create trigger plan_blocks_set_updated_at
  before update on public.plan_blocks
  for each row execute function public.set_updated_at();

alter table public.plan_blocks enable row level security;
revoke all on table public.plan_blocks from anon, authenticated;
create policy plan_blocks_no_client_access on public.plan_blocks
  for all to anon, authenticated using (false) with check (false);

-- Is [s, e) inside Mon–Thu 09:00–18:00 Abu Dhabi (the hard work-hours rule)?
create or replace function public.in_work_hours(p_start timestamptz, p_end timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from generate_series((p_start at time zone 'Asia/Dubai')::date,
                         (p_end   at time zone 'Asia/Dubai')::date, interval '1 day') d
    where extract(isodow from d) between 1 and 4
      and tstzrange((d::date + time '09:00') at time zone 'Asia/Dubai',
                    (d::date + time '18:00') at time zone 'Asia/Dubai')
          && tstzrange(p_start, p_end));
$$;

-- Book one block (called at "book it", after the event exists).
create or replace function public.coordinator_book_block(
  p_plan_id uuid, p_kind text, p_title text,
  p_slot_start timestamptz, p_slot_end timestamptz, p_calendar_event_id text,
  p_activity_id uuid default null, p_request_ids uuid[] default '{}', p_note text default null)
returns public.plan_blocks
language plpgsql
set search_path = ''
as $$
declare
  b public.plan_blocks;
  clash text;
  req public.requests;
  rid uuid;
  ids uuid[] := coalesce(p_request_ids, '{}');
begin
  if coalesce(btrim(p_calendar_event_id), '') = '' then
    raise exception 'calendar_event_id is required: create the Coordinator event first';
  end if;
  if p_slot_end <= p_slot_start then
    raise exception 'slot end % is not after start %', p_slot_end, p_slot_start;
  end if;
  if p_slot_start < now() and p_kind <> 'fixed' then
    raise exception 'slot % is in the past', p_slot_start;
  end if;
  if p_kind <> 'fixed' and public.in_work_hours(p_slot_start, p_slot_end) then
    raise exception 'slot % - % is in fund hours (Mon-Thu 09:00-18:00, hard rule)', p_slot_start, p_slot_end;
  end if;
  if p_kind in ('activity', 'held') and not exists (
       select 1 from public.recurring where id = p_activity_id and active) then
    raise exception 'activity % not found or stopped', p_activity_id;
  end if;

  select o.title into clash
  from public.plan_blocks o
  where o.status = 'booked'
    and tstzrange(o.slot_start, o.slot_end) && tstzrange(p_slot_start, p_slot_end)
  limit 1;
  if clash is not null then
    raise exception 'slot overlaps booked block "%"', clash;
  end if;
  select o.title into clash
  from public.requests o
  where o.status in ('proposed', 'scheduled')
    and not (o.id = any (ids))
    and tstzrange(o.slot_start, o.slot_end) && tstzrange(p_slot_start, p_slot_end)
  limit 1;
  if clash is not null then
    raise exception 'slot overlaps ledger request "%" (release or unbook it first)', clash;
  end if;

  if p_kind = 'prntcode' then
    if cardinality(ids) = 0 then
      raise exception 'a PRNTCODE focus block must cover at least one request';
    end if;
    foreach rid in array ids loop
      select * into req from public.requests where id = rid for update;
      if not found or req.source_agent <> 'prntcode' or req.status not in ('new', 'proposed') then
        raise exception 'request % is not an open PRNTCODE request', rid;
      end if;
    end loop;
  end if;

  insert into public.plan_blocks
    (plan_id, kind, activity_id, title, slot_start, slot_end, calendar_event_id, request_ids, note)
  values
    (p_plan_id, p_kind, p_activity_id, btrim(p_title), p_slot_start, p_slot_end,
     p_calendar_event_id, ids, nullif(btrim(p_note), ''))
  returning * into b;

  -- Covered PRNTCODE requests: bottom half only.
  update public.requests
     set status = 'scheduled', slot_start = p_slot_start, slot_end = p_slot_end,
         calendar_event_id = p_calendar_event_id,
         decision_note = 'In PRNTCODE focus block '
           || to_char(p_slot_start at time zone 'Asia/Dubai', 'Dy DD Mon HH24:MI') || '-'
           || to_char(p_slot_end at time zone 'Asia/Dubai', 'HH24:MI'),
         decided_at = now()
   where id = any (ids);

  return b;
end;
$$;

-- Unbook a block ("skip the run", or the first half of "move…"). The
-- event must already be removed from the Coordinator calendar. Covered
-- PRNTCODE requests still scheduled on that event go back to new.
create or replace function public.coordinator_unbook_block(
  p_id uuid, p_removed_event_id text, p_note text default null)
returns public.plan_blocks
language plpgsql
set search_path = ''
as $$
declare
  b public.plan_blocks;
begin
  select * into b from public.plan_blocks where id = p_id for update;
  if not found then
    raise exception 'plan block % not found', p_id;
  end if;
  if b.status <> 'booked' then
    raise exception 'plan block % is already %', p_id, b.status;
  end if;
  if p_removed_event_id is distinct from b.calendar_event_id then
    raise exception 'block % is on event %: remove that event from the Coordinator calendar first and pass its id',
      p_id, b.calendar_event_id;
  end if;

  update public.requests
     set status = 'new', slot_start = null, slot_end = null, calendar_event_id = null,
         decision_note = null, decided_at = now()
   where id = any (b.request_ids) and status = 'scheduled' and calendar_event_id = b.calendar_event_id;

  update public.plan_blocks
     set status = 'removed', note = coalesce(nullif(btrim(p_note), ''), note)
   where id = p_id
  returning * into b;
  return b;
end;
$$;

-- Housekeeping at the start of every plan: past blocks become done, and an
-- activity's last_done follows its latest done block. Ledger requests use
-- the existing coordinator_mark_done().
create or replace function public.coordinator_plan_housekeeping()
returns setof public.plan_blocks
language plpgsql
set search_path = ''
as $$
declare
  b public.plan_blocks;
begin
  for b in
    update public.plan_blocks set status = 'done'
     where status = 'booked' and slot_end <= now()
    returning *
  loop
    if b.activity_id is not null then
      update public.recurring
         set last_done = greatest(coalesce(last_done, (b.slot_start at time zone 'Asia/Dubai')::date),
                                  (b.slot_start at time zone 'Asia/Dubai')::date)
       where id = b.activity_id;
    end if;
    return next b;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. v1.5 pieces: resolve and release
-- ---------------------------------------------------------------------------
-- "2 done" / "supplier call not needed (+ reason)". Sets resolution and keeps
-- Khaled's reason after ": " in decision_note (the PRNTCODE safety net quotes
-- it). new/proposed -> done (done_elsewhere) or declined (not_needed).
-- scheduled -> done; its block/event is left alone (the skill offers to unbook it).
create or replace function public.coordinator_resolve(p_id uuid, p_resolution text, p_reason text default null)
returns public.requests
language plpgsql
set search_path = ''
as $$
declare
  r public.requests;
  label text;
begin
  if p_resolution not in ('done_elsewhere', 'not_needed') then
    raise exception 'resolution must be done_elsewhere or not_needed, not %', p_resolution;
  end if;
  select * into r from public.requests where id = p_id for update;
  if not found then
    raise exception 'request % not found', p_id;
  end if;
  if r.status not in ('new', 'proposed', 'scheduled') then
    raise exception 'request % is already %', p_id, r.status;
  end if;
  label := case p_resolution when 'done_elsewhere' then 'Done elsewhere' else 'Not needed' end;

  update public.requests
     set resolution    = p_resolution,
         status        = case when p_resolution = 'not_needed' and r.status <> 'scheduled'
                              then 'declined' else 'done' end,
         slot_start    = case when r.status = 'scheduled' then slot_start end,
         slot_end      = case when r.status = 'scheduled' then slot_end end,
         decision_note = label || ' (Khaled): ' || coalesce(nullif(btrim(p_reason), ''), 'no reason given'),
         decided_at    = now()
   where id = p_id
  returning * into r;
  return r;
end;
$$;

-- Retire a v1 digest proposal: proposed -> new, slot cleared, so the
-- half-week plan can cover it in a focus block.
create or replace function public.coordinator_release(p_id uuid)
returns public.requests
language plpgsql
set search_path = ''
as $$
declare
  r public.requests;
begin
  update public.requests
     set status = 'new', slot_start = null, slot_end = null, decision_note = null, decided_at = now()
   where id = p_id and status = 'proposed'
  returning * into r;
  if not found then
    raise exception 'request % not found or not proposed', p_id;
  end if;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Lock down: agents only
-- ---------------------------------------------------------------------------
revoke execute on function public.activity_next_due(public.recurring) from public, anon, authenticated;
revoke execute on function public.intake_add_activity(text, text, integer, smallint, text, smallint, text, text, text, date, smallint, time, smallint, time) from public, anon, authenticated;
revoke execute on function public.intake_update_activity(uuid, text, integer, smallint, text, smallint, text, text) from public, anon, authenticated;
revoke execute on function public.activity_mark_done(uuid, date) from public, anon, authenticated;
revoke execute on function public.in_work_hours(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public.coordinator_book_block(uuid, text, text, timestamptz, timestamptz, text, uuid, uuid[], text) from public, anon, authenticated;
revoke execute on function public.coordinator_unbook_block(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.coordinator_plan_housekeeping() from public, anon, authenticated;
revoke execute on function public.coordinator_resolve(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.coordinator_release(uuid) from public, anon, authenticated;

grant execute on function public.activity_next_due(public.recurring) to service_role;
grant execute on function public.intake_add_activity(text, text, integer, smallint, text, smallint, text, text, text, date, smallint, time, smallint, time) to service_role;
grant execute on function public.intake_update_activity(uuid, text, integer, smallint, text, smallint, text, text) to service_role;
grant execute on function public.activity_mark_done(uuid, date) to service_role;
grant execute on function public.in_work_hours(timestamptz, timestamptz) to service_role;
grant execute on function public.coordinator_book_block(uuid, text, text, timestamptz, timestamptz, text, uuid, uuid[], text) to service_role;
grant execute on function public.coordinator_unbook_block(uuid, text, text) to service_role;
grant execute on function public.coordinator_plan_housekeeping() to service_role;
grant execute on function public.coordinator_resolve(uuid, text, text) to service_role;
grant execute on function public.coordinator_release(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 6. Data: seed the routine and convert the existing items.
-- Applied through the checked functions above (the same path chat uses), so
-- it runs once: intake_add_activity refuses a second "PT", etc.
-- ---------------------------------------------------------------------------
select title from public.intake_add_activity('PT', 'coached', 60, 3::smallint,
  'Mon–Wed, before work, finishing by 08:30', 1::smallint, 'PT coach',
  p_start_dow => 1::smallint, p_start_time => '06:00', p_end_dow => 3::smallint, p_end_time => '08:30');
select title from public.intake_add_activity('Tennis', 'coached', 60, 2::smallint,
  'Evenings, any day', 1::smallint, 'Tennis coach');
select title from public.intake_add_activity('GMAT', 'protected', 120, 2::smallint,
  'Mon–Wed, both sessions (4h a week as 2 × 2h)',
  p_start_dow => 1::smallint, p_start_time => '06:00', p_end_dow => 3::smallint, p_end_time => '22:00');
select title from public.intake_add_activity('Swim', 'flexible', 60, 1::smallint);
select title from public.intake_add_activity('Run', 'flexible', 45, 1::smallint);

-- Haircut: every-2-weeks window item -> nudge, keeping its anchor (5 Oct).
select title from public.intake_update_activity(
  (select id from public.recurring where title = 'Haircut' and active),
  p_activity_type => 'nudge', p_preferred_time => 'Fri or Sat daytime');
-- Dubai drive stays held (the column default); Khaled wants it right after work Thursday.
select title from public.intake_update_activity(
  (select id from public.recurring where title = 'Drive back to Dubai' and active),
  p_preferred_time => 'Thu right after work (18:00); Fri if Thu is busy');
-- The haircut's open v1 copy (proposed by the old daily run) is retired:
select status from public.coordinator_decline(r.id, 'Haircut is now a nudge (v2): Khaled books it himself')
  from public.requests r
 where r.source_ref like 'recur-' || (select id::text from public.recurring where title = 'Haircut' limit 1) || '-%'
   and r.status = 'proposed';
