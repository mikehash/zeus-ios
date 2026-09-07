# Copy register

*Authored 2026-09-07 against `feat/m4-session-loop` @ `6258f1f`. One page. Read it
before you add a user-visible string.*

The app speaks in **two registers**, and they are not a style preference — they
track *who is talking*. Every copy defect found in the 31-string review of the
onboarding and the gateway editor was a string in the wrong one.

---

## Register A — the agent

**Who:** Zeus, addressing the operator. **Voice:** warm, first person, present
tense, contractions allowed. **Case:** sentence case. **Length:** one or two
short sentences. It may be charming; it may never be vague.

Three, from the shipping source:

1. `Commissioning.swift:41` — *"First — you. Authenticate as operator."*
2. `Commissioning.swift:54` — *"Now my brainstem. Give me a provider key and I reach the models direct."*
3. `Commissioning.swift:56` — *"Any hardware to enroll? Scan a node — or skip. I run fine solo."*

What makes them work: each states the *step* and the *ask* in the same breath,
and the personality is carried by the verb ("I reach", "I run fine solo"), never
by an adjective. Example 2 is the strongest line in the onboarding — the body
copy under it can be replaced; that sentence cannot.

## Register B — the machine

**Who:** the system reporting its own state. **Voice:** telegraphese — no
articles, no verbs of politeness, no first person. **Case:** upper. **Separator:**
` — ` between clauses, ` · ` between a value and its location.

Three, from the shipping source:

1. `NO PROVIDER — SET ONE IN ROUTES`
2. `PRESENT · KEYCHAIN`
3. `RUN PREFLIGHT`

What makes them work: **state → repair → where.** Example 1 is the canonical
form and the whole rule is derivable from it — it names the state (`NO
PROVIDER`), the repair (`SET ONE`), and the location (`IN ROUTES`). Example 2 is
the compressed form: state plus where, no repair needed because nothing is
broken. Example 3 is an imperative control, which is Register B's other legal
shape — verb first, object second, nothing else.

A Register B string that gives **state only** is incomplete. It leaves the
operator holding a fault with no next move, and — worse — it lets two distinct
states read as one. Two states that the code splits and the copy merges are
split for the tests only.

---

## The crossing rule

**A string crosses when its case, its person, or its vocabulary belongs to the
other register.** Three ways it happens, all observed:

- **Case crossing.** A lowercase field label sitting among caps controls reads as
  a hint rather than a label. Machine surfaces take caps, always.
- **Person crossing.** Register A saying "the system will…" is Register B in
  disguise; Register B saying "we couldn't…" is worse, because there is no *we*.
- **Vocabulary crossing — the expensive one.** Internal nouns never appear in
  either register. Not in an agent line, not in a machine verdict, not in a
  caption. If a term names a type, a milestone, a branch, a seat, or an
  acronym the team coined, it is ours and it stays inside.

The vocabulary rule has a corollary worth stating on its own, because it is how
the defect actually arrives: **never explain a disabled control by naming the
work that will enable it.** The operator cannot act on a milestone, cannot date
it, and cannot distinguish it from a bug. State the operator-facing fact
instead — what is true right now, in words that stop being true when the work
lands, so the string flags itself.

## Truth outranks both registers

A string in the right register can still be false. The one false claim in the
review promised an absence of network on a path that is explicitly network — and
the *true* claim available to it was both narrower and a stronger sell. When the
honest version is shorter, take it; when it is longer, take it anyway.

Two checks before a string ships:

1. **Does another screen contradict it?** Read the flow, not the string.
2. **Can it become false without anyone touching it?** If yes, pair it with a
   leg that greps it to zero when its condition ends. A caption whose premise
   can expire silently is a comment with no compiler behind it.

## Standing constraint

No seat names, no channel identifiers, no fleet vocabulary, and no bare counts
in user-visible copy. The counts matter for a mechanical reason as well as an
editorial one: the repo carries text guards that read prose and cannot
distinguish a number in *use* from a number in *mention*.

## Where this is enforced today

The source-reading legs (`RouteTests`, `VoiceTests`, `ApprovalsTests`,
`BackstepTests`) enumerate `Sources/ZeusApp/*.swift` only. **This document is
outside that corpus by construction** — a doc cannot trip them, and equally,
nothing here is enforced by them. The register is a review discipline; the legs
guard individual literals. Where a rule on this page can be turned into a grep,
turn it into a grep.
