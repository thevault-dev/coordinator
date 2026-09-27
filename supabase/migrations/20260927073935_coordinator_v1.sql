-- Coordinator v1: decision tracking and checked write functions.
--
-- decided_at   when the Coordinator last wrote its half of a request. A
--              domain agent re-posting the item afterwards bumps updated_at
--              past decided_at, which is how the digest spots changes.
--
-- The Coordinator never updates requests directly. It calls the functions
-- below, which check the transition, the slot and overlaps before writing,
-- and always stamp decided_at. A bad write fails loudly instead of landing.

alter table public.requests add column decided_at timestamptz;

comment on column public.requests.decided_at is
  'When the Coordinator last wrote this row (set only by the coordinator_* functions). updated_at > decided_at means the source agent changed it since.';

-- ---------------------------------------------------------------------------
-- Propose a slot for a new (or still-unanswered proposed) request
-- ---------------------------------------------------------------------------
create or replace function public.coordinator_propose(
  p_id uuid, p_slot_start timestamptz, p_slot_end timestamptz, p_note text)
returns public.requests
language plpgsql
set search_path = ''
as $$
declare
  r public.requests;
  clash uuid;
begin
  select * into r from public.requests where id = p_id for update;
  if not found then
    raise exception 'request % not found', p_id;
  end if;
  if r.status not in ('new', 'proposed') then
    raise exception 'request % is %; only new or proposed requests can be proposed', p_id, r.status;
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'decision_note is required';
  end if;
  if p_slot_end - p_slot_start <> make_interval(mins => r.duration_min) then
    raise exception 'slot length % does not match duration_min % for request %',
      p_slot_end - p_slot_start, r.duration_min, p_id;
  end if;
  if p_slot_start < now() then
    raise exception 'slot % is in the past', p_slot_start;
  end if;
  if r.earliest_start is not null and p_slot_start < r.earliest_start then
    raise exception 'slot starts before earliest_start %', r.earliest_start;
  end if;
  if r.due_by is not null and p_slot_end > r.due_by then
    raise exception 'slot ends after due_by %', r.due_by;
  end if;
  if r.flexibility = 'fixed' and r.earliest_start is not null
     and p_slot_start <> r.earliest_start then
    raise exception 'request % is fixed: slot must start exactly at %', p_id, r.earliest_start;
  end if;

  select o.id into clash
  from public.requests o
  where o.id <> p_id
    and o.status in ('proposed', 'scheduled')
    and tstzrange(o.slot_start, o.slot_end) && tstzrange(p_slot_start, p_slot_end)
  limit 1;
  if clash is not null then
    raise exception 'slot overlaps request % which is already proposed or scheduled', clash;
  end if;

  update public.requests
     set status = 'proposed', slot_start = p_slot_start, slot_end = p_slot_end,
         decision_note = p_note, decided_at = now()
   where id = p_id
  returning * into r;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- Bump: no valid slot before due_by
-- ---------------------------------------------------------------------------
create or replace function public.coordinator_bump(p_id uuid, p_note text)
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
  if r.status not in ('new', 'proposed') then
    raise exception 'request % is %; only new or proposed requests can be bumped', p_id, r.status;
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'decision_note is required when bumping';
  end if;

  update public.requests
     set status = 'bumped', slot_start = null, slot_end = null,
         decision_note = p_note, decided_at = now()
   where id = p_id
  returning * into r;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- Schedule: Khaled approved; the calendar event already exists
-- p_expected_start guards against approving a slot that moved since the digest.
-- ---------------------------------------------------------------------------
create or replace function public.coordinator_schedule(
  p_id uuid, p_calendar_event_id text, p_expected_start timestamptz)
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
  if r.status <> 'proposed' then
    raise exception 'request % is %; only proposed requests can be scheduled', p_id, r.status;
  end if;
  if r.slot_start is distinct from p_expected_start then
    raise exception 'request % slot is % but the digest showed %; re-run the digest',
      p_id, r.slot_start, p_expected_start;
  end if;
  if coalesce(btrim(p_calendar_event_id), '') = '' then
    raise exception 'calendar_event_id is required';
  end if;

  update public.requests
     set status = 'scheduled', calendar_event_id = p_calendar_event_id, decided_at = now()
   where id = p_id
  returning * into r;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- Decline: Khaled rejected the proposal
-- ---------------------------------------------------------------------------
create or replace function public.coordinator_decline(p_id uuid, p_note text)
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
  if r.status <> 'proposed' then
    raise exception 'request % is %; only proposed requests can be declined', p_id, r.status;
  end if;

  update public.requests
     set status = 'declined',
         decision_note = coalesce(nullif(btrim(p_note), ''), 'Declined by Khaled in the digest.'),
         decided_at = now()
   where id = p_id
  returning * into r;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- Acknowledge: Khaled saw a "changed since decided" flag and keeps the slot
-- ---------------------------------------------------------------------------
create or replace function public.coordinator_acknowledge(p_id uuid)
returns public.requests
language plpgsql
set search_path = ''
as $$
declare
  r public.requests;
begin
  update public.requests
     set decided_at = now()
   where id = p_id and status in ('proposed', 'scheduled')
  returning * into r;
  if not found then
    raise exception 'request % not found or not proposed/scheduled', p_id;
  end if;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- Housekeeping: scheduled requests whose slot has ended become done
-- ---------------------------------------------------------------------------
create or replace function public.coordinator_mark_done()
returns setof public.requests
language sql
set search_path = ''
as $$
  update public.requests
     set status = 'done', decided_at = now()
   where status = 'scheduled' and slot_end <= now()
  returning *;
$$;

-- ---------------------------------------------------------------------------
-- Changed since decided: re-posted by the source agent after the
-- Coordinator's last decision. The digest flags these instead of moving them.
-- ---------------------------------------------------------------------------
create view public.coordinator_changed_since_decision
with (security_invoker = on)
as
select id, source_agent, title, status, slot_start, slot_end,
       duration_min, earliest_start, due_by, decided_at, updated_at
from public.requests
where status in ('proposed', 'scheduled')
  and decided_at is not null
  and updated_at > decided_at;

comment on view public.coordinator_changed_since_decision is
  'Proposed or scheduled requests the source agent re-posted after the Coordinator last decided them.';

-- ---------------------------------------------------------------------------
-- Lock down: agents only
-- ---------------------------------------------------------------------------
revoke all on table public.coordinator_changed_since_decision from anon, authenticated;

revoke execute on function public.coordinator_propose(uuid, timestamptz, timestamptz, text) from public, anon, authenticated;
revoke execute on function public.coordinator_bump(uuid, text)                              from public, anon, authenticated;
revoke execute on function public.coordinator_schedule(uuid, text, timestamptz)             from public, anon, authenticated;
revoke execute on function public.coordinator_decline(uuid, text)                           from public, anon, authenticated;
revoke execute on function public.coordinator_acknowledge(uuid)                             from public, anon, authenticated;
revoke execute on function public.coordinator_mark_done()                                   from public, anon, authenticated;

grant execute on function public.coordinator_propose(uuid, timestamptz, timestamptz, text) to service_role;
grant execute on function public.coordinator_bump(uuid, text)                              to service_role;
grant execute on function public.coordinator_schedule(uuid, text, timestamptz)             to service_role;
grant execute on function public.coordinator_decline(uuid, text)                           to service_role;
grant execute on function public.coordinator_acknowledge(uuid)                             to service_role;
grant execute on function public.coordinator_mark_done()                                   to service_role;
