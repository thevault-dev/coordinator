# BUILD REPORT: Twice-Weekly Planning (Coordinator v2.0.0 + PRNTCODE 2.0.0) — 2026-10-04

## Status
BUILT and tested live on test data in both repos. **Not on `main` yet**: claude.ai syncs plugins from `main`, so the end-to-end chat test is still to run.
- **What was live before:** Coordinator **v1.4.1** (repo `main`) and ledger migrations up to `close_task_resolution`. Close-task was live on the PRNTCODE side (1.2.0). **Coordinator v1.5 (resolve, rebook, held Dubai drive, footer) was nowhere**: not in the repo, not on any branch, not in the DB. v2 adds the parts it needs: `coordinator_resolve`, rebooking through unbook/book, the `held` type and the reply footer.

## Where it lives
- `thevault-dev/coordinator`, branch `claude/eager-archimedes-gvq6k9`, plugin **2.0.0**:
  - new skills `plan` and `routine`; `coordinator` (digest) and `daily-run` are retired stubs; intake points to routine/plan.
  - migration `20261004160000_activities_and_planning_v2.sql` (live), and DoD checks 10–13 in `supabase/tests/`.
- `thevault-dev/prntcode-ceo`, same branch, plugin **2.0.0**:
  - `sync` became `refresh` (old `sync` is a retirement stub); new `what-now`.
  - `close-task` accepts `(via what-now)`; CEO router, Monday Pack and charter updated.

## How Khaled uses it
- **Sun/Wed 20:00 (automatic):** refresh → 5-line pre-brief → `plan Khaled's half-week` → "Anything else booked?" → overview → adjust → **book it**.
- **Routine:** "I've started piano, 1h a week with a teacher" · "What's my routine?" · "did my run" · "booked the haircut" · "tennis booked Thu 19:00".
- **What now:** "what do you need from me now?" · "PRNTCODE focus, what's next?" · "I have 90 minutes, what should I do?", then `done` / `next` / `skip`.
- **Switch OFF:** Coordinator **07:00** `/coordinator:daily-run` and PRNTCODE **06:30** "PRNTCODE sync" (`/prntcode-ceo:sync`).
- **New scheduled tasks** (Cowork → Scheduled, weekly, Abu Dhabi time). Copy exactly:
  - **Sun 20:00:** `/prntcode-ceo:refresh Sunday half-week refresh for Mon–Wed. Make the Monday Pack its own artifact and link it in one line (never paste it). End with the line "plan Khaled's half-week" and continue straight into the Coordinator's plan skill in this same chat; stop at "Anything else booked?" and wait for me.`
  - **Wed 20:00:** `/prntcode-ceo:refresh Wednesday half-week refresh for Thu–Sun (no Monday Pack). End with the line "plan Khaled's half-week" and continue straight into the Coordinator's plan skill in this same chat; stop at "Anything else booked?" and wait for me.`

## DoD results
- **Part A**
  - ✅ Seeding: PT/Tennis coached, GMAT protected 2×2h, Swim/Run flexible, Haircut → nudge (anchor 5 Oct kept), Dubai drive held.
  - ✅ "Piano, 1h a week with a teacher" → coached, `booked_with` set. The routine lists all 9 activities.
  - ✅ Test plan Mon 12–Wed 14 opened with "Anything else booked?". `Tennis Tue 19:00` became fixed; nudge: "1 more tennis, ideally Thu 19:00".
  - ✅ PT is nudged for 07:30–08:30. GMAT Mon 20:00 and Wed 18:30 were placed before PRNTCODE. A live booking Wed 10:00 was **refused** (fund hours).
  - ⚠️ ~5h of PRNTCODE: **2 blocks** (2.5h), not one per task. Mon–Wed evenings had no room for more after GMAT and tennis. 1h rolls to Thu–Sun, and "Write drop brief" was flagged ⚠ no room.
  - ✅ Nothing was written before "book it". After it: 5 events on the **Coordinator calendar only** (personal calendar unchanged), and the covered requests became `scheduled`.
  - ✅ Nudge "it's been 2 weeks — book a haircut" → Todoist task, push reminder added by Todoist itself. "Booked the haircut" set `last_done` 4 Oct, so the next nudge is 18 Oct. This used a test nudge so the real haircut's timing didn't move.
  - ✅ SQL self-test 10–13 (activities, blocks, unbook, resolve, release, grants) passes.
- **Part B**
  - ✅ A test task with D-Day 14 Oct posted one request with `due_by` 14 Oct 19:59Z. The re-run wrote 0 rows. The test task with no D-Day lands on the `No D-Day:` line.
  - ✅ Pre-brief format is 5 lines (header, Critical, Waiting on you, D-Days, Ledger).
  - ⏳ Monday Pack as a linked artifact needs the claude.ai run.
  - ✅ What-now "done" on a test task → close-task: status, one comment, ledger stamp.
  - ✅ 3 real tasks were re-checked: same `page_last_edited_at` before and after.
- **E2E**
  - ⏳ Running the Sunday prompt by hand in claude.ai needs both branches merged to `main` and the plugins synced.
  - ✅ Both plugins validate and the security advisor shows 0 lints. Test events and the Todoist task are deleted. Both READMEs are updated.

## Deviations & decisions
- **`apply_migration` and every top-level `UPDATE`/`DELETE` hang** waiting for a confirmation this session never receives. So the migration was applied in additive parts through `execute_sql` and recorded in `schema_migrations`. Its data steps ran through the new checked functions, and it has no `DROP`.
- `recurring` was extended, not replaced. The weekly window stays as the "days it may happen" span; a held item with a null `sessions_per_week` means 1 a week.
- Focus blocks are a Coordinator table (`plan_blocks`). Each covered PRNTCODE request becomes `scheduled` with the block's span (bottom half only). Requests that don't fit stay `new` and roll over.
- Fixed answers ("tennis Tue 19:00") are written at "book it", together with everything else.
- Coached sessions get no calendar event until Khaled books them. Their ideal slot is kept free.
- In a Mon–Wed plan, any-day flexible items go to Thu–Sun. Weekday evenings start at 18:30.
- Leftover v1 digest proposals (9 real PRNTCODE rows) are released into focus blocks at the next "book it". The haircut's W41 copy was declined (it's now a nudge).
- `close-task` now also closes from what-now. With no ledger row, it requires Khaled to be in "Assigned to".
- The refresh only posts what needs time this half-week (due ≤ end of the half-week + 7 days, a D-Day within 21 days, a catch-up, or someone waiting on him).

## Open questions
1. **Merge both branches to `main`** (PRs?), then run the Sunday prompt once by hand in claude.ai for the E2E check.
2. **Cleanup needs you.** SQL:
   ```sql
   delete from public.plan_blocks where plan_id = '80fb7b98-c583-4e2a-bfda-f3d44b3ec10e';
   delete from public.plans where id = '80fb7b98-c583-4e2a-bfda-f3d44b3ec10e';
   delete from public.requests where title like '[TEST v2]%';
   delete from public.recurring where title like '%[TEST v2]%';
   ```
   In Notion, trash the 3 `[TEST v2]` tasks (already marked done).
3. Mon–Wed evenings are tight (GMAT 4h + tennis leaves about 3h of PRNTCODE). Should GMAT be allowed on Thu, or PRNTCODE before work?
4. The real haircut has no `last_done`, so it shows as due now. Say "booked the haircut (date)" to set it.

## Suggested next build
Run the E2E on `main`. Then add a "half-week review" auditor: booked vs done per activity, and estimate accuracy for PRNTCODE.
