-- Read the RichOS window back out of the macOS accessibility API: every static text and
-- button title, in tree order. What the CEO can see, from outside the process, rather than
-- a screenshot nobody can grep or a claim about what was rendered.
on run argv
	set thePid to (item 1 of argv) as integer
	set out to ""
	tell application "System Events"
		tell (first process whose unix id is thePid)
			set frontmost to true
			delay 0.5
			set els to entire contents of window 1
			repeat with e in els
				try
					set r to role of e
					if r is "AXStaticText" or r is "AXButton" then
						set t to ""
						try
							set t to value of e as text
						end try
						if t is "" then
							try
								set t to title of e as text
							end try
						end if
						if t is not "" then set out to out & r & ": " & t & linefeed
					end if
				end try
			end repeat
		end tell
	end tell
	return out
end run
