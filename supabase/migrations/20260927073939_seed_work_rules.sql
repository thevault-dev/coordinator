-- Khaled's standing work rules for the Coordinator. Times are Abu Dhabi
-- local (Asia/Dubai, UTC+4). Idempotent: each rule is inserted only once.

insert into public.rules (owner_agent, rule, kind)
select v.owner_agent, v.rule, v.kind
from (values
  ('coordinator',
   'Mon-Thu 09:00-18:00 Abu Dhabi time: at the fund. Nothing can be placed in these hours.',
   'hard'),
  ('coordinator',
   'Fri 09:00-18:00 Abu Dhabi time: remote work. Khaled can step away for up to about 2 hours in total that day, so blocks here are allowed but must add up to 2 hours or less per Friday.',
   'soft'),
  ('coordinator',
   'Sat-Sun, and weekday times outside 09:00-18:00, are free unless a calendar shows busy.',
   'soft'),
  ('coordinator',
   'Avoid placing anything between 22:00 and 07:00 Abu Dhabi time unless the request is fixed there.',
   'soft')
) as v(owner_agent, rule, kind)
where not exists (select 1 from public.rules r where r.rule = v.rule);
