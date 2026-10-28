# Settings for the Kiirunavaara Mine Demo generator.
# This file is created under local/ by the setup view or Demo Control
# through the configurations REST endpoint. The app ships no default file.
# None of these settings is a secret.
# The modular input re-validates every value before acting, because a value
# can also arrive through a direct conf edit or a raw REST call.

[generator]
scenario = <string>
* Active demo scenario.
* Must be one of: healthy-shift, truck-stuck, loader-stopped-drawpoint,
  cascade-crusher-hoist, recovery.
* Any other value is ignored and the generator uses healthy-shift.
* No default in this file.

generator_enabled = <bool>
* Whether the modular input writes events to the kiruna_events index.
* No default in this file.

presentation_shift = <bool>
* true: three back-to-back 8 hour production shifts (06, 14, 22 Europe/Stockholm),
  so a talk at any hour has a shift in progress.
* false: wall-clock shifts 06:00-14:00 and 14:00-22:00, night idle 22:00-06:00.
* The setup view defaults this to true.
* No default in this file.

backfill_days = <integer>
* Days of history to write once, ending at the first live tick.
* Must be an integer from 0 through 14 inclusive.
* The generator writes only the part of the window it has not already written,
  then sets this value back to 0 (the request is consumed).
* No default in this file.
