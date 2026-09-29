# BUILD REPORT: Coordinator v1.4 (Todoist Reminders & Every-N-Weeks) — 2026-09-29

## Status
DONE. Reminders now live in Todoist, recurring items can repeat every N weeks, and every Definition of Done item passed. One item, the Todoist-doesn't-block check, was run in the build session rather than in chat.
- **Daily 07:00 task: exists and fired.** Run `e7fbea37` logged at 06:55 Abu Dhabi on 29 Sep.
- That digest proposed 3 items. Khaled replied "reject all", saying he wants the Dubai drive right after work on Thursday.

## Where it lives
- Repo `thevault-dev/coordinator`, branch `main`, commit `a4c1277`. The plugin `coordinator` is **v1.4.0**, validated and synced. The skills are `intake` (section 6 rewritten for Todoist, section 4 for intervals) and `coordinator`.
- Migration `supabase/migrations/20260928112111_every_n_weeks_and_retire_calendar_reminders.sql`:
  - It adds `recurring.interval_weeks` and `anchor_week`.
  - It adds `recurring_week_matches()`, and updates `coordinator_post_recurring` and the skip function.
  - It drops the calendar-reminder write functions.
  - The security advisor is clean.
- **Todoist:** Khaled is on the Free plan, timezone Asia/Dubai. Tasks go to the Inbox. Timed tasks sync to a dedicated **"Todoist"** Google calendar, not the primary one; this was checked before building.

## How Khaled uses it
- "Remind me in 5 minutes to…" · "remind me after work to…" · "remind me every Monday at 9 to review PRNTCODE numbers"
- "What reminders do I have?" · "cancel the X reminder"
- "Haircut every other week, 1h, Fri or Sat daytime" · "every 3 weeks…" · "What repeats?" (shows the interval)

## Definition of Done results
- **5-minute Todoist reminder alerts on the iPhone: PASS.** Khaled confirmed ("done and yes").
  - Todoist automatically adds its own at-due-time reminder to timed tasks, so the skill adds one only if it's missing. Adding a second one would alert twice.
- **Repeating reminder: PASS.** "Review PRNTCODE numbers" is set to `every monday at 9:00` (next Mon 5 Oct 09:00), with its automatic reminder.
- **List and cancel: PASS.** Both reminders were listed, and the 5-minute test task was cancelled (deleted from Todoist).
- **No new `[Reminder]` events, and old ones retired: PASS.**
  - The only old one ("Test this", already past) had its event deleted and its row closed.
  - The `reminders` table is now history only. The Coordinator calendar has no events.
- **A Todoist task doesn't block a slot: PASS, run in the build session.**
  - "Test blocking" sat on the Todoist calendar at Sat 3 Oct 10:00–10:30.
  - A fixed request for Sat 10:00–11:00 was placed by the skill's rules, which read only the personal, PRNTCODE and Coordinator calendars. It was proposed at 10:00.
  - Khaled created both items in chat, but no chat run followed, so the placement was run here.
- **Haircut every other week: PASS.**
  - The chat created an interval-2 template, moved to start next week at Khaled's request.
  - It matches W41, W43 and W45 only. The daily-run posting created Fri 9–Sat 10 Oct once, and a re-run posted 0.
  - A skip in an off-week is refused.
- **Weekly items still post weekly: PASS.** The Dubai drive has interval 1 and matches every week.
- **v1.4.0, validation, advisor, cleanup and README: PASS.** Test tasks and rows are removed.

## Deviations & decisions made on Khaled's behalf
- Reminder timing: no duration is set, the task goes to the Inbox, and a push reminder is added only if Todoist didn't add one. For recurring reminders, Todoist's own monthly phrasing ("every 1st at 9") is accepted, since it's Todoist-native.
- `starts_on` is also the anchor week. Intervals run from 1 to 8 weeks, and monthly or date-based block repeats aren't supported.
- The Coordinator never reads the Todoist calendar; it reads only its three.
- **Builder fix:** the haircut template was re-anchored to 5 Oct by a direct update. Changing a template's start date isn't available from chat yet.

## Open questions / risks
- **Thursday's Dubai drive is unbooked.** "Reject all" declined this week's drive and next week's copy. Khaled wants it "right after work Thursday". PRNTCODE is busy Thu 1 Oct 18:00–19:00. Should the template become fixed at Thu 18:00, or use a tighter window such as Thu 18:00–20:00? Next week's declined copy won't re-post unless it's restored.
- **Todoist-synced events also carry Google's default alerts.** If the Todoist calendar is visible in Apple Calendar, reminders may alert twice; hide that calendar on the phone if so.
- **Template edits** (start date, window) aren't available from chat.

## Suggested next build
Edit recurring templates from chat, including start and window, and settle the Dubai drive timing. Then connect the Personal and PRNTCODE agents.
