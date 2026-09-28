# BUILD REPORT: Coordinator v1.2 (Routing, Recurring & Edits) — 2026-09-28

## Status
PARTIAL. Everything is built, live and correct at the database level. Two Definition of Done items (weekly skip and editing a proposed item) were proven only in database tests, not in chat, because the chat test took a different path (below).

## Where it lives
- Repo `thevault-dev/coordinator`, branch `main`. v1.2.0 is in commit `49d9f8d`, and this report sits on top of it. The plugin `coordinator` is **v1.2.0**, validated and synced.
- Skills: `plugins/coordinator/skills/intake/SKILL.md` (routing, weekly items, edits) and `skills/coordinator/SKILL.md` (posts weekly copies, `(weekly)` label, golden rule).
- Migration: `supabase/migrations/20260928025117_recurring_and_edits.sql`. It adds the `recurring` table and the functions `coordinator_post_recurring`, `intake_add_recurring`, `intake_skip_recurring_week`, `intake_stop_recurring` and `intake_update`. The security advisor is clean.
- **This morning's 07:00 run did not fire.** No run was logged between 06:55 and 07:14. The only run today (07:14) was a manual "place it now". Please check Cowork → Scheduled.

## How Khaled uses it
- Any ask for time, with no need to mention the Coordinator: "I need time to…", "find time for…", "put X in my calendar", "block…"
- "Every week I drive back to Dubai Thursday after work or Friday, 1.5h, P1" · "What repeats?"
- "Skip the Dubai drive next week" (the template stays on) · "Stop the Dubai drive"
- "Make GMAT 3h" · "move it to P1" · "due Friday instead": for waiting or proposed items. Booked items get "drop and re-add".

## Definition of Done results
- **Routing: PASS.** Khaled ran the three phrases in a fresh chat. The haircut and gym items were declined at confirmation, so no rows were written. The Coordinator and personal calendars show no event created directly.
- **Dubai template from chat: PASS.** Thu 18:00 → Fri 23:59, 90 min, flexible, P1, starting 5 Oct, active.
- **Next week posted once, re-run posts nothing: PASS.** Run `7584190f` posted `recur-…-2026-W41` (Thu 8 Oct). A later `coordinator_post_recurring()` call returned 0 rows.
- **This week's hand-added drive left alone: PASS** by the template, which starts 5 Oct. See the first open question.
- **Skip one week: PASS in database tests only.**
  - In a test transaction, the skip declined only that week's copy and left the template on, and a skip before posting wrote a placeholder.
  - In chat, the W41 copy had already been declined by an approval reply, so there was nothing left to skip.
- **Edits:**
  - Editing a `new` item: PASS. GMAT went 2h → 3h via `intake_update`.
  - Editing a booked item: PASS. Chat refused and suggested drop and re-add; Khaled dropped GMAT (event deleted) and re-added it at 2h.
  - Editing a `proposed` item: PASS in database tests only. It reset to `new` with the slot cleared.
- **v1.2.0 validates and syncs, advisor clean, README updated: PASS.** Test-only rows were removed. The items in question 1 are left for Khaled to decide.

## Deviations & decisions made on Khaled's behalf
- The daily run posts **this week's and next week's** copy of each template. A copy is never posted twice, and a skip is never undone by a later run.
- A template starts this Monday, unless this week's window has passed or a matching item already exists; then it starts next Monday.
- "A single day with no time" means 07:00–22:00. Windows must fit inside one Mon–Sun week.
- Weekly copies carry `sub_agent = 'recurring'`.

## Open questions / risks
- **Your real drives were declined by an approval reply.** Replying `approve 2` to digest `7584190f` declined items 1 and 3: this week's real drive and next week's weekly copy. Restore them? Also, should unlisted items **stay proposed** instead of being declined? That would be safer.
- **GMAT prep (2h, due Sun 4 Oct) is still open.** Keep it, or was it a test?
- **The 07:00 scheduled task didn't fire today.** Check its status and expiry in Cowork.

## Follow-up (v1.2.1, same day)
- **Approval rule changed:** only items Khaled explicitly rejects ("no 2", "2 too late", "approve none") are declined. Unmentioned items stay proposed and reappear in the next digest.
- **Drives restored:** both Dubai drives (this week's and W41) are back to waiting.
- **07:00 run:** the scheduled task had not been created yet. Khaled is setting it up.
- **Reminders:** Apple Reminders has no claude.ai connector, so reminders can't reach it from phone chat. Calendar-alert reminders are the workable route.

## Suggested next build
Approval semantics (unlisted items stay proposed), plus reminders from chat. Reminders are sketched in the chat reply.
