-- Example data for testing: two requests and one rule.
-- Safe to run more than once: requests upsert on (source_agent, source_ref),
-- and the rule is only inserted if an identical one isn't already there.
-- Every example row is tagged "example-" so it is easy to remove:
--   delete from public.requests where source_ref like 'example-%';
--   delete from public.rules    where rule like '[example]%';

-- 1. A new Personal request, not yet placed by the Coordinator.
insert into public.requests
  (source_agent, sub_agent, source_ref, title, context, duration_min,
   earliest_start, due_by, flexibility, priority)
values
  ('personal', 'chief_of_staff', 'example-dentist',
   'Dentist check-up', 'Six-month check-up. Clinic is open Sun-Thu.', 60,
   now(), now() + interval '14 days', 'flexible', 3)
on conflict (source_agent, source_ref) do update set
  sub_agent      = excluded.sub_agent,
  title          = excluded.title,
  context        = excluded.context,
  duration_min   = excluded.duration_min,
  earliest_start = excluded.earliest_start,
  due_by         = excluded.due_by,
  flexibility    = excluded.flexibility,
  priority       = excluded.priority;

-- 2. A PRNTCODE request the Coordinator has already proposed a slot for,
--    on Sunday 10:00-11:30 Abu Dhabi time of the current week, so it shows
--    up in the this_week_proposed view.
insert into public.requests
  (source_agent, sub_agent, source_ref, title, context, duration_min,
   flexibility, priority, status, slot_start, slot_end, decision_note)
values
  ('prntcode', 'ops', 'example-supplier-call',
   'Supplier call: fabric lead times', 'Agree lead times for next drop.', 90,
   'flexible', 2, 'proposed',
   (date_trunc('week', now() at time zone 'Asia/Dubai') + interval '6 days 10 hours') at time zone 'Asia/Dubai',
   (date_trunc('week', now() at time zone 'Asia/Dubai') + interval '6 days 11 hours 30 minutes') at time zone 'Asia/Dubai',
   'Morning slot, before the afternoon training block.')
on conflict (source_agent, source_ref) do update set
  title         = excluded.title,
  context       = excluded.context,
  duration_min  = excluded.duration_min,
  status        = excluded.status,
  slot_start    = excluded.slot_start,
  slot_end      = excluded.slot_end,
  decision_note = excluded.decision_note;

-- 3. One standing rule.
insert into public.rules (owner_agent, rule, kind)
select 'personal', '[example] Train 4x per week', 'soft'
where not exists (
  select 1 from public.rules where rule = '[example] Train 4x per week'
);
