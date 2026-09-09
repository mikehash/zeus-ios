#!/bin/bash
# ONE recipe for "the tree object of <path> AS IT SITS IN THE WORKTREE".
#
# Sourced by BOTH sides of the crate-provenance pair:
#   producer  scripts/build-xcframework.sh   — stamps what it actually compiled
#   consumer  scripts/check_crate_tree.sh    — recomputes it now and compares
#
# ── Why a shared function and not two copies ────────────────────────────────
#
# The defect this pair exists to catch is "the .a was built from sources the
# tree no longer holds". If producer and consumer computed the aperture with
# two independently-written expressions, a divergence in the RECIPE would
# present as a DRIFT in the SUBJECT — the guard would red on a byte-correct
# artifact and the reader would go rebuild a binary that was already right.
# That already happened once one layer over: build-xcframework.sh:138 wrote a
# hardcoded `2a2168cd` into the bindings header while :184 computed the real
# dep-pin, so one producer run emitted two self-descriptions that disagreed.
#
# A shared FUNCTION is not the same thing as a shared VALUE. Both sides run
# this code, each on its own invocation, at its own moment — that is the whole
# comparison. What would destroy the guard is one side reading the other's
# recorded number instead of measuring; that is why the consumer never sources
# the producer's environment.
#
# ── Why the worktree and not `HEAD:<path>` ─────────────────────────────────
#
# `git rev-parse HEAD:<path>` reads the COMMITTED tree. Both halves of this
# pair used to do that, so they agreed on a clean tree and were JOINTLY BLIND
# on a dirty one: build clean, then edit a crate source and do not rebuild, and
# the old guard printed `OK` because HEAD had not moved — while the linked .a
# no longer corresponded to the sources on disk. The uncommitted state is
# exactly the state a developer builds and tests in, so the aperture that
# excluded it excluded the only interesting case.
#
# A temp index is how you ask git about the worktree without touching the real
# index or the stage. `git add` into GIT_INDEX_FILE hashes the files as they
# are on disk right now; `write-tree` turns that into a real tree object.
# Gitignored paths (rust/zeus-core-bridge/target/, 1.5 GB of build output) are
# skipped by `git add` for free, so the aperture stays the sources.
#
# ── mktemp -u, and why -u ──────────────────────────────────────────────────
#
# `GIT_INDEX_FILE=$(mktemp)` hands git an EXISTING zero-byte file, which git
# refuses: `fatal: index file smaller than expected`, rc=128 on both `add` and
# `write-tree`. Measured, not theorised — the recipe was written that way once
# and died. Worse than dying loudly: in a value-capture the rc is invisible,
# the tree comes back empty, and the next line interpolates it into `":<path>"`
# so git answers about a DIFFERENT SUBJECT (`path 'x' exists on disk, but not
# in the index`) and sends the reader hunting pathspec bugs. `-u` yields a
# NAME that does not exist yet, which is what git wants.
#
# ── Contract ───────────────────────────────────────────────────────────────
#
#   worktree_subtree <path>
#     stdout: the 40-hex tree object of <path> in the worktree
#     rc 0    measured
#     rc 2    could not measure (git faulted, or the result is not hex)
#             — callers MUST treat this as VOID, never as "no drift"
#
# Nothing here writes to the repo index, the stage, or HEAD.

worktree_subtree() {
    local path="$1"
    local idx tree root rc=0

    [ -n "$path" ] || { echo "worktree_subtree: no path given" >&2; return 2; }

    idx="$(mktemp -u)"                  # -u: a NAME. See above.

    # Each git invocation's rc is asserted ALONE, before its value is used: a
    # dead git and a healthy-empty result are the same empty string downstream.
    GIT_INDEX_FILE="$idx" git add -- "$path" 2>/tmp/worktree_tree.$$.err || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "worktree_subtree: git add -- $path exited $rc" >&2
        sed 's/^/      /' /tmp/worktree_tree.$$.err >&2 2>/dev/null
        rm -f "$idx" /tmp/worktree_tree.$$.err
        return 2
    fi

    root="$(GIT_INDEX_FILE="$idx" git write-tree 2>>/tmp/worktree_tree.$$.err)" || rc=$?
    rm -f "$idx"
    if [ "$rc" -ne 0 ] || [ -z "$root" ]; then
        echo "worktree_subtree: git write-tree exited $rc (root='$root')" >&2
        sed 's/^/      /' /tmp/worktree_tree.$$.err >&2 2>/dev/null
        rm -f /tmp/worktree_tree.$$.err
        return 2
    fi

    # The braces are load-bearing. `"$root:rust/zeus-core-bridge"` lets zsh eat
    # the colon-path into the variable NAME, and git then answers about
    # `fef25126…ust/zeus-core-bridge` — a different subject, loudly.
    tree="$(git rev-parse "${root}:${path}" 2>>/tmp/worktree_tree.$$.err)" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$tree" ]; then
        echo "worktree_subtree: git rev-parse ${root}:${path} exited $rc" >&2
        sed 's/^/      /' /tmp/worktree_tree.$$.err >&2 2>/dev/null
        rm -f /tmp/worktree_tree.$$.err
        return 2
    fi
    rm -f /tmp/worktree_tree.$$.err

    case "$tree" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
        *) echo "worktree_subtree: '$tree' is not lowercase hex" >&2; return 2 ;;
    esac

    printf '%s' "$tree"
}
