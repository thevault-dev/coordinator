# BUILD REPORT: Coordinator v1 — 2026-09-27

## Status
DONE. The Coordinator runs as a claude.ai plugin from a Cowork scheduled task. Its first run proposed a block, Khaled approved it by number, and it landed only on the Coordinator calendar. All Definition of Done items pass. Delivery moved from Code Routines to a plugin plus a Cowork task at Khaled's request.

## Where it lives
- **Repo:** `thevault-dev/coordinator`, branch `main`. Plugin packaging is in commit `ee19f3d`, and this report is committed on top of it.
  - The repo doubles as a **plugin marketplace**, defined in `.claude-plugin/marketplace.json`.
  - Plugin: `plugins/coordinator/`. Its skill is `skills/coordinator/SKILL.md`, and its commands are `commands/daily-run.md`, `approve.md` and `check-access.md`.
- **New migrations** (all applied to Supabase `coordinator`, ref `hgkreprqxevayruqpibf`):
  - `supabase/migrations/20260926201741_coordinator_runs.sql`: the run log
  - `supabase/migrations/20260927073935_coordinator_v1.sql`: the `decided_at` column, checked write functions and the change-flag view
  - `supabase/migrations/20260927073939_seed_work_rules.sql`: the work rules
- **Daily run:** a **Cowork scheduled task** Khaled created, daily at **07:00 Abu Dhabi**, prompt `/coordinator:daily-run`.
  - It runs in the cloud, so his computer can be off.
  - He gets a phone alert with the digest and replies `approve …` in that task.
  - He can also run it on demand in regular Chat by typing "run the coordinator".
- **Calendar access** is through Khaled's **Google Calendar connector** on claude.ai, with no separate Google sign-in or API keys.
  - Khaled allowed `list_calendars`, `list_events`, `get_event`, `create_event` and `delete_event`.
  - He created the **Coordinator** calendar by hand, because the connector has no "create calendar" tool.
  - He shared PRNTCODE (`thevault@prntcode.com`) with his personal account as **free/busy only**. A workspace admin setting prevents more.
  - Ledger access is through the **Supabase connector**.

## What was built
- **Plugin `coordinator` v1.0.0.** It installs from the repo under Customize → Plugins → Add marketplace, with Sync automatically on. It passes `claude plugin validate`, and a test install shows 1 skill and 3 commands.
- **The skill** covers:
  - the daily run: housekeeping → read ledger, rules and three calendars → propose or bump → digest
  - approval by number
  - safety rules: write only to the Coordinator calendar, nothing without approval, never edit `requests` directly
- **Checked SQL write functions.** These are the only way the Coordinator writes, and each stamps `decided_at`:
  - `coordinator_propose` rejects a wrong length, a slot outside the window, a fixed request off its time, a slot in the past, and overlaps
  - `coordinator_bump` requires a reason
  - `coordinator_schedule` refuses if the slot changed since the digest
  - `coordinator_decline`, `coordinator_acknowledge` and `coordinator_mark_done`
- **`decided_at` column and the `coordinator_changed_since_decision` view.** A request re-posted after a decision is flagged in the digest ("Changed since booked"), not moved.
- **`coordinator_runs` log.** Each digest's numbering is stored, and every digest ends with `(ref xxxxxxxx)`, so `approve 2` always maps to exactly that digest's item 2.
- **Work rules seeded into `rules`:**
  - Mon–Thu 09:00–18:00 at the fund (**hard**)
  - Fri 09:00–18:00 remote, up to about 2h away in total (soft)
  - weekends and after-hours free unless the calendar is busy (soft)
  - avoid 22:00–07:00 (soft)
- **Digest format.** Plain text on one phone screen:
  ```
  1. PRNTCODE: supplier call review — Tue 19:00–20:00 (due Wed)
  ```
  It adds a `Bumped:` line with the reason, a `Changed since booked:` line, and a one-line "nothing to propose today" when empty.
- **README** now explains how the Coordinator works, the one-time setup, the commands, and how to approve.

## Definition of Done results
- [x] **STEP 0, calendar read and write from where it runs: PASS.**
  - A one-off probe ran in a fresh scheduled session and read all three calendars, including PRNTCODE as busy blocks (7 blocks, no titles).
  - It created, confirmed and deleted a test event on the Coordinator calendar.
  - The final Cowork run did the same for real (below).
- [x] **Work rules in `rules`, and nothing can be placed Mon–Thu 09:00–18:00: PASS.** A 3h request due Mon 18:00 was bumped with *"No 3h gap before Mon 18:00: the whole window is Mon 09:00-18:00 fund hours (hard rule)."*
- [x] **Three test requests give two numbered proposals and one bumped line: PASS.**
  - Fixed dentist: Sat 3 Oct 11:00–12:00
  - Flexible supplier call: Sun 14:00–15:00, due Wed
  - Impossible board prep: bumped with the reason above
- [x] **`approve 1` creates exactly one event, with the matching `calendar_event_id`, and no other calendar changes: PASS.**
  - In the build session, event `3raet969…` landed on the Coordinator calendar and item 2 was declined.
  - In the real **Cowork scheduled task**, the digest (ref `43f4b4a5`) proposed Mon 21:00–21:30. Khaled replied `approve 1`, and exactly one event, `po64n5b1qb4fui4nhf7op0rfto`, appeared on the Coordinator calendar with the same ID in the ledger.
  - Neither run modified any event on the personal or PRNTCODE calendars.
- [x] **`approve none` creates no calendar events: PASS.** The request became `declined` ("Khaled: too busy"), and the Coordinator calendar was unchanged.
- [x] **A scheduled request whose slot has passed becomes `done` on the next run: PASS.** `coordinator_mark_done()` returned only the past item. A booked item later the same day stayed `scheduled`.
- [x] **The daily scheduled run exists and has fired at least once: PASS.**
  - The Cowork task exists, 07:00 daily.
  - It fired once via "Run now" on 2026-09-27 at 22:21 Abu Dhabi: run `43f4b4a5` logged as `ok`, followed by approval run `9ecc7970`, also `ok`.
  - The first **automatic** 07:00 firing is 2026-09-28.
- [x] **All test rows and events removed; README updated: PASS.**
  - The ledger has 0 requests and the Coordinator calendar is empty.
  - The run log keeps 3 rows as an audit trail: the access probe and the real Cowork daily and approval runs.
  - The Supabase security advisor shows no warnings.

## Deviations from the brief
- **Delivery.** The brief assumed a scheduled Claude session. Khaled switched to a **claude.ai plugin plus a scheduled task**. Plain Chat can't schedule tasks; only **Cowork** can. So the 07:00 digest arrives as a Cowork task (on phone, web or desktop), and on-demand runs work in regular Chat.
- **The Coordinator calendar was created by Khaled, not the Coordinator.** The connector can't create calendars. The skill finds the calendar by name and checks its ID.
- **Most Definition of Done checks ran in the build session**, which follows the same skill with the same connectors. These were: rules, three requests, approve 1, approve none, done, the change flag, and the guard rejections. The full loop (digest → `approve 1` → event) was then proven once in the real Cowork task. `approve none` and the `done` transition have not yet been exercised inside Cowork itself.
- **Added beyond the brief:**
  - the `coordinator_runs` table
  - the checked write functions
  - `keep N` to acknowledge a flagged item
  - the digest `ref`
  - a `/coordinator:check-access` diagnostic command
- **Nice-to-haves.**
  - The Monday "shape of the week" line is written into the skill but **untested**, since no Monday run has happened yet.
  - Automatically deleting the event when a scheduled request is later declined is **not built**. Declines only apply to `proposed` items in v1.

## Decisions made on Khaled's behalf
- Nothing is proposed that starts within **2 hours of the run**, so there's time to approve. Fixed requests keep their time.
- There is a soft rule to **avoid 22:00–07:00**.
- **Placement preferences:**
  - `flexible` takes the earliest good slot, with about a 15-minute buffer from busy blocks and starts rounded to :00 or :30
  - `anytime` takes the most convenient free evening or weekend slot
  - open proposals are kept if still valid, otherwise re-placed
- In an approval, **every digest item not listed is declined**, with the reason if given. A reply that doesn't match the digest makes it ask before writing.
- **Calendar events:**
  - titled `[Personal] …` or `[PRNTCODE] …`
  - the description holds the request context and `Coordinator request <id>`
  - marked busy, with no attendees, no Meet link and no email notifications
- **Busy time:**
  - all-day and "free" events are ignored
  - every PRNTCODE block is busy
  - existing proposed and scheduled requests count as busy
  - if **any** calendar can't be read, nothing is proposed that day
- The plugin `version` must be raised on each change so Sync picks it up.
- All work rules have `owner_agent = 'coordinator'`.
- The plugin and marketplace names are `coordinator` and `thevault-coordinator`.

## Open questions / risks
- **Your personal calendar looked empty.** `k.a.muhairi@gmail.com` returned **no events at all** for the two weeks ahead. If your real appointments live in another calendar, the Coordinator can't see them and may double-book. Candidates are "Calendar" (`3kqe1f1vq5vgantluat5pbmp44@…`, set to UTC) and "Sports". Please confirm which calendars count as busy.
- **Withdrawing requests.** Domain agents have no way to cancel a request yet: there is no `withdrawn` status, and nothing removes the calendar event. The next build should add this, e.g. a `coordinator_withdraw` function and event deletion.
- **Rules for domain agents writing to the ledger:**
  - Upsert on (`source_agent`, `source_ref`) and send **only top-half fields**.
  - Priority 1 is the most important.
  - Times are in UTC.
  - Re-posting a proposed or scheduled item raises a flag and does not move it.
- **Access is by convention only.** Every agent reaches Supabase through the same connector and account, so nothing in the database stops a domain agent from calling the Coordinator's functions. The split relies on each agent following its own rules.
- **Does the recurring Cowork task expire?** Not confirmed. Anthropic's help page doesn't mention an expiry. Watch for the digest arriving on day 8.
- **Supabase is on the Free plan** and pauses after about a week idle. The daily run should keep it active.
- **Rule enforcement.** The Friday 2h limit and the hard fund-hours rule are enforced by the Coordinator's reasoning plus a re-check before each write. The database guards cover only generic slot validity, not the plain-text rules.

## Suggested next build
Connect the Personal and PRNTCODE agents to the ledger: an upsert of the top half, a withdraw path, and reading back `decision_note` for bumped or declined items. Confirm which personal calendars count as busy first.
