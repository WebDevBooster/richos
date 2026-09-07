# Pending service installation and boot discovery

Review after the installed lifecycle fixture found that the installer placed a
RunAtLoad/KeepAlive plist in `/Library/LaunchDaemons/`. Although no launchctl
bootstrap had occurred and the service was confirmed unloaded, macOS could
discover that file at the next boot. The earlier `activated: false` result did
not establish that installation would remain inactive across a reboot.

The installer now writes the plist with a `.pending` suffix beneath its protected
application-support directory, outside launchd discovery. It refuses existing
published service files, public configuration or a production socket before
changing installed policy. A regression verifies that pending installation leaves
the launchd directory untouched and preserves preexisting published artifacts.
All 35 CLTools broker/installer tests passed after this change.

The host correction pins the exact previously installed plist bytes and inode,
validates root protection, confirms the fixed service is unloaded and moves the
same file into protected pending storage. Both containing directories are
fsynced. Unexpected bytes, a loaded service or an existing destination refuse the
move. No existing service is stopped and no launchd job is loaded.

Apple documents boot discovery of system daemon property lists in
[Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html).
The host migration receipt will establish when the actual file correction is
complete; the source change alone does not remove an earlier installed plist.
