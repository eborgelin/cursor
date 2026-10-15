#!/bin/bash
# Double-click: restart coreaudiod (password dialog), then retest HDMI sound.
set +e
echo "Reset HDMI Audio"
echo "macOS will ask for your password so it can restart Core Audio."
echo
osascript -e 'do shell script "killall coreaudiod" with administrator privileges'
kick=$?
if [[ $kick -ne 0 ]]; then
  echo "Core Audio reset was cancelled or failed (exit $kick)."
  echo
  read -r -n 1 -s -p "Press any key to close..."
  echo
  exit $kick
fi
echo "Core Audio restarted. Waiting 4 seconds for HDMI to reappear..."
sleep 4
echo
"$HOME/Library/Application Support/FixRoomDisplay/test-hdmi-audio.sh"
code=$?
echo
if [[ $code -eq 0 ]]; then
  echo "Next: play 10 seconds of YouTube or a PowerPoint video. If it freezes, press Esc."
else
  echo "HDMI audio is still wedged after a Core Audio restart."
  echo "Reboot with the HDMI cable already connected, log in, then run Test HDMI Audio."
  echo "If the beep still fails, use DisplayPort or analog room audio (see chat)."
fi
echo
read -r -n 1 -s -p "Press any key to close..."
echo
exit $code
