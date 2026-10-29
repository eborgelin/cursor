#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Kiirunavaara Mine Demo synthetic generator (Splunk modular input).

Every value this script writes is a synthetic, illustrative demo fixture.

Splunk runs it every 60 s (inputs.conf interval). Each run:
  1. reads [generator] from lkab_kiruna_demo_settings.conf and re-validates it,
  2. runs a pending backfill once (only the part not already written),
  3. writes the ticks since the last run (at most MAX_CATCHUP_TICKS),
  4. saves state in the modular input checkpoint directory.

Standalone use (no Splunk needed):
  kiruna_demo_gen.py --simulate --scenario truck-stuck --ticks 5
  kiruna_demo_gen.py --check-index main     # exits 2: refused
"""

from __future__ import print_function

import argparse
import csv
import io
import json
import os
import random
import ssl
import sys
import time
import xml.sax.saxutils as saxutils
from xml.etree import ElementTree

try:
    import configparser
except ImportError:  # pragma: no cover
    import ConfigParser as configparser

try:
    from urllib.parse import urlencode
    from urllib.request import Request, urlopen
except ImportError:  # pragma: no cover
    from urllib import urlencode
    from urllib2 import Request, urlopen

try:
    from zoneinfo import ZoneInfo
    LOCAL_TZ = ZoneInfo("Europe/Stockholm")
except Exception:  # pragma: no cover
    LOCAL_TZ = None

APP_NAME = "lkab_kiruna_demo"
DEMO_INDEX = "kiruna_events"
HOST = "kiruna-demo"
SOURCE = "kiruna_demo_gen"
SETTINGS_FILE = "lkab_kiruna_demo_settings.conf"
SCENARIOS = (
    "healthy-shift",
    "truck-stuck",
    "loader-stopped-drawpoint",
    "cascade-crusher-hoist",
    "recovery",
)
TICK_S = 60
BACKFILL_STEP_S = 300
MAX_CATCHUP_TICKS = 10
REF_EPOCH = 1767225600  # 2026-01-01T00:00:00Z, origin for hours and odometer growth

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Illustrative rates in tonnes per minute while a shift is producing.
PASS_RATE = {"KIR-OP-1220-A": 6.67, "KIR-OP-1220-B": 5.0, "KIR-OP-1288-A": 5.0}
LHD_SHARE = {"KIR-LHD-007": 0.4, "KIR-LHD-011": 0.6, "KIR-LHD-030": 1.0,
             "KIR-LHD-018": 0.5, "KIR-LHD-022": 0.5}
HOIST_PLAN_TPM = 16.67
STAGE_HOIST_TPM = 4.0
CRUSHER_FLOOR = {"KIR-CRU-01": 4.0, "KIR-CRU-02": 6.0}

SEVERITY = {"info": 1, "warning": 2, "critical": 3}

# Fault flag -> (asset or place id, alarm code, cause, severity)
FLAG_ALARMS = {
    "T014": ("KIR-TRK-014", "TRUCK_PATH_BLOCKED", "path_blocked", "warning"),
    "L007": ("KIR-LHD-007", "DRAWPOINT_HANGUP", "drawpoint_hangup", "warning"),
    "L011": ("KIR-LHD-011", "COMMS_LOSS", "comms_loss", "critical"),
    "COM1220": ("KIR-COM-1220", "COMMS_LOSS", "comms_loss", "critical"),
    "PASSA_LOW": ("KIR-OP-1220-A", "OREPASS_LOW", "orepass_low", "warning"),
    "CRU01_IDLE": ("KIR-CRU-01", "CRUSHER_IDLE", "crusher_idle", "warning"),
    "BUF_LOW": ("KIR-BUF-01", "BUFFER_LOW", "buffer_low", "critical"),
    "HOIST_UNDER": ("KIR-HST-01", "HOIST_UNDERFEED", "hoist_underfeed", "critical"),
}
TEMP_ALARM = ("KIR-LHD-018", "HYDRAULIC_TEMP_WARN", "hydraulic_temp", "info")

# Scenario schedules: flag -> first tick index (offset from scenario start) it is active.
SCHEDULE = {
    "healthy-shift": {},
    "truck-stuck": {"T014": 0},
    "loader-stopped-drawpoint": {"L007": 0},
    "cascade-crusher-hoist": {"T014": 0, "L007": 0, "L011": 0, "COM1220": 0,
                              "PASSA_LOW": 1, "CRU01_IDLE": 1,
                              "BUF_LOW": 2, "HOIST_UNDER": 2, "PLANT_RISK": 2},
}
# Recovery: flag -> tick index at which it clears. Truck, then loaders and comms,
# then pass and crusher, then buffers and hoist.
RECOVERY_CLEAR = {"T014": 0, "L007": 0, "L011": 0, "COM1220": 0,
                  "PASSA_LOW": 1, "CRU01_IDLE": 1,
                  "BUF_LOW": 2, "HOIST_UNDER": 2, "PLANT_RISK": 2}


class IndexRefused(Exception):
    pass


def require_demo_index(name):
    """The generator, and backfill in particular, writes only to kiruna_events."""
    if name != DEMO_INDEX:
        raise IndexRefused("refusing index %r: only %r is allowed" % (name, DEMO_INDEX))
    return name


# ---------------------------------------------------------------- settings

def _as_bool(value, default):
    if value is None:
        return default
    v = str(value).strip().lower()
    if v in ("1", "true", "t", "yes", "y", "on"):
        return True
    if v in ("0", "false", "f", "no", "n", "off"):
        return False
    return default


def validate_settings(raw):
    """Re-validate settings: the setup form is not the only way to write them."""
    warnings = []
    scenario = str(raw.get("scenario", "healthy-shift")).strip()
    if scenario not in SCENARIOS:
        warnings.append("scenario %r not allowed, using healthy-shift" % scenario)
        scenario = "healthy-shift"
    backfill = str(raw.get("backfill_days", "0")).strip()
    if backfill.isdigit() and 0 <= int(backfill) <= 14:
        backfill_days = int(backfill)
    else:
        warnings.append("backfill_days %r not in 0..14, using 0" % backfill)
        backfill_days = 0
    return {
        "scenario": scenario,
        "generator_enabled": _as_bool(raw.get("generator_enabled"), False),
        "presentation_shift": _as_bool(raw.get("presentation_shift"), True),
        "backfill_days": backfill_days,
    }, warnings


def read_settings(path=None):
    parser = configparser.RawConfigParser()
    paths = [path] if path else [os.path.join(APP_DIR, "default", SETTINGS_FILE),
                                 os.path.join(APP_DIR, "local", SETTINGS_FILE)]
    raw = {}
    for p in paths:
        if p and os.path.exists(p):
            with io.open(p, encoding="utf-8") as fh:
                text = fh.read()
            parser = configparser.RawConfigParser()
            parser.read_string(text) if hasattr(parser, "read_string") else parser.readfp(io.StringIO(text))
            if parser.has_section("generator"):
                raw.update(dict(parser.items("generator")))
    return validate_settings(raw)


# ---------------------------------------------------------------- lookups

def load_assets():
    with io.open(os.path.join(APP_DIR, "lookups", "kiruna_assets.csv"), encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


# ---------------------------------------------------------------- clock and shifts

def local_hour(t):
    if LOCAL_TZ is not None:
        import datetime
        return datetime.datetime.fromtimestamp(t, LOCAL_TZ).hour
    return int(((t + 3600) % 86400) // 3600)


def shift_start(t, presentation_shift):
    """Shifts start at 06, 14, 22 local. Returns (start_epoch, producing)."""
    hour = local_hour(t)
    base = t - (t % 3600) - ((hour - 6) % 8) * 3600
    producing = presentation_shift or (6 <= hour < 22)
    return int(base), producing


def rnd(*key):
    return random.Random("|".join(str(k) for k in key))


# ---------------------------------------------------------------- world model

def active_flags(scenario, k, prev_flags):
    if scenario == "recovery":
        return set(f for f in prev_flags if k < RECOVERY_CLEAR.get(f, 0))
    return set(f for f, start in SCHEDULE.get(scenario, {}).items() if k >= start)


def world(t, step, st, assets, settings):
    """Return the events for one tick at epoch t covering `step` seconds."""
    scenario = st["scenario"]
    k = max(0, int((t - st["scenario_start"]) // TICK_S))
    flags = active_flags(scenario, k, st.get("prev_flags", []))
    s_start, producing = shift_start(t, settings["presentation_shift"])
    minutes = step / 60.0
    events = []

    # Pass inflow from the loaders that are running.
    lhd_down = {"KIR-LHD-007": "L007" in flags, "KIR-LHD-011": "L011" in flags}
    inflow_tpm = {}
    for pid, rate in PASS_RATE.items():
        share = 1.0
        if pid == "KIR-OP-1220-A":
            share -= LHD_SHARE["KIR-LHD-007"] if lhd_down["KIR-LHD-007"] else 0
            share -= LHD_SHARE["KIR-LHD-011"] if lhd_down["KIR-LHD-011"] else 0
        n = rnd("in", pid, t).uniform(-0.03, 0.03)
        inflow_tpm[pid] = round(rate * max(share, 0) * (1 + n), 2) if producing else 0.0

    prev = set(st.get("prev_flags", []))
    recovering = scenario == "recovery"
    if "PASSA_LOW" in flags:
        pass_a_level = 8.0
    elif "L007" in flags and "L011" in flags:
        pass_a_level = 45.0
    elif "L007" in flags or "L011" in flags:
        pass_a_level = max(40.0, 70.0 - 4 * k)
    elif recovering and "PASSA_LOW" in prev:
        pass_a_level = min(70.0, 30.0 + 15 * max(0, k - 1))
    else:
        pass_a_level = 70.0 + rnd("lvl", t).uniform(-2, 2)

    cru_feed = {
        "KIR-CRU-01": 0.0 if "CRU01_IDLE" in flags else PASS_RATE["KIR-OP-1220-A"],
        "KIR-CRU-02": PASS_RATE["KIR-OP-1220-B"] + PASS_RATE["KIR-OP-1288-A"],
    }
    if not producing:
        cru_feed = {c: 0.0 for c in cru_feed}
    floors = CRUSHER_FLOOR if producing else {c: 0.0 for c in CRUSHER_FLOOR}

    if "BUF_LOW" in flags:
        buffer_min = 12.0 if k <= 2 else 9.0
    elif "CRU01_IDLE" in flags:
        buffer_min = 24.0
    elif recovering and "BUF_LOW" in prev:
        buffer_min = min(45.0, 31.0 + 4 * max(0, k - 2))
    else:
        buffer_min = 45.0 + rnd("buf", t).uniform(-2, 2)

    hoist_plan = HOIST_PLAN_TPM if producing else 0.0
    hoist_tpm = (7.0 if "HOIST_UNDER" in flags else HOIST_PLAN_TPM * (1 + rnd("h", t).uniform(-0.02, 0.02))) if producing else 0.0
    plant_risk = 1 if "PLANT_RISK" in flags else 0

    # Open alarms wanted this tick.
    wanted = {}
    for f in flags:
        if f in FLAG_ALARMS:
            obj, code, cause, sev = FLAG_ALARMS[f]
            wanted["%s-%s-%s" % (scenario, obj, cause)] = (obj, code, cause, sev)
    if 20 <= (t // 60) % 60 < 30:
        obj, code, cause, sev = TEMP_ALARM
        wanted["%s-%s-%s" % (scenario, obj, cause)] = (obj, code, cause, sev)
    obj_alarm = {}
    for obj, code, cause, sev in wanted.values():
        if SEVERITY[sev] > obj_alarm.get(obj, (None, 0))[1]:
            obj_alarm[obj] = (code, SEVERITY[sev])

    common = {"scenario": scenario, "tick_s": step}

    # Asset ticks.
    for a in assets:
        aid, atype = a["asset_id"], a["asset_type"]
        ev = dict(common)
        ev.update({
            "asset_id": aid, "asset_type": atype, "fleet": a["fleet"], "model": a["model"],
            "level_m": int(a["level_m"]), "place_id": a["place_id"],
            "state": "running", "autonomy_mode": "auto", "cause": "none", "activity": "in_service",
        })
        hrs = (t - REF_EPOCH) / 3600.0
        if a.get("engine_hours_seed"):
            ev["engine_hours"] = round(float(a["engine_hours_seed"]) + hrs * 0.7, 1)
        if a.get("odometer_seed"):
            ev["odometer_km"] = round(float(a["odometer_seed"]) + hrs * 0.7 * 9, 1)
        offset = rnd("off", aid).randint(0, 600)
        if atype == "truck":
            phase = int(((t + offset) // 60) % 10)
            activity, speed, payload = [
                ("loading", 0, 32), ("hauling_loaded", 12, 32), ("hauling_loaded", 12, 32),
                ("hauling_loaded", 12, 32), ("dumping", 0, 0), ("returning_empty", 18, 0),
                ("returning_empty", 18, 0), ("waiting_bay", 0, 0), ("waiting_bay", 0, 0),
                ("waiting_bay", 0, 0)][phase]
            ev.update(activity=activity, speed_kmh=speed,
                      payload_t=round(payload + (rnd("p", aid, t).uniform(-1.5, 1.5) if payload else 0), 1),
                      state="idle" if activity == "waiting_bay" else "running")
            if aid == "KIR-TRK-014" and "T014" in flags:
                ev.update(state="stuck", autonomy_mode="failsafe_stop", cause="path_blocked",
                          speed_kmh=0, payload_t=32.0, activity="stuck_in_drift")
            elif aid == "KIR-TRK-021" and "T014" in flags:
                ev.update(state="idle", cause="waiting_blocked_drift", speed_kmh=0, activity="waiting_behind_014")
        elif atype == "lhd":
            phase = int(((t + offset) // 60) % 5)
            activity, speed, payload = [("loading", 3, 12), ("tramming_loaded", 8, 12), ("dumping", 0, 0),
                                        ("tramming_empty", 10, 0), ("waiting_drawpoint", 0, 0)][phase]
            ev.update(activity=activity, speed_kmh=speed,
                      payload_t=round(payload + (rnd("p", aid, t).uniform(-0.8, 0.8) if payload else 0), 1),
                      state="idle" if activity == "waiting_drawpoint" else "running")
            if aid == "KIR-LHD-007" and "L007" in flags:
                ev.update(state="stopped", autonomy_mode="manual_hold", cause="drawpoint_hangup",
                          speed_kmh=0, payload_t=0, activity="stopped_at_drawpoint")
            elif aid == "KIR-LHD-011" and "L011" in flags:
                ev.update(state="stopped", autonomy_mode="failsafe_stop", cause="comms_loss",
                          speed_kmh=0, payload_t=0, activity="stopped_comms_loss")
        elif atype == "drill":
            ev.update(activity="drilling_fan" if ((t // 3600) % 3) else "moving_rig",
                      state="running" if ((t // 1800) % 4) else "idle", speed_kmh=0)
        elif atype == "crusher":
            fed = cru_feed[aid] >= floors[aid] and cru_feed[aid] > 0
            ev.update(state="running" if fed else "idle", activity="crushing" if fed else "starved",
                      cause="crusher_idle" if (aid == "KIR-CRU-01" and "CRU01_IDLE" in flags) else "none")
        elif atype == "hoist":
            if aid == "KIR-HST-01" and "HOIST_UNDER" in flags:
                ev.update(cause="hoist_underfeed", activity="hoisting_light")
            else:
                ev.update(activity="hoisting" if producing else "standby")
        if not producing and atype in ("truck", "lhd", "drill", "crusher", "hoist"):
            ev.update(state="idle", cause="night_shift_idle", activity="night_idle", speed_kmh=0)
        code, sev = obj_alarm.get(aid, ("none", 0))
        ev.update(alarm_code=code, alarm_severity=sev)
        events.append((t, "kiruna:asset", ev))

        # Completed cycles in (t - step, t].
        if atype in ("truck", "lhd") and ev["state"] == "running" and producing:
            cycle_s = 600 if atype == "truck" else 300
            done = int((t + offset) // cycle_s) - int((t - step + offset) // cycle_s)
            for i in range(done):
                ct = int(((t + offset) // cycle_s - i) * cycle_s - offset)
                cyc = dict(common)
                cyc.update(asset_id=aid, asset_type=atype, level_m=int(a["level_m"]),
                           place_id=a["place_id"], pass_id=a["pass_id"], cycle_min=cycle_s / 60,
                           payload_t=round((32 if atype == "truck" else 12) + rnd("c", aid, ct).uniform(-1.5, 1.0), 1),
                           ore_path=0 if aid == "KIR-TRK-040" else 1)
                events.append((ct, "kiruna:cycle", cyc))

    # Flow snapshots.
    def flow(obj, otype, level, **kw):
        ev = dict(common)
        code, sev = obj_alarm.get(obj, ("none", 0))
        ev.update(object_id=obj, object_type=otype, level_m=level, alarm_code=code,
                  alarm_severity=sev, shift_start=s_start, producing=int(producing),
                  presentation_shift=int(settings["presentation_shift"]))
        ev.update(kw)
        events.append((t, "kiruna:flow", ev))

    pass_levels = {"KIR-OP-1220-A": pass_a_level,
                   "KIR-OP-1220-B": 68.0 + rnd("b", t).uniform(-2, 2),
                   "KIR-OP-1288-A": 72.0 + rnd("c8", t).uniform(-2, 2)}
    drawn_tick = 0.0
    for pid in PASS_RATE:
        inflow_t = round(inflow_tpm[pid] * minutes, 1)
        drawn_tick += inflow_t
        flow(pid, "ore_pass", 1288 if "1288" in pid else 1220, inflow_tpm=inflow_tpm[pid],
             inflow_t=inflow_t, level_pct=round(pass_levels[pid], 1),
             plan_tpm=PASS_RATE[pid] if producing else 0.0)
    crushed_tick = 0.0
    for cid, feed in cru_feed.items():
        crushed_tick += feed * minutes
        flow(cid, "crusher", 1365, feed_tpm=round(feed, 2), feed_floor_tpm=floors[cid],
             crushed_t=round(feed * minutes, 1))
    pocket_t = round(buffer_min * HOIST_PLAN_TPM, 0)
    for bid, share in (("KIR-BUF-01", 0.55), ("KIR-BUF-02", 0.45)):
        flow(bid, "buffer", 1365, buffer_min=round(buffer_min, 1), buffer_t=round(pocket_t * share, 0))
    hoisted_tick = round(hoist_tpm * minutes, 1)
    st["shift_totals"] = st.get("shift_totals") if st.get("shift_totals", {}).get("shift_start") == s_start \
        else {"shift_start": s_start, "drawn_t": 0.0, "hoisted_t": 0.0, "crushed_t": 0.0}
    tot = st["shift_totals"]
    tot["drawn_t"] = round(tot["drawn_t"] + drawn_tick, 1)
    tot["hoisted_t"] = round(tot["hoisted_t"] + hoisted_tick, 1)
    tot["crushed_t"] = round(tot["crushed_t"] + crushed_tick, 1)
    flow("KIR-HST-01", "hoist", 1365, hoist_tpm=round(hoist_tpm, 2), plan_tpm=hoist_plan,
         hoisted_t=hoisted_tick, shift_drawn_t=tot["drawn_t"], shift_hoisted_t=tot["hoisted_t"],
         shift_crushed_t=tot["crushed_t"])
    flow("KIR-HST-02", "hoist", 1365, hoist_tpm=STAGE_HOIST_TPM if producing else 0.0,
         plan_tpm=STAGE_HOIST_TPM if producing else 0.0, hoisted_t=round((STAGE_HOIST_TPM if producing else 0) * minutes, 1))
    flow("KIR-CNV-01", "conveyor", 0, status="running", plant_feed_risk=plant_risk,
         feed_tpm=round(hoist_tpm, 2))
    for zone, level in (("KIR-COM-1220", 1220), ("KIR-COM-1288", 1288), ("KIR-COM-1365", 1365)):
        down = zone == "KIR-COM-1220" and "COM1220" in flags
        flow(zone, "comms_zone", level, status="down" if down else "up", heartbeat_ok=0 if down else 1)

    # Alarm transitions.
    open_alarms = st.setdefault("open_alarms", {})
    for aid_ in sorted(set(open_alarms) - set(wanted)):
        obj, code, cause, sev, opened = open_alarms.pop(aid_)
        events.append((t, "kiruna:alarm", dict(common, alarm_id=aid_, action="close", asset_id=obj,
                                               alarm_code=code, cause=cause, severity=sev,
                                               opened=opened, closed=t, duration_s=t - opened)))
    for i, aid_ in enumerate(sorted(set(wanted) - set(open_alarms))):
        obj, code, cause, sev = wanted[aid_]
        open_alarms[aid_] = [obj, code, cause, sev, t]
        events.append((t + i, "kiruna:alarm", dict(common, alarm_id=aid_, action="open", asset_id=obj,
                                                   alarm_code=code, cause=cause, severity=sev, opened=t)))

    st["last_flags"] = sorted(flags)
    return events


def supply_events(t, step):
    """Hourly inventory nodes and rail departures every two hours; daily quality."""
    events = []
    for h in range(int((t - step) // 3600) + 1, int(t // 3600) + 1):
        ht = h * 3600
        with io.open(os.path.join(APP_DIR, "lookups", "kiruna_supply_nodes.csv"), encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                wander = 1 + 0.03 * rnd("node", row["node_id"], h // 6).uniform(-1, 1)
                events.append((ht, "kiruna:supply", {"record": "inventory", "node_id": row["node_id"],
                                                     "node_order": int(row["node_order"]),
                                                     "tonnes": round(float(row["baseline_t"]) * wander, 0)}))
        if h % 2 == 0:
            r = rnd("train", h)
            dest = "Luleå" if (h // 2) % 10 in (2, 5, 8) else "Narvik"
            delay = r.choice([0, 0, 0, 2, 4, 6, 12, 25])
            events.append((ht, "kiruna:supply", {"record": "rail_departure", "train_id": "DEMO-TRN-%05d" % (h % 100000),
                                                 "destination": dest, "tonnes": round(1333 * r.uniform(0.95, 1.05), 0),
                                                 "delay_min": delay, "on_plan": 1 if delay <= 10 else 0}))
    for d in range(int((t - step) // 86400) + 1, int(t // 86400) + 1):
        r = rnd("quality", d)
        events.append((d * 86400 + 3600, "kiruna:quality", {
            "record": "daily_grade", "fe_pct": round(67 + r.uniform(-0.45, 0.35), 2),
            "sio2_pct": round(r.uniform(0.75, 1.28), 2), "p_pct": round(r.uniform(0.018, 0.037), 3)}))
    return events


# ---------------------------------------------------------------- output

class Writer(object):
    def __init__(self, mode, stanza, index, out=None):
        self.mode, self.stanza, self.out = mode, stanza, out or sys.stdout
        self.index = require_demo_index(index)
        self.count = 0
        if mode == "xml":
            self.out.write("<stream>")

    def write(self, t, sourcetype, body):
        self.count += 1
        if self.mode == "json":
            self.out.write(json.dumps({"_time": t, "index": self.index, "host": HOST, "source": SOURCE,
                                       "sourcetype": sourcetype, "event": body}, ensure_ascii=False) + "\n")
            return
        self.out.write('<event stanza=%s><time>%d</time><index>%s</index><host>%s</host><source>%s</source>'
                       '<sourcetype>%s</sourcetype><data>%s</data></event>' % (
                           saxutils.quoteattr(self.stanza), t, self.index, HOST, SOURCE, sourcetype,
                           saxutils.escape(json.dumps(body, ensure_ascii=False, sort_keys=True))))

    def close(self):
        if self.mode == "xml":
            self.out.write("</stream>")
        self.out.flush()


def log(msg):
    sys.stderr.write("kiruna_demo_gen: %s\n" % msg)


def load_state(path):
    try:
        with io.open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (IOError, OSError, ValueError):
        return None


def save_state(path, st):
    tmp = path + ".tmp"
    with io.open(tmp, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(st, ensure_ascii=False))
    os.replace(tmp, path) if hasattr(os, "replace") else os.rename(tmp, path)


def apply_scenario(st, scenario, now):
    if st.get("scenario") != scenario:
        st["prev_flags"] = st.get("last_flags", [])
        st["scenario"] = scenario
        st["scenario_start"] = int(now - (now % TICK_S))


def emit_range(writer, st, assets, settings, start, end, step):
    t = start
    while t <= end:
        for ev in world(t, step, st, assets, settings):
            writer.write(*ev)
        for ev in supply_events(t, step):
            writer.write(*ev)
        t += step
    return t - step


# ---------------------------------------------------------------- splunkd REST (best effort)

def rest(server_uri, session_key, path, params=None, method="POST"):
    if not server_uri or not session_key:
        return None
    url = server_uri.rstrip("/") + path
    data = urlencode(params or {}).encode("utf-8") if method == "POST" else None
    if method == "GET" and params:
        url += "?" + urlencode(params)
    req = Request(url, data=data, headers={"Authorization": "Splunk " + session_key})
    ctx = ssl.create_default_context()
    # splunkd's management port on the same host commonly uses its default self-signed cert.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return urlopen(req, context=ctx, timeout=30).read()


def rebuild_open_alarms(server_uri, session_key):
    """After lost state, rebuild open alarms from indexed events so a restart opens no duplicate."""
    query = ('search index=%s sourcetype="kiruna:alarm" earliest=-24h '
             '| stats latest(action) as action latest(asset_id) as asset_id latest(alarm_code) as alarm_code '
             'latest(cause) as cause latest(severity) as severity latest(opened) as opened by alarm_id '
             '| where action="open"' % DEMO_INDEX)
    body = rest(server_uri, session_key, "/servicesNS/nobody/%s/search/jobs/export" % APP_NAME,
                {"search": query, "output_mode": "json"})
    found = {}
    for line in (body or b"").decode("utf-8").splitlines():
        try:
            r = json.loads(line).get("result")
        except ValueError:
            continue
        if r and r.get("alarm_id"):
            found[r["alarm_id"]] = [r.get("asset_id"), r.get("alarm_code"), r.get("cause"),
                                    r.get("severity"), int(float(r.get("opened") or 0))]
    return found


# ---------------------------------------------------------------- modes

SCHEME = """<scheme>
  <title>Kiirunavaara Mine Demo generator</title>
  <description>Synthetic, illustrative mine events for the demo. Writes only to kiruna_events.</description>
  <use_external_validation>false</use_external_validation>
  <use_single_instance>false</use_single_instance>
  <streaming_mode>xml</streaming_mode>
  <endpoint>
    <args>
      <arg name="talk_label">
        <title>Talk label</title>
        <description>Optional free-text label for this generator stanza. Not used in events.</description>
        <required_on_create>false</required_on_create>
        <required_on_edit>false</required_on_edit>
      </arg>
    </args>
  </endpoint>
</scheme>"""


def run_modular_input():
    root = ElementTree.fromstring(sys.stdin.read())
    server_uri = root.findtext("server_uri")
    session_key = root.findtext("session_key")
    checkpoint_dir = root.findtext("checkpoint_dir") or APP_DIR
    stanza_el = root.find("configuration/stanza")
    stanza = stanza_el.get("name") if stanza_el is not None else "kiruna_demo_gen://kiruna_demo"
    params = {}
    if stanza_el is not None:
        for p in stanza_el.findall("param"):
            params[p.get("name")] = (p.text or "").strip()
    try:
        index = require_demo_index(params.get("index") or DEMO_INDEX)
    except IndexRefused as exc:
        log(str(exc))
        return 2

    settings, warnings = read_settings()
    for w in warnings:
        log(w)
    if not settings["generator_enabled"]:
        log("generator_enabled is false; no events written")
        return 0

    state_path = os.path.join(checkpoint_dir, "kiruna_demo_gen_state.json")
    st = load_state(state_path)
    now = int(time.time())
    tick_now = now - (now % TICK_S)
    if st is None:
        st = {"scenario": settings["scenario"], "scenario_start": tick_now, "prev_flags": []}
        try:
            st["open_alarms"] = rebuild_open_alarms(server_uri, session_key)
        except Exception as exc:  # best effort
            log("could not rebuild open alarms: %s" % exc)
            st["open_alarms"] = {}
    apply_scenario(st, settings["scenario"], now)

    assets = load_assets()
    writer = Writer("xml", stanza, index)
    first_live = st.get("first_live_tick") or tick_now
    st["first_live_tick"] = first_live

    if settings["backfill_days"] > 0:
        require_demo_index(index)
        want_from = first_live - settings["backfill_days"] * 86400
        have_from = st.get("backfilled_from", first_live)
        if want_from < have_from:
            live_state = {k: st[k] for k in ("scenario", "scenario_start", "prev_flags", "open_alarms", "last_flags")
                          if st.get(k) is not None}
            bst = {"scenario": "healthy-shift", "scenario_start": want_from, "prev_flags": [], "open_alarms": {}}
            # History uses wall-clock shifts so daily totals match the illustrative two-shift day plan.
            history_settings = dict(settings, presentation_shift=False)
            emit_range(writer, bst, assets, history_settings, want_from - (want_from % BACKFILL_STEP_S),
                       have_from - BACKFILL_STEP_S, BACKFILL_STEP_S)
            for aid_, (obj, code, cause, sev, opened) in sorted(bst["open_alarms"].items()):
                end = have_from - BACKFILL_STEP_S
                writer.write(end, "kiruna:alarm", {"scenario": "healthy-shift", "tick_s": BACKFILL_STEP_S,
                                                   "alarm_id": aid_, "action": "close", "asset_id": obj,
                                                   "alarm_code": code, "cause": cause, "severity": sev,
                                                   "opened": opened, "closed": end, "duration_s": end - opened})
            st.update(live_state)
            if st.get("shift_totals") is None and bst.get("shift_totals"):
                st["shift_totals"] = bst["shift_totals"]
            st["backfilled_from"] = want_from
            log("backfill wrote %d events from %d" % (writer.count, want_from))
        try:
            rest(server_uri, session_key,
                 "/servicesNS/nobody/%s/configs/conf-lkab_kiruna_demo_settings/generator" % APP_NAME,
                 {"backfill_days": "0"})
            rest(server_uri, session_key,
                 "/servicesNS/nobody/%s/saved/searches/kiruna_daily_rollup/dispatch" % APP_NAME,
                 {"dispatch.now": "true"})
        except Exception as exc:  # best effort
            log("could not consume backfill flag or dispatch rollup: %s" % exc)

    last = st.get("last_tick")
    start = tick_now if last is None else max(last + TICK_S, tick_now - (MAX_CATCHUP_TICKS - 1) * TICK_S)
    if start <= tick_now:
        st["last_tick"] = emit_range(writer, st, assets, settings, start, tick_now, TICK_S)
    writer.close()
    save_state(state_path, st)
    return 0


def run_simulate(args):
    settings, warnings = validate_settings({"scenario": args.scenario, "generator_enabled": "true",
                                            "presentation_shift": "true" if args.presentation_shift else "false",
                                            "backfill_days": "0"})
    for w in warnings:
        log(w)
    assets = load_assets()
    now = int(args.start or time.time())
    now -= now % TICK_S
    st = {"scenario": args.from_scenario or settings["scenario"], "scenario_start": now - 3600, "prev_flags": []}
    writer = Writer("json", "kiruna_demo_gen://simulate", require_demo_index(args.index))
    if args.from_scenario:
        emit_range(writer, st, assets, settings, now - 5 * TICK_S, now - TICK_S, TICK_S)
    apply_scenario(st, settings["scenario"], now)
    emit_range(writer, st, assets, settings, now, now + (args.ticks - 1) * TICK_S, TICK_S)
    writer.close()
    return 0


def main(argv):
    if len(argv) > 1 and argv[1] == "--scheme":
        print(SCHEME)
        return 0
    if len(argv) > 1 and argv[1] == "--validate-arguments":
        return 0
    if len(argv) > 1 and argv[1].startswith("--"):
        ap = argparse.ArgumentParser(description="Kiirunavaara demo generator, standalone mode")
        ap.add_argument("--simulate", action="store_true")
        ap.add_argument("--check-index")
        ap.add_argument("--scenario", default="healthy-shift")
        ap.add_argument("--from-scenario", help="run 5 ticks of this scenario first, then switch")
        ap.add_argument("--ticks", type=int, default=3)
        ap.add_argument("--start", type=int)
        ap.add_argument("--index", default=DEMO_INDEX)
        ap.add_argument("--presentation-shift", type=int, default=1)
        args = ap.parse_args(argv[1:])
        try:
            if args.check_index is not None:
                require_demo_index(args.check_index)
                print("ok: %s" % args.check_index)
                return 0
            return run_simulate(args)
        except IndexRefused as exc:
            log(str(exc))
            return 2
    return run_modular_input()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
