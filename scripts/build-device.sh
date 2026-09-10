#!/bin/bash
#
# Device build — archive + export a real .ipa you can put on a phone.
#
# ── WHAT THIS IS FOR ──────────────────────────────────────────────────────
#
# `xcodebuild test` and `capture_store_screens.sh` both target the SIMULATOR.
# A simulator build is not signed, targets `arm64-apple-ios*-simulator`, and
# cannot be installed on hardware. Every green result on this branch to date
# was measured on a simulator. This script is the first path in the repo that
# produces an artefact for a physical device, and it is a DIFFERENT build:
# different SDK, different triple, and — the part that actually bites — a
# signing step that the simulator path skips entirely.
#
# ── WHY THE TEAM ID IS AN ENV VAR AND NOT A LINE IN project.yml ────────────
#
# A Team ID is an account identifier. It is not secret in the cryptographic
# sense — it appears in every profile and in the exported plist — but it IS
# an account-scoped fact, and this repo's standing rule is that account-scoped
# facts live in the environment, never in the tree. The consequence people
# miss: putting it in `project.yml` makes the branch buildable by exactly one
# Apple account and silently un-buildable by every other, with no error that
# names the cause. Reading it from the environment makes the dependency
# EXPLICIT and the failure LOUD (see the refusal block below).
#
# `ExportOptions.plist` is likewise GENERATED into a temp directory at run
# time and never written into the working tree, for the same reason plus one
# more: a tracked ExportOptions.plist is a file whose correct contents differ
# per operator, so it would be modified-but-never-committed on every box —
# the exact state that trains people to ignore `git status`.
#
# ── THE REFUSAL IS THE FEATURE ────────────────────────────────────────────
#
# With no `DEVELOPMENT_TEAM` and no `-allowProvisioningUpdates`, `xcodebuild
# archive` does not politely stop. It emits a signing error tens of lines into
# a log nobody reads, and on some configurations it will happily produce an
# UNSIGNED archive that then fails at `-exportArchive` with a second, less
# related-looking error. So this script refuses BEFORE spending four minutes
# compiling, and names the variable, the accepted values, and where to find
# the value — because "error: exportArchive failed" teaches nothing.
#
# ── APERTURE, STATED HONESTLY ─────────────────────────────────────────────
#
# On the box where this was authored (zeus106), `security find-identity -v -p
# codesigning` returns **0 valid identities** and no provisioning profiles are
# installed. Therefore:
#
#   PROVEN HERE : the refusal legs fire; `xcodegen generate` succeeds;
#                 `bash -n` is clean; the archive step is REACHED.
#   NOT PROVEN  : that a signed archive exports, that the .ipa installs, that
#                 the exported bundle id matches. Those need a machine with a
#                 signing identity, which is the machine that will run this.
#
# The first operator to run this end-to-end should expect to discover
# something here. That is what a first run is for; it is not a claim of green.
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || { echo "VOID: cannot cd to repo root"; exit 2; }

# rc=2 means UNMEASURED (the instrument could not run), rc=1 means the BUILD
# FAILED. Collapsing these loses the distinction that says which repository to
# go look in — same rule as check_all.sh.
die_instrument() { echo "🔴 VOID (rc=2, unmeasured): $*" >&2; exit 2; }
die_build()      { echo "🔴 FAILED (rc=1): $*" >&2; exit 1; }

# ── 1a. ARGUMENTS ──────────────────────────────────────────────────────────
#
# Two flags, and the second is only meaningful under the first.
#
#   --testflight   after the export, hand the .ipa to App Store Connect.
#   --dry-run      under --testflight, VALIDATE instead of UPLOAD.
#
# `--dry-run` alone is refused rather than ignored. An ignored flag is the
# quietest possible failure: the operator types the word that means "do not
# publish", the script does exactly what it would have done anyway, and the
# only evidence is in the operator's memory of what they typed.
TESTFLIGHT=0
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --testflight) TESTFLIGHT=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)
      echo "usage: build-device.sh [--testflight [--dry-run]]" >&2
      echo "  env: ZEUS_TEAM_ID, ZEUS_EXPORT_METHOD  (see the refusals below)" >&2
      exit 0 ;;
    *) die_instrument "unknown argument '$1'.  usage: build-device.sh [--testflight [--dry-run]]" ;;
  esac
  shift
done

if [ "$DRY_RUN" -eq 1 ] && [ "$TESTFLIGHT" -eq 0 ]; then
  die_instrument "--dry-run has no meaning without --testflight.
  There is nothing to dry-run: a device build with no upload step already
  touches nothing outside this machine. Refusing rather than ignoring, because
  an ignored --dry-run is indistinguishable from a --dry-run that was honoured."
fi

# ── 1. REFUSE LOUDLY ───────────────────────────────────────────────────────

if [ -z "${ZEUS_TEAM_ID:-}" ]; then
  cat >&2 <<'EOF'
🔴 VOID: ZEUS_TEAM_ID is not set.

  This is your 10-character Apple Developer Team ID. Find it at
  https://developer.apple.com/account  →  Membership details  →  Team ID,
  or run:  security find-identity -v -p codesigning
           (it is the 10 chars in parentheses after your name)

  Then:    export ZEUS_TEAM_ID=ABCDE12345

  Refusing before the build rather than after, because a signing failure
  four minutes into a compile does not name this variable.
EOF
  exit 2
fi

if [ -z "${ZEUS_EXPORT_METHOD:-}" ]; then
  cat >&2 <<'EOF'
🔴 VOID: ZEUS_EXPORT_METHOD is not set.

  Pick ONE. They produce different artefacts and they are not interchangeable:

    development        → .ipa for devices REGISTERED to your team.
                         Install over USB/Xcode. Fastest loop. Use this to
                         put the app on your own phone right now.

    ad-hoc             → .ipa for devices in a provisioning profile's device
                         list (up to 100). Install over the air. Use this to
                         send a build to someone who is not you.

    app-store-connect  → .ipa for UPLOAD ONLY. It will not install directly.
                         Use this for TestFlight.

  Then:  export ZEUS_EXPORT_METHOD=development

  (Xcode 15.3+ renamed these to debugging / release-testing / app-store-connect.
   Both spellings are accepted here and translated for you.)
EOF
  exit 2
fi

# The method string is passed verbatim into a plist that xcodebuild parses. An
# unrecognised value there produces an export error that quotes the plist, not
# the variable — so validate it HERE where the variable's name is still in
# scope. Accept both the pre- and post-Xcode-15.3 spellings; canonicalise to
# the new ones because those are what this toolchain (26.5) documents.
case "$ZEUS_EXPORT_METHOD" in
  development|debugging)              EXPORT_METHOD="debugging" ;;
  ad-hoc|adhoc|release-testing)       EXPORT_METHOD="release-testing" ;;
  app-store|app-store-connect|appstore) EXPORT_METHOD="app-store-connect" ;;
  enterprise)                         EXPORT_METHOD="enterprise" ;;
  *)
    die_instrument "ZEUS_EXPORT_METHOD='$ZEUS_EXPORT_METHOD' is not a method.
  Accepted: development | ad-hoc | app-store-connect | enterprise
  (or the Xcode 15.3+ spellings: debugging | release-testing | app-store-connect)"
    ;;
esac

# 10 uppercase alphanumerics. Not cosmetic: a Team ID with a stray newline or a
# pasted 'Team ID: ' prefix produces a profile-matching failure whose message
# does not show the whitespace.
if ! printf '%s' "$ZEUS_TEAM_ID" | grep -Eq '^[A-Z0-9]{10}$'; then
  die_instrument "ZEUS_TEAM_ID='$ZEUS_TEAM_ID' is not a 10-character Team ID.
  Expected 10 uppercase letters/digits, e.g. ABCDE12345.
  Check for a trailing newline or a pasted 'Team ID:' prefix."
fi

# ── 1b. APP STORE CONNECT CREDENTIALS — PREFLIGHT, NOT POSTFLIGHT ──────────
#
# Read here, ~5 minutes BEFORE the upload needs them, for the same reason
# ZEUS_TEAM_ID is read before the compile: a credential fault discovered after
# an archive is a fault whose error text names a JWT, not a missing file.
#
# THREE INPUTS, all from a directory OUTSIDE the tree (default ~/.zeus/asc/):
#
#   issuer_id            the ASC API issuer UUID       (one line)
#   key_id               the 10-char ASC API key id    (one line)
#   AuthKey_<key_id>.p8  the private key
#
# The .p8 filename is NOT our choice. `altool` does not take a path to a key;
# it searches a fixed list of directories for a file named exactly
# `AuthKey_<apiKey>.p8`, and the only way to add a directory to that list is
# the API_PRIVATE_KEYS_DIR environment variable. So we do not pass the key —
# we point altool at the directory and let it find the name it insists on.
# That is why the filename check below is a hard refusal and not a nicety:
# a correctly-contented key under the wrong name is invisible to the tool,
# and its absence surfaces as an authentication error, not a missing file.
#
# NOTHING from this directory is ever echoed. The refusals below name PATHS
# and never contents — a "helpful" error that prints the issuer id puts an
# account credential into a terminal scrollback and a CI log.
ASC_DIR="${ZEUS_ASC_DIR:-$HOME/.zeus/asc}"
ASC_KEY_ID=""
ASC_ISSUER_ID=""
ASC_XCODEBUILD_ARGS=()

if [ "$TESTFLIGHT" -eq 1 ]; then
  if [ "$EXPORT_METHOD" != "app-store-connect" ]; then
    die_instrument "--testflight requires ZEUS_EXPORT_METHOD=app-store-connect (got '$ZEUS_EXPORT_METHOD').
  Refusing to override it for you: the method decides what the .ipa IS, and a
  development-signed .ipa is rejected by App Store Connect after the upload
  has already spent your time. Set the variable and mean it."
  fi

  [ -d "$ASC_DIR" ] || die_instrument "no App Store Connect credentials directory at $ASC_DIR

  Create it (chmod 700) and put three things in it:
    issuer_id            — the issuer UUID from App Store Connect → Users and
                           Access → Integrations → App Store Connect API
    key_id               — the 10-character Key ID from the same page
    AuthKey_<key_id>.p8  — the private key, downloadable EXACTLY ONCE at
                           key-creation time. Apple will not re-issue it.

  Override the location with ZEUS_ASC_DIR. It is outside the tree by default
  and must stay outside it: a .p8 is a live account credential."

  for f in issuer_id key_id; do
    [ -f "$ASC_DIR/$f" ] || die_instrument "missing $ASC_DIR/$f  (one line, no quotes)"
    [ -s "$ASC_DIR/$f" ] || die_instrument "$ASC_DIR/$f is empty"
  done

  # `tr -d` strips the trailing newline a text editor adds and any stray CR.
  # Not cosmetic: these go into a JWT, and a key id with a newline authenticates
  # as nothing while looking correct in every echo.
  ASC_KEY_ID=$(tr -d ' \t\r\n' < "$ASC_DIR/key_id")
  ASC_ISSUER_ID=$(tr -d ' \t\r\n' < "$ASC_DIR/issuer_id")

  printf '%s' "$ASC_KEY_ID" | grep -Eq '^[A-Z0-9]{10}$' \
    || die_instrument "the key id in $ASC_DIR/key_id is not 10 uppercase alphanumerics.
  (Its length is $(printf '%s' "$ASC_KEY_ID" | wc -c | tr -d ' ') characters. The value is not printed here on purpose.)"

  P8="$ASC_DIR/AuthKey_${ASC_KEY_ID}.p8"
  [ -f "$P8" ] || die_instrument "no private key at $P8

  altool searches for that EXACT filename — AuthKey_<key_id>.p8 — and takes no
  path argument. If your file is named something else, rename it; if the key id
  in $ASC_DIR/key_id does not match the one in the filename, one of the two is
  from a different key."

  # altool's only way to see a directory that is not one of its four defaults.
  export API_PRIVATE_KEYS_DIR="$ASC_DIR"

  command -v xcrun >/dev/null || die_instrument "xcrun not on PATH"
  xcrun --find altool >/dev/null 2>&1 || die_instrument "altool not found (xcrun --find altool). Full Xcode required; Command Line Tools alone do not ship it."

  # ── The signing half of these credentials ────────────────────────────────
  #
  # altool gets the key by DIRECTORY (above). xcodebuild does not: cloud-managed
  # signing takes the account on the command line, and `-allowProvisioningUpdates`
  # WITHOUT it is the defect this array fixes — the flag says "you may mint a
  # profile", and with no account there is nothing to mint WITH. The failure
  # surfaces at codesign, several minutes downstream, naming a certificate
  # rather than a missing credential.
  #
  # WHY AN ARRAY AND NOT THREE INLINE ARGUMENTS: these three variables are
  # EMPTY on a non-TestFlight run (the block that fills them is this one). An
  # inline literal would hand every ordinary device build
  # `-authenticationKeyPath $ASC_DIR/AuthKey_.p8 -authenticationKeyID ''` — an
  # argument whose value is the empty string is not the same as an absent
  # argument, and the path would name a file that cannot exist. The array is
  # empty unless this block ran, so the args appear exactly when they mean
  # something.
  #
  # `${ASC_XCODEBUILD_ARGS[@]+"${ASC_XCODEBUILD_ARGS[@]}"}` and not the bare
  # form: this is bash 3.2 (the macOS system bash) under `set -u`, where
  # expanding an EMPTY array is an unbound-variable error that would kill every
  # non-TestFlight build. The `+` guard is not style.
  ASC_XCODEBUILD_ARGS=(
    -authenticationKeyPath "$P8"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

command -v xcodegen  >/dev/null || die_instrument "xcodegen not on PATH (brew install xcodegen)"
command -v xcodebuild >/dev/null || die_instrument "xcodebuild not on PATH (install Xcode, then xcode-select)"

# ── 2. SIGNING IDENTITY PRESENCE, AS A SEPARATE LEG ────────────────────────
#
# Distinct from the env check above: the variables can be perfectly set on a
# machine with no keychain identity, and that failure surfaces ~4 minutes
# later as a compile-then-sign error. This is a WARNING and not a refusal,
# because `-allowProvisioningUpdates` can create an identity on the fly when
# the machine is signed into Xcode — so an empty keychain is not proof of
# doom, only of risk. Stated, not enforced.
IDENT_COUNT=$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'valid identities found' >/dev/null 2>&1; security find-identity -v -p codesigning 2>/dev/null | grep -Eo '^ *[0-9]+ valid identities found' | grep -Eo '[0-9]+' | head -1)
IDENT_COUNT="${IDENT_COUNT:-0}"
if [ "$IDENT_COUNT" = "0" ]; then
  echo "⚠️  security find-identity: 0 valid codesigning identities in this keychain."
  echo "    Continuing — -allowProvisioningUpdates can mint one if Xcode is signed in."
  echo "    If the archive fails at signing, this line is why."
fi

ARCHIVE_DIR="${ZEUS_BUILD_DIR:-$REPO/build/device}"
ARCHIVE="$ARCHIVE_DIR/Zeus.xcarchive"
EXPORT_DIR="$ARCHIVE_DIR/export"
# The plist goes to a temp dir, NOT the tree. See the header.
OPTS_DIR=$(mktemp -d /tmp/zeus-export.XXXXXX) || die_instrument "mktemp failed"
OPTS="$OPTS_DIR/ExportOptions.plist"
trap 'rm -rf "$OPTS_DIR"' EXIT

echo "── zeus-ios device build ──────────────────────────────────────────"
echo "  repo        : $REPO"
echo "  sha         : $(git rev-parse --short HEAD 2>/dev/null || echo '(not a git tree)')"
echo "  team        : $ZEUS_TEAM_ID"
echo "  method      : $ZEUS_EXPORT_METHOD  →  $EXPORT_METHOD"
if [ "$TESTFLIGHT" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  upload      : DRY RUN — altool --validate-app (nothing is published)"
  else
    echo "  upload      : LIVE — altool --upload-app → App Store Connect"
  fi
  echo "  asc creds   : $ASC_DIR  (key $ASC_KEY_ID)"
fi
echo "  archive     : $ARCHIVE"
echo "  export      : $EXPORT_DIR"
echo

# ── 3. GENERATE THE PROJECT ────────────────────────────────────────────────
#
# `.gitignore` excludes `*.xcodeproj/`, so a fresh checkout has no project at
# all and `xcodebuild` dies with "does not exist" — which is the failure mode
# the capture script hit from a detached worktree. Regenerating unconditionally
# also guarantees the archive reflects project.yml rather than a stale local
# pbxproj that predates someone's edit.
echo "→ xcodegen generate"
rc=0
xcodegen generate --quiet >/tmp/zeus-xcodegen.log 2>&1 || rc=$?
[ "$rc" -eq 0 ] || { cat /tmp/zeus-xcodegen.log >&2; die_instrument "xcodegen generate rc=$rc"; }
[ -d "$REPO/Zeus.xcodeproj" ] || die_instrument "xcodegen rc=0 but Zeus.xcodeproj absent — regeneration is a claim, this is the check"

# ── 3b. VERSION RESOLUTION ─────────────────────────────────────────────────
#
# TWO NUMBERS, TWO SOURCES, NEITHER OF THEM A LITERAL IN A PLIST.
#
#   CURRENT_PROJECT_VERSION  = git rev-list --count HEAD
#       The build number App Store Connect uses to order uploads. It must
#       INCREASE on every upload or the upload is rejected. Commit count is
#       monotonic by construction on a branch that only grows — no file to
#       forget to bump, no state outside the repo.
#
#       APERTURE: it is monotonic PER LINEAR HISTORY. A rebase that drops
#       commits, or an upload cut from a shorter branch, can produce a count
#       that has already been used. That is a real limit and it is stated
#       here rather than discovered at the rejection.
#
#   MARKETING_VERSION        = contents of the tracked VERSION file
#       The human-facing "1.0.0". ONE place, tracked, reviewable in a diff.
#       Not a tag: this repo has 0 tags, so a tag-derived value would resolve
#       empty on every box today.
#
# Both are passed to `xcodebuild archive` on the command line, which OUTRANKS
# the defaults in project.yml. The generated Info.plist reads them through
# $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION).
VERSION_FILE="$REPO/VERSION"
[ -f "$VERSION_FILE" ] || die_instrument "VERSION file absent at $VERSION_FILE — MARKETING_VERSION has no source"
MARKETING_VERSION="$(tr -d ' \t\r\n' < "$VERSION_FILE")"
[ -n "$MARKETING_VERSION" ] || die_instrument "VERSION file is empty — MARKETING_VERSION resolved to nothing. A blank version string builds a bundle App Store Connect will not accept."

rc=0
BUILD_NUMBER="$(git -C "$REPO" rev-list --count HEAD)" || rc=$?
[ "$rc" -eq 0 ] || die_instrument "git rev-list --count HEAD rc=$rc — CURRENT_PROJECT_VERSION unmeasured"
[ -n "$BUILD_NUMBER" ] || die_instrument "git rev-list --count HEAD produced an empty string — CURRENT_PROJECT_VERSION resolved to nothing"
printf '%s' "$BUILD_NUMBER" | grep -Eq '^[0-9]+$' || die_instrument "CURRENT_PROJECT_VERSION='$BUILD_NUMBER' is not a positive integer"

echo "  version     : $MARKETING_VERSION ($BUILD_NUMBER)   [VERSION file / commit count]"

# ── 4. ARCHIVE ─────────────────────────────────────────────────────────────
#
# `generic/platform=iOS` — NOT a named device and NOT a simulator. A named
# destination ties the archive to hardware that must be attached; the generic
# destination builds for the device SDK unconditionally, which is what an
# archive is for.
rm -rf "$ARCHIVE"
mkdir -p "$ARCHIVE_DIR"
echo "→ xcodebuild archive (this is the slow part — 2-5 min on a cold build)"
rc=0
xcodebuild archive \
  -project "$REPO/Zeus.xcodeproj" \
  -scheme Zeus \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  ${ASC_XCODEBUILD_ARGS[@]+"${ASC_XCODEBUILD_ARGS[@]}"} \
  DEVELOPMENT_TEAM="$ZEUS_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  >/tmp/zeus-archive.log 2>&1 || rc=$?

if [ "$rc" -ne 0 ]; then
  echo "── last 40 lines of /tmp/zeus-archive.log ──" >&2
  tail -40 /tmp/zeus-archive.log >&2
  die_build "xcodebuild archive rc=$rc  (full log: /tmp/zeus-archive.log)"
fi

# rc=0 from xcodebuild is not proof an archive exists — assert the artefact.
[ -d "$ARCHIVE/Products/Applications/Zeus.app" ] \
  || die_build "archive rc=0 but $ARCHIVE/Products/Applications/Zeus.app is absent"

ARCHIVE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$ARCHIVE/Products/Applications/Zeus.app/Info.plist" 2>/dev/null || echo '(unreadable)')
ARCHIVE_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$ARCHIVE/Products/Applications/Zeus.app/Info.plist" 2>/dev/null || echo '(unreadable)')
echo "  archived    : $ARCHIVE_ID  v$ARCHIVE_VER"

# ── 5. EXPORT ──────────────────────────────────────────────────────────────

cat > "$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>$EXPORT_METHOD</string>
  <key>teamID</key>
  <string>$ZEUS_TEAM_ID</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
  <key>destination</key>
  <string>export</string>
</dict>
</plist>
PLIST

rm -rf "$EXPORT_DIR"
echo "→ xcodebuild -exportArchive"
rc=0
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OPTS" \
  -allowProvisioningUpdates \
  ${ASC_XCODEBUILD_ARGS[@]+"${ASC_XCODEBUILD_ARGS[@]}"} \
  >/tmp/zeus-export.log 2>&1 || rc=$?

if [ "$rc" -ne 0 ]; then
  echo "── last 40 lines of /tmp/zeus-export.log ──" >&2
  tail -40 /tmp/zeus-export.log >&2
  die_build "xcodebuild -exportArchive rc=$rc  (full log: /tmp/zeus-export.log)"
fi

# ── 6. ASSERT THE ARTEFACT ─────────────────────────────────────────────────
#
# Same rule as the capture script: a zero exit code is the tool's opinion, the
# artefact is the fact. An .ipa of 0 bytes, or an export directory containing
# only a log, both exit 0 on some paths.
IPA=$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 2>/dev/null | head -1)
[ -n "$IPA" ] || die_build "export rc=0 but no .ipa in $EXPORT_DIR"
IPA_BYTES=$(stat -f%z "$IPA" 2>/dev/null || echo 0)
[ "$IPA_BYTES" -gt 100000 ] || die_build "$IPA is $IPA_BYTES bytes — too small to be an app"

echo
echo "✅ $IPA"
echo "   $IPA_BYTES bytes · $ARCHIVE_ID v$ARCHIVE_VER · method=$EXPORT_METHOD"
echo
# ── 7. UPLOAD ──────────────────────────────────────────────────────────────
#
# Until this section existed the script PRINTED an altool command for a human
# to paste. That is not an upload path — it is a document that happens to be
# emitted by a program, and it drifts from the script that emits it the moment
# either changes. It is retired here.
if [ "$TESTFLIGHT" -eq 1 ]; then
  # --validate-app runs the SAME server-side checks as --upload-app (bundle id,
  # signing, icon, version, entitlements, export compliance) and publishes
  # nothing. So the dry run is not a lesser test of the upload — it is the same
  # test with the mutation withheld, which is the only useful kind.
  if [ "$DRY_RUN" -eq 1 ]; then
    ALTOOL_VERB="--validate-app"
    echo "→ altool --validate-app  (DRY RUN — nothing is published)"
  else
    ALTOOL_VERB="--upload-app"
    echo "→ altool --upload-app  (LIVE — this publishes a build to TestFlight)"
  fi

  # The key itself is never on this command line; altool finds AuthKey_<id>.p8
  # inside API_PRIVATE_KEYS_DIR, exported at the preflight. So `ps` during the
  # upload shows an issuer id and a key id and no private key material.
  rc=0
  xcrun altool "$ALTOOL_VERB" \
    -f "$IPA" \
    -t ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    >/tmp/zeus-altool.log 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    echo "── last 40 lines of /tmp/zeus-altool.log ──" >&2
    tail -40 /tmp/zeus-altool.log >&2
    die_build "altool $ALTOOL_VERB rc=$rc  (full log: /tmp/zeus-altool.log)"
  fi

  # rc=0 is the tool's opinion; the artefact is the fact — same rule as the
  # .ipa size assert. altool has historically exited 0 while reporting errors
  # in its own output, so the log is read rather than trusted.
  if grep -qi 'ERROR ITMS\|error-code' /tmp/zeus-altool.log; then
    tail -40 /tmp/zeus-altool.log >&2
    die_build "altool exited 0 but its log reports errors (full log: /tmp/zeus-altool.log)"
  fi

  echo
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "✅ VALIDATED — App Store Connect accepted this build's shape."
    echo "   Nothing was published. Re-run without --dry-run to upload."
  else
    echo "✅ UPLOADED — build $ARCHIVE_VER is with App Store Connect."
    echo "   Processing takes ~5-15 min before it appears in TestFlight."
    echo "   App Store Connect → TestFlight → iOS builds."
  fi
  exit 0
fi

case "$EXPORT_METHOD" in
  app-store-connect)
    echo "   This .ipa is for UPLOAD ONLY — it will not install directly."
    echo "   Re-run with --testflight to hand it to App Store Connect,"
    echo "   or --testflight --dry-run to validate without publishing."
    ;;
  *)
    echo "   NEXT — put it on a phone:"
    echo "     • Plug the phone in, open Xcode → Window → Devices and Simulators,"
    echo "       drag the .ipa onto 'Installed Apps'."
    echo "     • Or: xcrun devicectl device install app --device <UDID> \"$IPA\""
    echo "       (list devices: xcrun devicectl list devices)"
    ;;
esac
exit 0
