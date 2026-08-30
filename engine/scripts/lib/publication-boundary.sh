#!/usr/bin/env bash
#
# scripts/lib/publication-boundary.sh — THE PUBLIC/PRIVATE SPLIT, AS MACHINERY.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On 2026-08-29 three measurement briefs and 137 asset files carrying full
# two-channel transcripts of the CEO's own webinar — a named third-party
# speaker, real business content, 28 verbatim quotes inside the brief prose —
# landed in `richos`, the repository `open-source-strategy.md` designates as
# the one that goes PUBLIC. They were moved out at f1bb459.
#
# The source audio was correctly gitignored at docs/reference/local/ the entire
# time. The check that failed was "no media committed", applied by a human on
# three consecutive lands and verified each time, while the sensitive payload
# went in as TEXT.
#
#   THE PRIVACY QUESTION IS WHAT THE BYTES SAY, NOT WHAT FORMAT THEY ARE IN.
#
# That is the CEO's own sentence from the removal commit, and it is the whole
# specification for this file.
#
# It belongs to a family. Four defects found the same week were one shape — a
# correct rule, written down, with nothing enforcing it: a hand-typed "13/13
# guards" that was not the registration; an "18/18 suites" that was one glob's
# size and not the inventory; a `-mc 0` documented as the primary fix and wired
# only to the tier nobody runs; and this one. The first three were fixed by
# deriving the claim from a source of truth. This one is fixed the same way,
# and the rule it must not break is the rule it exists to enforce: DO NOT ADD
# A RULE A HUMAN MUST REMEMBER TO APPLY.
#
# ===========================================================================
# WHAT IS DERIVED, AND FROM WHAT
# ===========================================================================
# Three separate questions, three separate sources of truth, none of them a
# list living in this script:
#
#   1. IS THIS REPOSITORY PUBLICATION-BOUND?
#      Answered by `.publication-boundary` at the repository root — a committed,
#      reviewable declaration. Its presence IS the statement "this tree gets
#      published". Nothing is inferred; adoption is declared, exactly as
#      `orchestration.config` declares engine adoption.
#
#      WHY NOT open-source-strategy.md, which already carries a routing table?
#      Because it was MEASURED against the tree and it does not survive contact
#      with it. The table says `docs/briefs/` "stays private"; two files there
#      are deliberately public today (the pointer README the removal commit
#      itself added, and Clark's Parakeet viability brief — a technology
#      evaluation quoting nothing). A guard derived from that table would block
#      both, and a guard that blocks legitimate work gets disabled, and then
#      protects nothing. The table is strategy narrative; it is not a
#      predicate. See the declaration file's own header for the cross-reference
#      that keeps the two from becoming a second copy of each other.
#
#   2. IS THIS PARTICULAR PATH PUBLICATION-BOUND?
#      Answered by .gitignore, via `git check-ignore`. An ignored path is not
#      going to be published, so writing a transcript there is not merely
#      allowed, it is the CORRECT destination — and it is what the operator was
#      already doing right with the audio. The guard's refusal says so.
#
#   3. IS THIS CONTENT PRIVATE?
#      Answered by the content, by two independent detectors below. Not by its
#      path, not by its extension, not by a maintained list of forbidden files.
#
# ===========================================================================
# THE TWO DETECTORS
# ===========================================================================
#
#   derived-from-private   The sharpest signal available, and it needs no
#                          heuristic at all. Any run of >= MIN_QUOTE_WORDS
#                          consecutive words in the incoming content that
#                          appears VERBATIM in the declared private corpus is
#                          reproduced private material, by construction. This
#                          is what catches quotes embedded in prose — the half
#                          of the real incident no shape rule can see.
#
#                          The corpus is itself DERIVED, never listed: walk the
#                          declared PRIVATE_SOURCES trees and keep the files
#                          that trip the recorded-speech detector below, PLUS
#                          the files that are another RENDERING of one of them.
#                          So the operator declares WHERE private material
#                          lives (a fact only they know) and the machine works
#                          out WHICH files it is (a fact it can check). A dated
#                          list of transcript paths would have gone stale by
#                          the next recording; this cannot.
#
#                          THE SECOND CLAUSE WAS MEASURED INTO EXISTENCE. On
#                          2026-08-30 the real private record held 481 candidate
#                          text files and the shape filter kept TWO — while
#                          seven more two-channel transcripts of the CEO's own
#                          recordings sat in the same tree, invisible, because
#                          whisper's plain `.txt` output carries no timestamps
#                          and no speaker labels. The detector that catches
#                          quotes inside prose was matching against one
#                          recording. A file now also joins when it reproduces
#                          the corpus IN BULK — at least 400 distinct
#                          MIN_QUOTE_WORDS-runs AND at least 8% of its own runs
#                          — which is the difference between another copy of a
#                          recording and a document that quotes one. Corpus:
#                          2 files / 26,339 words -> 10 files / 83,793 words.
#
#                          Composing the detectors this way is what buys the
#                          precision: only speech, and renderings of speech,
#                          enter the corpus, so a shared boilerplate sentence
#                          between two ordinary engineering documents can never
#                          collide with it. Measured both ways, across 5,333
#                          tracked text files in eleven repositories: the
#                          widened corpus blocks the same 8 files the narrow one
#                          did — every one a genuine reproduction of the
#                          recorded talk, in a repository that declares no
#                          boundary — and ZERO files in the publication-bound
#                          repository itself, before and after. The full sweep,
#                          including the two widenings that were REJECTED for
#                          false positives, is in publication-boundary.py above
#                          the closure constants.
#
#   recorded-speech        A structural shape: >= MIN_SPEECH_LINES lines of
#                          `[timestamp] Speaker: prose`, or SRT/WebVTT cues, or
#                          `Speaker (0:12):` turns. This is what catches a
#                          transcript arriving with no corpus declared, or from
#                          a recording nobody has declared yet.
#
#                          PRECISION IS THE CONTRACT here, so it was measured
#                          rather than argued: across 57,034 files in eleven
#                          repositories (richos, femcboost, prospects, deeply,
#                          claude-orchestration-kit, li-profile-data-grabber,
#                          webinar-booster, press-and-publicity, ai-book,
#                          voice-profile, saferecord) it flagged 17 files, and
#                          all 17 were genuine transcripts (.srt course
#                          captions). Zero non-transcript false positives.
#                          Log lines are the near-miss it is built against:
#                          `[12:34:56] ERROR: connection refused` is excluded by
#                          a log-level denylist AND by a prose test that
#                          requires >= 4 words and rejects dense code
#                          punctuation.
#
# ===========================================================================
# WHAT THIS CANNOT CATCH — stated here so nobody has to discover it
# ===========================================================================
#   * A short quote with no declared corpus to match it against. Under
#     MIN_QUOTE_WORDS, or from a recording whose transcript is nowhere on this
#     machine, a quoted phrase is indistinguishable from ordinary prose. The
#     corpus detector is only as wide as PRIVATE_SOURCES.
#   * THE CEO'S OWN WORDS, TYPED, QUOTED NOWHERE ELSE. A sentence he said that
#     lives only inside a private wiki page — never recorded, never transcribed
#     — is in no corpus member, so reproducing it here is invisible to both
#     detectors. This is the widening that was tried and REJECTED WITH NUMBERS,
#     not an oversight: harvesting every quoted prose run out of every private
#     file yields 1,339 runs and blocks 98 of 5,333 public files, 23 of them in
#     the publication-bound repository itself — its README, its WALKTHROUGH, two
#     agent definitions. Doctrine sentences live in both trees on purpose, so
#     that corpus cannot tell a reproduction from a shared rule. An honest
#     measured limit beats a guard nobody trusts; this is the limit.
#   * Paraphrase. Reproducing the SUBSTANCE of a private conversation in the
#     author's own words matches nothing. That is a judgment call and it stays
#     one.
#   * A drip feed. One transcript line per Edit never reaches
#     MIN_SPEECH_LINES in a single tool call — which is exactly why the commit
#     chokepoint exists: it re-reads the whole staged blob, so the drip is
#     caught when it tries to become history.
#   * Deletion of `.publication-boundary` itself. That is a visible, reviewable
#     diff on a committed file rather than a silent bypass, but it is a bypass.
#
# ===========================================================================
# NO SILENT DEGRADATION
# ===========================================================================
# A malformed declaration, an unknown key, a PRIVATE_SOURCES entry that lives
# INSIDE the repository and is not gitignored (so the "private" corpus is
# itself published), or a corpus walk that hits its bound — every one of these
# is BROKEN, and broken BLOCKS with an actionable message. A guard that quietly
# scans a truncated corpus and passes is the "no media committed" check wearing
# a different hat.
#
# The one thing that is NOT broken is a declared source that simply is not on
# this machine — a sibling private repo nobody cloned. That is skipped, and
# every block message names what was skipped, so a refusal never overstates its
# own coverage.
#
# Safe to source repeatedly. Never mutates state, never changes the caller's cwd.

if [ -n "${_PUBLICATION_BOUNDARY_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_PUBLICATION_BOUNDARY_SH_SOURCED=1

# The declaration marker. One file, one name, checked one way, everywhere.
: "${PUBLICATION_DECLARATION:=.publication-boundary}"

_PB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every key the declaration may carry. A key outside this set is a typo, and a
# typo that silently does nothing is the defect class this whole file exists to
# remove — so it is refused, loudly, by name.
_PB_KNOWN_KEYS="PRIVATE_RECORD PRIVATE_SOURCES MIN_SPEECH_LINES MIN_QUOTE_WORDS ALLOWLIST CORPUS_MAX_FILES CORPUS_MAX_BYTES CORPUS_MAY_BE_EMPTY"

# ---------------------------------------------------------------------------
# pb_physical <path>
# ---------------------------------------------------------------------------
# The path with every symlinked ancestor resolved, WITHOUT requiring the path
# itself to exist (a Write targets a file that does not exist yet).
#
# This is not tidiness. `git rev-parse --show-toplevel` always answers with a
# physical path, while a tool payload carries whatever the caller typed — and on
# macOS /tmp, /var and /etc are all symlinks, so the two disagree constantly.
# Measured on the first run of this suite: an ALLOWLIST entry silently stopped
# matching, because the repository root was /private/var/... and the file was
# /var/..., so the prefix test failed and a sanctioned path was refused. A
# guard that refuses a sanctioned path is a guard somebody switches off.
pb_physical() {
    local p="${1:-}" head tail=""
    [ -n "$p" ] || return 1
    head="$p"
    while [ ! -d "$head" ] && [ "$head" != "/" ] && [ -n "$head" ]; do
        tail="$(basename "$head")${tail:+/$tail}"
        head="$(dirname "$head")"
    done
    [ -d "$head" ] || { printf '%s\n' "$p"; return 0; }
    head="$( (cd "$head" 2>/dev/null && pwd -P) || printf '%s' "$head" )"
    printf '%s\n' "${head%/}${tail:+/$tail}"
}

# ---------------------------------------------------------------------------
# pb_repo_root <path>
# ---------------------------------------------------------------------------
# The git top level containing <path> (which need not exist yet — an unborn
# file's directory is what matters). Empty + rc 1 when there is no repository.
pb_repo_root() {
    local p="${1:-}" d
    [ -n "$p" ] || return 1
    d="$p"
    [ -d "$d" ] || d="$(dirname "$p")"
    # Walk up to the first existing ancestor; a Write may target a path several
    # not-yet-created directories deep.
    while [ ! -d "$d" ] && [ "$d" != "/" ] && [ -n "$d" ]; do
        d="$(dirname "$d")"
    done
    [ -d "$d" ] || return 1
    # Physicalised, so this answer and any path compared against it agree.
    local top
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$top" ] || return 1
    pb_physical "$top"
}

# ---------------------------------------------------------------------------
# pb_load_declaration <repo_root>
# ---------------------------------------------------------------------------
# Strict-parses <repo_root>/.publication-boundary into PB_* variables.
#
#   rc 0  a well-formed declaration was loaded  -> enforce
#   rc 1  no declaration                        -> stand down (nothing to enforce)
#   rc 2  BROKEN: present but malformed         -> caller must BLOCK
#
# The file is PARSED, never sourced. Sourcing a file to read four settings out
# of it hands arbitrary code execution to anything that can write a config, and
# buys nothing a twelve-line parser does not already do.
pb_load_declaration() {
    local root="${1:-}" f line key val
    PB_PRIVATE_RECORD=""
    PB_PRIVATE_SOURCES=""
    # Both defaults are MEASURED, not chosen. MIN_SPEECH_LINES=8: at that
    # threshold the shape detector flagged 17 of 52,799 files across eleven
    # repositories and all 17 were genuine transcripts. MIN_QUOTE_WORDS=10:
    # against the real 2026-08-29 transcripts it blocks all three leaked briefs
    # (runs of 36, 13 and 11 words) and 24 of the asset files, while dropping
    # the one collision class a shorter run picks up — stock biography copy
    # like "built and scaled an ai company from zero to" (9 words), which a
    # person says in a recording AND writes in a bio.
    PB_MIN_SPEECH_LINES="8"
    PB_MIN_QUOTE_WORDS="10"
    PB_ALLOWLIST=""
    PB_CORPUS_MAX_FILES="4000"
    PB_CORPUS_MAX_BYTES="67108864"
    # An empty corpus is BROKEN, not CLEAN — see the vacuity floor in
    # publication-boundary.py. This is the committed way to say "this
    # repository genuinely has no private corpus yet", in the spirit of
    # ALLOWLIST and pointedly not an in-the-moment override.
    PB_CORPUS_MAY_BE_EMPTY="0"
    PB_BROKEN_REASON=""

    [ -n "$root" ] || return 1
    f="$root/$PUBLICATION_DECLARATION"
    [ -f "$f" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        # Leading whitespace is tolerated; anything else must be KEY=value.
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *)
                PB_BROKEN_REASON="line is not KEY=value: '$line'"
                return 2 ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        # Strip one layer of matching quotes, and any trailing comment on an
        # unquoted value.
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
            *) val="${val%%#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
        esac
        case " $_PB_KNOWN_KEYS " in
            *" $key "*) ;;
            *)
                PB_BROKEN_REASON="unknown key '$key'. Known keys: $_PB_KNOWN_KEYS. A key this guard does not read is a setting that silently does nothing — refusing rather than pretending it took effect."
                return 2 ;;
        esac
        # Values are inert (never sourced), but shell-substitution syntax in one
        # means the author believed otherwise, and a guard configured under a
        # false belief is a guard nobody can reason about.
        case "$val" in
            *'$('*|*'`'*)
                PB_BROKEN_REASON="value for '$key' contains shell substitution syntax; this file is parsed, never sourced, so it would be taken literally"
                return 2 ;;
        esac
        case "$key" in
            PRIVATE_RECORD)   PB_PRIVATE_RECORD="$val" ;;
            PRIVATE_SOURCES)  PB_PRIVATE_SOURCES="$val" ;;
            MIN_SPEECH_LINES) PB_MIN_SPEECH_LINES="$val" ;;
            MIN_QUOTE_WORDS)  PB_MIN_QUOTE_WORDS="$val" ;;
            ALLOWLIST)        PB_ALLOWLIST="$val" ;;
            CORPUS_MAX_FILES) PB_CORPUS_MAX_FILES="$val" ;;
            CORPUS_MAX_BYTES) PB_CORPUS_MAX_BYTES="$val" ;;
            CORPUS_MAY_BE_EMPTY) PB_CORPUS_MAY_BE_EMPTY="$val" ;;
        esac
    done < "$f"

    case "$PB_MIN_SPEECH_LINES$PB_MIN_QUOTE_WORDS$PB_CORPUS_MAX_FILES$PB_CORPUS_MAX_BYTES" in
        *[!0-9]*|'')
            PB_BROKEN_REASON="MIN_SPEECH_LINES, MIN_QUOTE_WORDS, CORPUS_MAX_FILES and CORPUS_MAX_BYTES must all be non-negative integers"
            return 2 ;;
    esac
    if [ "$PB_MIN_QUOTE_WORDS" -lt 6 ] 2>/dev/null; then
        PB_BROKEN_REASON="MIN_QUOTE_WORDS=$PB_MIN_QUOTE_WORDS is below the floor of 6; runs that short collide with ordinary English, and a guard that blocks ordinary work gets switched off and then protects nothing"
        return 2
    fi
    if [ "$PB_MIN_SPEECH_LINES" -lt 3 ] 2>/dev/null; then
        PB_BROKEN_REASON="MIN_SPEECH_LINES=$PB_MIN_SPEECH_LINES is below the floor of 3"
        return 2
    fi
    case "$PB_CORPUS_MAY_BE_EMPTY" in
        0|1) ;;
        *)
            PB_BROKEN_REASON="CORPUS_MAY_BE_EMPTY must be 0 or 1, not '$PB_CORPUS_MAY_BE_EMPTY'. It switches off the refusal to scan an empty corpus, so a value this guard cannot read is not something to guess at."
            return 2 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# pb_path_is_ignored <repo_root> <abs_path>
# ---------------------------------------------------------------------------
# rc 0 when git would ignore this path — i.e. it is NOT publication-bound and
# private content belongs there. Uses `git check-ignore`, so .gitignore stays
# the single source of truth for the question it already answers.
pb_path_is_ignored() {
    local root="${1:-}" p="${2:-}"
    [ -n "$root" ] && [ -n "$p" ] || return 1
    git -C "$root" check-ignore -q -- "$p" 2>/dev/null
}

# ---------------------------------------------------------------------------
# pb_resolve_sources <repo_root>
# ---------------------------------------------------------------------------
# Turns PB_PRIVATE_SOURCES into two tab-separated lists:
#
#   PB_SOURCES_OK       declared trees that exist and are legitimately private
#   PB_SOURCES_SKIPPED  declared trees that are not on this machine
#
# A tree INSIDE the repository must be gitignored: a "private source" that is
# itself tracked is not private, and building a corpus from it would flag every
# file that legitimately quotes it. That is BROKEN (rc 2), not a warning —
# the declaration is making a claim the repository contradicts.
pb_resolve_sources() {
    local root="${1:-}" s abs main
    PB_SOURCES_OK=""
    PB_SOURCES_SKIPPED=""
    PB_BROKEN_REASON=""
    [ -n "$root" ] || return 2

    # A RELATIVE entry is anchored to the repository — but "the repository" has
    # two locations and only one of them is stable. Every agent works in a
    # LINKED WORKTREE, and a worktree of richos lives at
    # /Users/alex/ab/richos-wt/<branch>/, so `../richos-hq` resolves there to
    # /Users/alex/ab/richos-wt/richos-hq — which does not exist. Measured, on
    # the first live run of this guard: the corpus detector, the sharpest signal
    # this mechanism has, went inert in exactly the place all the work happens,
    # and the only symptom was one honest line in a message nobody would have
    # read on a PASS.
    #
    # So a sibling entry is tried against the worktree first (a source that
    # genuinely lives beside this checkout wins) and then against the MAIN
    # CHECKOUT, which is the repository's canonical location and the one the
    # declaration is written about.
    main=""
    if command -v resolve_main_checkout >/dev/null 2>&1; then
        main="$(resolve_main_checkout "$root" "$root" 2>/dev/null || true)"
        [ "$main" = "$root" ] && main=""
    fi

    for s in $PB_PRIVATE_SOURCES; do
        [ -n "$s" ] || continue
        case "$s" in
            /*) abs="$s" ;;
            *)  abs="$root/$s" ;;
        esac
        if [ ! -e "$abs" ] && [ -n "$main" ]; then
            case "$s" in
                /*) ;;
                *) [ -e "$main/$s" ] && abs="$main/$s" ;;
            esac
        fi
        if [ ! -e "$abs" ]; then
            PB_SOURCES_SKIPPED="${PB_SOURCES_SKIPPED}${s}"$'\t'
            continue
        fi
        abs="$( (cd "$abs" 2>/dev/null && pwd) || printf '%s' "$abs" )"
        # Containment is tested against BOTH checkouts, and the gitignore check
        # runs against whichever one actually contains it. Testing only the
        # worktree would let a source resolved through the main checkout skip
        # the "is it really private?" question entirely — a hole opened by the
        # very fallback added above.
        case "$abs/" in
            "$root"/*)
                if ! pb_path_is_ignored "$root" "$abs"; then
                    PB_BROKEN_REASON="PRIVATE_SOURCES entry '$s' resolves to '$abs', which is INSIDE this repository and is NOT gitignored. A private source that is itself published is not a private source; either gitignore it or move it to the private record."
                    return 2
                fi
                ;;
            *)
                if [ -n "$main" ]; then
                    case "$abs/" in
                        "$main"/*)
                            if ! pb_path_is_ignored "$main" "$abs"; then
                                PB_BROKEN_REASON="PRIVATE_SOURCES entry '$s' resolves to '$abs', which is INSIDE this repository's main checkout and is NOT gitignored. A private source that is itself published is not a private source; either gitignore it or move it to the private record."
                                return 2
                            fi
                            ;;
                    esac
                fi
                ;;
        esac
        PB_SOURCES_OK="${PB_SOURCES_OK}${abs}"$'\t'
    done
    return 0
}

# ---------------------------------------------------------------------------
# pb_allowlisted <repo_root> <abs_path>
# ---------------------------------------------------------------------------
# ALLOWLIST holds repository-relative path prefixes. Deliberate, committed,
# reviewable exemptions — the same affordance SECRET_SCAN_ALLOWLIST gives, for
# the same reason: a guard with no sanctioned way through gets removed whole.
pb_allowlisted() {
    local root="${1:-}" p="${2:-}" rel entry
    [ -n "$root" ] && [ -n "$p" ] || return 1
    [ -n "$PB_ALLOWLIST" ] || return 1
    # Both sides physicalised before the prefix test — see pb_physical for the
    # symlinked-/var incident this exists to stop repeating.
    root="$(pb_physical "$root")"
    p="$(pb_physical "$p")"
    case "$p" in
        "$root"/*) rel="${p#"$root"/}" ;;
        *) rel="$p" ;;
    esac
    for entry in $PB_ALLOWLIST; do
        [ -n "$entry" ] || continue
        case "$rel" in
            "$entry"|"$entry"/*) return 0 ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# pb_scan <job_json_file>
# ---------------------------------------------------------------------------
# Runs the content analysis. The job describes the corpus and the items to
# check; the answer comes back on stdout as one line per finding:
#
#   BLOCK<TAB><path><TAB><detector><TAB><evidence>
#   BROKEN<TAB><reason>
#   CLEAN
#
# Callers MUST treat any other output as fail-closed. Emitting a shape neither
# side understands is how a scanner starts passing for the wrong reason.
pb_scan() {
    local job="${1:-}"
    [ -f "$job" ] || { printf 'BROKEN\tjob file missing: %s\n' "$job"; return 2; }
    python3 "$_PB_LIB_DIR/publication-boundary.py" "$job" 2>/dev/null || {
        printf 'BROKEN\tcontent scanner failed to run (python3 error)\n'
        return 2
    }
}

# ---------------------------------------------------------------------------
# pb_refusal <hook> <what> <findings> <repo_root> <skipped>
# ---------------------------------------------------------------------------
# THE REFUSAL. A block the author cannot act on becomes a block the author
# routes around, so this says what tripped, why it is private, and exactly
# where the content should go instead.
pb_refusal() {
    local hook="$1" what="$2" findings="$3" root="$4" skipped="$5"
    local record="${PB_PRIVATE_RECORD:-the private record repository}"
    echo "=== Publication boundary BLOCKED ==="
    echo "  $what"
    echo ""
    echo "  This repository declares itself PUBLICATION-BOUND ($root/$PUBLICATION_DECLARATION),"
    echo "  and the content below is private material. The privacy question is what the"
    echo "  bytes SAY, not what format they are in — a transcript committed as text is the"
    echo "  same disclosure as the audio it came from."
    echo ""
    printf '%s\n' "$findings" | while IFS=$'\t' read -r _tag _path _detector _evidence; do
        [ "$_tag" = "BLOCK" ] || continue
        echo "    $_path"
        case "$_detector" in
            derived-from-private)
                echo "      -> reproduces private source material verbatim: $_evidence" ;;
            recorded-speech)
                echo "      -> reads as a recording of human speech: $_evidence" ;;
            *)
                echo "      -> $_detector: $_evidence" ;;
        esac
    done
    echo ""
    echo "  WHERE IT SHOULD GO — pick one:"
    echo "    1. The private record: $record. Development notes built on a"
    echo "       recording belong with the recording, not in the tree that gets published."
    echo "    2. A gitignored path in this repository. An ignored path is never"
    echo "       published, so private material is safe there — that is how the source"
    echo "       audio was handled correctly all along."
    echo "    3. Rewrite it so it carries no speech. Conclusions, measurements and"
    echo "       parameter values are not private; the words a person said are."
    echo ""
    echo "  If this content is genuinely publishable, add its repository-relative path"
    echo "  prefix to ALLOWLIST in $PUBLICATION_DECLARATION — a committed, reviewable"
    echo "  exemption, never a silent one."
    if [ -n "$skipped" ]; then
        echo ""
        echo "  NOTE — declared private sources not present on this machine (so nothing"
        echo "  was matched against them): $(printf '%s' "$skipped" | tr '\t' ' ')"
    fi
    echo "(hook: scripts/hooks/$hook)"
}

# ---------------------------------------------------------------------------
# pb_broken_banner <hook> <reason>
# ---------------------------------------------------------------------------
# The loud failure, in the house style: a fixed greppable banner, the reason,
# and the instruction. Broken BLOCKS — a publication guard that cannot tell
# whether it is configured correctly must never wave content through.
pb_broken_banner() {
    local hook="$1" reason="$2"
    echo "=== RICHOS ENGINE: PUBLICATION BOUNDARY BROKEN — REFUSING TO GUESS ==="
    echo "  hook   : scripts/hooks/$hook"
    echo "  file   : $PUBLICATION_DECLARATION"
    echo "  reason : $reason"
    echo "  This guard decides whether private material may enter a repository that"
    echo "  gets published. It cannot answer that from a declaration it does not"
    echo "  understand, and it will not carry on quietly — a defence that reports"
    echo "  'on' while protecting nothing is worse than none."
    echo "======================================================================="
}
