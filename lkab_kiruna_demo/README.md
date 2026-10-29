# Kiirunavaara Mine Demo (lkab_kiruna_demo) 0.1.0

Splunk app for a sales demo of an underground iron-ore mine modeled loosely on Kiirunavaara.

**Unofficial and illustrative.** This app is not made, endorsed or reviewed by LKAB. All data is
synthetic and comes from the bundled generator. Asset names, levels, rates and plans are demo values
and are not LKAB production data. The mine cross-section is an original schematic, not to scale.

## What is in 0.1.0

- Setup page (first run) and Demo Control view to pick a scenario, enable the generator, and
  set the backfill window (0 to 14 days).
- Modular input `kiruna_demo_gen` that writes only to the `kiruna_events` index (21-day retention),
  with a one-time backfill and minute ticks after that.
- Scheduled searches `kiruna_refresh_summaries` (every minute) and `kiruna_daily_rollup` (00:15),
  writing the lookups the dashboards read.
- Dashboard Studio views: Shift Brief, Mine Cross-Section, Level Operations, Asset Health,
  Asset Timeline, Outbound Overview, Stuck and Recovery, Service Health.
- Scenarios: healthy-shift, truck-stuck, loader-stopped-drawpoint, cascade-crusher-hoist, recovery.

Not in 0.1.0: ITSI objects, presenter lock, custom visualizations, HEC.

## Requirements

Recorded on Splunk Enterprise `Splunk 10.0.11 (build c1c0c3ccd7cb)`. Other 10.x builds are expected
to work but were not tested. The generator needs only the Python 3 that ships with Splunk.

## Install

1. Package: `tar -czf lkab_kiruna_demo-0.1.0.tgz lkab_kiruna_demo` from the repository root
   (exclude `README.md` only if your packaging policy requires it).
2. In Splunk Web: Apps > Manage Apps > Install app from file, upload the package, and restart
   when asked. From the CLI: `splunk install app lkab_kiruna_demo-0.1.0.tgz` and restart.
3. Open the app. On first run Splunk opens the setup page. Keep the defaults (generator on,
   presentation shift on, 14 days backfill) and save. You land on Shift Brief.
4. Backfill writes about 160k events (about 50 MB of license) once. After that the generator
   writes about 10k events, roughly 3.5 MB, per day.

Use Demo Control to switch scenarios during a demo. Changes show on the dashboards within one to
two summary cycles (60 to 120 seconds).

## Remove

Disable the app, delete `$SPLUNK_HOME/etc/apps/lkab_kiruna_demo`, restart, and delete the
`kiruna_events` index directory if you want the data gone.

## Developing

Views are generated. Edit `tools/build_views.py` and run `python3 tools/build_views.py` from the
repository root. Do not hand-edit the view XML.

Run the generator without Splunk:

```
python3 lkab_kiruna_demo/bin/kiruna_demo_gen.py --simulate --scenario cascade-crusher-hoist --ticks 5
```
