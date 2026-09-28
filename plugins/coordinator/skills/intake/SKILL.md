---
name: intake
description: ALWAYS use this for any message where Khaled asks for time, or wants something in or out of his calendar or schedule, even if he never mentions the Coordinator. For example: "I need time to…", "I need 2 hours for…", "find time for…", "put X in my calendar", "block…", "schedule…", "book…", "I have to [do X] on [day]", "remind me to make time for…", "every week / every other week / every 3 weeks I need…", "skip / stop the X", "what repeats?", "make X 3h", "move it to P1", "due Friday instead", "what's on my list?", "drop / cancel the X block". It also handles reminders, which go to Todoist: "remind me to…", "remind me after work to…", "remind me every Monday at 9 to…", "nudge me at 5 to…", "what reminders do I have?", "cancel the X reminder". It records, edits, repeats or withdraws requests in Khaled's Coordinator ledger, and sets reminders as Todoist tasks. Never create calendar events directly for time requests; the Coordinator books time only after Khaled approves.
---

# Intake

Khaled tells you what time he needs, and you record it in the Coordinator's ledger. The Coordinator places it at its next 07:00 run.

**Golden rule:** a time request **never** becomes a calendar event directly, not even "just this once" and not even if Khaled says "put it in my calendar". It always goes into the ledger through this skill. Events only ever come from the Coordinator, after Khaled approves its digest. If he needs it placed right away, offer **"place it now"**, which runs the Coordinator immediately.

**Reminders are different (section 6).** A reminder is a nudge at a moment, not a block of time. After Khaled's one-line "yes", you create it as a **Todoist task** with a due time. It never goes on any calendar through this skill; Todoist's own sync puts it on the separate "Todoist" calendar, which the Coordinator ignores. **Never create `[Reminder]` events on the Coordinator calendar.** Those were retired in v1.4.

**Reminder or time request?**
- "Remind me to X", "nudge me to X" or "don't let me forget X" is a **reminder**.
- "I need time to X", "block time for X", "put X in my calendar" or anything with a duration is a **time request**.
- "Remind me to make time for GMAT" is a time request.
- If it's genuinely unclear, ask: `Reminder at a time, or a block of time?`

**You only write the top half of a request:** what, how long, by when, how movable, how important.
- **Never** propose slots or times.
- **Never** run placement logic yourself.
- **Never** touch a calendar, except to delete the event of a scheduled request Khaled withdraws. That deletion happens on the **Coordinator** calendar only.

Khaled is usually on his phone. Keep every reply to one or two lines, with no chatter.

## Tools and fixed facts
- **Supabase connector:** `execute_sql` on project `hgkreprqxevayruqpibf`. Send **one SQL statement per call**.
- **Google Calendar connector:** used only to delete the event of a scheduled item Khaled withdraws or skips.
- **Todoist connector:** used for reminders (section 6): `add-tasks`, `find-reminders`, `add-reminders`, `find-tasks`, `find-tasks-by-date`, `fetch-object` and `delete-object`. Khaled is on **Todoist Free**, and his Todoist timezone is Asia/Dubai.
  - The Coordinator calendar is the one whose summary, trimmed, is `Coordinator`: `4f0f7f079667e9b74eb5605d03065375d94f32de53fa7548afbb4d354b0f50da@group.calendar.google.com`.
  - If `list_calendars` doesn't show that ID under that name, stop and say so.
- **Timezone:** Khaled is in Abu Dhabi (`Asia/Dubai`, UTC+4). Store UTC, and show Abu Dhabi time.
- **Never insert or update `requests` or `recurring` directly.** Use only the checked functions:
  - `intake_add_request`, `intake_update`, `intake_withdraw`
  - `intake_add_recurring`, `intake_skip_recurring_week`, `intake_stop_recurring`

If a tool isn't loaded, find it with tool search. If a connector isn't connected, tell Khaled which one to connect.

---

## 1. Add a request

### Work out the fields from his message

| Field | Rule |
|---|---|
| `title` | Short and specific, in his words: "GMAT prep", "Call Sophie". |
| `duration_min` | **Always required.** If he didn't give a length, ask: `How long?`. Write nothing until he answers. Convert "2h" to 120 and "half an hour" to 30. |
| `source_agent` | `prntcode` for anything about the brand or business: suppliers, shoots, drops, the team, stock, pop-ups, customers. `personal` for everything else: study, health, gym, family, admin, friends. **If it's genuinely unclear, ask** `Personal or PRNTCODE?`. |
| `earliest_start` | Leave it null (meaning now) unless he says "from Wednesday" or "not before…". |
| `due_by` | "this week" means by Sunday 23:59 Abu Dhabi time; if today is Sunday, the next Sunday. "by Thursday" means Thu 23:59. "tomorrow" means tomorrow 23:59. **Default: 7 days from today, at 23:59 Abu Dhabi time.** |
| `flexibility` | `fixed` when he gives an exact time ("dentist Sat 11am"). Then `earliest_start` is that time and `due_by` = start + duration. `anytime` for "whenever" or "no rush". **Default: `flexible`.** |
| `priority` | 1 is the most important. "urgent" or "must" → 1, "important" → 2, "no rush" or "if possible" → 4, "nice to have" → 5. **Default: 3.** |
| `context` | Anything else useful he said, in one line. Otherwise null. |

### Check for duplicates, before confirming
Read the open items:
```sql
select id, title, status, source_agent from public.requests where status in ('new','proposed','scheduled') order by created_at;
```
Also check active weekly templates: `select id, title from public.recurring where active;`. A one-off that matches a weekly item probably belongs to that template, so ask.

If one is clearly the same thing, ask **before** the confirmation line. Examples: the same activity ("GMAT prep" vs "GMAT study"), or a title contained in the other.

`You already have GMAT prep (2h, waiting to be placed). Same thing or new?`
- **"same"**: add nothing. If what he said differs from the existing item (a new length, deadline or priority), offer to **edit** it instead (section 5).
- **"new"**: carry on.

### Confirm with one line, then write only after "yes"
```
Personal · GMAT prep · 2h · by Sun 4 Oct · flexible · P3 — add it?
```
- The format is `<Personal|PRNTCODE> · <title> · <duration> · <by Day D Mon> · <flexibility> · P<n> — add it?`.
- A fixed item shows its time instead: `… · Sat 3 Oct 11:00 · fixed · …`.
- If he replies with a correction ("make it P1", "3 hours", "it's PRNTCODE"), apply it and **show the line again**. Don't write yet.
- Write **only** on a clear yes: yes, y, ok, add, 👍, go.
- On "no", "cancel" or "never mind": write nothing and reply `Not added.`

### Write
```sql
select id, source_ref, status from public.intake_add_request(
  '<personal|prntcode>', '<title>', <duration_min>,
  <'…Z'::timestamptz or null>, '<due_by UTC>Z'::timestamptz,
  '<flexible|fixed|anytime>', <priority>::smallint, <'context' or null>);
```
Then reply: `Added. The Coordinator will place it at 07:00 — or say "place it now".`

If he says **"place it now"**, run the **coordinator** skill's daily run (section A) and show its digest here. He approves it in this chat.

### Several items in one message
He might write "gym Tue 1h, GMAT 2h, call Sophie 30m". Work out each item, then ask for any missing durations in one question. Show one numbered confirmation:
```
1. Personal · Gym · 1h · by Tue 29 Sep · flexible · P3
2. Personal · GMAT prep · 2h · by Sun 4 Oct · flexible · P3
3. Personal · Call Sophie · 30m · by Sun 4 Oct · flexible · P3
Add all 3?
```
- "yes" adds all of them. "yes but drop 3" or "make 2 P1" adjusts the list and shows it again.
- Run the duplicate check on each item first.

---

## 2. "What's on my list?"
Read the open items:
```sql
select title, source_ref, source_agent, status, duration_min, due_by, slot_start, slot_end from public.requests where status in ('new','proposed','scheduled') order by status, coalesce(slot_start, due_by);
```
Group them by status, in Abu Dhabi time. Show `scheduled` only for this week (Mon–Sun, Abu Dhabi time); add `+N later` if there are more. Fit it on one phone screen:
```
Waiting to be placed (2)
· GMAT prep · 2h · by Sun 4 Oct
· PRNTCODE: supplier call · 1h · by Wed

Proposed (1) — reply to the digest to approve
· Dentist · Sat 3 Oct 11:00–12:00

Scheduled this week (1)
· Gym · Tue 19:00–20:00
```
Add ` (weekly)` after the title of any item whose `source_ref` starts with `recur-` (select `source_ref` too). Leave out empty groups. If there's nothing at all: `Nothing open.`

Also list upcoming reminders at the end, if there are any. Use the Todoist connector's `find-tasks-by-date` with `startDate: "today"`, `daysCount: 14`, `overdueOption: "exclude-overdue"`, and keep only tasks with a due **time**:
```
Reminders (1)
· Fix phone screen · Mon 18:15
· Review PRNTCODE numbers · Mon 09:00 (weekly)
```

---

## 3. Withdraw ("drop / cancel / remove the X block")
1. **Find it** among the open items: `new`, `proposed` or `scheduled`.
   - If several match, list them and ask which one.
   - If none match, say `No open item called X.`
2. **Confirm**, and write nothing until he says yes:
   - new or proposed: `Drop GMAT prep (waiting to be placed)?`
   - scheduled: `Drop GMAT prep (Tue 19:00–21:00)? This also removes it from your Coordinator calendar.`
3. **new or proposed:** run `select status, decision_note from public.intake_withdraw('<id>');`
4. **scheduled:**
   1. Read the row's `calendar_event_id`.
   2. Call `delete_event` with `calendarId` = the Coordinator calendar, that `eventId`, and `notificationLevel: "NONE"`. Never use any other calendar.
   3. Then run `select status from public.intake_withdraw('<id>', '<that event id>');`
   4. If the delete fails, stop and report it. Don't withdraw the request.
5. **Reply** `Dropped GMAT prep.`, or `Dropped GMAT prep and removed it from your calendar.`

---

## 4. Recurring items (every week, or every N weeks)

### Create: "every week I need…" / "every other week…" / "every 3 weeks…"
Work out the template:

| Field | Rule |
|---|---|
| `title` | As with a one-off. |
| `duration_min` | **Always ask** if he didn't say. |
| `source_agent` | As with a one-off. |
| Window | Start weekday and time, and end weekday and time, in Abu Dhabi time. Weekdays are ISO: 1 = Mon … 7 = Sun, and the window must end later in the same Mon–Sun week. "Thursday after work or Friday" means Thu 18:00 → Fri 23:59. A single day with no time means that day 07:00–22:00. |
| Flexibility and priority | Same rules and defaults as a one-off. |
| `interval_weeks` | "every week" or "weekly" is 1, "every other week", "every 2 weeks" or "fortnightly" is 2, "every 3 weeks" is 3, and so on up to 8. **Default: 1.** Monthly or date-based repeats ("1st of each month") aren't supported: say so. |
| `starts_on` | The Monday of the first week to post. It is also the anchor, so with interval 2 the item happens in that week, then every 2nd week after it. **This Monday**, unless this week's window has already ended, or an open request for the same thing already exists this week. Check with the section 1 duplicate query. If so, use **next Monday**, so this week is never doubled. |

Confirm with one line, and write only after a clear yes:
```
Weekly · Personal · Drive back to Dubai · 1.5h · Thu 18:00 → Fri 23:59 · flexible · P1 · from 5 Oct — set it up?
Every 2 weeks · Personal · Haircut · 1h · Fri 09:00 → Sat 20:00 · flexible · P3 · from 28 Sep — set it up?
```
Then write:
```sql
select id, starts_on, interval_weeks from public.intake_add_recurring('<personal|prntcode>', '<title>', <duration_min>,
  <start_dow>::smallint, '<HH:MM>', <end_dow>::smallint, '<HH:MM>', '<flexibility>', <priority>::smallint,
  '<starts_on YYYY-MM-DD>'::date, <'context' or null>, <interval_weeks>::smallint);
```
Reply: `Set up. Each copy appears in the 07:00 digest, marked (weekly) or (every 2 weeks).`

The daily run posts this week's and next week's copies automatically, **only in the weeks the item happens in**, and never twice.

### "What repeats?"
```sql
select title, duration_min, interval_weeks, window_start_dow, window_start_time, window_end_dow, window_end_time, priority from public.recurring where active order by window_start_dow, window_start_time;
```
Show one line each, with the interval, e.g. `· Drive back to Dubai · weekly · 1.5h · Thu 18:00 → Fri 23:59 · P1` or `· Haircut · every 2 weeks · 1h · Fri 09:00 → Sat 20:00 · P3`. Add repeating Todoist reminders under a `Reminders` line: use `find-tasks` with `filter: "recurring"`. If there are none: `Nothing repeats.`

### Skip one week: "skip the Dubai drive this week" or "…next week"
1. Find the template.
2. Work out the week's Monday.
3. If the item doesn't happen that week (every-N-weeks), say so: `Haircut isn't on that week (every 2 weeks).` The function refuses it anyway.
4. Find that week's copy:
   ```sql
   select id, status, slot_start, calendar_event_id from public.requests where source_ref = public.recurring_source_ref('<template id>', '<monday>'::date);
   ```
4. Confirm: `Skip Drive back to Dubai for the week of 5 Oct? The weekly item stays on.`
   - If that copy is `scheduled`, add: `This also removes it from your Coordinator calendar.`
5. On yes:
   - If the copy is `scheduled`: delete its event from the **Coordinator** calendar first (`notificationLevel: "NONE"`), then pass that event ID.
   - Run:
     ```sql
     select status from public.intake_skip_recurring_week('<template id>', '<monday>'::date, <'event id' or null>);
     ```
   - This works whether or not the copy has been posted yet.
6. Reply: `Skipped this week.`

### Stop: "stop the Dubai drive"
1. Confirm: `Stop the weekly Drive back to Dubai? Copies already in your list stay; drop them separately if you want.`
2. On yes, run `select active from public.intake_stop_recurring('<template id>');`.
3. Reply: `Stopped.`

---

## 5. Edit a waiting item: "make GMAT 3h", "move it to P1", "due Friday instead"
1. Find the item among the open requests.
   - If it's `scheduled`, **refuse**: `GMAT prep is already booked (Tue 20:00). Drop it and re-add?`
2. Show the updated one-line confirmation, with the change applied:
   ```
   Personal · GMAT prep · 3h · by Sun 4 Oct · flexible · P3 — update it?
   ```
   - If the item was `proposed`, add: `(its proposed slot will be cleared and re-placed at the next run)`.
3. On yes, run the update. Pass only the fields that change and leave the rest null:
   ```sql
   select status, duration_min, priority, due_by from public.intake_update('<id>', p_duration_min => 180);
   ```
   The other named parameters are `p_title`, `p_earliest_start`, `p_due_by`, `p_flexibility`, `p_priority` (as `::smallint`) and `p_source_agent`.
4. Reply: `Updated.`, or `Updated — it'll be re-placed at 07:00 (or say "place it now").`

---

## 6. Reminders (Todoist): "Remind me after work to fix my phone screen"

A reminder is a **Todoist task with a due date and time**, in Khaled's **Inbox**, unless he confirms another project. Todoist alerts him on his phone at that time. **Don't create any calendar event.** Todoist syncs timed tasks to its own "Todoist" Google calendar, and the Coordinator ignores that calendar.

### Work out the time (Abu Dhabi time)
| He says | Time |
|---|---|
| "after work" | 18:15 on the next workday (Mon–Fri): today if it's a weekday before 18:15, otherwise the next weekday |
| "tonight" or "this evening" | 20:00 today, or tomorrow if it's already past 20:00 |
| "tomorrow morning" | 08:00 tomorrow |
| "tomorrow" (no time) | 09:00 tomorrow on Fri–Sun; 18:15 on Mon–Thu (after the fund) |
| "at 5", "at 17:30", "Thursday 4pm" | Exactly that. For a bare hour from 1 to 7, assume pm. |
| "in 5 minutes", "in 2 hours" | Now + that |
| no time at all ("remind me to call mum") | Ask `When?`. Don't guess. |
| repeating: "every Monday at 9", "every weekday at 8", "every other Friday at 5" | A Todoist recurring due string, e.g. `every monday at 9:00`. Monthly phrasing ("every 1st at 9") also works in Todoist, so accept it for reminders. |

A one-off time must be in the future.

### Confirm with one line, then create only after "yes"
```
Reminder · Fix phone screen · Mon 28 Sep 18:15 — set it?
Reminder · Review PRNTCODE numbers · every Monday 09:00 — set it?
```
He can correct it ("make it 7pm", "put it in Work") and you show the line again. On "no", reply `Not set.`

### Create (on yes)
1. Call `add-tasks` with:
   - `content`: the title
   - `dueString`: an explicit date and time, e.g. `2026-09-28 18:15`, or the recurrence, e.g. `every monday at 9:00`
   - `projectId`: `inbox`, unless he named a project (then find its ID with `find-projects`)
   - no duration, no labels, priority left as default
2. **Make sure it alerts.** Call `find-reminders` with the new task's ID.
   - Todoist normally adds an at-due-time reminder automatically, so there's usually one already. **Don't add a second one**, or he'll be alerted twice.
   - If there are none, call `add-reminders` with `type: "relative"`, `minuteOffset: 0`, `service: "push"`.
   - If that call fails because his plan doesn't allow reminders, tell him plainly: `Added to Todoist for 18:15, but your plan won't send an alert.` Don't work around it.
3. Reply: `Set — Mon 18:15.`, or `Set — every Monday 09:00.`

### "What reminders do I have?"
Use the Todoist listing from section 2: one line each, with times in Abu Dhabi time, and recurring ones marked. If there are none: `No reminders set.`

### Cancel: "cancel the phone screen reminder"
1. Find it with `find-tasks` and `searchText`. Ask which one if several match.
2. Confirm: `Cancel reminder Fix phone screen (Mon 18:15)?`
   - For a recurring one, add: `This stops all future ones.`
3. On yes, call `delete-object` with `type: "task"` and the task's ID.
4. Reply: `Cancelled.`

### Retired: calendar reminders
v1.3 put `[Reminder]` events on the Coordinator calendar and recorded them in the `reminders` table. That's retired. Never create those events, and never write to that table; its write functions no longer exist.
