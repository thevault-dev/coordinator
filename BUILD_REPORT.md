# BUILD REPORT: Coordinator Ledger — 2026-09-26

## Status
DONE — both tables are live in a new Supabase project, every Definition of Done check passes, and the security advisor reports no findings.

## Where it lives
- Repo: `thevault-dev/coordinator`, branch `claude/coordinator-ledger-ubez2p`. The ledger commit is `738f884`, and this report is committed on top of it. The repo was empty, so there is no `main` branch yet and no PR has been opened.
- Supabase project: `coordinator` (ref `hgkreprqxevayruqpibf`, eu-central-1, thevault-dev org, Free plan)
- Migration files:
  - `supabase/migrations/20260926092126_create_ledger.sql`, which creates the `requests` and `rules` tables
  - `supabase/migrations/20260926092131_digest_view.sql`, which creates the `this_week_proposed` view
  - The file names match the versions recorded in Supabase's migration history.

## What was built
- **`requests` table** with every field in the brief (domain-agent half, Coordinator half, and `created_at`/`updated_at`).
  - Allowed values are enforced for `source_agent` (`personal`/`prntcode`), `flexibility` (`fixed`/`flexible`/`anytime`), `priority` (1–5) and `status` (`new`/`proposed`/`scheduled`/`done`/`declined`/`bumped`).
  - A unique constraint `requests_source_unique` covers (`source_agent`, `source_ref`).
  - Extra sanity checks: `duration_min` must be 1–1440, `title`/`source_ref` can't be blank, `due_by` must be after `earliest_start`, and `slot_end` must be after `slot_start`.
  - Lifecycle checks: `proposed`/`scheduled` need `slot_start` and `slot_end`, and `declined`/`bumped` need a non-empty `decision_note`.
  - An index on (`status`, `slot_start`) supports the Coordinator's and the digest's lookups.
- **`rules` table** with `id`, `owner_agent` (`personal`/`prntcode`/`coordinator`), `rule`, `kind` (`hard`/`soft`), `active`, plus `created_at`/`updated_at`.
- **Trigger `set_updated_at()`** runs on both tables and refreshes `updated_at` on every edit. It uses a pinned `search_path`, which the advisor requires.
- **Lockdown.**
  - Row-level security is on for both tables.
  - Every privilege is revoked from `anon` and `authenticated`.
  - An explicit deny-all policy for those roles is on each table.
  - Only `service_role` (the agents' key) can read or write.
- **Nice-to-have: `this_week_proposed` view.** It lists `proposed` requests whose slot starts this week (Monday–Sunday, Abu Dhabi time), with `*_local` columns converted to Asia/Dubai. It is `security_invoker`, so it can't be used to bypass the lockdown, and it is revoked from the public roles.
- **Nice-to-have: `supabase/seed.sql`.** It inserts two example requests and one rule, and is safe to re-run.
- **`supabase/tests/definition_of_done.sql`** re-runs all the checks below. It rolls back, so it leaves no data behind.
- **`README.md`** is a plain-language guide to the ledger.

## Definition of Done results
- [x] **Migration committed: PASS.** Both files are in `supabase/migrations/`, commit `738f884`.
- [x] **Applied to Supabase with all fields: PASS.** `list_migrations` shows `20260926092126 create_ledger` and `20260926092131 digest_view`, and `list_tables` shows every field in the brief on both tables.
- [x] **`status = 'banana'` fails: PASS.** Supabase returned `ERROR: 23514: new row for relation "requests" violates check constraint "requests_status_check"`.
- [x] **Same `source_agent` + `source_ref` twice leaves one row: PASS.** Posting `prntcode`/`dod-test-dup` twice as an upsert left `count = 1`, with the title updated from "v1" to "v2". A plain duplicate insert is refused with `23505: duplicate key value violates unique constraint "requests_source_unique"`.
- [x] **`updated_at` changes on edit: PASS.** A row created at `09:21:49.549` showed `updated_at = 09:21:55.445` after an edit (`updated_at_moved = true`). The same check passes on `rules` in the test script.
- [x] **RLS on, anon key can't read: PASS.**
  - `relrowsecurity = true` on both tables.
  - Running as the `anon` role, the database role an anon-key API request uses, `select` on `requests` and `rules` returned `42501: permission denied for table requests` and `42501: permission denied for table rules`.
  - The `authenticated` role on the view returned `permission denied for view this_week_proposed`.
  - `service_role` can still read and write.
- [x] **README explains the ledger, who writes what, and the lifecycle: PASS.** See `README.md`.
- [x] **Advisor shows no security warnings: PASS.** `get_advisors(security)` returned `{"lints": []}`. The performance advisor's only item is INFO "unused index", which is expected on an empty table.
- Seed data was run once to test the view. The view showed the example slot `06:00 UTC` as `10:00` Abu Dhabi time, as expected. The example rows were then **deleted**, so the live ledger starts empty.

## Deviations from the brief
- **Anon test ran inside the database, not over the internet.** This build environment's network policy blocks outgoing calls to `*.supabase.co`, so I couldn't call the REST API with the anon key. Instead I switched to the `anon` role inside the database, which is what the API does for an anon-key request, and got `permission denied`. To see it over HTTP yourself, open `https://hgkreprqxevayruqpibf.supabase.co/rest/v1/requests` with the anon key. It should return a 401/permission-denied error, never data.
- **Added fields and rules beyond the brief.**
  - `rules` also has `created_at`/`updated_at`.
  - `requests` has the extra checks listed under "What was built" (slot required for proposed/scheduled, note required for declined/bumped, and so on).
  - All of these make the brief's intent enforceable. None of them remove anything.

## Decisions made on Khaled's behalf
- **A new Supabase project was created, with Khaled's approval.** The only existing project, PRNTCODE-ops, holds live business data, and the ledger carries personal items. The new project is `coordinator` in eu-central-1, the same region as PRNTCODE-ops.
- **Priority 1 is the most important** and 5 the least.
- **Defaults:** `status = 'new'`, `flexibility = 'flexible'`, `priority = 3`, `kind = 'soft'`, `active = true`.
- **`source_ref` is required.** A request with no Notion page still needs a stable ID of its own. Without one, duplicates couldn't be detected.
- **`rules.owner_agent`** can also be `coordinator`, for rules the Coordinator sets itself.
- **Allowed values are check constraints on text columns**, not Postgres enum types, because check constraints are easier to extend later with a one-line migration.
- **The database only checks that `status` is a known value.** It does not police which status can follow which (e.g. `done` → `new` is allowed), so the Coordinator's future logic isn't boxed in. The rules it does enforce are slots for `proposed`/`scheduled` and a note for `declined`/`bumped`.
- **"This week" in the view** means Monday 00:00 to Sunday 24:00, Abu Dhabi time.
- **`duration_min` is capped at 1440** (one day).
- **The tables live in the `public` schema** of the new project, which is the simplest option for the Supabase client libraries.

## Open questions / risks
- **The service key is shared.** All three agents use the same service key, so the database can't stop a domain agent from writing the Coordinator's half, or the reverse. The split is by convention, as documented in the README. If that matters later, give each agent its own database role, with column-level grants.
- **Re-posting a request that is already scheduled.** The upsert updates the top half but leaves `status`/`slot_*` untouched. The Coordinator needs to spot these changes, for example by comparing `updated_at` to when it last decided, and decide whether to re-plan. Domain agents must upsert only top-half fields.
- **Free-plan pausing.** Supabase pauses Free-plan projects after about a week without activity. Until the agents are running daily, the project may pause and need restoring from the dashboard. Upgrading avoids this but costs money, so it is Khaled's call.
- **Agents need the secret key.** They need the service-role (secret) key from Supabase Dashboard → Project Settings → API keys. It was not generated or stored anywhere by this build. Keep it out of any client-side app.
- **No path onto `main`.** The branch hasn't been merged, and the repo has no `main` branch yet. Merge it or open a PR so future builds start from it.
- **`done` isn't set by anyone.** Nothing marks a request `done` automatically. The Coordinator (or a nightly job) should do it after `slot_end` passes.

## Suggested next build
Coordinator v1: read `new` requests and active `rules`, propose slots against the calendar, and write back `proposed` + `slot_*` + `decision_note`.
