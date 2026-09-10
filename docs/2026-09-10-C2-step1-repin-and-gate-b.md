# C2 step 1 — bridge re-pin to `8e19318c`, and the gate-(b) finding

**Date:** 2026-09-10
**Seat:** zeus106
**Repo:** `~/zeus-ios`, branch `feat/m4-session-loop`
**Landed:** `e057a0cd`, parent `4aba06e`, `ls-remote` sha-equal.

## What shipped

The bridge manifest + lock moved from pin `2bfc08aa` to `8e19318c` — the sha
Zeus100 landed carrying my `WORKSPACE_ROOT` pair:

- `set_workspace_root` / `WORKSPACE_ROOT` — `crates/zeus-agent/src/tools.rs:63,75`
- `aegis_path_refusal` — one helper, called from BOTH the sequential and the
  parallel tool-execution paths (the batching bypass fix).

20/20 git-dependency entries in `Cargo.lock` moved, 0 residue of the old pin,
POS control 20 `mikehash/Zeus` entries in the same invocation.

Forward move measured before the edit: `merge-base --is-ancestor 2bfc08aa
8e19318c` rc=0.

## The finding — gate (b) half-failed

Two gates, and they disagreed:

| gate | question | result |
|---|---|---|
| (a) | does the consumer crate compile at the new pin? | rc=0, 0 errors 0 warnings |
| (b) | is the symbol the pin was taken FOR callable from the consumer? | **half** |

`set_workspace_root` is `pub` and callable. Its reader `workspace_root` is
**private** — `E0603`. So **the bridge can establish the workspace root and
cannot read it back.**

Gate (a) cannot see this. It passes *because* nothing calls in — the same
dead-strip property measured during the phase-C walk (`zeus-agent` linked,
15.8 MB rlib, 0 symbols in the archive).

### Consequence for the C2 loop cut

The bridge must **retain its own copy** of the root it passes to
`set_workspace_root`. There is no getter to ask. Any leg that wants to assert
"the loop and the index share one root" must compare against the bridge's
retained value, not against a read-back from `zeus-agent`.

This is a delta to the approved plan, surfaced before the cut rather than
during it.

## Instrument method worth reusing

A scratch `examples/<name>.rs` in the **consumer** crate is the cheapest
gate-(b) probe:

- compiles against the real dependency graph with the real feature flags
- needs no edit to the crate's own source
- `rm -rf examples` leaves nothing in the commit

Probe **one symbol at a time**. Probing both halves together only says
"something is private"; separate probes say *which*.

## Instrument fault, my own standard #2, on its author

```sh
cargo check 2>&1 | tail -25; echo "RC=${PIPESTATUS[0]}"   # printed  RC=
```

`PIPESTATUS` was clobbered by the intervening command, so the producer's
status was never read. It rendered as an **empty string** — which reads like a
formatting glitch, not a void. Correct form, which reported rc=0 honestly:

```sh
rc=0; cargo check >/tmp/pin.out 2>/tmp/pin.err || rc=$?; echo "PRODUCER rc=$rc"
```

## Provenance prose ages silently

The manifest comment read "Re-pinned from 2a2168cd" — true one pin ago, false
after `2bfc08aa`. Repair: state the whole chain (`2a2168cd → 2bfc08aa →
8e19318c`) so a stale link shows up as a *gap* rather than as a plausible
sentence.

Re-read at the new sha rather than recalled: `zeus-agent`'s default set is
still `["audio","matrix","voice","automation"]`
(`crates/zeus-agent/Cargo.toml:10`), so `default-features = false` keeps both
its reason and its line citation.

## Remaining C2 scope (not cut)

1. `send` takes the loop — five-name allow-list, bridge-built `Config`
   (never `Config::default()`), `set_workspace_root(Some(workspace_dir))` as
   its production caller
2. `send` persists the turn via `Session::resume_or_create` with the
   `session_id` it currently discards (`lib.rs:268`)
3. `messages(id)` export over `Session::load`
4. content tokens via `with_tags` + re-index on `remember`
5. `SearchHit.line_number` retired (no producer can fill it)
6. Ollama default-URL literal → an error; `check_network_shape.sh` updated
7. NODES relabel + session list — **only after** 4 and 2 are true
