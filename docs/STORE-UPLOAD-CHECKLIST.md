# Store upload checklist — Zeus iOS

Items here are gates on **submission**, not on the test suite. They exist
because their subject cannot be asserted in-process: it is either artwork
(a human judgement), a compliance declaration (a legal one), or a device
render (needs a device). A leg that tried to guard one of these would
either be permanently red or green against the wrong thing.

Verified against a specific sha. Record the sha when you tick a box.

## BLOCKING — do not upload with any of these open

- [x] **Icon sha ≠ placeholder sha.** — CLOSED at `b66edce`+1.
      `AppIcon-1024-PLACEHOLDER.png` is deleted from the tree; the shipping
      file is `AppIcon.appiconset/AppIcon-1024.png`, Icon A, authored on
      branch `assets/app-icon-a` (`e7cb9465`, source `design/icon/icon-A.svg`).

      ```
      shipped  sha256  a983e78a9f6951353611c6ffa8845b08b232d9e6f219f1666fb837ac9e43f260
                       1024x1024 · RGB · hasAlpha no · sRGB IEC61966-2.1 · 578,466 B
      retired  sha256  b933612ad12f312e583692376fa48f45bd74e0360118dc524e588515b9218b8f
                       (generated placeholder, git blob 92959d5b)
      ```

      The gate is no longer a human item. `BundleResourceTests` now carries
      `testTheCatalogCarriesNoPlaceholderArtwork` and
      `testTheCatalogCarriesExactlyOneAppIconSet`, both content-free — they
      name no good sha, so they survive an artwork revision and go red only on
      a regression to a generated mark or on a stale duplicate set. The reason
      this could not be a leg before (a sha pin goes red on the good event)
      inverted the moment the swap landed: the durable claim is ABSENCE.

- [ ] **`ITSAppUsesNonExemptEncryption` confirmed by merakizzz.**
      Landing as `false` in ② on the stated assumption that the app speaks
      HTTPS to its own gateway and ships no custom crypto (`CryptoKit`: 0
      hits in `Sources` and `Tests`). That is a **compliance declaration**,
      not a measurement — a wrong answer is a legal problem, not a bug.
      Confirm before upload, not before the commit.

- [ ] **Screenshots captured on a build that carries the icon**, iPhone set
      only. Capturing before ① and ② is capturing an app that cannot be
      submitted.

## Device family

`TARGETED_DEVICE_FAMILY: "1"` — iPhone only, stated in `project.yml`.
iPad is a **product question for merakizzz**; this is the default until he
answers. If it ever becomes `"1,2"`, App Store Connect requires an iPad
screenshot set, and nothing in `Sources` has laid out a large canvas
(`UIScreen` / `horizontalSizeClass` / `idiom`: 0 hits).

## What the suite already guards, so it is NOT listed above

`BundleResourceTests` asserts, against the **built product** of the current
build: `CFBundleIconName` present (top-level or nested under
`CFBundleIcons.CFBundlePrimaryIcon`), a rasterised `AppIcon*.png` in the
bundle, `Assets.car` beside the plist, `UILaunchScreen.UIColorName` naming
the dark background, and `UIDeviceFamily` equal to `[1]`. Those are
packaging facts and they have a reporter. Everything above does not.

## Screenshots — how the set is produced, and what it is NOT

`scripts/capture_store_screens.sh` builds Debug, installs to an iPhone 17 Pro
Max simulator (1320×2868, the 6.9" class App Store Connect requires for a
`TARGETED_DEVICE_FAMILY = "1"` submission), and captures four frames:

| frame | launch arguments | what it photographs |
|---|---|---|
| `1-commissioning` | *(none)* | the real cold-start path |
| `2-zeus` | `-zeusSeedCommission -zeusTab zeus` | console, ZEUS tab |
| `3-session` | `-zeusSeedCommission -zeusTab session` | console, SESSION tab |
| `4-nodes` | `-zeusSeedCommission -zeusTab nodes` | console, NODES tab |

Output lands in `build/store-screenshots/`, which is **gitignored** — the set
is reproducible from the script, so the PNGs are an output, not a source.
Re-run the script rather than committing frames; a tracked frame goes stale
the first time the UI moves and nothing reports it.

**The failure the set is guarded against.** `LaunchArgs.initialTab` falls back
to `.zeus` on an unrecognised value, and *every* `LaunchArgs` member is
`#if DEBUG`. So a typo'd `-zeusTab sesion`, or a Release build, produces four
well-formed, correctly-sized PNGs in which every frame is the same screen.
File-exists, non-zero-bytes and 1320×2868 are all **green** on that set.
`scripts/verify_store_screens.py` is the only thing that isn't: it downsamples
each frame to a 12×24 grid of cell averages and requires the frames to differ.
Measured band on this box — same screen twice: **d = 3**; nearest genuinely
distinct pair: **d = 102**; tolerance **6**. Both bounds print on every run.

**Aperture.** Frames 2–4 are a *seeded* app: they prove the console renders
given a commission, not that the commissioning flow can produce one. Frame 1
is unargumented for exactly that reason.

- [ ] **Re-shoot after the real icon lands.** The frames above were captured
      on the placeholder build. The icon is not visible in any frame (no
      springboard shot), so this is a low-risk re-run, but the set should
      match the submitted binary.
- [ ] **Copy** — App Store description, keywords, subtitle, promotional text.
      Not written. Not a code artefact; no leg can guard it.
