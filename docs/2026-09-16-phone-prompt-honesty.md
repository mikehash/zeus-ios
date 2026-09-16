# Phone prompt honesty — §5 content-matched guard-replace

Date: 2026-09-16
Branch: `feat/phone-prompt-honesty`
Walk parent: `18ee2ecd` (docs-only), main at `bcc7589`
Pin: `8e19318` — **unchanged**

## The defect (merakizzz's screenshot)

The app replied, on the operator's own device:

- *"218 tools (shell, files, web, messaging, macOS automation, browser control,
  sub-Titans, memory)"* — the phone enforces **five**.
- *"I can't see my LLM from here"* — the bridge computes the exact string one
  line before it constructs the agent.

Two different faults wearing one costume.

## Substrate

```
zeus-memory:1215  DEFAULT_AGENTS
zeus-memory:1217  "...autonomous AI Titan with 218 tools ... filesystem, shell,
                   web, messaging platforms, macOS automation, browser control."
zeus-memory:80    Workspace::init -> ensure_file("AGENTS.md", DEFAULT_AGENTS)
zeus-memory:90    ensure_file: create_new(true)  = O_CREAT|O_EXCL  WRITE-ONCE
zeus-memory:764   get_context(): push_str header, AGENTS.md, SOUL, USER, ...
zeus-memory:163   pub async fn read     :171  pub async fn write
bridge:679        PHONE_TOOLS [5]   :690 PHONE_DENIED [4]
bridge:372        model = "{provider}/{model}" -> build_config:722 -> Config.model
agent_loop:625, :2514   the ONLY readers of Config.model (routing)
```

Override-seam census (pin `8e19318`):

```
set_system_prompt 0 · with_system_prompt 0 · set_context_override 0
set_prompt 0 · set_capabilities_summary 0
POS ctl set_tool_policy 1 · set_goals_context 1 · NEG ctl zzzNoSuchSeam 0
Workspace = concrete struct, no trait
```

### Three consequences

1. **The assembly is append-only and has no override seam.** A preamble pushed
   from the bridge can only *coexist* with the on-disk AGENTS.md. Honest text
   beside the lie is still the lie in the model's input — built-but-dark at the
   prompt layer. "Supersede + pin-unchanged" is unsatisfiable; Zeus100 verified
   and withdrew that ruling.

2. **Editing `DEFAULT_AGENTS` is a dead edit.** `ensure_file` is `create_new`,
   so any phone that has launched once keeps the desktop persona forever. A
   template fix reaches only installs that do not exist yet. Landed ≠ live.

3. **"I can't see my model" was HONEST.** `"model"` inside the whole
   `get_context` body = 2 hits, both in a path comment (POS ctl `"agents"` = 3).
   Nothing carries `Config.model` into the prompt. The repair is to *give the
   prompt the value*, not to stop the model disclaiming.

## The cut

Fix the **source**, and the faithful renderer starts telling the truth.

- `phone_agents_body(model: Option<&str>)` — body generated **from
  `PHONE_TOOLS`**, one array, two readers (prompt + policy), so the advertised
  set cannot drift from the enforced one.
- `make_agents_honest(&Workspace, Option<&str>)` — replace **only** on a
  content match; anything else is returned byte-for-byte.
- Callers: `init` (model `None` — `client` is `Mutex::new(None)` at that
  instant, so a rendered guess would be the same lie inverted) and
  `set_provider` (model `Some`, read off the **constructed** client rather than
  the requested argument).

### The idempotence defect, caught pre-gate

With only `DESKTOP_MARKER` to match on, `init`'s replacement **removes its own
trigger** — so `set_provider`'s re-render would find no marker, decline, and the
armed model would never reach the prompt on any real launch. Correct-looking
code, dead from the second call onward. `PHONE_MARKER` makes the guard recognise
its own output; `the_phone_marker_is_actually_in_the_phone_body` stops the
heading and the guard drifting apart.

### config-sacred is vacuous here, and pinned anyway

```
AGENTS.md editors/viewers/writers in Sources/ = 0 files
NEG ctl zzzNoFile 0 · POS ctl send 24 files
```

The container's copy has exactly one author. The divergence arm is a
**regression safety**, explicitly *not* claimed as phone coverage.

## Legs (6 new, 31 → 37)

| leg | subject |
|---|---|
| `the_assembled_phone_prompt_carries_no_desktop_claim` | **load-bearing** honesty NEG on the assembled prompt from a planted desktop file, with a vacuity control (dishonest before) and a POS control (phone body survives) |
| `init_makes_the_agents_file_honest_on_an_existing_install` | wiring, existing-install arm, through the real constructor |
| `set_provider_puts_the_armed_model_into_the_assembled_prompt` | wiring, arming arm, full `init`→`set_provider` sequence; `assert_ne!` refuses a constant body |
| `the_armed_model_reaches_the_assembled_prompt` | helper-level model injection + idempotence |
| `the_phone_body_advertises_exactly_the_allowed_tools` | arity vs `PHONE_TOOLS`, plus no denied name advertised |
| `a_diverged_agents_file_is_left_untouched` | the safety |
| `the_phone_marker_is_actually_in_the_phone_body` | marker/body uniqueness |

## Mutations — 5 axes, 5 distinct legs, all build-alive

| mutation | reds |
|---|---|
| `init` drops the guard-replace | `init_makes_the_agents_file_honest_on_an_existing_install` |
| `set_provider` drops the re-render | `set_provider_puts_the_armed_model_into_the_assembled_prompt` |
| guard forgets `PHONE_MARKER` | `the_armed_model_reaches...` + `set_provider_puts...` |
| guard drops the content match | `a_diverged_agents_file_is_left_untouched` |
| body hardcodes 4 tools | `the_phone_body_advertises_exactly_the_allowed_tools` |

Restored byte-identical (md5 `dde24aa3de1c283e417876a770e00ec8`), 37 green.

## Instrument faults this session

1. **Standard #1, live.** Unquoted `--include=*.rs` under zsh → `no matches
   found` → every count printed a clean zero **including the POS control**. The
   impossible POS=0 is the tell.
2. **MUT1 survived the first suite.** Every honesty leg called
   `make_agents_honest` directly, so all of them proved the helper *correct* and
   none witnessed that anything *calls* it. Deleting `init`'s call left 37 green.
   Two wiring legs added through the production exports. Sixth arrival of
   correct-but-unreached; first time a mutation, not review, was the detector.
3. **Use-vs-mention, in my own production prose.** The honesty NEG red on the
   *fix*: my denial sentence said "no macOS automation", which contains the
   phrase the NEG forbids. A denial that restates the claim is indistinguishable
   from the claim to a substring search. Reworded to name the denied **tool
   identifiers** instead of the desktop capability nouns.
4. **`&&` chaining swallowed two mutation runs.** `cargo test` exits 101 on a
   red — the expected outcome — so the `&&` short-circuited before the report.
   Producer rc captured separately.

## Pin

`git diff --stat -- rust/` is non-zero: this lands **in Rust**, so the pin moves
and the xcframework needs a rebuild at gate.
