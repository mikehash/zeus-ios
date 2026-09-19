# Arc E — ruling (c) fails gate (b), and the measurement that replaces it

Addendum to `docs/2026-09-19-arc-e-images-walk.md`. Read-only. Pin `8e19318c`.

## The ruling as written cannot be built at this pin

> "Add a sibling (`run_structured_with_attachments(&str, Vec<Attachment>) -> TurnResult`)
> that calls `run_turn(input, attachments, None)`."

Two-gate check on that instruction:

- **(a) target method exists** — YES. `agent_loop.rs:1499`.
- **(b) target method is callable from the rewrite site** — **NO.**

```
grep -c "pub async fn run_turn"        agent_loop.rs   → 0
grep -c "    async fn run_turn"        agent_loop.rs   → 1   (POS ctl, known-present)
grep -c "pub async fn run_with_attach" agent_loop.rs   → 1   (POS ctl, known-pub)
grep -c "pub async fn zzzNoSuchFn"     agent_loop.rs   → 0   (NEG ctl)
```

`run_turn` is **private to `zeus-agent`**. A sibling calling it must live inside
`impl Agent` in the upstream crate — i.e. an edit to the pinned dependency, which
is option (b) wearing option (c)'s clothes. The bridge is a different crate; it
cannot reach a private method by any local change.

## What replaces it: the field census the earlier walk never ran

The walk rejected `run_with_attachments` because it "loses `TurnResult`" and so
"regresses the authoritative-body preference at bridge:447." That was asserted,
not measured. Measured:

```
bridge/src/lib.rs, reads of TurnResult fields
  result.content        2      ← POS ctl, known-present
  result.tool_calls     0
  result.input_tokens   0
  result.output_tokens  0
  result.iterations     0
  result.stop_reason    0
  result.zzzNoSuchField 0      ← NEG ctl
grep -c TurnResult      1      ← a doc comment; never named in a signature
```

And upstream:

```rust
pub async fn run_with_attachments(&mut self, input, attachments) -> Result<String> {
    let turn = self.run_turn(input, attachments, None).await?;
    Ok(turn.content)                                  // ← the authoritative body
}
```

`turn.content` **is** the authoritative body bridge:447 prefers. The bridge reads
nothing else off `TurnResult`. So `run_with_attachments` delivers the identical
value the preference exists to select, and the `is_empty() → streamed join`
fallback survives unchanged on a `String`.

The rejection was wrong, and it was wrong in the specific way the standards name:
a property claimed of the type without measuring which of its fields the consumer
reads.

## Consequence

E1 is a **one-call-site change in our own crate**: `run_structured(&text)` →
`run_with_attachments(&text, attachments)`. Pin unmoved, no upstream edit, no
private method needed. `run_addressed` is a second pub door with the same shape
(`-> Result<String>`, takes attachments) if the `is_addressed` flag is ever wanted.
