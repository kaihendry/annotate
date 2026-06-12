#!/bin/bash

# Raycast script command — put this file in your Raycast scripts directory
# (Raycast → Settings → Extensions → Script Commands → Add Directory),
# then assign a hotkey to "Annotate Screenshot".

# @raycast.schemaVersion 1
# @raycast.title Annotate Screenshot
# @raycast.mode silent
# @raycast.icon ✏️
# @raycast.packageName Annotate

/usr/local/bin/annotate -g >/dev/null 2>&1 &
