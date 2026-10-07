---
name: splunk-dashboards
description: >-
  Author Splunk Platform Dashboard Studio dashboards (version 2 JSON
  definitions and the data/ui/views XML wrapper). Use when the user wants a
  Splunk dashboard, SOC or monitoring view, visualization JSON, or to convert
  Simple XML to Dashboard Studio. Not for Splunk Observability Cloud dashboards.
---

# Splunk Dashboard Studio

Generate **Platform** Dashboard Studio (`version="2"`) definitions. Preview panel SPL with `splunk_run_query` before embedding it. Discover existing views with `splunk_get_knowledge_objects` type `views` or `panels`.

This skill does not publish dashboards. MCP has no create-view tool. Hand the JSON/XML to the user to paste in Dashboard Studio or deploy via their app.

## Output

Always produce:

1. The JSON definition (`dataSources`, `visualizations`, `inputs`, `defaults`, `layout`)
2. The XML envelope for `data/ui/views`

```xml
<dashboard version="2" theme="dark">
  <label>My Dashboard</label>
  <description>Optional description</description>
  <definition><![CDATA[
    { ... JSON definition ... }
  ]]></definition>
</dashboard>
```

`theme` is `light` or `dark`. JSON goes inside CDATA.

## Definition skeleton

```json
{
  "title": "My Dashboard",
  "description": "",
  "dataSources": {},
  "visualizations": {},
  "inputs": {},
  "defaults": {
    "dataSources": {
      "ds.search": {
        "options": {
          "queryParameters": {
            "earliest": "$global_time.earliest$",
            "latest": "$global_time.latest$"
          }
        }
      }
    }
  },
  "layout": {
    "type": "grid",
    "options": {},
    "structure": [],
    "globalInputs": ["input_global_time"]
  }
}
```

## Data sources

Every `ds.search` **must** include `name` (shown in the UI).

```json
"ds_errors": {
  "type": "ds.search",
  "name": "Errors by host",
  "options": {
    "query": "index=app sourcetype=app:log error | stats count by host",
    "queryParameters": {
      "earliest": "$global_time.earliest$",
      "latest": "$global_time.latest$"
    }
  }
}
```

| Type | Use |
| --- | --- |
| `ds.search` | SPL. Required: `name`, `query` |
| `ds.chain` | Post-process a parent via `extend` + `query` |
| `ds.savedSearch` | `options.ref` = saved search name |
| `ds.test` | Mock columns for layout prototyping |

Reuse one base search plus chains instead of N nearly identical panel searches.

## Visualizations

```json
"viz_errors": {
  "type": "splunk.table",
  "title": "Errors by host",
  "dataSources": { "primary": "ds_errors" },
  "options": {}
}
```

Common types: `splunk.table`, `splunk.singlevalue`, `splunk.singlevalueicon`, `splunk.line`, `splunk.area`, `splunk.column`, `splunk.bar`, `splunk.pie`, `splunk.markdown`, `splunk.events`.

Markdown visualizations do **not** support pipe tables. Single values need a search that returns one row; use `majorValue` / `trendValue` only when the search provides those series.

Default chart palette: `#7B56DB`, `#009CEB`, `#00CDAF`, `#DD9900`, `#FF677B`.

## Inputs

Include a global time picker:

```json
"input_global_time": {
  "type": "input.timerange",
  "title": "Time range",
  "options": {
    "defaultValue": "-24h,now",
    "token": "global_time"
  }
}
```

Dropdowns use `input.dropdown` with `token` and either static `items` or a data source. Reference tokens as `$token$` in SPL.

## Layout

Grid positions are in pixels. Keep 20px gutters. Typical canvas ~1440×960.

```json
"layout": {
  "type": "grid",
  "options": { "width": 1440 },
  "structure": [
    { "item": "viz_kpi", "position": { "x": 0, "y": 0, "w": 360, "h": 160 } },
    { "item": "viz_trend", "position": { "x": 360, "y": 0, "w": 1080, "h": 400 } }
  ],
  "globalInputs": ["input_global_time"]
}
```

Use `absolute` layout only when overlapping or pixel-perfect placement is required.

## SPL in panels

- Bound every query with index + time tokens.
- Aggregate so MCP validation (`splunk_run_query`) and the dashboard stay cheap.
- Name data sources after the question they answer (`Failed logins by src`), not `Search_1`.

## Workflow

```text
- [ ] Confirm indexes/sourcetypes via MCP metadata
- [ ] Validate each panel SPL with splunk_run_query
- [ ] Emit JSON + XML envelope
- [ ] List viz ids, tokens, and SPL for review
```
