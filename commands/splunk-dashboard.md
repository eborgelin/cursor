---
name: splunk-dashboard
description: Draft a Splunk Dashboard Studio JSON definition and XML envelope from a stated purpose
---

# Draft a Splunk dashboard

Follow `splunk-dashboards` and `splunk-dashboard-design`.

1. Confirm the one question the dashboard answers and the indexes/sourcetypes involved (`splunk_get_indexes`, `splunk_get_metadata`).
2. Validate each panel’s SPL with `splunk_run_query` on a short window.
3. Emit a complete Dashboard Studio JSON definition plus the `version="2"` XML envelope.
4. Use a global time picker, named data sources, and a KPI → trend → table layout.
5. Do not publish the view via REST. Give the user the definition to paste or deploy.
