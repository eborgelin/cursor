---
name: splunk-search
description: Run a bounded Splunk search through MCP and summarize the results
---

# Search Splunk

Run a read-only search against the connected Splunk MCP server.

1. If the user did not provide SPL, indexes, or a time range, call `splunk_get_indexes` and `splunk_get_metadata` first, then draft SPL (use `saia_generate_spl` when available).
2. Default time range: last 15 minutes. Ask before searching all time.
3. Prefer `splunk_run_saved_search` when a named saved search already answers the question.
4. Otherwise call `splunk_run_query` with index + time + aggregation so the job stays under 1 minute and 1000 events.
5. Reply with the SPL, time window, row count, and a compact table. Do not paste secrets or full raw events.
