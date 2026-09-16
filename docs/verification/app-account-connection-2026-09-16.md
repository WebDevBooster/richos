# App account connection and process ownership

Source verification for app 1.2.0 on macOS arm64. Real sign-in from a clean
installed app remains pending; these are protocol and renderer tests with a
simulated provider.

The app offers subscription or Console sign-in through the provider's own
browser login command. It checks authentication on return, exposes cancellation
and allows retry. Account connection is also reachable from Settings. Installing
the software no longer claims the account is ready. The app retains only the
connection state, not the provider's account details or credentials.

Owned subprocess groups are fenced before their leader is reaped. This prevents
an obsolete Stop handle from targeting a reused process ID. Native cognition
and browser-login subprocesses use this owner. A leader exit retires remaining
owned descendants; unrelated processes remain untouched. This does not establish
Git completion or workspace cleanup eligibility.

Verified:

- Two real-process ownership tests, including a child that outlives its leader
  and an unrelated process that must survive.
- Eight native cancellation tests and six app tool-grant tests.
- Two provider protocol tests using a fictional executable: verified login,
  account-detail minimization, cancellation and retry.
- Three WebKit renderer scenarios for login return, cancel/Console retry and
  the Settings entry. Provider responses were simulated.
- The existing setup renderer suite passed with 98 assertions.
- Seven Tauri setup-view tests and a successful Tauri build check.
- 546 core library tests passed with one pre-existing ignored case.

No real account was signed in, signed out or switched by these tests. Native
browser authorization and the full installed assignment journey must still be
run against the final immutable candidate in the clean acceptance environment.
