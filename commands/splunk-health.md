---
name: splunk-health
description: Report Splunk instance status, indexes, and the current user's MCP permissions
---

# Splunk health

Call, in order:

1. `splunk_get_info`
2. `splunk_get_user_info`
3. `splunk_get_indexes`
4. Optional: `splunk_get_kv_store_collections` if KV Store size is relevant
5. Optional: a cheap `| tstats count where index=_internal earliest=-15m` or `index=_internal | stats count` via `splunk_run_query` to show recent searchability

Summarize version, user/roles, index count, and any indexes that look empty or full. Do not print the encrypted token or full user authentication details.
