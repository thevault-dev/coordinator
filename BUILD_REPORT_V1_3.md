# BUILD REPORT: Coordinator v1.3 (Calendar Reminders) — 2026-09-28

## Status
DONE, pending two checks on Khaled's phone. Reminders can be set, listed and cancelled from regular chat as alert events on the Coordinator calendar. The whole path was tested end to end against the real calendar, but not yet from Khaled's phone.

## Where it lives
- Repo `thevault-dev/coordinator`, branch `main`, commit `09dcf46`. The plugin `coordinator` is **v1.3.0**, validated and auto-syncing.
- The skill is `plugins/coordinator/skills/intake/SKILL.md`, new section 6. The Coordinator skill now ignores reminder events.
- Migration: `supabase/migrations/20260928032602_reminders.sql`. It adds the `reminders` table and the checked functions `intake_add_reminder` and `intake_cancel_reminder`. The security advisor is clean.
- Also shipped today:
  - **v1.2.1:** only items Khaled explicitly rejects are declined; anything unmentioned stays proposed.
  - The two Dubai drives that were declined by mistake are restored.

## Why calendar events, not Apple Reminders
Apple Reminders has no connector for claude.ai. The meal-plan skill most likely reaches it through Cowork on the Mac, which only works while the Mac is on. Khaled chose calendar reminders instead. They show in Apple Calendar through his Google account.

## How Khaled uses it
- "Remind me after work to fix my phone screen" → `Reminder · Fix phone screen · Mon 28 Sep 18:15 — set it?` → yes
- "Remind me tonight to call mum" (20:00) · "nudge me at 5 to leave" (17:00) · "remind me in 2 hours to…"
- "What reminders do I have?" (reminders also appear at the bottom of "What's on my list?")
- "Cancel the phone screen reminder"

## What was built
- **A reminder is a 15-minute `[Reminder] <title>` event on the Coordinator calendar only.**
  - It has a popup alert at the start time.
  - It's marked **free**, so it never blocks the Coordinator's placement.
  - It's created straight after Khaled's one-line "yes". This is the **only** path onto the calendar that skips the 07:00 digest; time blocks still need digest approval.
- **Time words:**
  - "after work" is 18:15 on the next weekday
  - "tonight" is 20:00
  - "tomorrow morning" is 08:00
  - exact times are taken as given; a bare hour from 1 to 7 means pm
  - no time at all → it asks "When?"
- **Reminder or time block:**
  - "Remind me to X" is a reminder
  - "I need time to X" is a time block
  - "Remind me to make time for X" is a time block
  - if unclear, it asks
- **Safe writes:**
  - The event is created first, then recorded; if recording fails, the event is deleted.
  - To cancel, the event is deleted first, and the database refuses a cancel whose event ID doesn't match.

## Test results (real Coordinator calendar)
- **Create: PASS.** The event was created free, with a popup at 0 minutes, then recorded (`status = set`).
- **Guards: PASS.**
  - A reminder in the past is refused.
  - Cancelling with the wrong event ID is refused.
  - A correct cancel works (`cancelled`), and the event is gone.
- **Cleanup: PASS.** Test rows and events are removed. The plugin validates, and the security advisor is clean.
- **Still to check on the phone:**
  1. The event appears in Apple Calendar. That needs the Google account under iPhone Settings → Calendar → Accounts.
  2. The alert actually fires on the iPhone. The alert is set on Google's side and can't be confirmed from the build environment.

## Decisions made on Khaled's behalf
- Reminders are 15 minutes long, carry a `[Reminder]` prefix, alert at the start, and are marked free.
- They're kept in their own table, not in `requests`, so the Coordinator's digest and placement ignore them.
- Repeating reminders ("every Monday…") aren't supported; it offers a one-off instead.

## Open questions / risks
- If iOS doesn't show Google's popup alerts, the fallback is iOS's default alert setting for that calendar.
- **The 07:00 Cowork scheduled task still needs creating:** daily at 07:00, prompt `/coordinator:daily-run`.
- **Repeating reminders** would reuse the weekly-template idea from v1.2.

## Suggested next build
Connect the Personal and PRNTCODE agents to the ledger, so the digest fills without manual input.
