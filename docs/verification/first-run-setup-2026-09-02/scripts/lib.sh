#!/usr/bin/env bash
# Shared by gap-proof.sh and fresh-install.sh.
#
# TWO THINGS IT EXISTS FOR, and both are constraints rather than conveniences:
#
#   1. A BUNDLE OUTSIDE THE REPOSITORY. `engine.rs` resolves seven candidates and two of them
#      walk the ancestors of the EXECUTABLE and of the working directory looking for an
#      `engine/`. A binary run from `app/src-tauri/target/debug/` is nine levels under a repo
#      that HAS one, so it would find the dogfood engine and prove nothing about a customer.
#      Assembling a minimal `.app` in a scratch directory outside the repository is what makes
#      the customer condition real instead of asserted.
#
#   2. KILLING WHAT WE START, AND COUNTING. A harness left 157 RichOS processes on the CEO's
#      Dock on 2026-09-01. `kill_ours` kills only processes whose executable path is the one
#      this run created, and `residue` prints the number that survived — so the count is a
#      measurement and not a hope.

RICHOS_BUNDLE_ID="com.richos.app.verify"

# Assemble a minimal, runnable `.app` around a freshly built binary, at $1.
assemble_bundle() {
    local app="$1" binary="$2"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$binary" "$app/Contents/MacOS/richos-tauri"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>richos-tauri</string>
  <key>CFBundleIdentifier</key><string>$RICHOS_BUNDLE_ID</string>
  <key>CFBundleName</key><string>RichOS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
    # NOT SIGNED, and said rather than left to be noticed: this bundle exists to exercise the
    # RESOLVER under a GUI launch's conditions. Signing and notarization are a different
    # proof and live in `docs/verification/developer-id-signing-2026-08-31/`.
    echo "$app/Contents/MacOS/richos-tauri"
}

# Boot the bundle with a built environment and a working directory of `/` — the GUI condition
# LaunchServices produces, reproduced as a real process rather than as a value someone passed.
# Captures to $LOG, waits for a decisive line, then kills.
boot_and_capture() {
    local exe="$1" home="$2" log="$3" wait_for="$4" limit="${5:-40}"
    : > "$log"
    ( cd / && /usr/bin/env -i \
        HOME="$home" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        "$exe" >> "$log" 2>&1 & echo $! > "$log.pid" )
    local n=0
    while [ $n -lt "$limit" ]; do
        grep -qE "$wait_for" "$log" 2>/dev/null && break
        n=$((n + 1)); /bin/sleep 1
    done
    /bin/sleep 2
    echo "(waited ${n}s for: $wait_for)"
}

# Kill ONLY processes running the executable this run created.
kill_ours() {
    local exe="$1"
    local pids
    pids="$(/usr/bin/pgrep -f "$exe" 2>/dev/null)"
    for p in $pids; do kill "$p" 2>/dev/null; done
    /bin/sleep 2
    for p in $pids; do kill -9 "$p" 2>/dev/null; done
    /bin/sleep 1
}

# How many of ours are still running. A NUMBER, printed, every time.
residue() {
    local exe="$1"
    local n
    n="$(/usr/bin/pgrep -f "$exe" 2>/dev/null | wc -l | tr -d ' ')"
    echo "residue (processes still running this run's executable): $n"
    [ "$n" = "0" ] || /usr/bin/pgrep -lf "$exe"
}

# THE CEO'S OWN FILES, fingerprinted. Read-only; nothing below ever writes to them.
his_state() {
    {
        echo "--- ~/.claude/richos-engine ---"
        if [ -L "$HOME/.claude/richos-engine" ]; then
            echo "symlink -> $(readlink "$HOME/.claude/richos-engine")"
        elif [ -d "$HOME/.claude/richos-engine" ]; then
            echo "directory"
        else
            echo "ABSENT"
        fi
        echo "--- ~/Library/Application Support/RichOS/loro-root ---"
        if [ -L "$HOME/Library/Application Support/RichOS/loro-root" ]; then
            echo "symlink -> $(readlink "$HOME/Library/Application Support/RichOS/loro-root")"
        elif [ -e "$HOME/Library/Application Support/RichOS/loro-root" ]; then
            echo "present"
        else
            echo "ABSENT"
        fi
        echo "--- ~/Library/Application Support/com.richos.app ---"
        if [ -d "$HOME/Library/Application Support/com.richos.app" ]; then
            ( cd "$HOME/Library/Application Support/com.richos.app" \
                && find . -type f -exec shasum -a 256 {} \; | sort -k2 )
        else
            echo "ABSENT"
        fi
    } 2>&1
}
