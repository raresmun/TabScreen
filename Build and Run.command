#!/bin/bash
# Double-click this file in Finder to build TabScreen and start it.
cd "$(dirname "$0")"
if pgrep -x TabScreen >/dev/null; then
  echo "Stopping the running TabScreen…"
  pkill -x TabScreen
  sleep 1
fi
if bash ./build.sh; then
  open TabScreen.app
  echo ""
  echo "TabScreen is running – look for the tablet icon in the menu bar at the top of the screen."
  echo "You can close this window."
else
  echo ""
  echo "The build failed. Tell Claude – the details are in build.log in this folder."
fi
