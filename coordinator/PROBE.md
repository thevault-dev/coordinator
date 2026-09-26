# Coordinator access probe (one-off)

You are running a one-off ACCESS PROBE for Khaled's Coordinator agent. It checks that a scheduled session can read his three calendars and write to the "Coordinator" calendar.

Don't build anything, edit files or push to git. Your only output is one row in the Supabase table `coordinator_runs`, plus a short summary at the end. Record errors word for word.

## Hard safety rules
- The **only** calendar you may write to is the one named exactly **Coordinator**. Never create, edit or delete events on any other calendar.
- If `create_event` can't target a specific calendar ID, don't call it at all. Record that fact instead.

## Steps
1. **Load the tools.** Use ToolSearch with `+Google_Calendar`, then again with `google calendar list create event freebusy`, to load every Google Calendar connector tool. Load the Supabase `execute_sql` tool with `+Supabase execute_sql`. Record each Google Calendar tool's name and parameter names. If a Supabase or Google Calendar tool is missing, say so clearly in your final summary, write what you can, and stop.
2. **List the calendars.** Call `list_calendars`. For every calendar, record its `id`, `summary`, `accessRole` and `primary` flag.
3. **Identify three calendars:**
   - (a) the primary personal calendar
   - (b) **PRNTCODE**: its name contains "PRNTCODE" or its ID ends in `prntcode.com`. It is shared as free/busy only, so its expected accessRole is `freeBusyReader`.
   - (c) **Coordinator**

   Record which of the three were found.
4. **Read test, next 7 days, on each of the three calendars.**
   - Call `list_events` with that calendar's ID.
   - Record success or the exact error, the number of events, and for the first 3 events only: start, end, transparency, and whether a title came back.
   - **For PRNTCODE:** Khaled's instruction is to treat it as busy blocks. If `list_events` fails or returns no times, try every other tool that can return busy time (a free/busy tool, or `suggest_time` covering that calendar) and record exactly what came back. **Don't skip it.** Report clearly whether busy blocks for PRNTCODE could be read by any method.
5. **Write test, Coordinator calendar only.**
   1. Create one event titled `[Coordinator] access test - delete me` on the Coordinator calendar's ID. It starts 7 days from now at 03:00 Asia/Dubai and lasts 15 minutes.
   2. Record the returned event ID and the calendar the event landed on.
   3. Call `get_event` to confirm it exists on the Coordinator calendar.
   4. Delete it with `delete_event`.
   5. Call `get_event` again to confirm it is gone (deleted, cancelled or not found).
6. **Write the result** with `execute_sql` (project_id `hgkreprqxevayruqpibf`):
   ```sql
   insert into public.coordinator_runs (kind, status, summary, detail, finished_at)
   values ('probe', '<ok|error>', '<one-line summary>', '<detail json>'::jsonb, now());
   ```
   - Status is `ok` only if **all three** calendars were read (PRNTCODE as busy blocks) **and** the write and delete test worked. Otherwise it is `error`.
   - The `detail` JSON has these keys: `tools`, `calendars`, `read_tests`, `prntcode_busy_method`, `write_test`, `errors`.
   - Double any single quotes inside it.
   - Keep it under about 20 KB by truncating event lists.
7. **Finish** with a one-paragraph plain summary.
