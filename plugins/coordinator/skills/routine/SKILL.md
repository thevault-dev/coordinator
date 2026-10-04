---
name: routine
description: Khaled's activities registry for the Coordinator. Use it whenever he adds, changes, lists or reports on a recurring activity, e.g. "I've started piano, 1h a week with a teacher", "GMAT class Tuesdays 7pm", "swim twice a week now", "make tennis 3 a week", "stop the run", "what's my routine?", "did my run", "done with GMAT today", "booked the haircut", "tennis booked Thu 19:00" (a coach session he booked himself), "haircut every 3 weeks". Each activity has a type (coached, protected, flexible, nudge, held) that decides how /coordinator:plan treats it. Confirms with one line before writing, and writes only through the ledger's checked functions.
---

# Routine (the activities registry)

The routine is the list of things Khaled does every week or every few weeks. `/coordinator:plan` reads it twice a week to plan his time. You keep it up to date from chat.

**Keep replies to one line.** Confirm before every write. Write only on a clear yes (yes, y, ok, add, 👍, go).

## Tools and facts
- Supabase `execute_sql` on project `hgkreprqxevayruqpibf`. **One statement per call.**
- Google Calendar, only for a late coached booking (section 4), and only on the **Coordinator** calendar (`4f0f7f079667e9b74eb5605d03065375d94f32de53fa7548afbb4d354b0f50da@group.calendar.google.com`, trimmed summary `Coordinator`), with `notificationLevel: "NONE"`.
- Abu Dhabi time (`Asia/Dubai`, UTC+4). Store UTC.
- Never `insert`/`update` `recurring` or `plan_blocks` directly. Use only: `intake_add_activity`, `intake_update_activity`, `intake_add_recurring` (held items), `intake_stop_recurring`, `activity_mark_done`, `coordinator_book_block`.

## The five types

| Type | What it means | Examples | How the plan treats it |
|---|---|---|---|
| `coached` | Booked with someone else at times that change. Khaled books it; the Coordinator only nudges. | PT, tennis coach, piano teacher, physio | A booking nudge with an ideal time: `Book with your coach: 1 more tennis, ideally Thu 19:00` |
| `protected` | His own commitment that must not get squeezed out. Placed early, hard to bump. | GMAT study | Placed right after fixed things |
| `flexible` | Done alone, any time. Fits around everything. | swim, run, stretching | Placed last before PRNTCODE |
| `nudge` | Needs an action, not a slot, every N weeks. | haircut, car service, eyebrow appointment | `It's been 2 weeks — book a haircut`, timed from `last_done` |
| `held` | A **fixed weekly time** protected by default; he confirms it in each plan. | Dubai drive Thu 18:00, a weekly class | Held at its time, shown `(held)` |

**Picking the type.**
- "with a teacher / coach / trainer / physio" and no fixed time → `coached`.
- A weekly fixed day and time ("GMAT class Tuesdays 7pm", "Arabic lesson every Sat 10:00") → `held`, with a window of exactly that slot.
- Study, deep work, or "make sure I get X h a week" → `protected`.
- Exercise or a hobby done alone, with no time given → `flexible`.
- "every N weeks I need to book / get / do X" → `nudge`.
- If two types fit, ask: `Booked with someone (coached) or on your own (flexible)?`

## 1. Add an activity

Work out: title (his words, short), type, sessions per week (default 1), duration (**always ask `How long?` if not given**, except for a nudge, which defaults to 1h), preferred time (free text, e.g. "evenings", "before work", "Mon–Wed"), `booked_with` for coached ("your teacher", "Coach Sam"), and the interval in weeks for a nudge (default 2).

Check for duplicates first: `select id, title, activity_type from public.recurring where active;`. If one matches, ask `You already have Piano (coached, 1 × 1h). Change it instead?`

**Confirm in one line:**
```
Coached · Piano · 1 × 1h a week · with your teacher · any evening — add it?
Held · GMAT class · Tue 19:00–21:00 every week — add it?
Protected · Reading · 2 × 1h a week · evenings — add it?
Nudge · Car service · every 8 weeks · 1h — add it?
```
Corrections ("2 a week", "it's 90 minutes") change the line and show it again. On "no": `Not added.`

**Write (on yes).**
- coached / protected / flexible / nudge:
  ```sql
  select id, title, activity_type from public.intake_add_activity('<title>', '<type>', <duration_min>,
    <sessions or null>::smallint, <'preferred time' or null>, <interval_weeks>::smallint, <'booked with' or null>,
    p_start_dow => <1-7>::smallint, p_start_time => '<HH:MM>', p_end_dow => <1-7>::smallint, p_end_time => '<HH:MM>');
  ```
  The window (`p_start_*`/`p_end_*`) is the **span of days** it may happen in. Default Mon 06:00 → Sun 22:00. Narrow it when he names days, e.g. "Mon–Wed" is `1, '06:00', 3, '22:00'`, and "before work Mon–Wed" is `1, '06:00', 3, '08:30'`.
- held: use the intake skill's weekly-item function with a window of exactly the slot, `flexibility` `fixed`, P2:
  ```sql
  select id, title from public.intake_add_recurring('personal', '<title>', <duration_min>, <dow>::smallint, '<HH:MM>', <dow>::smallint, '<HH:MM + duration>', 'fixed', 2::smallint, '<this Monday>'::date, null, 1::smallint);
  ```
  It starts as `held` (the column default).

Reply: `Added. It's in your next plan.`

## 2. "What's my routine?"

```sql
select title, activity_type, sessions_per_week, duration_min, preferred_time, booked_with, interval_weeks, last_done, public.activity_next_due(r) as next_due, window_start_dow, window_start_time, window_end_dow, window_end_time from public.recurring r where active order by array_position(array['held','coached','protected','flexible','nudge'], activity_type), title;
```
One line each, grouped by type, on one phone screen:
```
Held · Drive back to Dubai · Thu 18:00, 1.5h
Coached · PT · 3 × 1h · Mon–Wed before work, done by 08:30 · PT coach
Coached · Tennis · 2 × 1h · evenings · Tennis coach
Protected · GMAT · 2 × 2h · Mon–Wed
Flexible · Swim · 1 × 1h  ·  Run · 1 × 45m
Nudge · Haircut · every 2 weeks · next due Mon 5 Oct
```
Add `· last done Sat 3 Oct` when `last_done` is set. Repeating Todoist reminders are listed by the intake skill ("what repeats?"), not here.

## 3. "Did my run", "done with GMAT", "booked the haircut"

1. Find the activity. If unsure, ask which.
2. Date: today, unless he says a day ("did my run yesterday", "booked the haircut for Saturday", which uses that Saturday).
3. No confirmation needed for this one; it's his own report. Run `select title, last_done, public.activity_next_due(r) from public.activity_mark_done('<id>', '<YYYY-MM-DD>') r;`
4. Reply: `Noted — run done Sun 4 Oct.`, or for a nudge `Noted — next haircut nudge around Sun 18 Oct.`

`last_done` only moves forward. A booked block that ends also updates it automatically at the next plan.

## 4. A coached session he booked late: "tennis booked Thu 19:00"

This fills that week's coached gap, so the next plan nudges for one fewer.
1. Find the activity and the date. The length is the activity's `duration_min`, unless he says otherwise.
2. Confirm: `Tennis · Thu 8 Oct 19:00–20:00 (booked with coach) — add to your Coordinator calendar?`
3. On yes: `create_event` on the Coordinator calendar (`[Personal] Tennis (booked with coach)`, Asia/Dubai, `notificationLevel: "NONE"`), then:
   ```sql
   select id, title from public.coordinator_book_block(null, 'activity', 'Tennis (booked with coach)', '<start>Z', '<end>Z', '<event id>', '<activity id>', '{}', 'booked by Khaled');
   ```
   It refuses fund hours and overlaps. If it fails, delete the event you just created and say why in one line.
4. Reply: `Added — tennis Thu 19:00. That's 2/2 this week.`

## 5. Change or stop

- "make tennis 3 a week", "GMAT is 2.5h now", "haircut every 3 weeks", "piano is with Rania": confirm the one-line change, then
  `select title, activity_type, sessions_per_week, duration_min, interval_weeks from public.intake_update_activity('<id>', p_sessions_per_week => 3::smallint);`
  The other named parameters are `p_activity_type`, `p_duration_min`, `p_preferred_time`, `p_interval_weeks`, `p_booked_with` and `p_title`.
- "stop the run", "I quit piano": `Stop Run? It won't be planned any more.` On yes: `select active from public.intake_stop_recurring('<id>');`. Reply `Stopped.`
- Held items keep their time window. To move one ("the drive is Fri now"), stop it and add it again with the new time, after one confirmation.
