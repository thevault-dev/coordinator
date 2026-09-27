-- Intake: Khaled adds and withdraws requests himself from chat.
--
-- Intake writes only the top half of a request (what, how long, when, how
-- movable, how important). It never proposes slots. Like the Coordinator,
-- it never touches the requests table directly: it calls these checked
-- functions.

-- ---------------------------------------------------------------------------
-- Add a request typed in chat. sub_agent is always 'khaled'; source_ref is a
-- generated 'chat-xxxxxxxx' id, so a re-run can never collide with an agent's.
-- ---------------------------------------------------------------------------
create or replace function public.intake_add_request(
  p_source_agent   text,
  p_title          text,
  p_duration_min   integer,
  p_earliest_start timestamptz,
  p_due_by         timestamptz,
  p_flexibility    text,
  p_priority       smallint,
  p_context        text default null)
returns public.requests
language plpgsql
set search_path = ''
as $$
declare
  r public.requests;
begin
  if p_duration_min is null then
    raise exception 'duration_min is required: ask Khaled how long it takes';
  end if;
  if p_due_by is not null and p_due_by <= now() then
    raise exception 'due_by % is in the past', p_due_by;
  end if;
  if p_flexibility = 'fixed' and p_earliest_start is null then
    raise exception 'a fixed request needs earliest_start (its fixed time)';
  end if;

  insert into public.requests
    (source_agent, sub_agent, source_ref, title, context, duration_min,
     earliest_start, due_by, flexibility, priority)
  values
    (p_source_agent, 'khaled', 'chat-' || left(replace(gen_random_uuid()::text, '-', ''), 8),
     btrim(p_title), nullif(btrim(p_context), ''), p_duration_min,
     coalesce(p_earliest_start, now()), p_due_by, p_flexibility, p_priority)
  returning * into r;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- Withdraw a request Khaled no longer wants.
--   new / proposed : declined, note 'withdrawn by Khaled'.
--   scheduled      : only after its event was deleted from the Coordinator
--                    calendar; p_deleted_event_id must match the row, which
--                    proves the right event was removed first.
-- ---------------------------------------------------------------------------
create or replace function public.intake_withdraw(
  p_id uuid, p_deleted_event_id text default null)
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
  if r.status not in ('new', 'proposed', 'scheduled') then
    raise exception 'request % is %; only open requests can be withdrawn', p_id, r.status;
  end if;
  if r.status = 'scheduled'
     and (p_deleted_event_id is null or p_deleted_event_id is distinct from r.calendar_event_id) then
    raise exception 'request % is scheduled with event %: delete that event from the Coordinator calendar first and pass its id',
      p_id, r.calendar_event_id;
  end if;

  update public.requests
     set status = 'declined', decision_note = 'withdrawn by Khaled', decided_at = now()
   where id = p_id
  returning * into r;
  return r;
end;
$$;

revoke execute on function public.intake_add_request(text, text, integer, timestamptz, timestamptz, text, smallint, text) from public, anon, authenticated;
revoke execute on function public.intake_withdraw(uuid, text) from public, anon, authenticated;
grant execute on function public.intake_add_request(text, text, integer, timestamptz, timestamptz, text, smallint, text) to service_role;
grant execute on function public.intake_withdraw(uuid, text) to service_role;
