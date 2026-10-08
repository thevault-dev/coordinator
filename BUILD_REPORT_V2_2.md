# BUILD REPORT: Coordinator v2.2 — Todoist lists and labels (2026-10-08)

## Status
BUILT on branch `claude/todoist-lists-labels`, plugin **2.2.0**. Not merged yet, so **not live**: claude.ai syncs the plugin from `main`. **weekly-meal-plan is not in this build** (see "Left for a separate brief").

## Where it lives
- `plugins/coordinator/skills/intake/SKILL.md`: new **section 7, Lists and labels**. Section 6 (reminders) now files into Personal Tasks / PRNTCODE Tasks, with the Inbox only on request. "Cancel" also removes a list item he names. The description has new triggers.
- `plugins/coordinator/skills/plan/SKILL.md`: reads the `bring to GC` / `bring to apt` items (step 2.5), adds the **carry nudge** (step 4.9b), a `Carry ·` summary line (step 5) and the Todoist write at "book it" (step 6.5b), and moves or cancels the nudge when the drive moves after booking (section 7). Booking nudges now go to Personal Tasks, not the Inbox.
- `plugins/coordinator/skills/plan/half-week.html`: a `carry` note kind with the label "Carry".
- `plugin.json` 2.1.0 → 2.2.0 and README (v2.2 section, intake table).
- No migration, no ledger change.

## Khaled's Todoist, checked live (read-only)
Projects Inbox, Personal Tasks, PRNTCODE Tasks, Shopping and Grocery List, the six Grocery List sections and the four labels all exist under exactly the names in the brief. The skills look them up **by name** on every run (`find-projects`, `find-sections`, `find-labels`). They stop and say so if one is missing, and never create one.

## DoD
| Check | Result |
|---|---|
| 3 groceries in Dairy / Fruit and vegetables / Household after one yes | ✅ The skill text gives one line and one `add-tasks`. **Live API check:** a task in a section (Dairy) and a task with no section were added and read back, then deleted. ⏳ Not yet run as a claude.ai chat. |
| Trousers → `in person`; phone case → both | ✅ Skill rules. **Live:** a Shopping task with `in person`, `online` and `bring to GC` was accepted by name (labels with spaces work), then deleted. ⏳ Chat run pending. |
| "Remind me at 5 to call Sophie" → PRNTCODE Tasks 17:00; personal → Personal Tasks; never Inbox unless asked | ✅ Section 6 "Which project". ⚠ The Sophie test depends on intake seeing Sophie as PRNTCODE: it checks earlier ledger requests that mention her, otherwise it asks `Personal or PRNTCODE?`. Earlier intake examples treated "Call Sophie" as *Personal*, so in the test, say "…call Sophie about the drop" or answer the question. |
| Racket → `bring to GC`; charger to AD → `bring to apt` | ✅ Skill rules. **Live:** `find-tasks` with `labels: ["bring to GC"]` returned exactly the labelled task (the read the carry nudge and "what am I taking to Dubai?" use). |
| Plan with the drive + 2 GC items → one carry line; after "book it" one reminder 60 min before, naming both; none if empty | ✅ Plan steps 4.9b, 5 and 6.5b, re-read at booking, with a duplicate guard. ⏳ Needs the next Thu–Sun plan (Wed 14 Oct, or "plan Thu–Sun" today). |
| Meal plan writes to Todoist Grocery List | ❌ **Not built.** The skill isn't in a repo (below). |
| No project, section or label created or renamed; no Todoist ID in the repo | ✅ `grep` finds no Todoist IDs in the repo. The only Todoist write tools used are `add-tasks`, `add-reminders`, `reschedule-tasks` and `delete-object` on tasks. |
| Rest of intake unchanged | ✅ Sections 1–5 are untouched. Section 6 only changed the project and added optional labels; duplicate checks, recurring reminders and cancel are unchanged. |
| README and version; after sync the skills show the new behaviour | ✅ README and 2.2.0 done. ⏳ Sync happens after merge. |

All test tasks were deleted from Todoist; the build left nothing behind.

## Decisions
- **Return-drive default.** "Default time Saturday 20:00" is read as the **reminder** time when the plan shows no return drive. With a return drive, the reminder is 60 min before it.
- **Carry nudges only come with the Dubai drive.** The return nudge is set in the same plan as the Dubai drive (normally Thu–Sun). A skipped drive means no nudges.
- **Carry-only items** ("take my racket to Dubai") go to Personal Tasks, or PRNTCODE Tasks if they're for the brand, undated.
- **Duplicate list items** are skipped and named in the confirmation, not asked about.
- **Grocery vs shopping** is decided from the item; if it's unclear, the line asks `Groceries or Shopping?`.
- **Timed list items** ("remind me at 5 to buy milk") are reminders (section 6), with labels if any.
- **Live artifact.** Only the local `half-week.html` template learned the "Carry" label. The published "Khaled's half-week" page shows the carry note's text without the label until its next republish.
- **Skill descriptions** were trimmed to ≤ 1024 characters (intake was 1102 before this build).

## Left for a separate brief: weekly-meal-plan → Todoist
`weekly-meal-plan` is an uploaded claude.ai skill (`anthropic-skills:weekly-meal-plan`), not in any repo. `list_repos` finds nothing. Its step 6a still writes to the Apple Reminders "Groceries" list (`reminder_create_v0`). Suggested drop-in replacement for its step 6a, for the next brief:

> ### 6a. Grocery list → Todoist Grocery List
> Look up the project **Grocery List** with `find-projects` and its sections with `find-sections`, **by name**. Never hard-code IDs, and never create a project or section. Then `find-tasks` with that project (`limit: 100`) to see what's already open, and skip any item already open, saying what you skipped.
> **Buy** items: one `add-tasks` call, one task per item, quantity in the title (`Sweet potato x2`), in the section that fits: Fruit and vegetables 🍎 · Bread, cereal and rice 🍞 · Dairy 🥛 · Spices 🌶 · Drinks 💧 · Household 🏠. No section fits → no section. No due date, no labels, no reminders.
> **Check stock** stays chat-only, as now. Never write to Apple Reminders.

Its `compatibility` line also changes to the Todoist tools (`find-projects`, `find-sections`, `find-tasks`, `add-tasks`). The nice-to-have "tag groceries for the home where he'll cook them" would add `bring to apt` to AD-week items.

## Open questions
1. Merge the PR so claude.ai syncs 2.2.0, then run the DoD lines on the phone.
2. Who is Sophie: PRNTCODE or personal? If PRNTCODE, the first time intake asks, answer "PRNTCODE". Later reminders follow from the ledger only if a ledger request mentions her.
