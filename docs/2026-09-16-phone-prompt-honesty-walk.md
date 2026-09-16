# Phone prompt honesty — substrate walk

**Date:** 2026-09-16
**Branch:** `feat/phone-prompt-honesty`, parent `bcc7589` (= zeus-ios main)
**Pin:** mikehash/Zeus @ `8e19318ccda7023a5c2ec59e4978c6a0855b8c50` — unchanged, read-only for this walk
**Subject:** the screenshot defect — the phone claiming "218 tools" and disclaiming a model
the bridge already computes.

---

## 1. What the model actually receives

```
bridge send():372   model = "{provider}/{model}"   → build_config:722 → Config.model
Agent::new(config, llm, workspace, session, None)
run_turn:1825       context_hash = workspace.get_context_mtime_hash()
run_turn:1836       system_prompt = workspace.get_context().await?      ← DISK
zeus-memory get_context:764-880 reads, in order:
  AGENTS.md · SOUL.md · USER.md · IDENTITY.md · USER.md · TOOLS.md ·
  HEARTBEAT.md · CAPABILITIES · MEMORY.md · RECENT_ACTIVITY · MENTIONS
```

`Config.model` is read by the loop for **routing** (agent_loop:625, :2514) and is never
pushed into `system_prompt`. Measured: `"model"` inside the whole `get_context` body = 2
hits, both inside a comment about file paths (POS ctl `"agents"` = 3).

**So the screenshot's "I can't see my model" is HONEST.** The repair is not "stop lying",
it is "give the prompt the value the bridge already holds".

## 2. Why the 218 line is not fixable by editing the template

```
zeus-memory:1215  const DEFAULT_AGENTS = "…autonomous AI Titan with 218 tools …
                   filesystem, shell, web, messaging platforms, macOS automation,
                   and browser control."
  :1305  "## macOS Automation (Talos — 193 tools)"
  :1329  "Browser Automation (11 tools)"
workspace.init():80   ensure_file("AGENTS.md", DEFAULT_AGENTS)
ensure_file:90-108    OpenOptions::create_new(true)   // O_CREAT|O_EXCL
                      AlreadyExists => "nothing to do"
bridge init():186     rt.block_on(workspace.init())
```

Write-once. Every phone that has launched the app **once** already holds the desktop
persona in its container, and no future default reaches it. Editing `DEFAULT_AGENTS`
repairs fresh installs only — the landed-≠-live rung.

## 3. The seam census — there is no prompt-override on the pin

Counted in `crates/zeus-agent/src/agent_loop.rs`:

```
pub fn set_system_prompt          0
pub fn with_system_prompt         0
pub fn set_prompt                 0
pub fn set_context_override       0
pub fn set_capabilities_summary   0
zzzNoSuchSeam                     0      ← NEG ctl
pub fn set_tool_policy            1      ← POS ctl
pub fn set_goals_context          1      ← POS ctl
```

`Workspace` is a **concrete struct**, not a trait (`agent_loop:15,299,511`) — there is no
conformer to substitute. The only pub setters that reach the prompt are
`set_goals_context` / `set_tasks_context`, and both **append** at :1979-1990, i.e. AFTER
the AGENTS.md body at :1836.

> **Therefore: with the pin unchanged, a preamble can only COEXIST with the frozen file.**
> That is precisely the shape the ruling rejects — honest text riding alongside the lie,
> built-but-dark at the prompt layer.

## 4. The "config-sacred" premise does not hold on the phone

The ruling declines a rewrite because it clobbers user edits. Measured on the app:

```
AGENTS      in Sources/ = 0 files
SOUL.md     in Sources/ = 0 files
IDENTITY.md in Sources/ = 0 files
zzzNoFile   in Sources/ = 0 files   ← NEG ctl
send        in Sources/ = 24 files  ← POS ctl
```

There is **no editor, viewer, or writer for AGENTS.md anywhere in the app.** The file in
the phone container has exactly one author — `DEFAULT_AGENTS`, via `ensure_file`, at first
launch. "User edits" is a desktop-shaped concern with no phone-shaped instance.

## 5. Proposed reconciliation — supersede the template, never an edit

Write a phone-scoped `AGENTS.md` at bridge `init`, **guarded on the content being the
template we know we wrote** (the `218 tools` marker line):

- content matches the desktop template → replace with the phone body → the frozen lie
  does not survive into `get_context`, and the load-bearing leg is satisfied.
- content has diverged → leave untouched. Config-sacred is honoured at the only place it
  can bind. On a phone this arm is a **safety, not a live path** (§4) — state that, do not
  claim it as coverage.

Body is generated from the bridge's own `PHONE_TOOLS` array (one body, two readers — the
shape `phone_tool_policy` already uses), so the advertised count cannot drift from the
allow-list. Arity leg asserts preamble names == `PHONE_TOOLS.len()`.

**Model string:** not knowable at `init` (`client: Mutex::new(None)`, bridge:227). It is
knowable at `set_provider`, which is the arming site — so the phone body is re-rendered
there with the armed `provider/model`. Two write sites, one generator.

## 6. Gate shape

- honesty NEG on the **assembled** prompt (`workspace.get_context()` after a planted
  `218` file), not on the preamble in isolation — assert `218` and the disclaim string
  are both absent from the model's real input.
- arity leg: rendered body names == `PHONE_TOOLS.len()`.
- supersede leg: planted template → replaced; planted divergent file → byte-identical
  after init.
- build-alive mutations, distinct legs. `cargo test` on the bridge; Swift suite on the
  warm framework (pin unchanged → verify the xcframework is present, rebuild only if the
  tmp-cleaner gutted it).

## 7. Open adjudication

§3 and §4 together mean the ruling's two constraints ("pin unchanged" + "never rewrite the
persisted file") cannot both hold while the load-bearing leg is satisfied. §5 is the
reconciliation I lean to. The alternatives are: move the pin and add a prompt-override
seam upstream (different repo's review), or accept a coexisting preamble (rejected shape).
Not cutting code until that is ruled.
