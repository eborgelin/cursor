---
name: splunk-search
description: >-
  Run Splunk searches through the Splunk MCP Server. Use when the user asks to
  search logs, run SPL, look up indexes, sourcetypes, hosts, or events, generate
  SPL from natural language, explain a search, or pull results from Splunk Cloud
  or Splunk Enterprise. Prefer this skill over curl or REST whenever the Splunk
  MCP plugin is connected.
---

# Splunk search via MCP

Use the `splunk` MCP server. Never substitute REST calls, `curl`, or plaintext tokens.

## Tool map

| Goal | Tool |
| --- | --- |
| Run SPL | `splunk_run_query` |
| Run an existing report/alert | `splunk_run_saved_search` (beta, MCP Server 1.1+) |
| Generate SPL from English | `saia_generate_spl` (needs Splunk AI Assistant) |
| Explain SPL | `saia_explain_spl` |
| Optimize SPL | `saia_optimize_spl` |
| Splunk product questions | `saia_ask_splunk_question` |
| Instance health | `splunk_get_info` |
| List indexes | `splunk_get_indexes` |
| One index | `splunk_get_index_info` |
| Hosts / sources / sourcetypes | `splunk_get_metadata` |
| Saved searches, macros, lookups, views | `splunk_get_knowledge_objects` |
| Who am I | `splunk_get_user_info` |

If a tool is missing, it is disabled on the server or the optional app is not installed. Say that and continue with what remains.

## Procedure

Copy this checklist and tick it off:

```text
- [ ] Confirm MCP tools are available
- [ ] Orient: info + indexes
- [ ] Scope: metadata for the time window
- [ ] Reuse: saved searches / macros / data models
- [ ] Author SPL (SAIA if present)
- [ ] Run a bounded search
- [ ] Summarize results, not raw dumps
```

### 1. Orient

Call `splunk_get_info`, then `splunk_get_indexes`. If the user named an index, follow with `splunk_get_index_info`.

### 2. Scope the data

Call `splunk_get_metadata` for the relevant indexes and time window. Use the returned hosts, sources, and sourcetypes in the SPL instead of guessing.

### 3. Reuse knowledge objects

Call `splunk_get_knowledge_objects` with the type you need:

- `saved_searches` — prefer these over new SPL
- `macros`, `lookups`, `lookup_transforms`
- `data_models` — use with `tstats` when the model fits
- `field_extractions`, `tags`
- `alerts`, `views`, `panels`

Supported types also include `field_aliases`, `calculated_fields`, `automatic_lookups`, `workflow_actions`, `apps`, `mltk_models`, and `mltk_algorithms`.

When `splunk_run_saved_search` is available and a named saved search matches the question:

- Pass `saved_search_name`
- Optionally pass token `args` as `key="value"` pairs (no pipes, brackets, backticks, semicolons, or newlines)
- Optionally override `earliest_time` / `latest_time`
- Do not run disabled saved searches; the server blocks them

### 4. Author SPL

If `saia_generate_spl` exists, use it with the index/sourcetype context from step 2. Otherwise write conservative SPL:

```spl
index=<index> sourcetype=<sourcetype> earliest=-15m latest=now
| <cheap filter>
| stats count by <field>
```

Rules of thumb:

- Put `index`, time, and sourcetype first.
- Reduce with `stats`, `timechart`, `tstats`, `top`, or `head` before `table` or raw events.
- Avoid `join`, `transaction`, and unbounded `search *`.
- Keep the job under 1 minute and 1000 events — that is a server guardrail, not a suggestion.

### 5. Run and report

Call `splunk_run_query` with the SPL. If it fails:

| Failure | What to do |
| --- | --- |
| Unsafe / destructive command | Rewrite without mutating commands |
| Timeout (> 1 minute) | Narrow time range, add index/sourcetype, switch to `tstats` or `head` |
| > 1000 events | Aggregate or `head` |
| Unknown field / no results | Re-check metadata and sample a few events with `| head 20` |
| Permission error | Report the role limitation from `splunk_get_user_info` |

Summarize: time window, SPL used, row count, and the answer. Show a small results table, not the entire payload.

## SPL patterns

Volume by sourcetype:

```spl
index=_internal earliest=-15m latest=now
| stats count by sourcetype
| sort -count
```

Error rate over time:

```spl
index=<app> sourcetype=<st> (error OR fail* OR exception) earliest=-60m latest=now
| timechart span=5m count
```

High-cardinality tstats (when a data model exists):

```spl
| tstats count from datamodel=<model> where earliest=-15m latest=now by sourcetype
```
