-- Coordinator Ledger: the shared table the Personal, PRNTCODE and Coordinator
-- agents use to talk to each other.
--
--   requests  one row per block of Khaled's time a domain agent needs.
--             Top half written by the domain agent, bottom half by the Coordinator.
--   rules     standing constraints the Coordinator checks against.
--
-- All timestamps are timestamptz (stored in UTC). Convert to Asia/Dubai only
-- when displaying.
--
-- Access: RLS is on and no client role (anon, authenticated) has any access.
-- Agents connect with the service_role key, which bypasses RLS.

-- ---------------------------------------------------------------------------
-- Shared trigger function: keep updated_at current on every edit
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Trigger: stamps updated_at with the current time on every UPDATE.';

-- ---------------------------------------------------------------------------
-- requests
-- ---------------------------------------------------------------------------
create table public.requests (
  id                uuid primary key default gen_random_uuid(),

  -- Top half: written by the domain agent (personal | prntcode)
  source_agent      text        not null,
  sub_agent         text,
  source_ref        text        not null,
  title             text        not null,
  context           text,
  duration_min      integer     not null,
  earliest_start    timestamptz,
  due_by            timestamptz,
  flexibility       text        not null default 'flexible',
  priority          smallint    not null default 3,

  -- Bottom half: written by the Coordinator
  status            text        not null default 'new',
  slot_start        timestamptz,
  slot_end          timestamptz,
  calendar_event_id text,
  decision_note     text,

  -- Housekeeping
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint requests_source_agent_check
    check (source_agent in ('personal', 'prntcode')),
  constraint requests_source_ref_not_blank
    check (length(btrim(source_ref)) > 0),
  constraint requests_title_not_blank
    check (length(btrim(title)) > 0),
  constraint requests_duration_min_check
    check (duration_min > 0 and duration_min <= 1440),
  constraint requests_window_check
    check (earliest_start is null or due_by is null or due_by > earliest_start),
  constraint requests_flexibility_check
    check (flexibility in ('fixed', 'flexible', 'anytime')),
  constraint requests_priority_check
    check (priority between 1 and 5),
  constraint requests_status_check
    check (status in ('new', 'proposed', 'scheduled', 'done', 'declined', 'bumped')),
  constraint requests_slot_order_check
    check (slot_start is null or slot_end is null or slot_end > slot_start),
  constraint requests_slot_required_check
    check (status not in ('proposed', 'scheduled')
           or (slot_start is not null and slot_end is not null)),
  constraint requests_decision_note_required_check
    check (status not in ('declined', 'bumped')
           or length(btrim(coalesce(decision_note, ''))) > 0),

  -- No duplicates: one row per item per source agent. Re-posting the same
  -- item must upsert on this pair (see README).
  constraint requests_source_unique unique (source_agent, source_ref)
);

create index requests_status_slot_idx on public.requests (status, slot_start);

create trigger requests_set_updated_at
  before update on public.requests
  for each row execute function public.set_updated_at();

comment on table public.requests is
  'Blocks of Khaled''s time requested by a domain agent. Top half (source_agent..priority) is written by the domain agent; bottom half (status..decision_note) by the Coordinator. Times are UTC.';
comment on column public.requests.source_agent   is 'Which domain agent posted this: personal | prntcode.';
comment on column public.requests.sub_agent      is 'Optional sub-agent inside the domain agent, e.g. chief_of_staff.';
comment on column public.requests.source_ref     is 'The item''s id in the source system (e.g. a Notion page id). Unique per source_agent.';
comment on column public.requests.duration_min   is 'Length of the block in minutes (1-1440).';
comment on column public.requests.earliest_start is 'Do not schedule before this moment (UTC).';
comment on column public.requests.due_by         is 'Must be finished by this moment (UTC).';
comment on column public.requests.flexibility    is 'fixed = must happen exactly at earliest_start; flexible = anywhere in the window; anytime = no real constraint.';
comment on column public.requests.priority       is '1 = most important, 5 = least important.';
comment on column public.requests.status         is 'new -> proposed -> scheduled -> done; or ends as declined / bumped.';
comment on column public.requests.slot_start     is 'Where the Coordinator placed the block (UTC). Required when proposed or scheduled.';
comment on column public.requests.decision_note  is 'Coordinator''s reason. Required when declined or bumped, so the source agent can see why.';

-- ---------------------------------------------------------------------------
-- rules
-- ---------------------------------------------------------------------------
create table public.rules (
  id          uuid primary key default gen_random_uuid(),
  owner_agent text        not null,
  rule        text        not null,
  kind        text        not null default 'soft',
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint rules_owner_agent_check
    check (owner_agent in ('personal', 'prntcode', 'coordinator')),
  constraint rules_rule_not_blank
    check (length(btrim(rule)) > 0),
  constraint rules_kind_check
    check (kind in ('hard', 'soft'))
);

create trigger rules_set_updated_at
  before update on public.rules
  for each row execute function public.set_updated_at();

comment on table public.rules is
  'Standing constraints the Coordinator checks against, e.g. "train 4x per week". hard = never break; soft = break only with a reason.';

-- ---------------------------------------------------------------------------
-- Lock down: RLS on, no client access. service_role bypasses RLS.
-- ---------------------------------------------------------------------------
alter table public.requests enable row level security;
alter table public.rules    enable row level security;

revoke all on table public.requests from anon, authenticated;
revoke all on table public.rules    from anon, authenticated;
revoke execute on function public.set_updated_at() from public, anon, authenticated;

-- Explicit deny-all policies: documents intent and keeps RLS meaningful even
-- if a grant is ever re-added by mistake.
create policy requests_no_client_access on public.requests
  for all to anon, authenticated
  using (false) with check (false);

create policy rules_no_client_access on public.rules
  for all to anon, authenticated
  using (false) with check (false);
