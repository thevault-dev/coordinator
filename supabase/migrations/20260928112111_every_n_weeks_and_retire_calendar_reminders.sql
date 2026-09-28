-- v1.4: recurring items every N weeks; calendar reminders retired.
--
-- recurring.interval_weeks   1 = weekly, 2 = every other week, ... (1-8)
-- recurring.anchor_week      Monday of a week the item happens in. A week
--                            matches when (week - anchor_week) is a whole
--                            multiple of interval_weeks.
-- coordinator_post_recurring still looks at this week and next week, and
-- still uses source_ref recur-<id>-<IYYY-Www>, so nothing can duplicate.
--
-- Reminders now live in Todoist (via the Todoist connector). The reminders
-- table stays for history; its write functions are dropped so no new rows
-- can be written.

alter table public.recurring
  add column interval_weeks smallint not null default 1,
  add column anchor_week    date;

update public.recurring set anchor_week = starts_on where anchor_week is null;

alter table public.recurring
  alter column anchor_week set not null,
  add constraint recurring_interval_check check (interval_weeks between 1 and 8),
  add constraint recurring_anchor_monday  check (extract(isodow from anchor_week) = 1);

comment on column public.recurring.interval_weeks is '1 = every week, 2 = every other week, up to 8.';
comment on column public.recurring.anchor_week is 'Monday of a week the item happens in; with interval_weeks it fixes which weeks match.';

-- ---------------------------------------------------------------------------
-- Does a template happen in the week starting p_week_monday?
-- ---------------------------------------------------------------------------
create or replace function public.recurring_week_matches(p_template public.recurring, p_week_monday date)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_week_monday >= p_template.starts_on
     and ((p_week_monday - p_template.anchor_week) / 7) % p_template.interval_weeks = 0
     and (p_week_monday - p_template.anchor_week) % 7 = 0;
$$;

-- ---------------------------------------------------------------------------
-- Daily run: as before, but only in matching weeks.
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

-- ---------------------------------------------------------------------------
-- Chat: create a template, now with an interval. The anchor is starts_on:
-- the first week posted is always a matching week.
-- (Replaces the v1.2 signature.)
-- ---------------------------------------------------------------------------
drop function public.intake_add_recurring(text, text, integer, smallint, time, smallint, time, text, smallint, date, text);

create or replace function public.intake_add_recurring(
  p_source_agent text, p_title text, p_duration_min integer,
  p_start_dow smallint, p_start_time time, p_end_dow smallint, p_end_time time,
  p_flexibility text, p_priority smallint, p_starts_on date,
  p_context text default null, p_interval_weeks smallint default 1)
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
     window_end_dow, window_end_time, flexibility, priority, starts_on,
     interval_weeks, anchor_week)
  values
    (p_source_agent, btrim(p_title), nullif(btrim(p_context), ''), p_duration_min, p_start_dow, p_start_time,
     p_end_dow, p_end_time, p_flexibility, p_priority, p_starts_on,
     coalesce(p_interval_weeks, 1), p_starts_on)
  returning * into t;
  return t;
end;
$$;

-- ---------------------------------------------------------------------------
-- Skip: refuse weeks the item doesn't happen in (nothing to skip).
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
  if not public.recurring_week_matches(t, wk) then
    raise exception '% does not happen in the week of % (every % weeks); nothing to skip', t.title, wk, t.interval_weeks;
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
-- Retire calendar reminders: history only, no new writes.
-- ---------------------------------------------------------------------------
drop function public.intake_add_reminder(text, timestamptz, text);
drop function public.intake_cancel_reminder(uuid, text);

comment on table public.reminders is
  'HISTORY ONLY (retired in v1.4). Calendar reminders set in v1.3. Reminders now live in Todoist; nothing writes here any more.';

-- ---------------------------------------------------------------------------
-- Lock down
-- ---------------------------------------------------------------------------
revoke execute on function public.recurring_week_matches(public.recurring, date) from public, anon, authenticated;
revoke execute on function public.intake_add_recurring(text, text, integer, smallint, time, smallint, time, text, smallint, date, text, smallint) from public, anon, authenticated;
grant execute on function public.recurring_week_matches(public.recurring, date) to service_role;
grant execute on function public.intake_add_recurring(text, text, integer, smallint, time, smallint, time, text, smallint, date, text, smallint) to service_role;
