-- v1.2: weekly recurring requests and editing of waiting requests.
--
-- recurring    weekly templates ("drive back to Dubai, Thu 18:00 -> Fri 23:59").
--              The daily run calls coordinator_post_recurring(), which posts
--              one request per template per ISO week (this week and next), with
--              source_ref recur-<template id>-<IYYY-Www>. The unique
--              (source_agent, source_ref) pair makes a second post impossible.
-- intake_*     Khaled's chat actions: create / stop / skip a template, and
--              edit a waiting request. All checked, no direct row writes.
-- Weekdays are ISO: 1 = Monday ... 7 = Sunday. Times are Abu Dhabi local.

create table public.recurring (
  id                uuid primary key default gen_random_uuid(),
  source_agent      text        not null,
  title             text        not null,
  context           text,
  duration_min      integer     not null,
  window_start_dow  smallint    not null,
  window_start_time time        not null,
  window_end_dow    smallint    not null,
  window_end_time   time        not null,
  flexibility       text        not null default 'flexible',
  priority          smallint    not null default 3,
  active            boolean     not null default true,
  starts_on         date        not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint recurring_source_agent_check check (source_agent in ('personal', 'prntcode')),
  constraint recurring_title_not_blank    check (length(btrim(title)) > 0),
  constraint recurring_duration_check     check (duration_min > 0 and duration_min <= 1440),
  constraint recurring_dow_check          check (window_start_dow between 1 and 7 and window_end_dow between 1 and 7),
  constraint recurring_window_order_check check (
    (window_end_dow, window_end_time) > (window_start_dow, window_start_time)),
  constraint recurring_flexibility_check  check (flexibility in ('fixed', 'flexible', 'anytime')),
  constraint recurring_priority_check     check (priority between 1 and 5),
  constraint recurring_starts_on_monday   check (extract(isodow from starts_on) = 1)
);

comment on table public.recurring is
  'Weekly request templates. Window is Abu Dhabi local time, ISO weekdays (1=Mon). starts_on is the Monday of the first week to post.';

create trigger recurring_set_updated_at
  before update on public.recurring
  for each row execute function public.set_updated_at();

alter table public.recurring enable row level security;
revoke all on table public.recurring from anon, authenticated;
create policy recurring_no_client_access on public.recurring
  for all to anon, authenticated using (false) with check (false);

-- ---------------------------------------------------------------------------
-- Helpers: Monday of the current Abu Dhabi week, and a template's window for
-- a given week, as UTC timestamps.
-- ---------------------------------------------------------------------------
create or replace function public.recurring_week_monday(p_at timestamptz default now())
returns date
language sql
stable
set search_path = ''
as $$
  select date_trunc('week', p_at at time zone 'Asia/Dubai')::date;
$$;

create or replace function public.recurring_source_ref(p_template_id uuid, p_week_monday date)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'recur-' || p_template_id::text || '-' || to_char(p_week_monday, 'IYYY-"W"IW');
$$;

-- ---------------------------------------------------------------------------
-- Daily run: post this week's and next week's copies of every active
-- template. Skips weeks before starts_on and windows that are already over
-- (or too short to fit the block). ON CONFLICT DO NOTHING makes re-runs,
-- skipped weeks and withdrawn copies safe: an existing row, in any status,
-- is never duplicated or revived.
-- ---------------------------------------------------------------------------
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
  for t in select * from public.recurring where active loop
    foreach wk in array array[public.recurring_week_monday(), public.recurring_week_monday() + 7] loop
      continue when wk < t.starts_on;
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

-- ---------------------------------------------------------------------------
-- Chat: create a template ("every week I need ...")
-- ---------------------------------------------------------------------------
create or replace function public.intake_add_recurring(
  p_source_agent text, p_title text, p_duration_min integer,
  p_start_dow smallint, p_start_time time, p_end_dow smallint, p_end_time time,
  p_flexibility text, p_priority smallint, p_starts_on date, p_context text default null)
returns public.recurring
language plpgsql
set search_path = ''
as $$
declare
  t public.recurring;
  win interval;
begin
  if p_duration_min is null then
    raise exception 'duration_min is required: ask Khaled how long it takes';
  end if;
  if p_starts_on < public.recurring_week_monday() then
    raise exception 'starts_on % is before this week', p_starts_on;
  end if;
  win := ((p_end_dow - p_start_dow) * interval '1 day') + (p_end_time - p_start_time);
  if make_interval(mins => p_duration_min) > win then
    raise exception 'a % min block does not fit in the % window', p_duration_min, win;
  end if;

  insert into public.recurring
    (source_agent, title, context, duration_min, window_start_dow, window_start_time,
     window_end_dow, window_end_time, flexibility, priority, starts_on)
  values
    (p_source_agent, btrim(p_title), nullif(btrim(p_context), ''), p_duration_min, p_start_dow, p_start_time,
     p_end_dow, p_end_time, p_flexibility, p_priority, p_starts_on)
  returning * into t;
  return t;
end;
$$;

-- ---------------------------------------------------------------------------
-- Chat: stop a template ("stop the Dubai drive"). Copies already posted stay.
-- ---------------------------------------------------------------------------
create or replace function public.intake_stop_recurring(p_id uuid)
returns public.recurring
language plpgsql
set search_path = ''
as $$
declare
  t public.recurring;
begin
  update public.recurring set active = false where id = p_id and active returning * into t;
  if not found then
    raise exception 'recurring template % not found or already stopped', p_id;
  end if;
  return t;
end;
$$;

-- ---------------------------------------------------------------------------
-- Chat: skip one week ("skip the Dubai drive this week").
--   copy exists and open -> declined 'skipped by Khaled' (a scheduled copy
--                           needs its Coordinator event deleted first, as
--                           with intake_withdraw)
--   copy not posted yet  -> a declined placeholder is written, so the daily
--                           run's ON CONFLICT never posts that week.
-- The template stays active.
-- ---------------------------------------------------------------------------
create or replace function public.intake_skip_recurring_week(
  p_template_id uuid, p_week_monday date default null, p_deleted_event_id text default null)
returns public.requests
language plpgsql
set search_path = ''
as $$
declare
  t public.recurring;
  wk date := coalesce(p_week_monday, public.recurring_week_monday());
  ref text;
  r public.requests;
begin
  select * into t from public.recurring where id = p_template_id;
  if not found then
    raise exception 'recurring template % not found', p_template_id;
  end if;
  if extract(isodow from wk) <> 1 then
    raise exception 'week % must be a Monday', wk;
  end if;
  ref := public.recurring_source_ref(t.id, wk);

  select * into r from public.requests where source_agent = t.source_agent and source_ref = ref for update;
  if found then
    if r.status not in ('new', 'proposed', 'scheduled') then
      raise exception 'this week''s copy is already %', r.status;
    end if;
    if r.status = 'scheduled'
       and (p_deleted_event_id is null or p_deleted_event_id is distinct from r.calendar_event_id) then
      raise exception 'this week''s copy is scheduled with event %: delete it from the Coordinator calendar first and pass its id',
        r.calendar_event_id;
    end if;
    update public.requests
       set status = 'declined', decision_note = 'skipped by Khaled', decided_at = now()
     where id = r.id
    returning * into r;
  else
    insert into public.requests
      (source_agent, sub_agent, source_ref, title, context, duration_min, flexibility, priority,
       status, decision_note, decided_at)
    values
      (t.source_agent, 'recurring', ref, t.title, t.context, t.duration_min, t.flexibility, t.priority,
       'declined', 'skipped by Khaled', now())
    returning * into r;
  end if;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- Chat: edit a waiting request ("make GMAT 3h", "move it to P1",
-- "due Friday instead"). Null arguments mean "leave as is".
--   new       -> fields updated.
--   proposed  -> fields updated AND reset to new with no slot, so the next
--                run places it again.
--   scheduled -> refused: drop and re-add instead.
-- ---------------------------------------------------------------------------
create or replace function public.intake_update(
  p_id uuid,
  p_title text default null,
  p_duration_min integer default null,
  p_earliest_start timestamptz default null,
  p_due_by timestamptz default null,
  p_flexibility text default null,
  p_priority smallint default null,
  p_source_agent text default null)
returns public.requests
language plpgsql
set search_path = ''
as $$
declare
  r public.requests;
begin
  select * into r from public.requests where id = p_id for update;
  if not found then
    raise exception 'request % not found', p_id;
  end if;
  if r.status = 'scheduled' then
    raise exception 'request % is already scheduled and cannot be edited: drop it and re-add', p_id;
  end if;
  if r.status not in ('new', 'proposed') then
    raise exception 'request % is %; only waiting requests can be edited', p_id, r.status;
  end if;
  if p_due_by is not null and p_due_by <= now() then
    raise exception 'due_by % is in the past', p_due_by;
  end if;

  update public.requests
     set title          = coalesce(nullif(btrim(p_title), ''), title),
         duration_min   = coalesce(p_duration_min, duration_min),
         earliest_start = coalesce(p_earliest_start, earliest_start),
         due_by         = coalesce(p_due_by, due_by),
         flexibility    = coalesce(p_flexibility, flexibility),
         priority       = coalesce(p_priority, priority),
         source_agent   = coalesce(p_source_agent, source_agent),
         status         = 'new',
         slot_start     = null,
         slot_end       = null,
         decision_note  = null,
         decided_at     = null
   where id = p_id
  returning * into r;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lock down: agents only
-- ---------------------------------------------------------------------------
revoke execute on function public.recurring_week_monday(timestamptz) from public, anon, authenticated;
revoke execute on function public.recurring_source_ref(uuid, date) from public, anon, authenticated;
revoke execute on function public.coordinator_post_recurring() from public, anon, authenticated;
revoke execute on function public.intake_add_recurring(text, text, integer, smallint, time, smallint, time, text, smallint, date, text) from public, anon, authenticated;
revoke execute on function public.intake_stop_recurring(uuid) from public, anon, authenticated;
revoke execute on function public.intake_skip_recurring_week(uuid, date, text) from public, anon, authenticated;
revoke execute on function public.intake_update(uuid, text, integer, timestamptz, timestamptz, text, smallint, text) from public, anon, authenticated;

grant execute on function public.recurring_week_monday(timestamptz) to service_role;
grant execute on function public.recurring_source_ref(uuid, date) to service_role;
grant execute on function public.coordinator_post_recurring() to service_role;
grant execute on function public.intake_add_recurring(text, text, integer, smallint, time, smallint, time, text, smallint, date, text) to service_role;
grant execute on function public.intake_stop_recurring(uuid) to service_role;
grant execute on function public.intake_skip_recurring_week(uuid, date, text) to service_role;
grant execute on function public.intake_update(uuid, text, integer, timestamptz, timestamptz, text, smallint, text) to service_role;
