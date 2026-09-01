on run argv
	set thePid to (item 1 of argv) as integer
	set out to ""
	tell application "System Events"
		tell (first process whose unix id is thePid)
			set els to entire contents of window 1
			repeat with e in els
				try
					if (role of e) is "AXTextArea" then
						set out to out & "TEXTAREA=[" & (value of e) & "]" & linefeed
					end if
				end try
			end repeat
			try
				set f to value of attribute "AXFocusedUIElement"
				set out to out & "FOCUS role=" & (role of f) & " desc=" & (description of f) & " val=" & (value of f) & linefeed
			end try
		end tell
	end tell
	return out
end run
