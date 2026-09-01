#!/usr/bin/env bash
#
# check_narration_shape.sh — pin the structure that makes the narration
# accessibility property structural rather than remembered.
#
# BUILD-PLAN.md § M3 requires that commissioning captions render with voice
# off, with TTS unavailable, and with the synthesizer silently failing.
# Narrator.swift satisfies that by SHAPE: the caption is advanced by a Task
# that never awaits the synthesizer, and the synthesizer has exactly one
# declaration site. The shape is structural; the CLAIM that the shape holds
# is a census, and a census is a statement about the file today. It decays
# silently the first time a second call site appears — at which point the
# property is back to being remembered, with no compiler behind it.
#
# This script is the compiler behind it. A second AVSpeechSynthesizer, a
# caption write outside Narrator.reveal, or a non-stopSpeaking touch of the
# synthesizer outside speak() moves a pinned count and exits non-zero.
#
# Exit codes
#   0  shape holds
#   2  GUARD VOID — an instrument failed (path untracked, control dead)
#   3  DRIFT — a pinned count moved
#
# Aperture: run from anywhere inside the worktree; measures the WORKING TREE
# via `git grep --untracked`, so an uncommitted second call site is caught.

set -u

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "GUARD VOID: not inside a git worktree" >&2
    exit 2
}
cd "$REPO_ROOT" || exit 2

# --untracked admits new files that are not yet committed; --exclude-standard is
# deliberately NOT passed, so a .gitignore cannot hide a second call site from
# the guard. Whole-tree legs use $SCAN; single-file legs address a tracked path
# directly and do not need it.
SCAN="--untracked --no-exclude-standard"

SUBJECT="Sources/ZeusApp/Narrator.swift"
VIEW="Sources/ZeusApp/Commissioning.swift"
DECL_FORM='private let synth = AVSpeechSynthesizer()'

# ---------------------------------------------------------------------------
# Instrument liveness. Every count below is meaningless if these fail.
# ---------------------------------------------------------------------------

# Tracked-ness, tri-state — rc=1 is a refusal (path absent), anything else is
# an instrument fault. Same shape as the licence guard's :166 repair: a false
# --error-unmatch and a true zero-hits are otherwise the same observable.
for p in "$SUBJECT" "$VIEW"; do
    rc=0
    git ls-files --error-unmatch -- "$p" >/dev/null 2>/tmp/nsg.err || rc=$?
    case "$rc" in
        0) : ;;
        1) echo "GUARD VOID: '$p' is NOT TRACKED (rc=1, $(wc -c </tmp/nsg.err | tr -d ' ')B)" >&2
           rm -f /tmp/nsg.err; exit 2 ;;
        *) echo "GUARD VOID: ls-files fault on '$p' (rc=$rc, $(wc -c </tmp/nsg.err | tr -d ' ')B)" >&2
           rm -f /tmp/nsg.err; exit 2 ;;
    esac
done
rm -f /tmp/nsg.err

# POS control — a needle known present. If this reads 0 the engine is dead
# and every zero below is an instrument fault wearing the costume of compliance.
pos=$(git grep -c -F -e 'import AVFoundation' -- "$SUBJECT" | cut -d: -f2)
[ "${pos:-0}" -ge 1 ] || { echo "GUARD VOID: POS control dead (import AVFoundation = ${pos:-0})" >&2; exit 2; }

# NEG control — generated at RUNTIME, never a literal.
# A sentinel written into a tracked script is guaranteed present in the corpus
# that script greps, so a hardcoded needle is dead on its first commit.
neg_needle="zzznope-narr-$$-${RANDOM}"
neg=$(git grep -c -F -e "$neg_needle" -- "$SUBJECT" | cut -d: -f2)
[ "${neg:-0}" -eq 0 ] || { echo "GUARD VOID: NEG control alive ($neg_needle = $neg)" >&2; exit 2; }

fail=0
pin() { # pin <label> <expected> <actual>
    if [ "$3" -eq "$2" ]; then
        printf '  ok    %-46s %s\n' "$1" "$3"
    else
        printf '  DRIFT %-46s %s (pinned %s)\n' "$1" "$3" "$2"
        fail=1
    fi
}

# ---------------------------------------------------------------------------
# Pinned counts.
# ---------------------------------------------------------------------------

# 1. The type appears in exactly one file.
files=$(git grep $SCAN -l -F -e 'AVSpeechSynthesizer' -- 'Sources/*.swift' | wc -l | tr -d ' ')
pin 'files naming AVSpeechSynthesizer' 1 "$files"

# 2. Exactly one CODE occurrence. The doc comment above the class names the
#    type too, so a raw count of 2 conflates the guard's subject with the
#    prose describing it — a needle built from the documentation cannot tell
#    a live call site from a sentence about call sites.
code_occ=$(git grep -n -F -e 'AVSpeechSynthesizer' -- "$SUBJECT" \
    | grep -vc ':[[:space:]]*//')
pin 'CODE occurrences of AVSpeechSynthesizer' 1 "$code_occ"

# 3. And that one occurrence is the declaration, verbatim.
decl=$(git grep -c -F -e "$DECL_FORM" -- "$SUBJECT" | cut -d: -f2)
pin 'declaration site, verbatim' 1 "${decl:-0}"

# 4. Every touch of the instance. Five: the declaration, the voiceOn didSet,
#    stop(), and two inside speak(). Any sixth is a new coupling and must be
#    read by a human before it lands.
touches=$(git grep -n -e '\bsynth\.' -e "$DECL_FORM" -- "$SUBJECT" \
    | grep -vc ':[[:space:]]*//')
pin 'code touches of the synth instance' 5 "$touches"

# 5. The load-bearing one. Outside speak(), every touch of the synthesizer is
#    a stopSpeaking — i.e. it can SUPPRESS voice and can never gate, block or
#    fail the caption. `synth.speak(` appears exactly once, inside speak().
speak_calls=$(git grep -c -F -e 'synth.speak(' -- "$SUBJECT" | cut -d: -f2)
pin 'synth.speak( call sites' 1 "${speak_calls:-0}"
stop_calls=$(git grep -c -F -e 'synth.stopSpeaking(' -- "$SUBJECT" | cut -d: -f2)
pin 'synth.stopSpeaking( call sites' 3 "${stop_calls:-0}"

# 6. The caption is written in exactly two places, both in the reveal Task,
#    both in this file. A caption write anywhere else is a path by which the
#    caption could come to depend on voice state.
cap_writes=$(git grep $SCAN -n -e '\bcaption = ' -e '\.caption = ' -- 'Sources/*.swift' \
    | grep -vc ':[[:space:]]*//')
pin 'caption assignment sites, whole tree' 2 "$cap_writes"

# 6b. THE AVFOUNDATION SURFACE, not just the synthesizer type. Zeus100's
#     count-neutral hunt closed the named-symbol routes by accident:
#     `AVSpeechSynthesizerDelegate` CONTAINS the pinned needle, so conformance
#     moves leg 2, and `synth.isSpeaking` moves leg 4. The survivor found here
#     names neither — `guard !AVSpeechSynthesisVoice.speechVoices().isEmpty
#     else { return }` above the reveal Task makes the caption depend on TTS
#     AVAILABILITY while legs 1-9 all stay green. It is caught only at the
#     WIDER needle: AVSpeech* code occurrences are exactly 4 (the declaration,
#     the utterance, and pickVoice's two), all inside speak() or its helper.
#     A fifth is a new AVFoundation touch and must be read by a human.
av_surface=$(git grep -n -F -e 'AVSpeech' -- "$SUBJECT" | grep -vc ':[[:space:]]*//')
pin 'AVSpeech* code occurrences' 4 "${av_surface:-0}"

# 6c. And all of them sit at or below speak(). The reveal Task runs above it,
#     so an AVFoundation touch between the declaration and the reveal is a
#     coupling regardless of which symbol it spells.
reveal_line=$(git grep -n -F -e 'revealTask = Task' -- "$SUBJECT" | head -1 | cut -d: -f2)
first_av=$(git grep -n -F -e 'AVSpeech' -- "$SUBJECT" | grep -v ':[[:space:]]*//' \
    | head -1 | cut -d: -f2)
[ -n "${reveal_line:-}" ] && [ -n "${first_av:-}" ] || {
    echo "GUARD VOID: line-order leg could not locate its anchors" >&2; exit 2; }
av_before_reveal=$(git grep -n -F -e 'AVSpeech' -- "$SUBJECT" | grep -v ':[[:space:]]*//' \
    | cut -d: -f2 | awk -v r="$reveal_line" 'NR>1 && $1<r' | wc -l | tr -d ' ')
pin 'AVSpeech touches between decl and reveal' 0 "${av_before_reveal:-0}"

# 7. No await on the synthesizer, anywhere. This is the property that makes
#    the reveal Task independent of TTS: awaiting the synthesizer is the one
#    edit that would make a hung or unavailable voice engine stall captions.
awaits=$(git grep $SCAN -c -e 'await[^)]*synth' -- 'Sources/*.swift' | wc -l | tr -d ' ')
pin 'awaits on the synthesizer' 0 "${awaits:-0}"

# 8. The view renders the caption from the Narrator only. If Commissioning
#    ever reads synthesizer state directly, the separation is gone at the
#    consumer end even though Narrator.swift is untouched.
view_av=$(git grep -c -e 'AVSpeech' -e '\bsynth\.' -- "$VIEW" | cut -d: -f2)
pin 'synthesizer references in the view' 0 "${view_av:-0}"

echo
if [ "$fail" -eq 0 ]; then
    echo "OK: narration shape holds — 1 declaration site, 1 speak call, captions independent"
    exit 0
fi
echo "DRIFT: the narration accessibility property is no longer structural." >&2
echo "Either restore the shape, or update the pins AND the doc comment in $SUBJECT." >&2
exit 3
