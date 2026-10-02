# Escalation: quint-opus-blank1: the iPhone cold-start blank check needs two unlanded Isaac branches (tap launch + screen recording)

- id: `esc-20261002T083830Z-b757b930`
- raised: 2026-10-02T08:38:30Z
- from: quint-opus-blank1
- worktree: `/Users/alex/ab/richos-wt/quint-opus-blank1` (branch `cc/quint-opus-blank1`)
- head: `0ba39f9c604b459f9a8392178859b3c12acf5d62`
- state: **proceeding**
- for: lead

## The question

Do you want the iPhone half wired on top of cc/isaac-opus-launch1 (tap launches from the Home Screen, 8d08b6003/abc56788c) plus ab96039a8 from cc/isaac-opus-white1 (phone-ios.py --screen-recording), i.e. may I merge those into cc/quint-opus-blank1, or should I ship the analyzer plus a ready-to-call iPhone entry point and leave the 3-line call site for whoever lands after launch1?

## What was already tried

Base is 0ba39f9c6 (cc/zach-sonnet-vinputs1, per your base correction). On that base perf.py ios times cold starts through Instruments and devicectl launches, never a tap on the Home Screen icon, and phone-ios.py cannot keep a screen recording. Both exist only on Isaac's unlanded branches (git branch --contains 8d08b6003: cc/isaac-opus-launch1, cc/isaac-opus-white1; ab96039a8 only on cc/isaac-opus-white1, whose worktree has uncommitted changes). Also: Homebrew ffmpeg/ffprobe fail to load on this Mac (libvpx.11.dylib missing after libvpx moved to 1.17/.12), so the analyzer decodes through macOS AVFoundation instead; I did not touch Homebrew.

## Proceeding meanwhile

Building the analyzer and its synthetic tests, the Android cold-start check in perf.py (home-screen icon tap, screenrecord, analyzer, fail over 100 ms), the static launch-screen check, and an iPhone entry point that reads phone-ios.py screenRecordings. Verdicts on Andy's real Android recordings follow.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T083830Z-b757b930`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T083830Z-b757b930 --disposition "<what you decided or did>"
