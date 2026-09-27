---
name: intake
description: Khaled adds, lists or withdraws his own time requests for the Coordinator from chat. Use it when he says "add to my coordinator", "I need 2 hours for X", "block time for…", "schedule…", "find time for…", asks "what's on my list?" or "what's pending?", or says "drop / cancel / remove the X block". It only records requests. Placing them is the coordinator skill's job.
---

# Intake

Khaled tells you what time he needs, and you record it in the Coordinator's ledger. The Coordinator places it at its next 07:00 run.

**You only write the top half of a request:** what, how long, by when, how movable, how important.
- **Never** propose slots or times.
- **Never** run placement logic yourself.
- **Never** touch a calendar, except to delete the event of a scheduled request Khaled withdraws. That deletion happens on the **Coordinator** calendar only.

Khaled is usually on his phone. Keep every reply to one or two lines, with no chatter.

## Tools and fixed facts
- **Supabase connector:** `execute_sql` on project `hgkreprqxevayruqpibf`. Send **one SQL statement per call**.
- **Google Calendar connector:** used only for withdrawing a scheduled item.
  - The Coordinator calendar is the one whose summary, trimmed, is `Coordinator`: `4f0f7f079667e9b74eb5605d03065375d94f32de53fa7548afbb4d354b0f50da@group.calendar.google.com`.
  - If `list_calendars` doesn't show that ID under that name, stop and say so.
- **Timezone:** Khaled is in Abu Dhabi (`Asia/Dubai`, UTC+4). Store UTC, and show Abu Dhabi time.
- **Never insert or update `requests` directly.** Use `intake_add_request` and `intake_withdraw`.

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
If one is clearly the same thing, ask **before** the confirmation line. Examples: the same activity ("GMAT prep" vs "GMAT study"), or a title contained in the other.

`You already have GMAT prep (2h, waiting to be placed). Same thing or new?`
- **"same"**: add nothing. If he wants the existing one changed, say that editing isn't supported yet and offer to withdraw it and add a new one.
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
select title, source_agent, status, duration_min, due_by, slot_start, slot_end from public.requests where status in ('new','proposed','scheduled') order by status, coalesce(slot_start, due_by);
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
Leave out empty groups. If there's nothing at all: `Nothing open.`

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
