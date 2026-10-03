-- Close a PRNTCODE task from the digest: ledger support.
--
--   resolution         Khaled's verdict on an item from the digest:
--                      done_elsewhere | not_needed. Set by the Coordinator
--                      (its own brief); null otherwise.
--   tracker_closed_at  When the PRNTCODE agent closed the matching Notion task.
--                      Stamped only through agent_mark_tracker_closed.
--
-- PRNTCODE's safety net reads: source_agent = 'prntcode' and resolution is
-- not null and tracker_closed_at is null  ->  close the task, then stamp.
--
-- Neither column is a "change" to the request itself, so editing only these
-- two no longer bumps updated_at. Otherwise a stamp would show the row as
-- "changed since booked" in the digest (updated_at > decided_at).

alter table public.requests
  add column resolution        text,
  add column tracker_closed_at timestamptz,
  add constraint requests_resolution_check
    check (resolution is null or resolution in ('done_elsewhere', 'not_needed'));

comment on column public.requests.resolution is
  'Khaled''s digest verdict: done_elsewhere | not_needed (null = none). Set by the Coordinator. Domain agent closes its source item when set.';
comment on column public.requests.tracker_closed_at is
  'When the source agent closed the item in its own tracker (e.g. Notion). Stamped only by agent_mark_tracker_closed.';

create index requests_tracker_close_pending_idx
  on public.requests (source_agent)
  where resolution is not null and tracker_closed_at is null;

-- ---------------------------------------------------------------------------
-- updated_at: ignore edits that touch only resolution / tracker_closed_at
-- ---------------------------------------------------------------------------
create or replace function public.requests_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (to_jsonb(new) - 'resolution' - 'tracker_closed_at' - 'updated_at')
     = (to_jsonb(old) - 'resolution' - 'tracker_closed_at' - 'updated_at') then
    new.updated_at := old.updated_at;
  else
    new.updated_at := now();
  end if;
  return new;
end;
$$;

comment on function public.requests_set_updated_at() is
  'Trigger on requests: stamps updated_at on every UPDATE, except one that only changes resolution / tracker_closed_at.';

create or replace trigger requests_set_updated_at
  before update on public.requests
  for each row execute function public.requests_set_updated_at();

-- ---------------------------------------------------------------------------
-- agent_mark_tracker_closed: PRNTCODE stamps that it closed the Notion task.
--   Only prntcode rows. Idempotent: an already-stamped row is returned as is.
-- ---------------------------------------------------------------------------
create or replace function public.agent_mark_tracker_closed(p_request_id uuid)
returns public.requests
language plpgsql
set search_path = ''
as $$
declare
  r public.requests;
begin
  select * into r from public.requests where id = p_request_id for update;
  if not found then
    raise exception 'request % not found', p_request_id;
  end if;
  if r.source_agent <> 'prntcode' then
    raise exception 'request % belongs to %; only prntcode requests can be marked tracker-closed',
      p_request_id, r.source_agent;
  end if;
  if r.tracker_closed_at is not null then
    return r;
  end if;

  update public.requests
     set tracker_closed_at = now()
   where id = p_request_id
  returning * into r;
  return r;
end;
$$;

comment on function public.agent_mark_tracker_closed(uuid) is
  'PRNTCODE agent stamps tracker_closed_at after closing the request''s Notion task. Refuses non-prntcode and missing rows; idempotent.';

revoke execute on function public.requests_set_updated_at() from public, anon, authenticated;
revoke all on function public.agent_mark_tracker_closed(uuid) from public, anon, authenticated;
grant execute on function public.agent_mark_tracker_closed(uuid) to service_role;
