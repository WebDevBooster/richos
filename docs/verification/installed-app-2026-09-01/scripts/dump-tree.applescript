on run argv
	set thePid to (item 1 of argv) as integer
	set out to ""
	tell application "System Events"
		tell (first process whose unix id is thePid)
			set els to entire contents of window 1
			repeat with e in els
				try
					set r to role of e
					set d to ""
					try
						set d to description of e
					end try
					set v to ""
					try
						set v to (value of e) as text
					end try
					set t to ""
					try
						set t to title of e
					end try
					set out to out & r & " | title=" & t & " | desc=" & d & " | val=" & v & linefeed
				end try
			end repeat
		end tell
	end tell
	return out
end run
