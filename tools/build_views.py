#!/usr/bin/env python3
"""Build the eight Dashboard Studio views of lkab_kiruna_demo.

Writes lkab_kiruna_demo/default/data/ui/views/<id>.xml. Development tool only;
it is not part of the app package. Re-run after editing, then commit the XML.
"""

import csv
import json
import os
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "lkab_kiruna_demo")
VIEWS = os.path.join(APP, "default", "data", "ui", "views")
APP_ID = "lkab_kiruna_demo"

CANVAS, PANEL, STROKE = "#1A1C20", "#1E2128", "#3D4456"
OK, WARN, CRIT, UNKNOWN, INFO = "#65A637", "#F5A623", "#D93F3C", "#8B90A0", "#5C9BD6"
W = 1440

STATUS_COLORS = [{"to": 0.5, "value": UNKNOWN}, {"from": 0.5, "to": 1.5, "value": OK},
                 {"from": 1.5, "to": 2.5, "value": WARN}, {"from": 2.5, "value": CRIT}]
ROW_COLORS = [{"to": 1.5, "value": "#5A2A2A"}, {"from": 1.5, "to": 2.5, "value": "#5A4A22"},
              {"from": 2.5, "value": PANEL}]
SCORE_COLORS = [{"to": 50, "value": CRIT}, {"from": 50, "to": 80, "value": WARN}, {"from": 80, "value": OK}]
PCT_COLORS = [{"to": 80, "value": CRIT}, {"from": 80, "to": 95, "value": WARN}, {"from": 95, "value": OK}]


def load_csv(name):
    with open(os.path.join(APP, "lookups", name), encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


ASSETS = load_csv("kiruna_assets.csv")
LEVELS = load_csv("kiruna_levels.csv")


class View(object):
    def __init__(self, view_id, title, description, time_default):
        self.id, self.title, self.description = view_id, title, description
        self.ds, self.viz, self.inputs = {}, {}, {}
        self.global_inputs = ["input_global_trp"]
        self.inputs["input_global_trp"] = {"type": "input.timerange", "title": "Time range",
                                           "options": {"token": "global_time", "defaultValue": time_default}}
        self.tabs = []

    def search(self, ds_id, name, query, live=False):
        opts = {"query": query}
        if live:
            opts.update(refresh="60s", refreshType="delay")
        self.ds[ds_id] = {"type": "ds.search", "name": name, "options": opts}
        return ds_id

    def chain(self, ds_id, name, extend, query):
        self.ds[ds_id] = {"type": "ds.chain", "name": name, "options": {"extend": extend, "query": query}}
        return ds_id

    def add(self, viz_id, spec):
        self.viz[viz_id] = spec
        return viz_id

    def tab(self, label, items, height):
        self.tabs.append((label, items, height))

    def definition(self):
        layout_defs, tab_items = {}, []
        for i, (label, items, height) in enumerate(self.tabs):
            lid = "layout_%d" % (i + 1)
            layout_defs[lid] = {
                "type": "absolute",
                "options": {"width": W, "height": height, "display": "auto-scale", "backgroundColor": CANVAS},
                "structure": [{"item": v, "type": "block", "position": {"x": x, "y": y, "w": w, "h": h}}
                              for (v, x, y, w, h) in items],
            }
            tab_items.append({"label": label, "layoutId": lid})
        placed = set(v for _, items, _ in self.tabs for (v, _, _, _, _) in items)
        missing = set(self.viz) - placed
        if missing:
            raise SystemExit("%s: visualizations not in a layout: %s" % (self.id, sorted(missing)))
        return {
            "title": self.title,
            "description": self.description,
            "dataSources": self.ds,
            "visualizations": self.viz,
            "inputs": self.inputs,
            "defaults": {"dataSources": {"ds.search": {"options": {"queryParameters": {
                "earliest": "$global_time.earliest$", "latest": "$global_time.latest$"}}}}},
            "layout": {"globalInputs": self.global_inputs, "layoutDefinitions": layout_defs,
                       "tabs": {"items": tab_items, "options": {"showTabBar": len(tab_items) > 1}}},
            "applicationProperties": {"theme": "dark"},
        }

    def write(self):
        body = json.dumps(self.definition(), indent=2, ensure_ascii=False)
        for bad in ("]]>", "\u2014", "\u2192", "\u00b7"):
            if bad in body:
                raise SystemExit("%s: forbidden sequence %r in definition" % (self.id, bad))
        xml = ('<dashboard version="2" theme="dark">\n  <label>%s</label>\n  <description>%s</description>\n'
               '  <definition><![CDATA[\n%s\n]]></definition>\n</dashboard>\n') % (self.title, self.description, body)
        with open(os.path.join(VIEWS, self.id + ".xml"), "w", encoding="utf-8") as fh:
            fh.write(xml)


# ------------------------------------------------------------------ viz helpers

def md(text, size=None):
    opts = {"markdown": text, "fontColor": "#E1E6EB"}
    if size:
        opts["fontSize"] = size
    return {"type": "splunk.markdown", "options": opts}


def rect():
    return {"type": "splunk.rectangle", "options": {"fillColor": PANEL, "strokeColor": STROKE, "cornerRadius": 6}}


def single(title, ds, value_field, color_field=None, colors=None, unit=None, under=None, sparkline_field=None):
    opts = {"majorValue": '> primary | seriesByName("%s") | lastPoint()' % value_field, "backgroundColor": PANEL}
    ctx = {}
    if color_field:
        opts["majorColor"] = '> primary | seriesByName("%s") | lastPoint() | rangeValue(bandColors)' % color_field
        ctx["bandColors"] = colors
    if unit:
        opts.update(unit=unit, unitPosition="after")
    if under:
        opts["underLabel"] = under
    if sparkline_field:
        opts["sparklineValues"] = '> primary | seriesByName("%s")' % sparkline_field
        opts["sparklineDisplay"] = "below"
    spec = {"type": "splunk.singlevalue", "title": title, "dataSources": {"primary": ds}, "options": opts}
    if ctx:
        spec["context"] = ctx
    return spec


def radial(title, ds, value_field, max_value, under):
    return {"type": "splunk.singlevalueradial", "title": title, "dataSources": {"primary": ds},
            "options": {"majorValue": '> primary | seriesByName("%s") | lastPoint()' % value_field,
                        "maxValue": max_value, "underLabel": under, "backgroundColor": PANEL,
                        "majorColor": '> majorValue | rangeValue(pctColors)',
                        "radialStrokeColor": '> majorValue | rangeValue(pctColors)'},
            "context": {"pctColors": PCT_COLORS}}


def table(title, ds, link=None, set_token=None, count=10):
    spec = {"type": "splunk.table", "title": title, "dataSources": {"primary": ds},
            "options": {"count": count, "showInternalFields": False, "backgroundColor": PANEL,
                        "tableFormat": {"rowBackgroundColors":
                                        '> table | seriesByName("_color_rank") | rangeValue(rowColors)'}},
            "context": {"rowColors": ROW_COLORS}}
    handlers = []
    if link:
        dash, tokens = link
        handlers.append({"type": "drilldown.linkToDashboard",
                         "options": {"app": APP_ID, "dashboard": dash, "newTab": False, "tokens": tokens}})
    if set_token:
        handlers.append({"type": "drilldown.setToken", "options": {"tokens": set_token}})
    if handlers:
        spec["eventHandlers"] = handlers
    return spec


def chart(kind, title, ds, colors=None, extra=None):
    opts = {"backgroundColor": PANEL, "legendDisplay": "bottom"}
    if colors:
        opts["seriesColorsByField"] = colors
    if extra:
        opts.update(extra)
    return {"type": kind, "title": title, "dataSources": {"primary": ds}, "options": opts}


def asset_dropdown(v, default="KIR-TRK-014"):
    v.inputs["input_asset"] = {
        "type": "input.dropdown", "title": "Asset",
        "options": {"token": "asset_id", "defaultValue": default,
                    "items": [{"label": "%s  %s" % (a["asset_id"], a["label"]), "value": a["asset_id"]}
                              for a in ASSETS]}}
    v.global_inputs.append("input_asset")


def level_dropdown(v, live_only):
    rows = [l for l in LEVELS if l["role"] != "surface" and (l["live"] == "1" or not live_only)]
    v.inputs["input_level"] = {
        "type": "input.dropdown", "title": "Level",
        "options": {"token": "level_m", "defaultValue": "1220",
                    "items": [{"label": l["label"], "value": l["level_m"]} for l in rows]}}
    v.global_inputs.append("input_level")


ILLUSTRATIVE = "Synthetic, illustrative demo data. Scenario clock is time-compressed. Not LKAB production data."


def header(v, question):
    v.add("viz_header", md("## %s\n%s  \n%s" % (v.title, question, ILLUSTRATIVE)))


def heartbeat(v):
    v.search("ds_heartbeat", "Generator heartbeat age",
             "| inputlookup kiruna_asset_latest\n| stats max(last_seen) as t\n"
             "| eval age_s=if(isnull(t), 99999, round(now()-t)), band=if(age_s<=180, 3, 1)\n"
             "| eval label=if(age_s<=180, \"Alive \".age_s.\" s\", \"Stale \".age_s.\" s\")\n| fields label band",
             live=True)
    return v.add("viz_heartbeat", single("Generator heartbeat", "ds_heartbeat", "label", "band",
                                         [{"to": 2, "value": CRIT}, {"from": 2, "value": OK}],
                                         under="Since last tick. Stale means the generator stopped."))


ALARM_TABLE_SPL = ("| stats earliest(_time) as opened_t latest(_time) as last_t latest(action) as action "
                   "by alarm_id asset_id alarm_code severity\n"
                   "| eval status=if(action=\"open\", \"Open\", \"Closed\"), opened=strftime(opened_t, \"%d %b %H:%M\"), "
                   "closed=if(action=\"open\", \"\", strftime(last_t, \"%H:%M\"))\n"
                   "| eval _color_rank=case(status=\"Open\" AND severity=\"critical\", 1, status=\"Open\" AND "
                   "severity=\"warning\", 2, true(), 3)\n"
                   "| sort 0 _color_rank -opened_t\n"
                   "| table asset_id alarm_code severity status opened closed _color_rank")

# ------------------------------------------------------------------ views


def shift_brief():
    v = View("shift_brief", "Shift Brief", "Is this shift making ore, and is anything stuck?", "-8h,now")
    header(v, "Is this shift making ore, and is anything stuck?")
    heartbeat(v)
    v.search("ds_shift_kpi", "Shift tonnes versus illustrative plan (summary lookup)",
             "| inputlookup kiruna_flow_latest where object_id=\"KIR-HST-01\"\n"
             "| eval elapsed_h=min(8, max(0.01, (now()-shift_start)/3600)), plan_now=round(8000*elapsed_h/8)\n"
             "| eval drawn_pct=round(100*shift_drawn_t/plan_now), hoisted_pct=round(100*shift_hoisted_t/plan_now)\n"
             "| eval drawn_word=case(drawn_pct>=95, \"Healthy\", drawn_pct>=80, \"Warning\", true(), \"Critical\")\n"
             "| eval hoisted_word=case(hoisted_pct>=95, \"Healthy\", hoisted_pct>=80, \"Warning\", true(), \"Critical\")\n"
             "| eval drawn_label=tostring(round(shift_drawn_t), \"commas\").\" of \".tostring(plan_now, \"commas\").\" t \".drawn_word\n"
             "| eval hoisted_label=tostring(round(shift_hoisted_t), \"commas\").\" of \".tostring(plan_now, \"commas\").\" t \".hoisted_word\n"
             "| eval drawn_label=if(producing=0, \"Night idle, no plan\", drawn_label), "
             "hoisted_label=if(producing=0, \"Night idle, no plan\", hoisted_label), "
             "drawn_pct=if(producing=0, 100, drawn_pct), hoisted_pct=if(producing=0, 100, hoisted_pct)\n"
             "| table drawn_label drawn_pct hoisted_label hoisted_pct", live=True)
    v.search("ds_fleet_kpi", "Stuck and fleet counts (summary lookup)",
             "| inputlookup kiruna_asset_latest\n"
             "| stats count(eval(state=\"stuck\" OR state=\"stopped\")) as stuck "
             "count(eval(asset_type=\"truck\")) as trucks "
             "count(eval(asset_type=\"truck\" AND (state=\"running\" OR activity=\"waiting_bay\"))) as in_cycle\n"
             "| eval stuck_label=if(stuck=0, \"0 Healthy\", stuck.\" \".if(stuck>=3, \"Critical\", \"Warning\"))\n"
             "| eval stuck_band=case(stuck=0, 1, stuck<3, 2, true(), 3)\n"
             "| eval cycle_label=in_cycle.\" of \".trucks.\" \".if(in_cycle=trucks, \"Healthy\", \"Warning\"), "
             "cycle_band=if(in_cycle=trucks, 1, 2)\n"
             "| table stuck_label stuck_band cycle_label cycle_band", live=True)
    v.add("viz_kpi_bg", rect())
    v.add("viz_kpi_drawn", single("Tonnes drawn vs plan to now", "ds_shift_kpi", "drawn_label", "drawn_pct",
                                  PCT_COLORS, under="Illustrative plan 8,000 t per shift"))
    v.add("viz_kpi_hoisted", single("Tonnes hoisted vs plan to now", "ds_shift_kpi", "hoisted_label",
                                    "hoisted_pct", PCT_COLORS, under="Main hoist (CA-uppfordring), illustrative"))
    v.add("viz_kpi_stuck", single("Stuck or stopped assets", "ds_fleet_kpi", "stuck_label", "stuck_band",
                                  STATUS_COLORS, under="Demo rule from the generator state"))
    v.add("viz_kpi_cycle", single("Trucks in cycle vs fleet", "ds_fleet_kpi", "cycle_label", "cycle_band",
                                  STATUS_COLORS, under="Running or waiting in a bay"))
    v.search("ds_trend", "Drawn and hoisted tonnes over the shift",
             "`kiruna_flow` (object_type=\"ore_pass\" OR object_id=\"KIR-HST-01\")\n"
             "| timechart span=5m sum(eval(if(object_type=\"ore_pass\", inflow_t, null()))) as drawn_t "
             "sum(eval(if(object_id=\"KIR-HST-01\", hoisted_t, null()))) as hoisted_t", live=True)
    v.add("viz_trend", chart("splunk.line", "Tonnes per 5 minutes: drawn and hoisted (illustrative)", "ds_trend",
                             {"drawn_t": INFO, "hoisted_t": OK}, {"yAxisTitleText": "t per 5 min"}))
    v.search("ds_alarms", "Alarms in the shift", "`kiruna_alarm`\n" + ALARM_TABLE_SPL, live=True)
    v.add("viz_alarms", table("Alarms (click to open Asset Health)", "ds_alarms",
                              link=("asset_health", {"form.asset_id": "$row.asset_id.value|u$"})))
    v.tab("Shift", [("viz_header", 20, 10, 1000, 90), ("viz_heartbeat", 1040, 10, 380, 90),
                    ("viz_kpi_bg", 20, 110, 1400, 180),
                    ("viz_kpi_drawn", 30, 120, 335, 160), ("viz_kpi_hoisted", 375, 120, 335, 160),
                    ("viz_kpi_stuck", 720, 120, 335, 160), ("viz_kpi_cycle", 1065, 120, 345, 160),
                    ("viz_trend", 20, 310, 860, 380), ("viz_alarms", 900, 310, 520, 380)], 720)
    return v


def mine_section():
    v = View("mine_section", "Mine Cross-Section", "Which level is degraded right now?", "-8h,now")
    level_dropdown(v, live_only=False)
    header(v, "Which level is degraded right now? Click a level band, or pick it in the Level input.")
    heartbeat(v)
    with open(os.path.join(APP, "appserver", "static", "images", "kiruna_section.svg"), encoding="utf-8") as fh:
        svg = " ".join(line.strip() for line in fh)
    # The choropleth renderer mangles non-ASCII text (even as character references), so fold it.
    svg = unicodedata.normalize("NFKD", svg).encode("ascii", "ignore").decode("ascii")
    v.search("ds_levels", "Level status (summary lookup)",
             "| inputlookup kiruna_level_status\n| table svg_region_id status_code level_m status", live=True)
    v.add("viz_section", {
        "type": "splunk.choropleth.svg", "title": "Kiirunavaara vertical section (schematic)",
        "dataSources": {"primary": "ds_levels"},
        "options": {"svg": svg, "backgroundColor": PANEL,
                    "areaIds": '> primary | seriesByName("svg_region_id")',
                    "areaValues": '> primary | seriesByName("status_code")',
                    "areaColors": "> areaValues | rangeValue(statusColors)"},
        "context": {"statusColors": STATUS_COLORS},
        "eventHandlers": [{"type": "drilldown.setToken",
                           "options": {"tokens": [{"token": "level_m", "key": "row.level_m.value"}]}}]})
    v.add("viz_legend", md(
        "**Legend.** Grey: historic horizon or no demo fleet. Green: **Healthy**. Amber: **Warning**. "
        "Red: **Critical**.  \nColors are the latest generator state from the summary lookup. "
        "The time range does not filter the map.  \n1045 m is the main level on the teaching poster "
        "(huvudnivå). The poster calls 1365 m kommande huvudnivå; this demo treats 1365 m as the active "
        "main level. 1220 m and 1288 m are demo sublevels, not poster labels."))
    v.search("ds_level_assets", "Assets on the selected level (summary lookup)",
             "| inputlookup kiruna_asset_latest where level_m=$level_m|s$\n"
             "| eval _color_rank=case(status=\"Critical\", 1, status=\"Warning\", 2, true(), 3)\n"
             "| sort 0 _color_rank asset_id\n"
             "| table asset_id label state activity status level_m _color_rank\n"
             "| appendpipe [ stats count | where count=0 | eval label=\"No demo equipment on this horizon.\" "
             "| fields label ]", live=True)
    v.add("viz_level_assets", table("Assets on level $level_m$ m (click to open Asset Health)", "ds_level_assets",
                                    link=("asset_health", {"form.asset_id": "$row.asset_id.value|u$"}), count=12))
    v.tab("Section", [("viz_header", 20, 10, 1000, 90), ("viz_heartbeat", 1040, 10, 380, 90),
                      ("viz_section", 20, 110, 900, 760), ("viz_legend", 940, 110, 480, 190),
                      ("viz_level_assets", 940, 310, 480, 560)], 890)
    return v


def level_ops():
    v = View("level_ops", "Level Operations",
             "On this level, is ore moving from drawpoints into the passes?", "-8h,now")
    level_dropdown(v, live_only=True)
    header(v, "On this level, is ore moving from drawpoints into the passes?")
    v.search("ds_level_base", "Cycles and flows on the level",
             "`kiruna_events` (sourcetype=\"kiruna:cycle\" OR sourcetype=\"kiruna:flow\") level_m=$level_m|s$\n"
             "| fields _time sourcetype asset_type place_id payload_t object_type object_id inflow_t", live=True)
    v.chain("ds_level_tonnes", "Tonnes into passes from this level", "ds_level_base",
            "| where object_type=\"ore_pass\"\n| stats sum(inflow_t) as tonnes\n"
            "| eval tonnes=round(coalesce(tonnes, 0))")
    v.chain("ds_drawpoint_bar", "Tonnes by drawpoint", "ds_level_base",
            "| where sourcetype=\"kiruna:cycle\" AND asset_type=\"lhd\"\n"
            "| stats sum(payload_t) as tonnes by place_id\n| sort - tonnes")
    v.search("ds_level_state", "Asset state on the level (summary lookup)",
             "| inputlookup kiruna_asset_latest where level_m=$level_m|s$\n"
             "| stats count(eval(asset_type=\"lhd\" AND state!=\"stopped\" AND state!=\"down\")) as producing "
             "count(eval(state=\"stuck\" OR state=\"stopped\" OR state=\"down\")) as stopped\n"
             "| eval stopped_band=case(stopped=0, 1, stopped<3, 2, true(), 3)", live=True)
    v.add("viz_kpi_bg", rect())
    v.add("viz_kpi_dp", single("Producing drawpoints", "ds_level_state", "producing",
                               under="LHDs not stopped on this level"))
    v.add("viz_kpi_tonnes", single("Tonnes into passes", "ds_level_tonnes", "tonnes", unit="t",
                                   under="Illustrative, selected time range"))
    v.add("viz_kpi_stopped", single("Stuck or stopped assets", "ds_level_state", "stopped", "stopped_band",
                                    STATUS_COLORS, under="Green Healthy, amber Warning, red Critical"))
    v.add("viz_dp_bar", chart("splunk.bar", "Tonnes by drawpoint (tappställe), illustrative", "ds_drawpoint_bar",
                              extra={"seriesColors": [INFO], "legendDisplay": "off"}))
    v.search("ds_assets", "Assets on the level, drills included (summary lookup)",
             "| inputlookup kiruna_asset_latest where level_m=$level_m|s$\n"
             "| search asset_type IN (\"lhd\", \"truck\", \"drill\", \"crusher\", \"hoist\", \"buffer\")\n"
             "| eval _color_rank=case(status=\"Critical\", 1, status=\"Warning\", 2, true(), 3)\n"
             "| table asset_id label asset_type state activity place_id status _color_rank", live=True)
    v.add("viz_assets", table("Assets (click to open Asset Health)", "ds_assets",
                              link=("asset_health", {"form.asset_id": "$row.asset_id.value|u$"})))
    v.search("ds_passes", "Ore passes starting on this level (flow lookup)",
             "| inputlookup kiruna_flow_latest where object_type=\"ore_pass\" level_m=$level_m|s$\n"
             "| eval status=case(status_code=3, \"Critical\", status_code=2, \"Warning\", true(), \"Healthy\"), "
             "_color_rank=case(status_code=3, 1, status_code=2, 2, true(), 3)\n"
             "| rename object_id as pass_id\n"
             "| table pass_id inflow_tpm level_pct plan_tpm status _color_rank", live=True)
    v.add("viz_passes", table("Ore passes (störtschakt): inflow t/min and fill percent", "ds_passes"))
    v.tab("Level", [("viz_header", 20, 10, 1400, 90), ("viz_kpi_bg", 20, 110, 1400, 180),
                    ("viz_kpi_dp", 30, 120, 455, 160), ("viz_kpi_tonnes", 495, 120, 455, 160),
                    ("viz_kpi_stopped", 960, 120, 450, 160),
                    ("viz_dp_bar", 20, 310, 560, 300), ("viz_passes", 600, 310, 820, 300),
                    ("viz_assets", 20, 630, 1400, 360)], 1010)
    return v


def asset_health():
    v = View("asset_health", "Asset Health", "Is this machine utilized, and why did it alarm?", "-24h,now")
    asset_dropdown(v)
    header(v, "Is this machine utilized, and why did it alarm?")
    v.search("ds_identity", "Asset identity (lookups)",
             "| inputlookup kiruna_asset_latest where asset_id=$asset_id|s$\n"
             "| lookup kiruna_assets asset_id OUTPUT model\n"
             "| eval _color_rank=case(status=\"Critical\", 1, status=\"Warning\", 2, true(), 3)\n"
             "| table asset_id label fleet model asset_type status _color_rank", live=True)
    v.search("ds_place", "Asset place (summary lookup)",
             "| inputlookup kiruna_asset_latest where asset_id=$asset_id|s$\n"
             "| eval _color_rank=case(status=\"Critical\", 1, status=\"Warning\", 2, true(), 3)\n"
             "| table level_m place_id pass_id state activity cause alarm_code _color_rank", live=True)
    v.search("ds_asset_base", "Asset ticks in the time range",
             "`kiruna_asset` asset_id=$asset_id|s$\n"
             "| fields _time asset_id state speed_kmh payload_t tick_s engine_hours odometer_km", live=True)
    v.chain("ds_hours", "Hours by state", "ds_asset_base",
            "| stats sum(eval(if(state=\"running\", tick_s, 0))) as r sum(eval(if(state=\"idle\", tick_s, 0))) as i "
            "sum(eval(if(state=\"stuck\" OR state=\"stopped\", tick_s, 0))) as s "
            "sum(eval(if(state=\"down\", tick_s, 0))) as d latest(engine_hours) as engine_hours "
            "latest(odometer_km) as odometer_km\n"
            "| eval running_h=round(r/3600, 1), idle_h=round(i/3600, 1), stuck_h=round(s/3600, 1), "
            "down_h=round(d/3600, 1), utilization=if(r+i+s+d>0, round(100*r/(r+i+s+d)), null())\n"
            "| eval stuck_band=if(s>0, 2, 1), down_band=if(d>0, 3, 1)")
    v.chain("ds_payload", "Average payload", "ds_asset_base",
            "| where payload_t>0\n| stats avg(payload_t) as payload\n| eval payload=round(payload, 1)")
    v.chain("ds_speeds", "Loaded and empty speed", "ds_asset_base",
            "| where speed_kmh>0\n| stats avg(eval(if(payload_t>0, speed_kmh, null()))) as loaded "
            "avg(eval(if(payload_t=0, speed_kmh, null()))) as empty\n"
            "| eval loaded=round(loaded, 1), empty=round(empty, 1)")
    v.chain("ds_state_timeline", "State timeline", "ds_asset_base",
            "| eval duration=tick_s*1000\n| table _time asset_id state duration")
    v.chain("ds_speed_line", "Speed over time", "ds_asset_base",
            "| timechart span=10m avg(speed_kmh) as speed_kmh")
    v.search("ds_asset_alarms", "Alarms for the asset", "`kiruna_alarm` asset_id=$asset_id|s$\n" + ALARM_TABLE_SPL,
             live=True)
    v.add("viz_identity", table("Identity (click to open Asset Timeline)", "ds_identity",
                                link=("asset_timeline", {"form.asset_id": "$row.asset_id.value|u$"}), count=1))
    v.add("viz_kpi_bg", rect())
    v.add("viz_run", single("Running", "ds_hours", "running_h", unit="h"))
    v.add("viz_idle", single("Idle", "ds_hours", "idle_h", unit="h"))
    v.add("viz_stuck", single("Stuck or stopped", "ds_hours", "stuck_h", "stuck_band", STATUS_COLORS, unit="h",
                              under="Amber when above zero: Warning"))
    v.add("viz_down", single("Down", "ds_hours", "down_h", "down_band", STATUS_COLORS, unit="h",
                             under="Red when above zero: Critical"))
    v.add("viz_util", radial("Utilization", "ds_hours", "utilization", 100, "Running share of the time range, pct"))
    v.add("viz_payload", single("Average payload", "ds_payload", "payload", unit="t",
                                under="Trucks and loaders. Empty means not a driving asset."))
    v.add("viz_hours", single("Engine hours", "ds_hours", "engine_hours", unit="h", under="Seeded, illustrative"))
    v.add("viz_place", table("Place (click to show on Mine Cross-Section)", "ds_place",
                             link=("mine_section", {"form.level_m": "$row.level_m.value|u$"}), count=1))
    v.add("viz_timeline", {"type": "splunk.timeline", "title": "State over time",
                           "dataSources": {"primary": "ds_state_timeline"},
                           "options": {"category": "> primary | seriesByName('state')", "backgroundColor": PANEL,
                                       "legendDisplay": "right",
                                       "seriesColors": [OK, UNKNOWN, WARN, CRIT, INFO]}})
    v.add("viz_loaded", single("Average loaded speed", "ds_speeds", "loaded", unit="km/h",
                               under="Empty means not a driving asset."))
    v.add("viz_empty", single("Average empty speed", "ds_speeds", "empty", unit="km/h",
                              under="Empty means not a driving asset."))
    v.add("viz_speed", chart("splunk.line", "Speed km/h (not a driving asset: no line)", "ds_speed_line",
                             {"speed_kmh": INFO}))
    v.add("viz_alarm_table", table("Alarms in the time range (click to open Asset Timeline)", "ds_asset_alarms",
                                   link=("asset_timeline", {"form.asset_id": "$asset_id|u$"}), count=15))
    v.tab("Status", [("viz_header", 20, 10, 1400, 90), ("viz_identity", 20, 110, 1400, 110),
                     ("viz_kpi_bg", 20, 240, 1400, 180),
                     ("viz_run", 30, 250, 335, 160), ("viz_idle", 375, 250, 335, 160),
                     ("viz_stuck", 720, 250, 335, 160), ("viz_down", 1065, 250, 345, 160),
                     ("viz_util", 20, 440, 460, 280), ("viz_payload", 500, 440, 440, 135),
                     ("viz_hours", 500, 585, 440, 135), ("viz_place", 960, 440, 460, 280)], 740)
    v.tab("Motion", [("viz_timeline", 20, 20, 1400, 280), ("viz_loaded", 20, 320, 690, 160),
                     ("viz_empty", 730, 320, 690, 160), ("viz_speed", 20, 500, 1400, 300)], 820)
    v.tab("Alarms", [("viz_alarm_table", 20, 20, 1400, 500)], 540)
    return v


def asset_timeline():
    v = View("asset_timeline", "Asset Timeline", "What did this asset do over the selected time?", "-24h,now")
    asset_dropdown(v)
    header(v, "What did this asset do over the selected time?")
    v.search("ds_tl_base", "Asset ticks and alarms",
             "`kiruna_events` (sourcetype=\"kiruna:asset\" OR sourcetype=\"kiruna:alarm\") asset_id=$asset_id|s$\n"
             "| fields _time sourcetype asset_id state speed_kmh payload_t tick_s scenario level_m alarm_id "
             "alarm_code severity action", live=True)
    v.chain("ds_tl_state", "State timeline", "ds_tl_base",
            "| where sourcetype=\"kiruna:asset\"\n| eval duration=tick_s*1000\n| table _time asset_id state duration")
    v.chain("ds_tl_motion", "Speed and payload", "ds_tl_base",
            "| where sourcetype=\"kiruna:asset\"\n| timechart span=10m avg(speed_kmh) as speed_kmh "
            "avg(payload_t) as payload_t")
    v.chain("ds_tl_alarms", "Alarms", "ds_tl_base", "| where sourcetype=\"kiruna:alarm\"\n" + ALARM_TABLE_SPL)
    v.chain("ds_tl_scen", "Scenario changes seen by this asset", "ds_tl_base",
            "| where sourcetype=\"kiruna:asset\"\n| sort 0 _time\n| streamstats current=f last(scenario) as prev\n"
            "| where isnull(prev) OR scenario!=prev\n| eval started=strftime(_time, \"%d %b %H:%M\")\n"
            "| table started scenario level_m\n| eval _color_rank=3")
    v.add("viz_tl", {"type": "splunk.timeline", "title": "State over time",
                     "dataSources": {"primary": "ds_tl_state"},
                     "options": {"category": "> primary | seriesByName('state')", "backgroundColor": PANEL,
                                 "legendDisplay": "right", "seriesColors": [OK, UNKNOWN, WARN, CRIT, INFO]}})
    v.add("viz_motion", chart("splunk.line", "Speed (km/h) and payload (t, right axis)", "ds_tl_motion",
                              {"speed_kmh": INFO, "payload_t": WARN},
                              {"y2Fields": "> primary | frameBySeriesNames('payload_t')",
                               "y2AxisTitleText": "payload t", "yAxisTitleText": "km/h"}))
    v.add("viz_tl_alarms", table("Alarms", "ds_tl_alarms"))
    v.add("viz_tl_scen", table("Scenario changes (click to show this level on Mine Cross-Section)", "ds_tl_scen",
                               link=("mine_section", {"form.level_m": "$row.level_m.value|u$"})))
    v.add("viz_links", md("[Open Asset Health for this asset](/app/%s/asset_health?form.asset_id=$asset_id|u$)  \n"
                          "[Open Mine Cross-Section](/app/%s/mine_section)" % (APP_ID, APP_ID)))
    v.tab("Timeline", [("viz_header", 20, 10, 1000, 90), ("viz_links", 1040, 10, 380, 90),
                       ("viz_tl", 20, 110, 1400, 260), ("viz_motion", 20, 390, 1400, 280),
                       ("viz_tl_alarms", 20, 690, 860, 300), ("viz_tl_scen", 900, 690, 520, 300)], 1010)
    return v


def outbound_overview():
    v = View("outbound_overview", "Outbound Overview",
             "Are illustrative tonnes on plan from the mine to the ports?", "-14d@d,now")
    header(v, "Are illustrative tonnes on plan from the mine to the ports? Tonnes only.")
    v.search("ds_today", "Today drawn, crushed, hoisted versus day plan",
             "`kiruna_flow` (object_type=\"ore_pass\" OR object_type=\"crusher\" OR object_id=\"KIR-HST-01\") "
             "earliest=@d latest=now\n"
             "| stats sum(eval(if(object_type=\"ore_pass\", inflow_t, 0))) as drawn sum(crushed_t) as crushed "
             "sum(eval(if(object_id=\"KIR-HST-01\", hoisted_t, 0))) as hoisted "
             "sum(eval(if(object_type=\"ore_pass\", plan_tpm*tick_s/60, 0))) as plan_now\n"
             "| eval drawn_pct=round(100*drawn/plan_now), crushed_pct=round(100*crushed/plan_now), "
             "hoisted_pct=round(100*hoisted/plan_now)", live=True)
    v.search("ds_daily", "Daily summary lookup (written by kiruna_daily_rollup)",
             "| inputlookup kiruna_daily_summary\n| eval _time=day_epoch\n| sort 0 _time")
    v.chain("ds_ytd", "Year to date versus illustrative plan", "ds_daily",
            "| where strftime(_time, \"%Y\")=strftime(now(), \"%Y\")\n"
            "| eval ytd_pct=round(100*ytd_hoisted_t/ytd_plan_t, 1)\n"
            "| eval ytd_label=tostring(round(ytd_hoisted_t/1000000, 2)).\" Mt hoisted, \".ytd_pct.\" pct of plan\"\n"
            "| table _time ytd_label ytd_pct hoisted_t")
    v.chain("ds_movement", "Last 14 days drawn, hoisted, railed", "ds_daily",
            "| where _time>=relative_time(now(), \"-14d@d\")\n"
            "| table _time drawn_t hoisted_t railed_t day_plan_t")
    v.chain("ds_quality", "Fe grade versus target", "ds_daily",
            "| where _time>=relative_time(now(), \"-14d@d\")\n| eval fe_target=67\n| table _time fe_pct fe_target")
    v.chain("ds_ceiling", "Days outside SiO2 or P ceiling", "ds_daily",
            "| where _time>=relative_time(now(), \"-14d@d\")\n"
            "| eval outside=if(sio2_over=1 OR p_over=1, 1, 0)\n| table _time outside")
    v.chain("ds_logistics", "Rail tonnes toward Narvik and Luleå versus plan split", "ds_daily",
            "| where _time>=relative_time(now(), \"-14d@d\")\n"
            "| stats sum(narvik_t) as narvik sum(lulea_t) as lulea sum(railed_t) as railed\n"
            "| eval narvik_plan=round(railed*0.7), lulea_plan=round(railed*0.3)\n"
            "| eval destination=mvappend(\"Narvik\", \"Luleå\")\n| mvexpand destination\n"
            "| eval shipped_t=if(destination=\"Narvik\", narvik, lulea), plan_t=if(destination=\"Narvik\", narvik_plan, lulea_plan)\n"
            "| table destination shipped_t plan_t")
    v.chain("ds_shipped", "Shipped versus plan and departures on plan", "ds_daily",
            "| where _time>=relative_time(now(), \"-14d@d\")\n"
            "| stats sum(railed_t) as railed sum(day_plan_t) as plan sum(departures_on_plan) as onp sum(departures) as dep\n"
            "| eval shipped_pct=round(100*railed/plan), on_plan_pct=round(100*onp/dep)")
    v.search("ds_inventory", "Inventory by node, latest hour",
             "`kiruna_supply` record=\"inventory\" earliest=-2h\n"
             "| stats latest(tonnes) as tonnes latest(node_order) as node_order by node_id\n"
             "| lookup kiruna_supply_nodes node_id OUTPUT label\n| sort node_order\n| eval _color_rank=3\n"
             "| table label tonnes _color_rank", live=True)
    v.chain("ds_inventory_bar", "Inventory bar", "ds_inventory", "| fields label tonnes")
    v.add("viz_today_note", md("Every figure on this view is a demo fixture. **Illustrative targets.** "
                               "Day plan 16,000 t."))
    v.add("viz_r_drawn", radial("Drawn today vs plan to now", "ds_today", "drawn_pct", 120, "pct, illustrative"))
    v.add("viz_r_crushed", radial("Crushed today vs plan to now", "ds_today", "crushed_pct", 120, "pct, illustrative"))
    v.add("viz_r_hoisted", radial("Hoisted today vs plan to now", "ds_today", "hoisted_pct", 120, "pct, illustrative"))
    v.add("viz_ytd", single("Year to date hoisted vs illustrative plan", "ds_ytd", "ytd_label", "ytd_pct",
                            PCT_COLORS, sparkline_field="hoisted_t",
                            under="Daily lookup; days before the backfill window are seeded fixtures"))
    v.add("viz_movement", chart("splunk.column", "Last 14 days: drawn, hoisted, railed (t), plan as line",
                                "ds_movement", {"drawn_t": INFO, "hoisted_t": OK, "railed_t": "#A57BD6",
                                                "day_plan_t": "#E1E6EB"},
                                {"overlayFields": "day_plan_t", "yAxisTitleText": "t per day"}))
    v.add("viz_fe", chart("splunk.line", "Fe percent vs illustrative target 67", "ds_quality",
                          {"fe_pct": INFO, "fe_target": WARN}))
    v.add("viz_ceiling", chart("splunk.column", "Days outside the SiO2 or P ceiling (1 = outside)", "ds_ceiling",
                               {"outside": CRIT}, {"legendDisplay": "off"}))
    v.add("viz_inv_bar", chart("splunk.bar", "Tonnes by node (illustrative)", "ds_inventory_bar",
                               extra={"seriesColors": [INFO], "legendDisplay": "off"}))
    v.add("viz_inv_table", table("Inventory nodes", "ds_inventory"))
    v.add("viz_rail_bar", chart("splunk.bar", "Railed toward Narvik and Luleå vs plan split, 14 days (Malmbanan)",
                                "ds_logistics", {"shipped_t": INFO, "plan_t": UNKNOWN}))
    v.add("viz_r_shipped", radial("Shipped vs plan, 14 days", "ds_shipped", "shipped_pct", 120, "pct, illustrative"))
    v.add("viz_on_plan", single("Departures inside the on-plan window", "ds_shipped", "on_plan_pct", "on_plan_pct",
                                PCT_COLORS, unit="%", under="Illustrative departures, delay up to 10 min"))
    v.tab("Today", [("viz_header", 20, 10, 1400, 90), ("viz_today_note", 20, 100, 1400, 40),
                    ("viz_r_drawn", 20, 150, 455, 300), ("viz_r_crushed", 492, 150, 455, 300),
                    ("viz_r_hoisted", 965, 150, 455, 300), ("viz_ytd", 20, 470, 1400, 200)], 690)
    v.tab("Movement", [("viz_movement", 20, 20, 1400, 520)], 560)
    v.tab("Quality", [("viz_fe", 20, 20, 1400, 300), ("viz_ceiling", 20, 340, 1400, 260)], 620)
    v.tab("Inventory", [("viz_inv_bar", 20, 20, 860, 460), ("viz_inv_table", 900, 20, 520, 460)], 500)
    v.tab("Logistics", [("viz_rail_bar", 20, 20, 860, 400), ("viz_r_shipped", 900, 20, 520, 240),
                        ("viz_on_plan", 900, 280, 520, 140)], 440)
    return v


def stuck_recovery():
    v = View("stuck_recovery", "Stuck and Recovery", "What is stuck, and what is downstream?", "-1h,now")
    header(v, "What is stuck, and what is downstream?")
    v.search("ds_heroes", "Hero assets (summary lookup)",
             "| inputlookup kiruna_asset_latest where asset_id=\"KIR-TRK-014\" OR asset_id=\"KIR-LHD-007\"\n"
             "| eval label=asset_id.\" \".state.\" \".status\n"
             "| eval band=status_code\n| table asset_id label band", live=True)
    v.chain("ds_hero_014", "KIR-TRK-014", "ds_heroes", "| where asset_id=\"KIR-TRK-014\"")
    v.chain("ds_hero_007", "KIR-LHD-007", "ds_heroes", "| where asset_id=\"KIR-LHD-007\"")
    v.add("viz_kpi_bg", rect())
    v.add("viz_014", single("Driverless truck KIR-TRK-014", "ds_hero_014", "label", "band", STATUS_COLORS,
                            under="Drift KIR-DRF-1220-N"))
    v.add("viz_007", single("Autonomous loader KIR-LHD-007", "ds_hero_007", "label", "band", STATUS_COLORS,
                            under="Drawpoint KIR-DP-1220-04, pass KIR-OP-1220-A"))
    v.search("ds_stuck", "Assets stuck or stopped (summary lookup)",
             "| inputlookup kiruna_asset_latest where state=\"stuck\" OR state=\"stopped\" OR state=\"down\"\n"
             "| eval _color_rank=case(status=\"Critical\", 1, status=\"Warning\", 2, true(), 3)\n"
             "| table asset_id label state cause place_id status _color_rank\n"
             "| appendpipe [ stats count | where count=0 | eval label=\"Nothing stuck or stopped.\" | fields label ]",
             live=True)
    v.add("viz_stuck", table("Stuck or stopped now (click to open Asset Health)", "ds_stuck",
                             link=("asset_health", {"form.asset_id": "$row.asset_id.value|u$"})))
    v.search("ds_chain_line", "Pass A inflow, CRU-01 feed, buffer minutes, hoist t/h",
             "`kiruna_flow` (object_id=\"KIR-OP-1220-A\" OR object_id=\"KIR-CRU-01\" OR object_id=\"KIR-BUF-01\" "
             "OR object_id=\"KIR-HST-01\")\n"
             "| eval pass_a_inflow_tph=if(object_id=\"KIR-OP-1220-A\", inflow_tpm*60, null()), "
             "cru01_feed_tph=if(object_id=\"KIR-CRU-01\", feed_tpm*60, null()), "
             "buffer_min=if(object_id=\"KIR-BUF-01\", buffer_min, null()), "
             "hoist_tph=if(object_id=\"KIR-HST-01\", hoist_tpm*60, null())\n"
             "| timechart span=1m avg(pass_a_inflow_tph) as pass_a_inflow_tph avg(cru01_feed_tph) as cru01_feed_tph "
             "avg(buffer_min) as buffer_min avg(hoist_tph) as hoist_tph", live=True)
    v.add("viz_chain", chart("splunk.line", "Downstream: pass A inflow t/h, CRU-01 feed t/h, hoist t/h, "
                             "buffer minutes (right axis)", "ds_chain_line",
                             {"pass_a_inflow_tph": INFO, "cru01_feed_tph": WARN, "buffer_min": "#A57BD6",
                              "hoist_tph": OK},
                             {"y2Fields": "> primary | frameBySeriesNames('buffer_min')",
                              "y2AxisTitleText": "buffer min", "nullValueDisplay": "connect"}))
    v.search("ds_talk", "Talk track for the running scenario (scenario lookup)",
             "| inputlookup kiruna_service_scores\n| stats first(scenario) as scenario\n"
             "| lookup kiruna_scenarios scenario OUTPUT title expected_bands talk_track\n"
             "| eval _color_rank=3\n| table scenario title expected_bands talk_track _color_rank", live=True)
    v.add("viz_talk", table("Talk track", "ds_talk", count=1))
    v.add("viz_links", md("[Open Demo Control](/app/%s/demo_control) to change the scenario.  \n"
                          "[Open Service Health](/app/%s/service_health)" % (APP_ID, APP_ID)))
    v.tab("Stuck", [("viz_header", 20, 10, 1000, 90), ("viz_links", 1040, 10, 380, 90),
                    ("viz_kpi_bg", 20, 110, 1400, 180),
                    ("viz_014", 30, 120, 685, 160), ("viz_007", 725, 120, 685, 160),
                    ("viz_stuck", 20, 310, 560, 340), ("viz_chain", 600, 310, 820, 340),
                    ("viz_talk", 20, 670, 1400, 150)], 840)
    return v


def service_health():
    v = View("service_health", "Service Health", "Which production service is degraded?", "-8h,now")
    header(v, "Which production service is degraded?")
    heartbeat(v)
    v.search("ds_scores", "Service scores (summary lookup)",
             "| inputlookup kiruna_service_scores\n| sort 0 service_order\n"
             "| eval _color_rank=color_rank\n"
             "| table service score band reason drilldown_view _color_rank", live=True)
    v.chain("ds_parent", "Parent score", "ds_scores",
            "| where service=\"Kiruna production\"\n| eval label=score.\" \".band\n| table label score")
    v.chain("ds_children", "Child scores", "ds_scores",
            "| where service!=\"Kiruna production\"\n| table service score")
    v.add("viz_kpi_bg", rect())
    v.add("viz_parent", single("Kiruna production (parent)", "ds_parent", "label", "score", SCORE_COLORS,
                               under="80-100 Healthy, 50-79 Warning, 0-49 Critical. Demo score."))
    v.add("viz_children", chart("splunk.bar", "Child service scores (demo fixture bands)", "ds_children",
                                extra={"seriesColors": [INFO], "legendDisplay": "off",
                                       "xAxisTitleText": "", "yAxisMax": 100}))
    scores = v.add("viz_scores", table("Services (click to open the related view)", "ds_scores"))
    v.viz[scores]["eventHandlers"] = [{"type": "drilldown.customUrl", "options": {
        "url": "/app/%s/$row.drilldown_view.value|u$" % APP_ID, "newTab": False}}]
    v.add("viz_deps", md(
        "**Dependency (top to bottom).** Kiruna production depends on Draw and load, Level haulage, Crushing, "
        "Hoisting, and Autonomy and comms. Outbound logistics depends on Hoisting and is lagged; it is not an "
        "input to the parent minimum. One stuck truck alone does not pull production down.  \n"
        "When ITSI is installed, continue in Service Analyzer. This table is the demo score."))
    v.tab("Services", [("viz_header", 20, 10, 1000, 90), ("viz_heartbeat", 1040, 10, 380, 90),
                       ("viz_kpi_bg", 20, 110, 460, 280), ("viz_parent", 30, 120, 440, 260),
                       ("viz_children", 500, 110, 920, 280),
                       ("viz_scores", 20, 410, 1400, 320), ("viz_deps", 20, 750, 1400, 110)], 880)
    return v


def main():
    for build in (shift_brief, mine_section, level_ops, asset_health, asset_timeline,
                  outbound_overview, stuck_recovery, service_health):
        v = build()
        v.write()
        print("wrote %s.xml (%d data sources, %d visualizations)" % (v.id, len(v.ds), len(v.viz)))


if __name__ == "__main__":
    sys.exit(main())
