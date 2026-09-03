#!/usr/bin/env bash

# Script to toggle a Kakoune notes instance with persistence
# This script enables the note button to:
# 1. Start a new Kakoune session in your notes directory when pressed for the first time
# 2. Hide the Kakoune window (toggle floating state) when pressed again
# 3. Show the Kakoune window again when pressed a third time
#
# Usage: toggle-kakoune-notes.sh

SESSION_NAME="kak-notes"
NOTES_DIR="$HOME/Documents/notes"

# Create notes directory if it doesn't exist
mkdir -p "$NOTES_DIR"

# Function to check if Kakoune session exists
session_exists() {
    kak -l 2>/dev/null | grep -q "^$SESSION_NAME"
}

# Main logic
if session_exists; then
    # Session exists, toggle visibility of the window
    echo "Kakoune session $SESSION_NAME found"

    # Try to find and toggle the floating state of existing kak-notepad window
    if niri msg action focus-window --id $(niri msg -j windows | jq -r '.[] | select(.title | test("kak-notes"; "i")) | .id') 2>/dev/null; then

        # Window found - toggle its floating state (this will hide/show it)
        # echo "Toggling visibility of existing Kakoune window"
        # niri msg action "toggle-window-floating"
    else
        # Session exists but no window found - this shouldn't happen normally,
        # but start a new window just in case
        echo "Session exists but no window found, starting new window..."
        gnome-terminal --title="kak-notepad" -- kak -s "$SESSION_NAME" "${NOTES_DIR}/scratch"
    fi
else
    # No session, start a new one
    echo "Starting new Kakoune session in $NOTES_DIR"
    gnome-terminal --title="kak-notepad" -- kak -s "$SESSION_NAME" "${NOTES_DIR}/scratch"
fi

echo "Note: The Kakoune instance will persist in the background and can be toggled with Mod+P"
