# BUILD REPORT: Coordinator v2.1 — Human-Shaped Planning (2026-10-04)

## Status
BUILT, **merged to `main`** ([PR #3](https://github.com/thevault-dev/coordinator/pull/3)), live in the database and tested on rolled-back test data. claude.ai syncs plugin **2.1.0** from `main`. Khaled hasn't run the planning chat in claude.ai yet; that's the last check (open question 1).

## Where it lives
- `thevault-dev/coordinator`, plugin 2.1.0: `skills/plan/SKILL.md` (rewritten: opener, 3b places, H rules, R rule edits, V visual plan), `skills/plan/half-week.html` (timeline template), `skills/routine/SKILL.md` (places), README.
- Migration `20261004200000_human_shaped_planning_v2_1.sql` (live, recorded in `schema_migrations`). Self-test checks 14–16 are in `supabase/tests/`.
- Artifact **Khaled's half-week**: https://claude.ai/artifact/SfbR2SsyNiu7rks2KDdNLE. It's private and currently shows his real booked Mon 5–Wed 7 plan.

## How Khaled uses it
- Sun/Wed 20:00 as before. The plan now opens with *"Before I plan Mon–Wed: any commitments…? And where will you be each day?"*, then asks "Where's tennis?" / "How long from home?" once per new place or pair. The plan appears in the artifact; chat shows one summary line plus any "Doesn't fit" lines with options.
- "dinner at 20:00 from now on", "buffers 10 min", "tennis is at the Saadiyat club, 20 min from home". Each is confirmed first, then remembered.
- Optional: in the Sun/Wed scheduled prompts, change `stop at "Anything else booked?"` to `stop at the commitments question`. The skill works either way.

## DoD results
- ✅ **Opener.** I ran the test plan for Mon 12–Wed 14 Oct by hand against his live calendars, following the new skill. It shows "Already on" (Mon 18:00 and 19:00 PRNTCODE busy), asks the commitments-and-location question, and proposes nothing before the answer. ⏳ Not yet run as a claude.ai chat.
- ✅ **New place.** The test answer "Padel with Omar Wed 18:30 at Zayed Sports City" leads to one "Where is it?", then `place_add` + `travel_set`. The timeline shows 15m travel before and after, with buffers. Reuse without asking was proven at DB level: a unique place name, `travel_between` symmetric, one row per pair (rolled back).
- ✅ **Rules.** GMAT is live as 3 × 90. `coordinator_book_block` refuses a 2h focus block, a focus block <15 min after another, a 3rd focus block on a weekday evening, and a weeknight block ending 22:15. A fixed late dinner and the travel home are allowed. Dinners sit in 19:30–21:00.
- ✅ **Doesn't fit.** The test plan produced 3 lines with options: Mon dinner (calls run to 20:00), GMAT 1 of 3, PRNTCODE 6.5h → 30m. No rule was squeezed.
- ✅ **Artifact in place.** Same URL across propose (v1 publish) → adjust (db v1) → book it (db v2) → republish + db v3 (real plan). Both update paths work. At 390px wide there's no horizontal scroll and no JS errors, in light and dark.
- ✅ **"Dinner at 20:00 from now on".** `coordinator_set_rule` replaces the rule (old row kept inactive) and refuses 20:30 unless the window moves (rolled back). The live rule is unchanged.
- ✅ **Book it.** All 11 test blocks were accepted by the live functions, and the factory-visit request became `scheduled`. A squeezed GMAT was refused. Everything was rolled back, so no calendar events were written.
- ✅ Plugin 2.1.0 validates and is merged to `main` · advisor 0 lints · README updated · this build left no test rows (places=0, plans unchanged).

## Deviations & decisions
- **DROP/UPDATE/DELETE still hang in this environment.** The migration went in additive parts. The old `coordinator_book_block` is **renamed** `coordinator_book_block_v2_0` (it now just raises), not dropped. All tests ran inside blocks that always roll back.
- An activity's default place lives on the activity (`recurring.place_id`), so one place can serve PT and swim. Bases are places too. The day's bases are stored in `plans.detail`.
- **Weekday evenings start 18:15** (fund end + buffer, was 18:30). Without that, a 90-min GMAT plus a dinner inside 19:30–21:00 plus buffers can never fit before 22:00. There's no office→home commute yet.
- Meals and travel are booked on the Coordinator calendar and exempt from the fund-hours check (breakfast after a late PT can touch 09:00; the plan flags it). Buffers are gaps, not events.
- The artifact reads the shared doc `plan/current`; republishing `half-week.html` is the fallback. Test stages were labelled `[TEST]`.

## Open questions
1. Check that claude.ai shows Coordinator 2.1.0 (re-sync the marketplace if not), then run the Sunday prompt once in claude.ai.
2. Next Mon–Wed (12–14 Oct) fits only **1 of 3 GMAT** under these rules (Monday PRNTCODE calls 18:00–20:00). Options: allow GMAT Thu–Sun, a 75-min early-morning session, or make Mon dinner flexible.
3. Do you go home from the fund first? Tell me the minutes, and evenings will start later.
4. **Cleanup SQL (v2 leftovers; DELETE hangs here, so please run it):**
   ```sql
   delete from public.plan_blocks where plan_id = '80fb7b98-c583-4e2a-bfda-f3d44b3ec10e';
   delete from public.plans where id = '80fb7b98-c583-4e2a-bfda-f3d44b3ec10e';
   delete from public.requests where title like '[TEST v2]%';
   delete from public.recurring where title like '%[TEST v2]%';
   drop function if exists public.coordinator_book_block_v2_0(uuid, text, text, timestamptz, timestamptz, text, uuid, uuid[], text); -- optional
   ```

## Suggested next build
A fund-office place plus commute, and the "half-week review" auditor (booked vs done, and how many "doesn't fit" choices Khaled made each week).
