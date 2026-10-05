#!/usr/bin/env bash
# Click macOS Photos "Allow Full Access" / "Allow Access to All Photos" dialogs.
# Requires Accessibility permission for Terminal/Cursor (System Settings → Privacy & Security → Accessibility).
set -euo pipefail

osascript <<'APPLESCRIPT'
tell application "System Events"
  set buttonTitles to {"Allow Full Access", "Allow Access to All Photos", "Allow access to all photos", "Allow All Photos", "Allow", "OK"}
  set processNames to {"PhotoCurator", "Photo Curator", "tccd", "UserNotificationCenter", "SecurityAgent", "coreauthd", "UniversalAccessAuthWarn"}
  set clicked to false
  set detail to ""

  repeat with procName in processNames
    if not (exists process procName) then
      -- continue
    else
      try
        tell process procName
          set wins to windows
          repeat with w in wins
            try
              set btns to buttons of w
              repeat with b in btns
                set t to name of b as text
                repeat with wanted in buttonTitles
                  if t is equal to (wanted as text) then
                    click b
                    set clicked to true
                    set detail to "clicked " & t & " in " & procName
                    exit repeat
                  end if
                end repeat
                if clicked then exit repeat
              end repeat
            end try
            -- Sheets / groups
            try
              repeat with s in sheets of w
                repeat with b in buttons of s
                  set t to name of b as text
                  repeat with wanted in buttonTitles
                    if t is equal to (wanted as text) then
                      click b
                      set clicked to true
                      set detail to "clicked " & t & " in sheet of " & procName
                      exit repeat
                    end if
                  end repeat
                  if clicked then exit repeat
                end repeat
                if clicked then exit repeat
              end repeat
            end try
            if clicked then exit repeat
          end repeat
        end tell
      end try
    end if
    if clicked then exit repeat
  end repeat

  if clicked then
    return detail
  else
    return "no_photos_access_dialog"
  end if
end tell
APPLESCRIPT
