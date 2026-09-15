@echo off
REM RichOS native-messaging host launcher (Windows). P3 packages the registry registration; this
REM launcher is provided now so the Windows path is not Mac-only in the shared logic. install-host.sh
REM rewrites the two paths on POSIX; a Windows installer will do the equivalent.
set NODE_BIN=__NODE_BIN__
set HOST_JS=__HOST_JS__
"%NODE_BIN%" "%HOST_JS%"
