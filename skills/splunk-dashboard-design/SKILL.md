---
name: splunk-dashboard-design
description: >-
  Visual design for Splunk dashboards: layout, chart choice, color, KPI
  hierarchy, and operational vs executive vs investigation layouts. Use when
  the user wants a dashboard to look professional, pick chart types, organize
  panels, or apply a monitoring / SOC / executive template. Works with
  Dashboard Studio and Simple XML.
---

# Splunk dashboard design

Pair this with `splunk-dashboards` for correct JSON. This skill is how the dashboard should look and read.

## Principles

1. **One question per dashboard.** Executive: “Are we healthy?” Ops: “What is happening now?” Investigation: “What caused this?” Capacity: “How are we trending?”
2. **Overview then detail.** Top row = KPIs. Second = trends. Below = tables and drilldown.
3. **Consistent grid.** 20px margin and gutters. Do not mix random panel widths.

## Layout templates

Recommended canvas: 1440 × 960, absolute or tight grid.

```text
y=20   inputs (h=40)
y=80   four KPIs (h=160)
y=260  primary chart + supporting table (h=340)
y=620  detail / secondary (h=300)
```

**Executive:** 4 single values, 1 trend, 1 small table of exceptions.
**Operations:** live timechart, top talkers table, error breakdown pie/column.
**Investigation:** time range + entity dropdown, timeline, events table, related hosts.

## Chart choice

| Question | Viz |
| --- | --- |
| Is this number OK right now? | `splunk.singlevalue` (with trend if a sparkline exists) |
| How did it change? | `splunk.line` or `splunk.area` |
| Compare categories | `splunk.column` / `splunk.bar` |
| Share of total (few slices) | `splunk.pie` (max ~6 slices; otherwise bar) |
| Exact values, many fields | `splunk.table` |
| Narrative / runbook | `splunk.markdown` |

Do not use a pie for time series or for more than a handful of categories.

## Color

Dark operational theme (preferred for SOC / NOC):

- Canvas `#0F1117` / panel `#1E2128`
- OK `#00CDAF`, warn `#DD9900`, critical `#FF677B`, info `#009CEB`, accent `#7B56DB`

Light executive theme:

- Canvas `#F5F7FA` / panel `#FFFFFF`
- Same semantic colors, slightly darker text

Encode meaning with color, not decoration. Status fields (`allowed`/`blocked`, `2xx`/`5xx`) should use `seriesColorsByField` so they stay stable across refreshes.

## Density

- At most 8–10 panels on one view. Split the rest into linked dashboards.
- Tables: 10–20 rows, not hundreds. Rank with `head` / `top`.
- Titles state the insight (“5xx rate, 15m”) not the viz type (“Line chart 1”).
- Every KPI needs a unit and a comparison (vs prior period or threshold).

## Accessibility

- Do not rely on red/green alone; include the numeric value.
- Legend on, axis titles on for charts that are not self-explanatory.
- Markdown panels: short sentences, no pipe tables (Studio limitation).
