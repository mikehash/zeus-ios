# Store upload checklist — Zeus iOS

Items here are gates on **submission**, not on the test suite. They exist
because their subject cannot be asserted in-process: it is either artwork
(a human judgement), a compliance declaration (a legal one), or a device
render (needs a device). A leg that tried to guard one of these would
either be permanently red or green against the wrong thing.

Verified against a specific sha. Record the sha when you tick a box.

## BLOCKING — do not upload with any of these open

- [ ] **Icon sha ≠ placeholder sha.**
      `Sources/ZeusApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024-PLACEHOLDER.png`
      is a **generated mark**, not brand artwork — a dark field and a red
      glyph, five sampled colours. It is a TRACKED file, so it ships if
      nobody replaces it, and every packaging leg in `BundleResourceTests`
      is exactly as green on it as on the real icon (their subject is
      whether `actool` produced an image, not which image).

      Placeholder identity, recorded so the check is mechanical:

      ```
      git blob   92959d5b03a0edf9252458fd15d4ced9ae676395
      sha256     b933612ad12f312e583692376fa48f45bd74e0360118dc524e588515b9218b8f
      1024x1024 · RGB · no alpha · 27,316 B
      ```

      Owner: **merakizzz** (1024², no alpha, no transparency — App Store
      rejects an alpha channel on the marketing icon). On replacement:
      drop the `-PLACEHOLDER` suffix from the filename, update
      `AppIcon.appiconset/Contents.json` (`filename` **and** remove the
      `properties.zeus-artwork-status` line), and delete this item.

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
