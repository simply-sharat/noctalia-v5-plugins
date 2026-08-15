#!/bin/sh
# Focus or launch the BudsLink app.
#
# BudsLink is a Gio.Application singleton: launching `budslink` again while it
# is already running exits without showing anything, and the app's own
# present() may not move focus across workspaces. On niri we focus the window
# directly via IPC; elsewhere we use D-Bus activation and fall back to
# launching the app if it isn't running.

BUS_NAME="io.github.maniacx.BudsLink"
OBJ_PATH="/io/github/maniacx/BudsLink"

if [ "${XDG_SESSION_DESKTOP:-}" = "niri" ] || [ "${XDG_CURRENT_DESKTOP:-}" = "niri" ]; then
    WID=$(niri msg windows 2>/dev/null | awk '
        /^Window ID/ { id = $3; sub(":", "", id) }
        /App ID: "io.github.maniacx.BudsLink"/ { print id; exit }')
    if [ -n "$WID" ]; then
        exec niri msg action focus-window --id "$WID"
    fi
fi

if ! gdbus call --session --dest "$BUS_NAME" --object-path "$OBJ_PATH" \
        --method org.freedesktop.Application.Activate '{}' >/dev/null 2>&1; then
    exec budslink
fi
