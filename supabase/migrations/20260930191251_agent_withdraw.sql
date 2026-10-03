-- agent_withdraw: a domain agent withdraws its own new/proposed request.
--
-- Applied to the live ledger on 30 Sep 2026 from the PRNTCODE build session,
-- which could not reach this repo at the time. This file records that exact
-- definition (from pg_get_functiondef) so the repo matches the database.

create or replace function public.agent_withdraw(p_source_agent text, p_source_ref text, p_reason text)
returns public.requests
language plpgsql
set search_path to ''
as $function$
declare
  r public.requests;
begin
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'a reason is required to withdraw %/%', p_source_agent, p_source_ref;
  end if;

  select * into r from public.requests
   where source_agent = p_source_agent and source_ref = p_source_ref
   for update;
  if not found then
    raise exception 'request %/% not found', p_source_agent, p_source_ref;
  end if;
  if r.status = 'scheduled' then
    raise exception 'request %/% is scheduled (event %): a booked block can only be dropped by Khaled',
      p_source_agent, p_source_ref, r.calendar_event_id;
  end if;
  if r.status not in ('new', 'proposed') then
    raise exception 'request %/% is %; only new or proposed requests can be withdrawn',
      p_source_agent, p_source_ref, r.status;
  end if;

  update public.requests
     set status = 'declined',
         decision_note = 'withdrawn by ' || p_source_agent || ': ' || btrim(p_reason),
         decided_at = now()
   where id = r.id
  returning * into r;
  return r;
end;
$function$;

comment on function public.agent_withdraw(text, text, text) is
  'Domain agent withdraws its own new/proposed request (-> declined, "withdrawn by <agent>: <reason>"). Refuses scheduled and missing rows.';

revoke all on function public.agent_withdraw(text, text, text) from public, anon, authenticated;
grant execute on function public.agent_withdraw(text, text, text) to service_role;
