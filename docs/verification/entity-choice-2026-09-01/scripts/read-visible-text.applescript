on run argv
	set thePid to (item 1 of argv) as integer
	set out to ""
	tell application "System Events"
		tell (first process whose unix id is thePid)
			set els to entire contents of window 1
			repeat with e in els
				try
					set r to role of e
					if r is "AXStaticText" then
						set v to value of e
						if v is not missing value and v is not "" then set out to out & "TEXT: " & v & linefeed
					end if
				end try
			end repeat
		end tell
	end tell
	return out
end run
