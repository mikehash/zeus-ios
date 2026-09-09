import Foundation

/// What the linked core actually is, read from the artifact's own manifest.
///
/// ## Why this file exists
///
/// `NodesView` rendered `zeus-core 0.9 · this iphone`. That string was not
/// stale — it was UNFALSIFIABLE. No version crosses the FFI at all (the
/// bridge exports `init`, `setProvider`, `listModels`, `send`, `sessions`,
/// `remember`, `search`, `indexSize`, `hasProvider`, `listProviders`,
/// `credentialShape` — a version export census reads 0), and the crate's own
/// `Cargo.toml` says `0.1.0`. `0.9` matched nothing that has ever existed.
///
/// Real provenance does exist and is exact: `scripts/build-xcframework.sh`
/// writes `zeus-build-manifest.txt` INTO the xcframework, so it travels with
/// the slices it describes. `FrameworkProvenanceTests` already reads it — but
/// from the REPO ROOT, which a phone does not have. That is gate two of the
/// same pair (i) turned on: the value must exist AND the view must be able to
/// reach it. `project.yml` now bundles that exact path as a resource — not a
/// copy of it, the path itself, so the bundled bytes cannot drift from the
/// archive the app links.
///
/// ## Why `dep-pin` and not `crate-tree`
///
/// Both are sourced and both are in the manifest. `crate-tree` is the tree
/// object of `rust/zeus-core-bridge` — exact, and meaningless to anyone who
/// is not holding this repo. `dep-pin` is the `Zeus` main sha the core was
/// built from, which an operator can paste into a log, a git host, or a
/// message to the seat that built it. Provenance an operator cannot LOOK UP
/// is provenance only to the toolchain.
enum CoreProvenance {

    /// The bundled manifest's text, or `nil` when no manifest shipped.
    ///
    /// `nil` is a real state, not a defect to paper over: a build that
    /// predates the resource line, or a test host, has none. Everything below
    /// abstains rather than substituting a literal — the entire point of the
    /// retirement is that this row stops inventing values.
    static func manifestText(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "zeus-build-manifest",
                                   withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// One `key: value` line, or `nil`.
    ///
    /// AMBIGUITY VOIDS. Two lines with the same key means the manifest was
    /// concatenated or hand-edited, and picking the first would silently pick
    /// one of two provenances. There is no correct guess, so there is no
    /// guess.
    static func value(_ key: String, in text: String) -> String? {
        let hits = text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == key
            else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// The 40-hex sha inside a manifest value, short form, or `nil`.
    ///
    /// The `dep-pin` line is written by the build script as a Cargo fragment —
    /// `rev = "2bfc08aa…"` — so the sha is EMBEDDED IN SYNTAX rather than
    /// alone on the line. Extracting by regex rather than by trimming quotes
    /// means a change to how the script spells that fragment surfaces as a
    /// `nil` (the row abstains) instead of as `rev = "2bfc08a` rendered to an
    /// operator as a version.
    static func shortSHA(from value: String) -> String? {
        let scalars = Array(value)
        var run = ""
        for ch in scalars {
            if ch.isHexDigit {
                run.append(ch)
                if run.count == 40 { return String(run.prefix(8)) }
            } else {
                run = ""
            }
        }
        return nil
    }

    /// The phone row's subtitle.
    ///
    /// `core <short dep-pin> · this iphone` when the manifest shipped and
    /// carries an unambiguous, well-formed pin; `this iphone` otherwise —
    /// which is TRUE, unconditionally, and is the whole of what this row is
    /// entitled to say without a source.
    static func nodeSubtitle(in bundle: Bundle = .main) -> String {
        guard let text = manifestText(in: bundle),
              let pin = value("dep-pin", in: text),
              let short = shortSHA(from: pin)
        else { return "this iphone" }
        return "core \(short) · this iphone"
    }
}
