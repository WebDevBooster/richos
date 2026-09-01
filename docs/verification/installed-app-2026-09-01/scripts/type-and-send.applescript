on run argv
	set thePid to (item 1 of argv) as integer
	set theText to (item 2 of argv) as text
	set out to ""
	tell application "System Events"
		tell (first process whose unix id is thePid)
			set frontmost to true
			delay 0.6
			set els to entire contents of window 1
			repeat with e in els
				try
					if (role of e) is "AXTextArea" then
						set p to position of e
						set s to size of e
						set cx to (item 1 of p) + ((item 1 of s) / 2)
						set cy to (item 2 of p) + ((item 2 of s) / 2)
						click at {cx, cy}
						delay 0.5
						exit repeat
					end if
				end try
			end repeat
		end tell
		delay 0.3
		keystroke theText
		delay 0.8
		key code 36
	end tell
	return "sent"
end run
