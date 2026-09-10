# How to get Zeus onto a phone

Three paths. **Path 0 needs nothing and works right now.** Paths 1 and 2 need an
Apple Developer account ($99/yr) and neither has been run end-to-end yet — see
*What has and has not been proven* at the bottom, and read it before you budget
time against them.

---

## Path 0 — Simulator (zero setup, works today)

Nothing to buy, nothing to sign, no account. This is the fastest way to look at
the app.

```
cd ~/zeus-ios
./scripts/build-xcframework.sh         # ~5 min, FIRST TIME ON ANY MAC — see below
xcodegen generate                      # the .xcodeproj is gitignored — regenerate it
open Zeus.xcodeproj                    # then hit ⌘R in Xcode
```

### The first line is not optional, and skipping it fails at LINK, not at build

The app now contains a Rust core, and it is **linked in**, not talked to over a
network. That archive — `Frameworks/ZeusCore.xcframework`, ~112 MB — is
**deliberately not in git**: binaries are immortal once committed, and this one
is fully reproducible from the crate, the lockfile, the pinned toolchain and
the script, all four of which *are* tracked. So the first build on any Mac
builds it.

Skip it and Xcode gets a long way in before dying, with a message about a
missing framework or `ZeusCore` not found — **not** a message that says "run
the script". That is why this paragraph exists.

**Three prerequisites, all one-time:**

1. **Full Xcode** — not the Command Line Tools. `xcode-select -p` must print a
   path ending in `Xcode.app/Contents/Developer`. If it prints
   `/Library/Developer/CommandLineTools`, you have CLT only and there is no
   iPhoneOS SDK on the box. *This one the script checks by name*: it exits with
   `FATAL: no iphoneos SDK on this box` rather than letting you find out later.
2. **Rust** — `rustup` and a working `cargo` (<https://rustup.rs>).
3. **The two iOS targets** —
   `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`.
   Both of them: the device slice and the simulator slice are different
   platforms, and an xcframework with one of them is half an artifact.

Prerequisites 2 and 3 are **not** checked by name — measured, not assumed. With
no `cargo` on `PATH` the script dies on a bare `command not found`; with a
missing target it dies inside `cargo build` complaining it cannot find `std`
for `aarch64-apple-ios`. Both are loud and both are exit-non-zero, so nothing
proceeds on a broken toolchain — but neither message will tell you to run the
`rustup` line above. That is what this list is for.

**What you see:** ~5 minutes (two release builds of the core, one per slice),
then the archive plus a `MANIFEST.txt` *inside* it recording the exact
`rustc`, `xcodebuild`, SDK path and per-slice sha256 that produced it — so two
machines' builds can be compared before anyone tries to explain a difference.

**When to re-run it:** after changing anything under `rust/`, and never
otherwise. It is not part of the normal edit-build-run loop — the generated
Swift bindings (`Sources/ZeusCoreFFI/`) *are* checked in, so ordinary UI work
needs no Rust toolchain at all. Only linking needs the archive.

**A note on fresh checkouts and verification trees.** Two facts this repo has
paid for once already:

1. **Put worktrees under `$HOME`, never `/tmp`.** Xcode's build-description
   resolution does not survive macOS's `/tmp → /private/tmp` symlink: the same
   tree at `/tmp/…` fails with an error string that reads like three different
   problems (missing SDK, broken project, bad path), while the identical tree
   under `$HOME` builds clean. The probe that collapsed the three worlds into
   one cause was literally the same tree moved to a different path.
2. **`Frameworks/ZeusCore.xcframework` is gitignored by design** (see the
   first paragraph of this path). On a fresh checkout — or a fresh verification
   worktree — **copy the archive in** from another machine/checkout, or run
   `./scripts/build-xcframework.sh` (~5 min), **before** `xcodegen generate`.
   Generating the project without the archive present produces a project that
   builds partway and dies at LINK with a missing-framework error, which does
   not name the missing step.

**What you see:** Xcode boots an iPhone simulator and the app launches into the
ZEUS tab. Tabs at the bottom, live orb at the top.

To jump straight to a screen without tapping:

```
xcrun simctl launch booted ai.novaxai.zeus.mobile -zeusTab session
```

`-zeusTab` accepts `zeus` · `session` · `nodes`. A **typo falls back to `zeus`
silently and by design** — so if you asked for `session` and got the orb, check
your spelling before you file a bug.

When a command names a simulator — `xcodebuild -destination 'platform=iOS
Simulator,…'` most of all — **pin it by UDID, not by device name**: the
installed simulator inventory drifts (runtimes and device pairings come and go
with Xcode updates), and a vanished name like `iPhone 16` reads as a build
failure (`xcodebuild` exit 70) when the build itself was fine. `xcrun simctl
list devices` prints the UDIDs; use `-destination 'id=<UDID>'`.

**What it does NOT tell you:** touch feel, real Dynamic Type behaviour, actual
network conditions, or anything about performance. It is a picture of the UI,
not the product.

---

## Path 1 — Your own phone, over USB (`development`)

For putting the build on **your** device, plugged into this Mac.

```
export ZEUS_TEAM_ID=ABCDE12345          # your 10-char Team ID (see below)
export ZEUS_EXPORT_METHOD=development
cd ~/zeus-ios && ./scripts/build-device.sh
```

**What you type:** those three lines.
**What you see:** ~2–5 min of build, then a green `✅ …/Zeus.ipa` with its byte
count and bundle id, followed by the install command.
**Then:** plug the phone in → Xcode → *Window → Devices and Simulators* → drag
the `.ipa` onto **Installed Apps**. Or:

```
xcrun devicectl list devices            # find the UDID
xcrun devicectl device install app --device <UDID> <the .ipa path it printed>
```

**First launch on the phone will refuse to open** until you trust the profile:
*Settings → General → VPN & Device Management → your team → Trust*. That is
normal for a development build and is not a bug in the app.

---

## Path 2 — TestFlight (`app-store-connect`)

For sending the build to someone who is not sitting at this Mac.

```
export ZEUS_TEAM_ID=ABCDE12345
export ZEUS_EXPORT_METHOD=app-store-connect
cd ~/zeus-ios && ./scripts/build-device.sh --testflight --dry-run
```

**First, the credentials.** `--testflight` reads three things from `~/.zeus/asc/`
(override with `ZEUS_ASC_DIR`), outside the tree, and refuses before the build
rather than after it:

```
~/.zeus/asc/
  issuer_id             the issuer UUID    (ASC → Users and Access → Integrations)
  key_id                the 10-char Key ID (same page)
  AuthKey_<key_id>.p8   the private key — downloadable EXACTLY ONCE, at
                        key-creation time. Apple will not re-issue it.
```

The `.p8` filename is not our choice: `altool` takes no path to a key, it
searches for that exact name inside `API_PRIVATE_KEYS_DIR`. A correct key under
the wrong filename is invisible to the tool, so the script refuses on the name.

**`--dry-run` runs `altool --validate-app`** — the same server-side checks as a
real upload (bundle id, signing, icon, version, entitlements, export
compliance), publishing nothing. **Drop `--dry-run` to upload for real.** The
script no longer prints a command for you to paste; it performs the upload and
reads altool's log, because altool has exited 0 while reporting errors.

Then in App Store Connect → TestFlight, wait for processing (5–30 min), add
yourself as an internal tester, and the build appears in the TestFlight app on
your phone.

**The icon is real artwork now.** `AppIcon-1024.png` (Icon A, sha256
`a983e78a…`) replaced the generated placeholder, and two legs in
`BundleResourceTests` keep a placeholder from coming back. Nothing about the
icon blocks a TestFlight build.

---

## The two environment variables

The script **refuses to build** if either is missing, and tells you exactly what
it wants. That refusal is deliberate: without it, a missing Team ID surfaces as
a signing error forty lines into a log, four minutes after you started.

| Variable | What | Where to find it |
|---|---|---|
| `ZEUS_TEAM_ID` | 10-char Apple Team ID, e.g. `ABCDE12345` | developer.apple.com/account → Membership → Team ID |
| `ZEUS_EXPORT_METHOD` | `development` · `ad-hoc` · `app-store-connect` | pick per the paths above |

Neither is written into the repo, and neither is a secret in the cryptographic
sense — they are **account-scoped facts**, and account-scoped facts live in the
environment so the branch stays buildable by anyone. `ExportOptions.plist` is
generated into a temp dir at run time for the same reason: a tracked one would
be modified-but-never-committed on every box.

`ad-hoc` is the third option: an `.ipa` installable over the air by up to 100
devices you have registered. Use it to send a build to someone else without
TestFlight.

---

## The remote-gateway editor (M4)

Two doors, one sheet — both open the same `REMOTE GATEWAY` editor:

* **HOME LINK pill** — the LINK stat cell on the home screen.
* **The NODES row, in every arm** — the row below the state line. Its title is
  the state (`NO GATEWAY — LINK ONE` / `CORE — THIS PHONE` /
  `GATEWAY URL INVALID — FIX IT`) and its action is `USE A REMOTE GATEWAY`;
  tapping it opens the editor in **every** resolution arm, including `LOCAL`.

**What SAVE does today.** The token half is real: a non-empty token field
writes to the Keychain and toasts `TOKEN SAVED`. The URL half is disabled with
the caption `TOKEN SAVES NOW — URL IS READ-ONLY IN THIS BUILD` — honest about
what is not wired; the commission wiring enables it.

**RUN PREFLIGHT** performs one authenticated request against the configured
gateway and maps the measured outcome to one of four verdicts. What each means
the operator should do:

| Verdict | Measured | Operator does |
|---|---|---|
| `TOKEN OK — GATEWAY REACHABLE` | 2xx from the gateway | nothing — gateway and token are good |
| `TOKEN REJECTED — REPLACE IT ABOVE` | 401 (or non-2xx) with a token on file | re-enter the token, SAVE, re-run preflight |
| `NO TOKEN — ADD ONE ABOVE TO UNBLOCK` | 401 (or non-2xx) with no token | add the token above |
| `GATEWAY UNREACHABLE — CHECK THE URL` | transport failed | check host/port/LAN before touching the token |

**`-zeusInMemoryTokens`** — a capture launch arg, beside `-zeusSeededCommission`:
routes the editor's writes to an `InMemoryTokenStore` instead of the real
Keychain, so capture runs never dirty the operator's keychain. Absent by
default in production; tests inject it through the same `LaunchArgs` seam.

---

## What has and has not been proven

Stated plainly, because the alternative is you budgeting an hour against a path
that has never completed.

**Proven on this box (zeus106), by running it:**
- All four refusal legs fire with `rc=2` — missing team, missing method, bad
  method, malformed team ID.
- `xcodegen generate` succeeds and the `.xcodeproj` materialises.
- The archive step is **reached** with valid-looking env.
- Path 0 (simulator) — this is what the whole test suite and every screenshot
  on this branch run against.

**NOT proven — nobody has run it:**
- That a signed archive exports. On this box
  `security find-identity -v -p codesigning` returns **0 valid identities**, so
  the archive dies at signing with:

  ```
  error: No Accounts: Add a new account in Accounts settings.
  error: No profiles for 'ai.novaxai.zeus.mobile' were found
  ```

  That is the *expected* failure for an unsigned box, it exits `rc=1` (build
  failed) rather than `rc=2` (instrument void), and the script warns you about
  the empty keychain **before** it starts compiling.
- That the `.ipa` installs on hardware.
- That TestFlight processing accepts the bundle.

**So the first person to run Path 1 or Path 2 should expect to find something.**
The likely candidates, in order: no Apple account signed into Xcode
(*Xcode → Settings → Accounts*), and the App ID `ai.novaxai.zeus.mobile` not existing on
your team yet — automatic signing usually creates it, but if it does not, make it
by hand in the developer portal.

## Exit codes

`0` shipped · `1` the build failed (a real measurement — go read
`/tmp/zeus-archive.log`) · `2` the instrument could not run (env unset, tool
missing — nothing was measured). Same convention as `check_all.sh`: a void is
not a weak failure, it is the **absence** of a result, and it sends you to a
different place to look.
