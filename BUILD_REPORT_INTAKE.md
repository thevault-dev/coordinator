# BUILD REPORT: Coordinator Intake — 2026-09-28

## Status
DONE. Khaled can add, list and withdraw requests in regular claude.ai chat. Every Definition of Done item passed in his live chat test.

## Where it lives
- Repo `thevault-dev/coordinator`, branch `main`. Intake is in commit `248aeb2`, and this report sits on top of it.
- Skill: `plugins/coordinator/skills/intake/SKILL.md`. The Coordinator skill's logic is unchanged; only its description now points adding, listing and withdrawing to intake.
- Migration: `supabase/migrations/20260927183234_intake.sql`. It adds the checked functions `intake_add_request` and `intake_withdraw`. There are no direct inserts. The security advisor is clean.
- Plugin `coordinator` **v1.1.0**. It passes `claude plugin validate` and synced to claude.ai.

## How Khaled uses it
- "I need 2 hours for GMAT prep this week" → `Personal · GMAT prep · 2h · by Sun 4 Oct · flexible · P3 — add it?` → yes
- "Block time for a supplier call, 1h, by Wed, urgent" gets PRNTCODE, P1. "Dentist Sat 11am, 1 hour" is added as fixed.
- "gym Tue 1h, GMAT 2h, call Sophie 30m": several items, one confirmation.
- "What's on my list?" or "Drop the GMAT block"
- "Place it now" runs the Coordinator immediately instead of waiting for 07:00.

## Definition of Done results
- **Add in claude.ai chat: PASS.** "I need 2 hours for GMAT prep this week" → yes. Exactly one `new` row: `sub_agent = khaled`, `chat-48ecfa60`, 120 min, flexible, P3, due Sun 4 Oct 23:59.
- **Missing duration is asked for: PASS.** "Block time to call the bank" got "How long?". No row was written.
- **"no" writes nothing: PASS.** The bank call was answered "no", and there is no row for it.
- **Duplicate guard: PASS.** "Add GMAT study, 1 hour" asked "same thing or new?". Khaled said "same", and no second row was created.
- **"What's on my list?" groups by status in Abu Dhabi time: PASS.** Confirmed by Khaled in chat.
- **Withdraw a `new` item: PASS.** Haircut (`chat-8bc98c22`) became `declined`, "withdrawn by Khaled".
- **Withdraw a `scheduled` item: PASS.**
  - GMAT was approved to Tue 29 Sep 20:00–22:00 (event `du3qlnr8…`), then dropped.
  - The event now returns "not found" on the Coordinator calendar.
  - Neither the personal nor the PRNTCODE calendar was modified.
- **Chat item picked up by the next daily run: PASS.** "Place it now" started a daily run (ref `85b921b5`), which proposed GMAT as item 1.
- **v1.1.0, validation, auto-sync: PASS.**
- **Cleanup and README: PASS.**
  - Test rows and events are removed, and the ledger has 0 requests.
  - The README now lists the phrases Khaled can use.

## Deviations & decisions made on Khaled's behalf
- **Editing isn't supported**, and Khaled noticed this in testing. "Same thing" on a duplicate adds nothing and offers to withdraw and re-add. The brief excluded edits to scheduled items; edits to waiting items weren't asked for.
- **Chat-added items:**
  - `source_ref` is `chat-` plus 8 random hex characters.
  - `earliest_start` is now unless he gives one.
  - Deadlines are 23:59 Abu Dhabi time. "This week" means the coming Sunday, or next Sunday when today is Sunday.
- **Wording maps to settings:** "urgent/must" → P1, "important" → P2, "no rush" → P4, "nice to have" → P5; "whenever" → anytime, and an exact time → fixed.
- **Personal or PRNTCODE** is judged from the topic. Brand, suppliers, shoots, team and stock count as PRNTCODE. It asks only when unclear.
- **Both nice-to-haves were built:** "place it now" and several items in one message.

## Open questions / risks
- **Edit waiting items?** A small follow-up could add an `intake_update` function for `new` items, e.g. "make GMAT 3h" or "move it to P1".
- **Personal calendar still empty.** `k.a.muhairi@gmail.com` still shows no events. Confirm which calendars count as busy.
- **The first automatic 07:00 run** is due today, 28 Sep, at 07:00 Abu Dhabi time. It has not fired yet as of this report.

## Suggested next build
Edit waiting items from chat, plus confirmation of which personal calendars count as busy.
