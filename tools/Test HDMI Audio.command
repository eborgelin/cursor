#!/bin/bash
# Double-click: lock HDMI to 16-bit 48 kHz, select it, play a ding, leave it selected.
set +e
echo "Test HDMI Audio"
echo "HDMI stays selected so you can play a short video after a PASS."
echo
"$HOME/Library/Application Support/FixRoomDisplay/test-hdmi-audio.sh"
code=$?
echo
if [[ $code -eq 0 ]]; then
  echo "Next: play 10 seconds of YouTube or a PowerPoint video. If it freezes, press Esc."
else
  echo "Next: double-click Reset HDMI Audio, then run this test again."
  echo "If it still fails, reboot with HDMI already plugged in, then run this test."
fi
echo
read -r -n 1 -s -p "Press any key to close..."
echo
exit $code
