# BUILD REPORT: Coordinator v1 — 2026-09-26

## Status
BLOCKED at STEP 0. The Coordinator can't write to Google Calendar from where it runs yet. Nothing was built, per the brief. Khaled needs to choose one of the options below.

## Where it lives
- Repo: `thevault-dev/coordinator`, branch `main`. Only this report was added. There is no skill and no new migration yet.
- Daily run: not scheduled yet. The plan is a Claude Routine that starts a fresh cloud session each morning at about 07:00 Abu Dhabi time. Khaled gets a push notification and replies `approve …` in that session.
- Calendar access: today only a **read-only search of the primary calendar** works (details below). No Google sign-in has been approved yet.

## What was found (STEP 0)
| Check | Result |
|---|---|
| Google Calendar connector (claude.ai) | Connected to Khaled's personal account (`k.a.muhairi@gmail.com`). Its tools include `list_calendars`, `list_events`, `get_event`, `create_event` and `delete_event`, but **only `search_events` is switched on for this session**. |
| `search_events` | Works. It returned real events from the primary calendar. It is keyword search on one calendar only, so it can't give reliable busy time across three calendars. |
| Direct Google Calendar API from the cloud container | Reachable: `www.googleapis.com` answers `401 Unauthorized`, which means it wants credentials and is not blocked by the network. No credentials exist yet. |
| Supabase ledger | Works through the Supabase connector (the direct REST API is blocked from the container, as found in the last build). |
| Creating the "Coordinator" calendar | The connector lists no "create calendar" tool, so it most likely **can't create a calendar**. With Option 1, Khaled creates it once by hand. |

## Options

**Option 1: switch on the connector's calendar tools (recommended; about 5 minutes, no code or keys).**
1. At claude.ai → Settings → Connectors → Google Calendar, set these tools to *Allowed*: `list_calendars`, `list_events`, `get_event`, `create_event`, `delete_event`.
2. In Google Calendar, create a calendar named **Coordinator** on the personal account.
3. Make sure the PRNTCODE calendar is shared with the personal account, at least for free/busy, so the connector can see it. If it lives on `holla@prntcode.com`, this is the sharing step Khaled does himself.

The limit: "only ever write to the Coordinator calendar" is enforced by the skill's own rules. The connector itself could write to any calendar.

**Option 2: own Google API credentials (strongest lock-down, more setup).**
- Khaled creates a Google Cloud OAuth client and signs in once. This yields a refresh token, which he stores as environment variables (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REFRESH_TOKEN`) in the cloud environment's settings, never in chat.
- It uses the `calendar.app.created` scope plus the free/busy scope. With that scope, **Google itself** refuses writes to any calendar the Coordinator didn't create, and the Coordinator can create its own calendar.
- Downsides:
  - It takes about 20–30 minutes of Google Cloud console setup.
  - The OAuth app must be set to "In production", or Google expires the token every 7 days.
  - It adds one more secret to look after.

**Option 3: hybrid.** Reads go through the connector (Option 1, read tools only) and writes use Option 2's locked-down credentials. This gives the best safety, but it is the most setup.

## What was built
Nothing, by design: the brief says to stop at STEP 0 rather than build around a missing write path.

## Definition of Done results
- STEP 0 resolved, read + write working: **FAIL.** Only read-only `search_events` is available (see above).
- All other items: **NOT STARTED.**

## Deviations from the brief
None.

## Decisions made on Khaled's behalf
None yet. The proposed schedule (daily at about 07:00 Abu Dhabi, fresh session each run, push notification) is a suggestion to confirm.

## Open questions / risks
- **Which option?** Option 1 is the fastest route to a working v1.
- **The PRNTCODE calendar.** Which account owns it, and is it visible from the personal account?
- **Scheduled runs need connectors granted explicitly.** Each morning's session needs the Google Calendar and Supabase connectors granted to the Routine.
- **Free-plan pausing.** The Supabase `coordinator` project is on the Free plan and pauses after about a week idle. Once the daily run is live, that run keeps it active.

## Suggested next build
Re-run Coordinator v1 once Option 1 (or 2) is in place. The rest of the brief can then be built in one session.
