# Walk — attach coherence guard (`feat/attach-coherence-guard`)

Base: iOS `main 875ac8b`. Prose before code, per the standing order.

## What is on disk today

`RootView.stage(_:)` — `RootView.swift:661-680`, the only production stage site:

```
662  guard let caps = EmbeddedCapabilities.shared()      // no core -> refuse
665  let scoped = url.startAccessingSecurityScopedResource()
666  defer { if scoped { url.stopAccessingSecurityScopedResource() } }
669  data = try Data(contentsOf: url)                    // UNCOORDINATED
673  guard !data.isEmpty else { .failed("THAT FILE IS EMPTY — NOTHING STAGED") }
675  caps.stageAttachmentSync(fileName:bytes:)
```

Census of the surfaces this arc needs, comment-stripped, with controls in the
same invocation:

```
resourceValues                        0 files
fileSizeKey / totalFileSizeKey        0 files
NSFileCoordinator                     0 files
ubiquitousItemDownloadingStatus       0 files
zzzNoSuchKey                          0 files   <- NEG ctl
startAccessingSecurityScopedResource  2 files   <- POS ctl
Data(contentsOf:                      2 files   <- POS ctl
```

So all three legs are net-new surface. Nothing to refactor, nothing to drift
from. (The first two attempts at this census returned clean zeros for *every*
pattern including both POS controls — an unquoted `--include` glob under zsh,
then an `xargs -0 -a` form fed from nothing. Standards #1/#3: the POS controls
are the only reason the dead instrument was distinguishable from true absence.)

## The defect the arc closes

`:673` is `!data.isEmpty` with **no size comparison**. Two distinct failures
collapse into one symptom at that line:

| what happened | what `:673` sees | honest? |
|---|---|---|
| security scope denied | read throws | yes — `COULD NOT READ THAT FILE` |
| ubiquitous item not downloaded | 0 bytes | yes — refuses, under-delivers |
| **partially materialised / streaming extension returns early** | **N > 0 bytes** | **NO — stages a fragment under a complete-looking `STAGED` line** |

The third row is the defect. The empty case refuses truthfully; the short case
*asserts a completeness it does not have*, and the model then reasons over a
fragment with no marker saying so. Reclassified with Zeus100: staged-and-short
is a defect, not an under-delivery.

## The three legs, and what each one actually is

**(a) status precondition** — `ubiquitousItemDownloadingStatusKey == .current`.
A *materialisation* predicate rather than a *quantity* comparison, so it does
not inherit the era-dependence below. It is a **different axis, same
respondent**: it widens the aperture, it does **not** create a second witness.

**(b) coordinated read** — `NSFileCoordinator`. A **barrier**, not a witness:
it makes the status, the declared size and the bytes coherent *in time*, which
kills the racy-disagreement case. A provider that under-reports the total and
short-reads the bytes agrees with itself inside the block as happily as outside
it.

**(c) coherence-post** — staged byte count vs `declaredTotal`.

> 🔴 `declaredTotal` arrives at the seam as a **PARAMETER**, never inline-read
> from the URL. Inline, the assert reads a value the simulator will never make
> short, so the failing red is **unwritable by construction** — the
> `written.starts_with(root.join(x))` tautology class, one arc later. At a seam
> taking `(declaredTotal, stagedCount)` the red is trivial: `(4096, 512)` →
> refuse.

Era-dependence, and why (c) alone would not do: a dataless APFS placeholder
reports the declared *logical* size (guard works), whereas a legacy `.icloud`
stub is a different, small file whose size is the *stub's* (guard becomes a
tautology after a short read of the stub). Same key, opposite semantics,
decided by the provider extension. (a) is what makes that unreachable.

## The headline, scoped at the boundary

> **Materialised-and-coherent against a non-adversarial, eventually-consistent
> provider.**

Never "complete". The check catches **incoherent** truncation — the common
case, a partially-materialised item read without coordination. It is **blind to
coherent truncation**, where the provider under-reports and short-reads in
agreement. Standard #5 in provider costume: naming it correctly is the guard
against trusting it past its reach.

The generator behind that scoping: **ask which RESPONDENT answers a check
before asking WHAT it measures.** Status, size and bytes all come from the one
provider. Two questions to one source is a *consistency* instrument; an
independent witness needs a different *source*, and inside an app sandbox
reading a file provider there isn't one. That is the boundary of the position,
not a gap in the design.

## Shape of the cut

A new `AttachCoherence` seam, pure and `URL`-free by construction, plus the
coordinated read at the one layer that holds the security scope.

- `AttachCoherence.materialisation(downloadingStatus:)` — (a), takes the status
  value, returns materialised / a refusal sentence.
- `AttachCoherence.coherence(declaredTotal:stagedCount:)` — (c), the parameter
  seam. Takes two `Int?`/`Int`, knows nothing about files.
- `RootView.stage` reads the two resource values, coordinates the read, and
  hands both seams their arguments.

The seam file containing **zero** `URL`/`resourceValues` tokens is itself the
guard against the inline regression: inlining the size read would have to put a
URL read in that file, which a census leg reds on.

Refusals render through the existing `stageError` path — the same surface the
empty guard uses, so staged-but-incomplete is shown as honestly as empty.

## Legs to write

1. `(declaredTotal, stagedCount) = (4096, 512)` → refuse, and `(4096, 4096)` →
   allow. The writable red.
2. `declaredTotal == nil` → allow (a non-ubiquitous local file has no declared
   total; refusing there would break every ordinary pick).
3. status not `.current` → refuse with a sentence naming the fix.
4. status `nil` (not a ubiquitous item at all) → allow.
5. wiring: `stage` calls both seams — the correct-but-unreached class has
   arrived twice in this arc already, and only a wiring leg catches it.
6. coordination: the read is inside `NSFileCoordinator.coordinate`, and the
   uncoordinated `Data(contentsOf: url)` form is absent from `stage`.
7. seam purity: `AttachCoherence.swift` contains no `URL`/`resourceValues`
   token — the inline-regression census, with a POS control.
8. Phase-3 `PendingPromptHasExactlyTwoNamedWriters` and every existing attach
   leg stay green and unmodified.
