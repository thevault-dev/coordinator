-- v1.3: calendar reminders.
--
-- A reminder is a nudge at a moment ("remind me after work to fix my phone
-- screen"), not a block of time. After Khaled's one-line "yes", intake
-- creates a short [Reminder] event with an alert on the Coordinator calendar
-- (marked free, so it never blocks placement) and records it here. This is
-- the one path onto the calendar that skips the 07:00 digest.
--
-- Order of writes: the event is created first, then recorded with
-- intake_add_reminder (which requires its event id). Cancelling deletes the
-- event first, then intake_cancel_reminder checks the event id matches.

create table public.reminders (
  id                uuid primary key default gen_random_uuid(),
  title             text        not null,
  remind_at         timestamptz not null,
  calendar_event_id text        not null,
  status            text        not null default 'set',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint reminders_title_not_blank check (length(btrim(title)) > 0),
  constraint reminders_event_not_blank check (length(btrim(calendar_event_id)) > 0),
  constraint reminders_status_check    check (status in ('set', 'cancelled')),
  constraint reminders_event_unique    unique (calendar_event_id)
);

comment on table public.reminders is
  'Reminders Khaled set from chat. Each is a [Reminder] event (free, with an alert) on the Coordinator calendar. Times are UTC.';

create trigger reminders_set_updated_at
  before update on public.reminders
  for each row execute function public.set_updated_at();

alter table public.reminders enable row level security;
revoke all on table public.reminders from anon, authenticated;
create policy reminders_no_client_access on public.reminders
  for all to anon, authenticated using (false) with check (false);

-- ---------------------------------------------------------------------------
-- Record a reminder whose calendar event was just created.
-- ---------------------------------------------------------------------------
create or replace function public.intake_add_reminder(
  p_title text, p_remind_at timestamptz, p_calendar_event_id text)
returns public.reminders
language plpgsql
set search_path = ''
as $$
declare
  m public.reminders;
begin
  if p_remind_at <= now() then
    raise exception 'remind_at % is in the past', p_remind_at;
  end if;
  insert into public.reminders (title, remind_at, calendar_event_id)
  values (btrim(p_title), p_remind_at, btrim(p_calendar_event_id))
  returning * into m;
  return m;
end;
$$;

-- ---------------------------------------------------------------------------
-- Cancel a reminder after its event was deleted from the Coordinator calendar.
-- ---------------------------------------------------------------------------
create or replace function public.intake_cancel_reminder(
  p_id uuid, p_deleted_event_id text)
returns public.reminders
language plpgsql
set search_path = ''
as $$
declare
  m public.reminders;
begin
  select * into m from public.reminders where id = p_id for update;
  if not found then
    raise exception 'reminder % not found', p_id;
  end if;
  if m.status <> 'set' then
    raise exception 'reminder % is already %', p_id, m.status;
  end if;
  if p_deleted_event_id is distinct from m.calendar_event_id then
    raise exception 'reminder % has event %: delete that event from the Coordinator calendar first and pass its id',
      p_id, m.calendar_event_id;
  end if;

  update public.reminders set status = 'cancelled' where id = p_id returning * into m;
  return m;
end;
$$;

revoke execute on function public.intake_add_reminder(text, timestamptz, text) from public, anon, authenticated;
revoke execute on function public.intake_cancel_reminder(uuid, text) from public, anon, authenticated;
grant execute on function public.intake_add_reminder(text, timestamptz, text) to service_role;
grant execute on function public.intake_cancel_reminder(uuid, text) to service_role;
