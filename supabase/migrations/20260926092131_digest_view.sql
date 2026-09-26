-- Read-only view for the daily digest: this week's proposed requests.
--
-- "This week" is Monday 00:00 to next Monday 00:00 in Abu Dhabi time
-- (Asia/Dubai, UTC+4). Stored times stay UTC; the *_local columns are the
-- same moments shown as Abu Dhabi wall-clock time, ready to display.
--
-- security_invoker = on: the view runs with the caller's permissions, so it
-- is exactly as locked down as the requests table underneath it.

create view public.this_week_proposed
with (security_invoker = on)
as
select
  r.id,
  r.source_agent,
  r.sub_agent,
  r.source_ref,
  r.title,
  r.context,
  r.duration_min,
  r.priority,
  r.flexibility,
  r.slot_start,
  r.slot_end,
  r.slot_start at time zone 'Asia/Dubai' as slot_start_local,
  r.slot_end   at time zone 'Asia/Dubai' as slot_end_local,
  r.due_by,
  r.due_by     at time zone 'Asia/Dubai' as due_by_local,
  r.decision_note,
  r.updated_at
from public.requests r
where r.status = 'proposed'
  and r.slot_start >= (date_trunc('week', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai')
  and r.slot_start <  ((date_trunc('week', now() at time zone 'Asia/Dubai') + interval '7 days') at time zone 'Asia/Dubai')
order by r.slot_start, r.priority;

comment on view public.this_week_proposed is
  'Digest feed: requests in status proposed whose slot starts this week (Mon-Sun, Abu Dhabi time). *_local columns are Asia/Dubai wall-clock time.';

revoke all on table public.this_week_proposed from anon, authenticated;
