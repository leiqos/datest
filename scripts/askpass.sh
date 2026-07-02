#!/bin/bash
# SUDO_ASKPASS helper. When a Homebrew cask genuinely needs admin rights,
# sudo runs this to show a native macOS password prompt. The password goes
# from the dialog straight to sudo's stdin — the app never sees or stores it.
# Cancelling the dialog makes osascript exit non-zero, which aborts sudo.
osascript 2>/dev/null <<'EOF'
set response to display dialog "Datest needs your administrator password to finish a Homebrew operation." with title "Datest — Homebrew" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with icon caution
text returned of response
EOF
