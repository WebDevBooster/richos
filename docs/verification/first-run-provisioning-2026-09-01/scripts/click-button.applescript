-- Press a button in the RichOS window by its title, through the macOS accessibility API.
-- Adapted from `installed-app-2026-09-01/scripts/pick-company.applescript`, which drove the
-- company picker the same way: no hand, and the click lands where the AX tree says the
-- control is rather than at coordinates typed by a human.
on run argv
	set thePid to (item 1 of argv) as integer
	set wanted to (item 2 of argv) as text
	set out to ""
	tell application "System Events"
		tell (first process whose unix id is thePid)
			set frontmost to true
			delay 0.5
			set els to entire contents of window 1
			repeat with e in els
				try
					set t to title of e
					if t is equal to wanted then
						set p to position of e
						set s to size of e
						set cx to (item 1 of p) + ((item 1 of s) / 2)
						set cy to (item 2 of p) + ((item 2 of s) / 2)
						set out to out & "clicking [" & t & "] at " & cx & "," & cy & linefeed
						click at {cx, cy}
						delay 1
						return out
					end if
				end try
			end repeat
		end tell
	end tell
	return out & "NOT FOUND: " & wanted
end run
