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
					if t starts with wanted then
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
	return out & "NOT FOUND"
end run
