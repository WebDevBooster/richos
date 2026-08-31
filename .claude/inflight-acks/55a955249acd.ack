sha: 55a955249acd15e465cd073b0b509cbf7efae4c5
impact: stale-record
detail: My brief's premise flipped: the CEO enrolled in the Apple Developer Program today, so richos-hq/wiki/packaging-and-signing.md decision 1.1 is CLOSED. package-app.sh at this tip still tells the operator, in two places (its header comment and its no-identity refusal at lines 303-305), that enrolling is an OPEN CEO decision and that the developer-id path 'selects itself NEVER' because of it. That justification is now factually wrong and I must rewrite it rather than build on it. I also assumed a notarization step existed behind RICHOS_NOTARIZE=1; it does not - the script validates APPLE_ID/APPLE_PASSWORD/APPLE_TEAM_ID and then never calls notarytool or stapler at all, so 'notarized' was never true on any path.
paths: app/scripts/package-app.sh app/src-tauri/Entitlements.plist
worktree: /Users/alex/ab/richos-wt/echo-signing-2026-08-31
written: 2026-08-31T13:30:16Z
