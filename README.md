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

## Where things are in this repo

| Path | What it is |
|---|---|
| `supabase/migrations/` | The database changes, in order. **The only way the schema changes**: never edit tables in the Supabase dashboard. |
| `supabase/seed.sql` | Two example requests and one rule, for testing. Safe to run more than once; the file shows how to delete the examples again. |
| `supabase/tests/definition_of_done.sql` | A self-check. Paste it into the Supabase SQL editor and run it. It should print `ALL LEDGER CHECKS PASSED` and leaves no data behind. |

### Changing the schema later

1. Add a new file in `supabase/migrations/` named `YYYYMMDDHHMMSS_what_it_does.sql`.
2. Apply it to Supabase with `supabase db push`, or through the Supabase MCP `apply_migration` tool, using the same name.
3. Commit the file.

**Supabase project:** `coordinator` (ref `hgkreprqxevayruqpibf`, region eu-central-1).
