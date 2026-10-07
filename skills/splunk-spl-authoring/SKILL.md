---
name: splunk-spl-authoring
description: >-
  Write, explain, and optimize Splunk Search Processing Language (SPL) for
  Splunk Cloud and Enterprise. Use when the user wants better SPL, faster
  searches, tstats rewrites, CIM/data-model queries, macro usage, or a
  review of a slow dashboard or scheduled search. Uses Splunk MCP tools
  (including saia_* when Splunk AI Assistant is installed) to generate,
  explain, and validate searches.
---

# SPL authoring and optimization

Produce SPL that is correct, cheap, and safe to run through `splunk_run_query`.

## Prefer MCP over guesswork

1. `splunk_get_indexes` / `splunk_get_index_info` — confirm the index exists and is allowed.
2. `splunk_get_metadata` — real sourcetypes, hosts, sources for the window.
3. `splunk_get_knowledge_objects` — macros, lookups, data models, saved searches to reuse.
4. `saia_generate_spl` — natural language to SPL when the tool exists.
5. `saia_explain_spl` — before changing someone else’s search.
6. `saia_optimize_spl` — performance rewrite when the tool exists.
7. `splunk_run_query` — validate on a tight time range.

If SAIA tools are absent, write the SPL yourself using the rules below and still validate with `splunk_run_query`.

## Cost model

Cheapest to most expensive, prefer the first option that preserves meaning:

1. `tstats` against an accelerated data model or TSIDX
2. Indexed fields + early `index=` / `sourcetype=` / time bounds
3. Streaming commands (`eval`, `rex`, `fields`) after filters
4. Transforming aggregations (`stats`, `timechart`, `chart`)
5. `join`, `append`, `transaction`, map/subsearches, dense `rex`/`spath` on raw events

Impact signal to optimize first: high scan volume, scheduled frequency, or dashboard reuse — not one-off ad hoc searches.

## Rules

- Filter in the first search clause: index, time, sourcetype, host.
- Never start with `search *` or an index-less `...` over all time.
- Replace `join` with `lookup` or a `stats` correlation when keys exist.
- Replace `transaction` with `stats` / `streamstats` unless you truly need duration/maxpause semantics.
- Pull fields with `fields` / `table` only after reduction.
- Use CIM data models when `splunk_get_knowledge_objects` type `data_models` shows a fit.
- Macros: expand mentally (or via objects) before blaming the outer search.

## Rewrite patterns

Raw aggregate:

```spl
index=web sourcetype=nginx:access earliest=-15m latest=now
| stats count by status
```

Time series:

```spl
index=web sourcetype=nginx:access earliest=-4h latest=now
| timechart span=5m count by status
```

tstats (when a model is present):

```spl
| tstats count from datamodel=Web.Web where earliest=-15m latest=now by Web.status
```

Enrichment without join:

```spl
index=auth sourcetype=linux_secure earliest=-15m latest=now
| lookup identity_lookup user OUTPUT department
| stats count by department, action
```

## Validation

Run the original and the rewrite on the **same** time window via `splunk_run_query`. Compare:

- Result meaning (not just row count)
- Whether scope accidentally narrowed (missing index/host)
- Whether the rewrite still finishes under the 1 minute / 1000 event MCP cap

Report:

1. Original SPL and cost drivers
2. Rewritten SPL
3. Semantic risk
4. Validation result
5. What should change in production (saved search, dashboard panel) — do not change it unless asked

## MCP search limits

`splunk_run_query` is the wrong tool for multi-hour raw dumps. For optimization of a heavy scheduled search, validate a **narrower equivalent** (same predicates, shorter latest-earliest) and say that the production job still needs the scheduler, not MCP.
