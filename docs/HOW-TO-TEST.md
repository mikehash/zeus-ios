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
xcodegen generate                      # the .xcodeproj is gitignored — regenerate it
open Zeus.xcodeproj                    # then hit ⌘R in Xcode
```

**What you see:** Xcode boots an iPhone simulator and the app launches into the
ZEUS tab. Tabs at the bottom, live orb at the top.

To jump straight to a screen without tapping:

```
xcrun simctl launch booted com.zeus.Zeus -zeusTab session
```

`-zeusTab` accepts `zeus` · `session` · `nodes`. A **typo falls back to `zeus`
silently and by design** — so if you asked for `session` and got the orb, check
your spelling before you file a bug.

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
cd ~/zeus-ios && ./scripts/build-device.sh
```

**What you see:** the same build, then a `.ipa` and the upload command. **This
`.ipa` will not install directly — it is upload-only.** Drag it into
`Transporter.app`, or:

```
xcrun altool --upload-app -f <the .ipa> -t ios \
  --apiKey "$ZEUS_ASC_KEY_ID" --apiIssuer "$ZEUS_ASC_ISSUER_ID"
```

Then in App Store Connect → TestFlight, wait for processing (5–30 min), add
yourself as an internal tester, and the build appears in the TestFlight app on
your phone.

**The placeholder icon is fine here.** `AppIcon-1024-PLACEHOLDER.png` is
acceptable for TestFlight and for every internal build. The
`STORE-UPLOAD-CHECKLIST.md` gate that blocks on *icon sha ≠ placeholder* applies
to **App Store review submission only** — it does not block you from testing.
Internal TestFlight distribution requires no review at all.

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
  error: No profiles for 'com.zeus.Zeus' were found
  ```

  That is the *expected* failure for an unsigned box, it exits `rc=1` (build
  failed) rather than `rc=2` (instrument void), and the script warns you about
  the empty keychain **before** it starts compiling.
- That the `.ipa` installs on hardware.
- That TestFlight processing accepts the bundle.

**So the first person to run Path 1 or Path 2 should expect to find something.**
The likely candidates, in order: no Apple account signed into Xcode
(*Xcode → Settings → Accounts*), and the App ID `com.zeus.Zeus` not existing on
your team yet — automatic signing usually creates it, but if it does not, make it
by hand in the developer portal.

## Exit codes

`0` shipped · `1` the build failed (a real measurement — go read
`/tmp/zeus-archive.log`) · `2` the instrument could not run (env unset, tool
missing — nothing was measured). Same convention as `check_all.sh`: a void is
not a weak failure, it is the **absence** of a result, and it sends you to a
different place to look.
