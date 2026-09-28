# Coordinator Ledger

The ledger is the shared notebook Khaled's three agents use to coordinate his time.

- The **Personal agent** and the **PRNTCODE agent** each write down blocks of Khaled's time they need, such as "90 minutes for a supplier call before Thursday."
- The **Coordinator**, which owns the calendar, reads those requests and writes back where each one landed, or why it didn't.

The agents never talk to each other directly. Everything goes through this ledger, which lives in a Supabase database. Khaled never opens it. He sees the results in his daily digest and on his calendar.

---

## The two tables

### `requests`: one row per block of time needed

Each row has two halves. Each agent fills in only its own half.

**Top half, written by the domain agent (Personal or PRNTCODE)**

| Field | What it means |
|---|---|
| `source_agent` | Who is asking: `personal` or `prntcode`. |
| `sub_agent` | Optional. Which helper inside that agent is asking, e.g. `chief_of_staff`. |
| `source_ref` | The item's ID back home, e.g. a Notion page ID. |
| `title` | Short name, e.g. "Dentist check-up". |
| `context` | Optional notes the Coordinator should know. |
| `duration_min` | How long the block is, in minutes. |
| `earliest_start` | Optional. Don't book it before this moment. |
| `due_by` | Optional. It must be finished by this moment. |
| `flexibility` | `fixed` (must be exactly at `earliest_start`), `flexible` (anywhere in the window) or `anytime`. |
| `priority` | 1 to 5, where **1 is most important**. |

**Bottom half, written by the Coordinator**

| Field | What it means |
|---|---|
| `status` | Where the request is in its life (see below). |
| `slot_start`, `slot_end` | Where the Coordinator placed the block. |
| `calendar_event_id` | The ID of the calendar event, once one exists. |
| `decision_note` | The Coordinator's reason, e.g. "Moved to Tuesday: clashes with a board call." |

**Housekeeping, filled in automatically:** `id`, `created_at`, `updated_at`. `updated_at` refreshes itself every time a row is edited.

### `rules`: standing constraints

Standing constraints the Coordinator checks before placing anything, e.g. "train 4x per week" or "no work calls on Friday."

| Field | What it means |
|---|---|
| `owner_agent` | Who set the rule: `personal`, `prntcode` or `coordinator`. |
| `rule` | The rule, in plain English. |
| `kind` | `hard` means never break it. `soft` means it may be broken, but only with a reason. |
| `active` | Switch a rule off without deleting it. |

---

## The life of a request (`status`)

```
 new ──► proposed ──► scheduled ──► done
  │          │            │
  └──────────┴────────────┴──► declined   (won't be booked)
                          └──► bumped     (was booked, got pushed out)
```

| Status | Meaning | Rule the database enforces |
|---|---|---|
| `new` | Just posted; the Coordinator hasn't looked yet. | The default for every new request. |
| `proposed` | The Coordinator has a slot in mind and it is waiting for Khaled's OK in the digest. | Must have `slot_start` and `slot_end`. |
| `scheduled` | The slot is on the calendar. | Must have `slot_start` and `slot_end`. |
| `done` | It happened. | |
| `declined` | It won't be booked. | Must have a `decision_note` saying why. |
| `bumped` | It was booked, then pushed out by something more important. | Must have a `decision_note`, so the source agent can see why. |

Any other status, such as `banana`, is rejected by the database.

---

## No duplicates

Each agent can have only one row per item, identified by the pair (`source_agent`, `source_ref`). When an agent posts the same item again, for example because a Notion page changed, the existing row is **updated** and no second row is created.

Agents must post as an **upsert** on that pair. With the Supabase client:

```js
await supabase
  .from('requests')
  .upsert(row, { onConflict: 'source_agent,source_ref' })
```

Over plain HTTP, send `POST /rest/v1/requests?on_conflict=source_agent,source_ref` with the header `Prefer: resolution=merge-duplicates`.

A plain insert of a duplicate is refused with `duplicate key value violates unique constraint "requests_source_unique"`, so a second row can never be created by accident.

A domain agent's upsert should only send the **top-half** fields, so it doesn't wipe the Coordinator's decision.

---

## Times

All times are stored in **UTC**. Khaled is in Abu Dhabi (UTC+4, no daylight saving), so anything that shows a time to him must convert it first. The `this_week_proposed` view (below) does this for you: its `*_local` columns are Abu Dhabi time.

---

## Digest view: `this_week_proposed`

This is a read-only list of every request in status `proposed` whose slot starts this week. The week runs Monday to Sunday, Abu Dhabi time. It is sorted by start time, then priority, and is ready for the daily digest to read.

---

## Who can access it

Only the agents can, using the project's **service role key**. That key is secret and belongs to the agents only; never paste it into a website or app.

Row-level security is switched on for both tables, and the public ("anon") and logged-in-user roles have no access at all. Anyone who holds only the public key gets `permission denied`.

---

## The Coordinator (v1)

The Coordinator is a **Claude plugin** that lives in this repo (`plugins/coordinator/`). You install it once in claude.ai, and it runs every morning at 07:00 as a **Cowork scheduled task**. You can also run it any time in a regular Chat by typing "run the coordinator".

The repo is also a plugin marketplace (`.claude-plugin/marketplace.json`), so claude.ai installs the plugin straight from GitHub and keeps it in sync.

### What happens each morning
1. **Housekeeping.** Anything scheduled whose time has passed is marked `done`. Anything a domain agent re-posted after it was proposed or booked is **flagged** in the digest. It is never moved silently.
2. **Reading.** It reads the new requests, the active `rules`, and busy time on three calendars:
   - your personal calendar
   - PRNTCODE, which it sees as busy blocks only, with no titles
   - the Coordinator calendar
3. **Placing.** It proposes a slot for each request:
   - It respects each request's window, `fixed`/`flexible`/`anytime` setting and priority. 1 wins over 2.
   - Mon–Thu 09:00–18:00 is never used (fund hours).
   - Fridays allow up to about 2 hours away in total.
   - It avoids 22:00–07:00.
   - It never proposes anything starting within 2 hours of the run.
   - If nothing fits before the due date, the request is **bumped**, with the reason.
4. **Digest.** You get one short message on your phone:
   ```
   Coordinator · Sun 27 Sep

   1. PRNTCODE: supplier call review — Tue 19:00–20:00 (due Wed)
   2. Personal: dentist — Sat 3 Oct 11:00–12:00 (fixed)

   Bumped: Personal: board prep — no 3h slot before Mon 18:00 (fund hours)

   Reply: approve 1 2 · approve all · no 2 (+ reason)   (ref 23c40c74)
   ```

### How to approve
Reply **in the same Cowork task or Chat** where the digest arrived:

| You type | What happens |
|---|---|
| `approve 1 3` | 1 and 3 go on the **Coordinator** calendar. Anything you don't mention **stays proposed** and shows up again in tomorrow's digest. |
| `approve all` | Everything in the digest goes on the calendar. |
| `no 2` · `2 too late` | Declines just item 2, saving your reason for the source agent. You can combine this with an approval: `approve 1; 2 too late`. |
| `approve none` | Declines everything in the digest. Nothing touches any calendar. |
| `keep 4` | Keeps a flagged "changed since booked" item as it is. |

Approved blocks appear on the **Coordinator** calendar, titled `[Personal] …` or `[PRNTCODE] …`. The Coordinator never writes to any other calendar, and never touches events you created yourself. Nothing is written anywhere without your reply.

### One-time setup (in the Claude app)
1. **Install the plugin.**
   1. Go to **Customize → Plugins → Add → Add marketplace**.
   2. Enter `thevault-dev/coordinator`. If asked, connect GitHub and give the Claude GitHub App access to this repo.
   3. Install **coordinator**.
   4. Turn on **Sync automatically**, so every change pushed to `main` reaches you.
2. **Connectors.** Google Calendar and Supabase must both show as connected under **Customize → Connectors**.

   The Google Calendar connector needs these tools allowed: `list_calendars`, `list_events`, `get_event`, `create_event` and `delete_event`.
3. **Create the daily task.** In **Cowork → Scheduled**, create a new task:
   - **Schedule:** daily at 07:00 Abu Dhabi time
   - **Prompt:** `/coordinator:daily-run`

   Scheduled tasks run in the cloud, so your computer can be off. You get a phone alert when the digest is ready.

### Commands
| Command | What it does |
|---|---|
| `/coordinator:daily-run` | The daily run: housekeeping, placement and the digest. The 07:00 task uses this. |
| `/coordinator:approve approve 1 3` | Applies a reply. Plain `approve 1 3` under a digest works too. |
| `/coordinator:check-access` | Diagnoses calendar and ledger access if something seems broken. |

In a regular Chat, just type "run the coordinator"; Chat loads plugin commands as skills.

### Changing the Coordinator
Edit the files under `plugins/coordinator/`, **raise `version`** in `plugins/coordinator/.claude-plugin/plugin.json`, and push to `main`. With Sync automatically on, claude.ai picks up the new version.

### Adding your own requests from chat (intake)
Until the Personal and PRNTCODE agents are connected, you feed the Coordinator yourself, in any regular Claude chat. Just type:

| You type | What happens |
|---|---|
| `I need 2 hours for GMAT prep this week` | You get one line to confirm: `Personal · GMAT prep · 2h · by Sun 4 Oct · flexible · P3 — add it?`. Reply `yes`, or correct it ("make it P1") and it shows the line again. |
| `Block time for a supplier call, 1h, by Wed, urgent` | Same, filed under PRNTCODE, at P1. |
| `Dentist Sat 11am, 1 hour` | Added as **fixed** at that time. |
| `gym Tue 1h, GMAT 2h, call Sophie 30m` | Several items at once, with one confirmation. |
| `What's on my list?` | Open items, grouped: waiting to be placed, proposed, scheduled this week. |
| `Drop the GMAT block` | Withdraws it after you confirm. If it was already on your calendar, the Coordinator calendar event is removed too. |
| `Place it now` (after adding) | Runs the Coordinator immediately instead of waiting for 07:00. |
| `Make GMAT 3h` · `move it to P1` · `due Friday instead` | Edits an item that's waiting or proposed, after a one-line confirmation. A proposed item goes back to waiting and is placed again. A booked item can't be edited; you drop it and re-add it. |
| `Every week I drive back to Dubai Thursday after work or Friday, 1.5h, P1` | Sets up a **weekly** item after confirmation. Each week's copy appears in the digest marked `(weekly)`. |
| `Skip the Dubai drive this week` | Drops only this week's copy. The weekly item stays on. |
| `Haircut every other week, 1h, Fri or Sat daytime` | Sets up an **every-N-weeks** item: every week, every other week, every 3 weeks, and so on. It's posted only in the weeks it happens and marked `(every 2 weeks)`. |
| `Stop the Dubai drive` | Turns the recurring item off. |
| `What repeats?` | Lists your recurring items with their interval, plus any repeating Todoist reminders. |

| `Remind me after work to fix my phone screen` | Sets a **reminder in Todoist**: after your one-line "yes", a Todoist task is created in your Inbox, due Mon 18:15 in this example, and Todoist alerts your phone. No digest needed. |
| `Remind me every Monday at 9 to review PRNTCODE numbers` | A **repeating** Todoist reminder, using Todoist's own recurrence. |
| `What reminders do I have?` · `Cancel the phone screen reminder` | Lists or cancels reminders in Todoist. |

**You never have to mention the Coordinator.** Any ask for time, such as "I need time to…", "find time for…", "put X in my calendar" or "block…", goes to intake. **Nothing goes straight onto your calendar:** time blocks only appear after you approve a digest.

Reminders live in **Todoist**. Todoist's own sync shows timed tasks on a separate "Todoist" Google calendar. The Coordinator never reads that calendar, so a reminder never blocks a time slot. The old v1.3 `[Reminder]` calendar events are retired. If something can't wait until 07:00, say "place it now".

**Defaults, if you don't say:**
- due in 7 days
- `flexible`
- priority 3, where 1 is the most important
- personal or PRNTCODE decided from what the item is about

It always asks how long the item takes if you don't say. It asks personal or PRNTCODE only when that's unclear. If you already have something similar open, it asks "same thing or new?" first. Nothing is written until you say yes.

Intake only *records* what you need. The Coordinator decides where it goes, at 07:00 or when you say "place it now". Chat-added items carry `sub_agent = 'khaled'` and a `chat-…` reference.

### Weekly items
Recurring templates live in the `recurring` table: title, length, a weekly window such as Thu 18:00 → Fri 23:59, flexibility, priority, and on/off.

An `interval_weeks` (1 = weekly, 2 = every other week, up to 8) and an `anchor_week` decide which weeks the item happens in.

Every daily run posts **this week's and next week's** copy of each active template, as ordinary requests with `source_ref = recur-<template id>-<year>-W<week>`. That reference can only exist once per week, so a copy is never posted twice. A skipped week also keeps its reference, so a skip is never undone by the next run.

### How the writes are kept exact
Neither the Coordinator nor intake edits the `requests` table directly. Intake uses `intake_add_request`, `intake_update`, `intake_withdraw`, `intake_add_recurring`, `intake_skip_recurring_week`, `intake_stop_recurring`, and the Coordinator calls its own checked database functions, `coordinator_propose`, `coordinator_bump`, `coordinator_schedule`, `coordinator_decline`, `coordinator_acknowledge` and `coordinator_mark_done`, which refuse a bad write:
- a slot of the wrong length
- a slot outside the request's window
- a fixed item not at its fixed time
- a slot in the past
- an overlap with something already proposed or booked
- approving a slot that has changed since the digest

Every run is logged in `coordinator_runs`, including the digest numbering. Each digest ends with a short `ref`, so `approve 2` always means exactly the item shown as 2 in *that* digest.

### Changing the rules
Standing rules live in the `rules` table, in plain English. `hard` rules are never broken; `soft` rules can be broken, but only with a reason in the decision note. To change one, add a migration, or ask Claude to add, edit or deactivate a rule.

---

## Where things are in this repo

| Path | What it is |
|---|---|
| `supabase/migrations/` | The database changes, in order. **The only way the schema changes**: never edit tables in the Supabase dashboard. |
| `supabase/seed.sql` | Two example requests and one rule, for testing. Safe to run more than once; the file shows how to delete the examples again. |
| `.claude-plugin/marketplace.json` | Makes this repo installable as a plugin marketplace in claude.ai. |
| `plugins/coordinator/` | The Coordinator plugin: its manifest, `skills/coordinator/SKILL.md` (the daily run, digest format and approval handling), `skills/intake/SKILL.md` (adding, editing, repeating, listing and withdrawing requests, and Todoist reminders, from chat) and `commands/` (daily-run, approve, check-access). |
| `supabase/tests/definition_of_done.sql` | A self-check. Paste it into the Supabase SQL editor and run it. It should print `ALL LEDGER CHECKS PASSED` and leaves no data behind. |

### Changing the schema later

1. Add a new file in `supabase/migrations/` named `YYYYMMDDHHMMSS_what_it_does.sql`.
2. Apply it to Supabase with `supabase db push`, or through the Supabase MCP `apply_migration` tool, using the same name.
3. Commit the file.

**Supabase project:** `coordinator` (ref `hgkreprqxevayruqpibf`, region eu-central-1).
