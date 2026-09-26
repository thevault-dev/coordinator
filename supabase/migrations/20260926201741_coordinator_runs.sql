-- Run log for the Coordinator. One row per run (daily placement, approval,
-- or access probe), written by the Coordinator itself, so there is a durable
-- record that each scheduled run fired and what it did.

create table public.coordinator_runs (
  id          uuid primary key default gen_random_uuid(),
  kind        text        not null,
  status      text        not null,
  summary     text,
  detail      jsonb       not null default '{}'::jsonb,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,

  constraint coordinator_runs_kind_check
    check (kind in ('daily', 'approval', 'probe')),
  constraint coordinator_runs_status_check
    check (status in ('running', 'ok', 'error'))
);

create index coordinator_runs_started_idx on public.coordinator_runs (started_at desc);

comment on table public.coordinator_runs is
  'One row per Coordinator run: daily placement, approval reply, or access probe. detail holds counts and any errors.';

alter table public.coordinator_runs enable row level security;
revoke all on table public.coordinator_runs from anon, authenticated;
create policy coordinator_runs_no_client_access on public.coordinator_runs
  for all to anon, authenticated
  using (false) with check (false);
