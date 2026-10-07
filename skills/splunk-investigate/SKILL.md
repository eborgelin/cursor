---
name: splunk-investigate
description: >-
  Investigate production incidents, errors, latency, security events, or
  outages using Splunk MCP. Use when the user reports an incident, asks why
  something broke, wants a timeline, blast radius, or root-cause hypothesis
  from logs in Splunk.
---

# Splunk incident investigation

Investigate with the `splunk` MCP server. Stay read-only. Do not enable acceleration, edit saved searches, or write lookups unless the user explicitly asks.

## Inputs to collect (or infer)

- Symptom and when it started (UTC if possible)
- Service, host, index, sourcetype, or correlation ID if known
- User-visible impact

If the time window is unknown, start with the last 15–60 minutes, then widen.

## Playbook

```text
Investigation
- [ ] Confirm instance + identity
- [ ] Identify candidate indexes / sourcetypes
- [ ] Build a timeline
- [ ] Isolate the entity (host, user, cid, request id)
- [ ] Compare against baseline
- [ ] State blast radius and likely cause
- [ ] Suggest next SPL or a saved search to watch
```

### 1. Confirm access

- `splunk_get_info` — version and status
- `splunk_get_user_info` — roles (explains empty results)
- `splunk_get_indexes` — where data could live

### 2. Find the data

Use `splunk_get_metadata` on likely indexes for the incident window. Map the symptom to sourcetypes and hosts from that output, not from memory.

Reuse existing content with `splunk_get_knowledge_objects`:

- `saved_searches` and `alerts` that already encode the team’s view of this service
- `macros` and `lookups` for enrichment
- `data_models` (CIM) for `tstats`

Run matching saved searches with `splunk_run_saved_search` when that beta tool is enabled.

### 3. Timeline

Run a cheap volume search first:

```spl
index=<idx> sourcetype=<st> earliest=-60m latest=now
| timechart span=1m count
```

Then error-class events:

```spl
index=<idx> sourcetype=<st> (error OR fatal OR exception OR 5??) earliest=-60m latest=now
| timechart span=1m count
```

Look for the first inflection, not the loudest minute.

### 4. Isolate

Pick one correlation key (host, `sid`, `trace_id`, user, `status`). Sample a few events (`| head 20`) to learn field names, then aggregate:

```spl
index=<idx> sourcetype=<st> earliest=<start> latest=<end>
| stats count min(_time) as first max(_time) as last by <entity>
| sort -count
```

### 5. Baseline

Compare the incident window to the previous equivalent window (for example last hour vs the hour before, or week-over-week). Report both counts. Do not claim a regression from a single window.

### 6. Report

Return, in order:

1. **What happened** — one paragraph
2. **When** — start, peak, current state
3. **Where** — indexes, hosts, sourcetypes
4. **Evidence** — SPL plus a short table
5. **Blast radius** — entities touched
6. **Likely cause** — hypothesis, labeled as such
7. **Follow-ups** — next search, alert, or dashboard panel

Redact secrets, tokens, passwords, and raw PII. Keep identifiers that the operator needs (host, status, error code).

## Guardrails

- `splunk_run_query` may reject destructive SPL, jobs over 1 minute, or more than 1000 events. Narrow before you retry.
- Do not run `| delete` or write commands during an investigation.
- If MCP tools 401/403, stop and report auth/role failure instead of inventing REST workarounds.
