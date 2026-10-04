-- Coordinator v2.1: human-shaped planning.
--
-- places          where things happen (name + area). Learned from chat: the plan
--                 asks "Where's tennis?" once, then remembers.
-- travel_minutes  Khaled's own estimate between two places (symmetric, one row
--                 per pair). No map APIs in v1: the plan asks once, then stores.
-- recurring.place_id    each activity's default place (PT gym, tennis club...).
--                 It lives on the activity, not the place, so one place can be
--                 the default for several activities (gym: PT and swim).
-- plan_blocks.place_id  where a booked block happens; new kinds 'meal' and
--                 'travel' (dinner is protected, travel is blocked).
-- rules.key / rules.params  the "human time" rules become keyed and machine
--                 readable, so chat can edit them ("dinner at 20:00 from now on")
--                 and coordinator_book_block can enforce them:
--   focus_block        focus blocks (PRNTCODE, protected study) <= 90 min, 15 min break between
--   meal_breakfast     30 min straight after morning PT
--   meal_dinner        1h, protected, inside 19:30-21:00 (moves within the window)
--   buffer             15 min between back-to-back items, on top of travel
--   evening_focus_max  at most 2 focus blocks per weekday evening
--   wind_down          weeknights (Sun-Thu): nothing ends after 22:00 (was soft)
-- GMAT becomes 3 x 90 min (4.5h a week) instead of 2 x 2h.
--
-- Applied live through execute_sql in additive parts (this environment never
-- confirms DROP/UPDATE/DELETE statements), so the old coordinator_book_block is
-- RENAMED to coordinator_book_block_v2_0 and retired, not dropped.

-- ---------------------------------------------------------------------------
-- 1. Places and travel time
-- ---------------------------------------------------------------------------
create table public.places (
  id          uuid primary key default gen_random_uuid(),
  name        text        not null,
  area        text,
  note        text,
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint places_name_not_blank check (length(btrim(name)) > 0)
);

comment on table public.places is
  'Where Khaled''s activities and commitments happen (name + area, e.g. "Tennis club", "Saadiyat, Abu Dhabi"). Learned from chat. Written only through place_add / place_retire.';

create unique index places_name_active_unique on public.places (lower(btrim(name))) where active;

create trigger places_set_updated_at
  before update on public.places
  for each row execute function public.set_updated_at();

alter table public.places enable row level security;
revoke all on table public.places from anon, authenticated;
create policy places_no_client_access on public.places
  for all to anon, authenticated using (false) with check (false);

create table public.travel_minutes (
  place_a     uuid        not null references public.places (id),
  place_b     uuid        not null references public.places (id),
  minutes     smallint    not null,
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  primary key (place_a, place_b),
  constraint travel_minutes_pair_order check (place_a < place_b),
  constraint travel_minutes_range check (minutes between 0 and 300)
);

comment on table public.travel_minutes is
  'Khaled''s travel-time estimate between two places, one row per pair (place_a < place_b, symmetric). Entered by Khaled; no map APIs. Written only through travel_set.';

create trigger travel_minutes_set_updated_at
  before update on public.travel_minutes
  for each row execute function public.set_updated_at();

alter table public.travel_minutes enable row level security;
revoke all on table public.travel_minutes from anon, authenticated;
create policy travel_minutes_no_client_access on public.travel_minutes
  for all to anon, authenticated using (false) with check (false);

alter table public.recurring add column place_id uuid references public.places (id);
comment on column public.recurring.place_id is 'Default place for this activity (v2.1). Null = not known yet: the plan asks once.';

alter table public.plan_blocks add column place_id uuid references public.places (id);
comment on column public.plan_blocks.place_id is 'Where the block happens (v2.1). Travel blocks are placed between blocks at different places.';

alter table public.plan_blocks drop constraint plan_blocks_kind_check;
alter table public.plan_blocks add constraint plan_blocks_kind_check
  check (kind in ('fixed', 'activity', 'held', 'prntcode', 'meal', 'travel'));

-- "Where's tennis?" -> "Tennis club, Saadiyat". Refuses a second active place with the same name.
create or replace function public.place_add(p_name text, p_area text default null, p_note text default null)
returns public.places
language plpgsql
set search_path = ''
as $$
declare
  p public.places;
begin
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'a place needs a name';
  end if;
  if exists (select 1 from public.places where active and lower(btrim(name)) = lower(btrim(p_name))) then
    raise exception 'a place called "%" already exists: reuse it', btrim(p_name);
  end if;
  insert into public.places (name, area, note)
  values (btrim(p_name), nullif(btrim(p_area), ''), nullif(btrim(p_note), ''))
  returning * into p;
  return p;
end;
$$;

-- "Forget that place." Activities pointing at it lose their default.
create or replace function public.place_retire(p_id uuid)
returns public.places
language plpgsql
set search_path = ''
as $$
declare
  p public.places;
begin
  update public.places set active = false where id = p_id and active returning * into p;
  if not found then
    raise exception 'place % not found or already retired', p_id;
  end if;
  update public.recurring set place_id = null where place_id = p_id;
  return p;
end;
$$;

-- "Tennis is at the tennis club." Pass null to clear.
create or replace function public.activity_set_place(p_activity_id uuid, p_place_id uuid)
returns public.recurring
language plpgsql
set search_path = ''
as $$
declare
  t public.recurring;
begin
  if p_place_id is not null and not exists (select 1 from public.places where id = p_place_id and active) then
    raise exception 'place % not found or retired', p_place_id;
  end if;
  update public.recurring set place_id = p_place_id
   where id = p_activity_id and active
  returning * into t;
  if not found then
    raise exception 'activity % not found or stopped', p_activity_id;
  end if;
  return t;
end;
$$;

-- "About 25 minutes." Stored once per pair, either direction.
create or replace function public.travel_set(p_from uuid, p_to uuid, p_minutes integer, p_note text default null)
returns public.travel_minutes
language plpgsql
set search_path = ''
as $$
declare
  t public.travel_minutes;
begin
  if p_from = p_to then
    raise exception 'travel needs two different places';
  end if;
  if p_minutes is null or p_minutes not between 0 and 300 then
    raise exception 'travel minutes must be 0-300, not %', p_minutes;
  end if;
  if (select count(*) from public.places where id in (p_from, p_to) and active) <> 2 then
    raise exception 'both places must exist and be active';
  end if;
  insert into public.travel_minutes (place_a, place_b, minutes, note)
  values (least(p_from, p_to), greatest(p_from, p_to), p_minutes, nullif(btrim(p_note), ''))
  on conflict (place_a, place_b) do update
    set minutes = excluded.minutes, note = coalesce(excluded.note, public.travel_minutes.note)
  returning * into t;
  return t;
end;
$$;

-- Minutes between two places: 0 for the same place, null when not known yet (ask).
create or replace function public.travel_between(p_from uuid, p_to uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select case
    when p_from is null or p_to is null then null
    when p_from = p_to then 0
    else (select minutes::integer from public.travel_minutes
           where place_a = least(p_from, p_to) and place_b = greatest(p_from, p_to))
  end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Keyed, editable rules
-- ---------------------------------------------------------------------------
alter table public.rules
  add column key    text,
  add column params jsonb not null default '{}'::jsonb;

comment on column public.rules.key is 'Stable name for a machine-checked rule (v2.1), e.g. meal_dinner. One active row per key.';
comment on column public.rules.params is 'Machine-readable values the planner and coordinator_book_block use, e.g. {"window_start":"19:30","window_end":"21:00","duration_min":60}.';

create unique index rules_key_active_unique on public.rules (key) where active and key is not null;

-- Params of the active rule with this key ('{}' if none).
create or replace function public.coordinator_rule_params(p_key text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((select params from public.rules where key = p_key and active limit 1), '{}'::jsonb);
$$;

-- "Dinner at 20:00 from now on." The old row is kept (inactive) as history.
-- p_params null keeps the current params (a wording-only change).
-- p_replaces retires one keyless legacy rule in the same step.
create or replace function public.coordinator_set_rule(
  p_key text, p_rule text, p_kind text default 'hard',
  p_params jsonb default null, p_replaces uuid default null)
returns public.rules
language plpgsql
set search_path = ''
as $$
declare
  r public.rules;
  prm jsonb;
  ws time; we time; fs time; dur integer;
begin
  if p_key is null or p_key !~ '^[a-z][a-z0-9_]{1,40}$' then
    raise exception 'rule key must be snake_case, not %', p_key;
  end if;
  if coalesce(btrim(p_rule), '') = '' then
    raise exception 'rule text is required';
  end if;
  if p_kind not in ('hard', 'soft') then
    raise exception 'rule kind must be hard or soft, not %', p_kind;
  end if;
  prm := coalesce(p_params, public.coordinator_rule_params(p_key));

  -- Sanity checks for the rules the database itself enforces or the plan relies on.
  if p_key = 'focus_block' and ((prm->>'max_min')::int not between 30 and 180
                               or coalesce((prm->>'break_min')::int, 0) not between 0 and 60) then
    raise exception 'focus_block: max_min 30-180 and break_min 0-60';
  end if;
  if p_key = 'evening_focus_max' and (prm->>'max')::int not between 0 and 4 then
    raise exception 'evening_focus_max: max 0-4';
  end if;
  if p_key = 'buffer' and (prm->>'min')::int not between 0 and 60 then
    raise exception 'buffer: min 0-60';
  end if;
  if p_key = 'wind_down' and ((prm->>'latest_end')::time is null or jsonb_typeof(prm->'nights') <> 'array') then
    raise exception 'wind_down needs latest_end (HH:MM) and nights (ISO weekdays)';
  end if;
  if p_key = 'meal_dinner' then
    ws := (prm->>'window_start')::time;
    we := (prm->>'window_end')::time;
    dur := (prm->>'duration_min')::int;
    fs := nullif(prm->>'fixed_start', '')::time;
    if ws is null or we is null or dur is null or dur not between 15 and 180 then
      raise exception 'meal_dinner needs window_start, window_end and duration_min (15-180)';
    end if;
    if ws + make_interval(mins => dur) > we then
      raise exception 'meal_dinner: a %-minute dinner does not fit in %-%', dur, ws, we;
    end if;
    if fs is not null and (fs < ws or fs + make_interval(mins => dur) > we) then
      raise exception 'meal_dinner: % is outside the %-% window; move the window too', fs, ws, we;
    end if;
  end if;

  update public.rules set active = false
   where active and (key = p_key or (p_replaces is not null and id = p_replaces));

  insert into public.rules (owner_agent, rule, kind, key, params)
  values ('coordinator', btrim(p_rule), p_kind, p_key, prm)
  returning * into r;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. coordinator_book_block v2.1: place, meal/travel kinds, human-time rules
-- ---------------------------------------------------------------------------
alter function public.coordinator_book_block(uuid, text, text, timestamptz, timestamptz, text, uuid, uuid[], text)
  rename to coordinator_book_block_v2_0;

create or replace function public.coordinator_book_block_v2_0(
  p_plan_id uuid, p_kind text, p_title text,
  p_slot_start timestamptz, p_slot_end timestamptz, p_calendar_event_id text,
  p_activity_id uuid default null, p_request_ids uuid[] default '{}', p_note text default null)
returns public.plan_blocks
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'retired in v2.1: use coordinator_book_block(..., p_place_id)';
end;
$$;

-- Is this a focus block (PRNTCODE, or a protected activity such as GMAT)?
create or replace function public.plan_block_is_focus(p_kind text, p_activity_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_kind = 'prntcode'
      or (p_kind = 'activity' and exists (
            select 1 from public.recurring where id = p_activity_id and activity_type = 'protected'));
$$;

create or replace function public.coordinator_book_block(
  p_plan_id uuid, p_kind text, p_title text,
  p_slot_start timestamptz, p_slot_end timestamptz, p_calendar_event_id text,
  p_activity_id uuid default null, p_request_ids uuid[] default '{}', p_note text default null,
  p_place_id uuid default null)
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
  d date := (p_slot_start at time zone 'Asia/Dubai')::date;
  dow integer := extract(isodow from (p_slot_start at time zone 'Asia/Dubai'))::integer;
  is_focus boolean := public.plan_block_is_focus(p_kind, p_activity_id);
  focus jsonb := public.coordinator_rule_params('focus_block');
  wind jsonb := public.coordinator_rule_params('wind_down');
  eve jsonb := public.coordinator_rule_params('evening_focus_max');
  max_min integer;
  break_min integer;
  n integer;
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
  -- Meals and travel are logistics, not work competing with the fund; the plan
  -- itself keeps dinner out of fund hours.
  if p_kind not in ('fixed', 'meal', 'travel') and public.in_work_hours(p_slot_start, p_slot_end) then
    raise exception 'slot % - % is in fund hours (Mon-Thu 09:00-18:00, hard rule)', p_slot_start, p_slot_end;
  end if;
  if p_kind in ('activity', 'held') and not exists (
       select 1 from public.recurring where id = p_activity_id and active) then
    raise exception 'activity % not found or stopped', p_activity_id;
  end if;
  if p_place_id is not null and not exists (select 1 from public.places where id = p_place_id and active) then
    raise exception 'place % not found or retired', p_place_id;
  end if;

  -- Wind-down (hard): on weeknights nothing Khaled didn't fix himself ends after 22:00.
  if p_kind not in ('fixed', 'travel')
     and wind ? 'latest_end'
     and dow in (select jsonb_array_elements_text(wind->'nights')::integer)
     and (p_slot_end at time zone 'Asia/Dubai') > d + (wind->>'latest_end')::time then
    raise exception 'slot ends after % on a weeknight (wind-down rule)', wind->>'latest_end';
  end if;

  if is_focus then
    max_min := coalesce((focus->>'max_min')::integer, 90);
    break_min := coalesce((focus->>'break_min')::integer, 15);
    if p_slot_end - p_slot_start > make_interval(mins => max_min) then
      raise exception 'focus blocks are at most % min: split it into blocks with a break between', max_min;
    end if;
    select o.title into clash
    from public.plan_blocks o
    where o.status = 'booked'
      and public.plan_block_is_focus(o.kind, o.activity_id)
      and tstzrange(o.slot_start - make_interval(mins => break_min), o.slot_end + make_interval(mins => break_min))
          && tstzrange(p_slot_start, p_slot_end)
    limit 1;
    if clash is not null then
      raise exception 'needs a % min break after focus block "%"', break_min, clash;
    end if;
    if dow between 1 and 5 and (p_slot_start at time zone 'Asia/Dubai')::time >= time '18:00' then
      select count(*) into n
      from public.plan_blocks o
      where o.status = 'booked'
        and public.plan_block_is_focus(o.kind, o.activity_id)
        and (o.slot_start at time zone 'Asia/Dubai')::date = d
        and (o.slot_start at time zone 'Asia/Dubai')::time >= time '18:00';
      if n >= coalesce((eve->>'max')::integer, 2) then
        raise exception 'already % focus blocks that evening (max % per weekday evening)', n, coalesce((eve->>'max')::integer, 2);
      end if;
    end if;
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
    (plan_id, kind, activity_id, title, slot_start, slot_end, calendar_event_id, request_ids, note, place_id)
  values
    (p_plan_id, p_kind, p_activity_id, btrim(p_title), p_slot_start, p_slot_end,
     p_calendar_event_id, ids, nullif(btrim(p_note), ''), p_place_id)
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

-- ---------------------------------------------------------------------------
-- 4. Lock down: agents only
-- ---------------------------------------------------------------------------
revoke execute on function public.place_add(text, text, text) from public, anon, authenticated;
revoke execute on function public.place_retire(uuid) from public, anon, authenticated;
revoke execute on function public.activity_set_place(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.travel_set(uuid, uuid, integer, text) from public, anon, authenticated;
revoke execute on function public.travel_between(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.coordinator_rule_params(text) from public, anon, authenticated;
revoke execute on function public.coordinator_set_rule(text, text, text, jsonb, uuid) from public, anon, authenticated;
revoke execute on function public.plan_block_is_focus(text, uuid) from public, anon, authenticated;
revoke execute on function public.coordinator_book_block(uuid, text, text, timestamptz, timestamptz, text, uuid, uuid[], text, uuid) from public, anon, authenticated;
revoke execute on function public.coordinator_book_block_v2_0(uuid, text, text, timestamptz, timestamptz, text, uuid, uuid[], text) from public, anon, authenticated;

grant execute on function public.place_add(text, text, text) to service_role;
grant execute on function public.place_retire(uuid) to service_role;
grant execute on function public.activity_set_place(uuid, uuid) to service_role;
grant execute on function public.travel_set(uuid, uuid, integer, text) to service_role;
grant execute on function public.travel_between(uuid, uuid) to service_role;
grant execute on function public.coordinator_rule_params(text) to service_role;
grant execute on function public.coordinator_set_rule(text, text, text, jsonb, uuid) to service_role;
grant execute on function public.plan_block_is_focus(text, uuid) to service_role;
grant execute on function public.coordinator_book_block(uuid, text, text, timestamptz, timestamptz, text, uuid, uuid[], text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 5. Data: seed the human-time rules and reshape GMAT (through the checked
-- functions, the same path chat uses).
-- ---------------------------------------------------------------------------
select key from public.coordinator_set_rule('focus_block',
  'Focus blocks (PRNTCODE, GMAT and other protected study) are at most 90 minutes. Longer time is split into 90-minute blocks with at least a 15-minute break between them.',
  'hard', '{"max_min": 90, "break_min": 15}');
select key from public.coordinator_set_rule('meal_breakfast',
  'Breakfast: 30 minutes straight after morning PT.',
  'hard', '{"duration_min": 30, "after": "PT"}');
select key from public.coordinator_set_rule('meal_dinner',
  'Dinner is protected for 1 hour inside 19:30-21:00 Abu Dhabi time. Its exact time can move within the window.',
  'hard', '{"duration_min": 60, "window_start": "19:30", "window_end": "21:00", "fixed_start": null}');
select key from public.coordinator_set_rule('buffer',
  '15-minute buffer between back-to-back items, on top of any travel time.',
  'hard', '{"min": 15}');
select key from public.coordinator_set_rule('evening_focus_max',
  'At most 2 focus blocks per weekday evening (Mon-Fri).',
  'hard', '{"max": 2}');
select key from public.coordinator_set_rule('wind_down',
  'Wind-down: on weeknights (Sun-Thu) nothing ends after 22:00 Abu Dhabi time, except commitments Khaled fixed himself. Other nights: avoid 22:00-07:00 unless fixed.',
  'hard', '{"latest_end": "22:00", "nights": [7, 1, 2, 3, 4]}',
  (select id from public.rules
    where active and key is null
      and rule = 'Avoid placing anything between 22:00 and 07:00 Abu Dhabi time unless the request is fixed there.'));

select title, sessions_per_week, duration_min from public.intake_update_activity(
  (select id from public.recurring where title = 'GMAT' and active),
  p_duration_min => 90, p_sessions_per_week => 3::smallint,
  p_preferred_time => 'Mon–Wed evenings, 3 × 90 min (4.5h a week), one per evening');
