# E2 walk — images AND documents (PDF/docx/txt/md)

Walked at `5cb1d86` on `feat/vision-images`, parent chain to `main 2af7865`.
Dispatch: merakizzz — "get the images working (and other attachments as well,
PDF, .docs, txt, .md)".

## Headline

**The document half is already shipped.** It is not a second capability to
build; it is a capability whose only missing piece is a picker filter and an
honest refusal. The two kinds travel on two *different, both-live* channels,
and conflating them is the mistake this walk exists to prevent.

## The two channels, measured

| kind | channel | encoder | reaches model as |
|---|---|---|---|
| `image/*` | `send(images:)` → `run_with_attachments` | `zeus_llm::multimodal` dialect table | a content part (base64) |
| everything else | `stage_attachment` → `[ATTACHED FILE: …]` → model calls `read_file` | `zeus_agent::document_extract` | `Role::Tool` text |

### Document extraction is real, pure-Rust, and already linked

```
zeus-agent/src/tools.rs:1526-1538   read_file detects the extension FIRST
  "docx"|"pptx"|"xlsx"|"xlsm"|"pdf"|"odt"|"ods"|"odp"|"epub"|"rtf"
zeus-agent/src/document_extract/mod.rs:38  extract_by_path → ooxml | pdf | odf
  ooxml.rs:41 extract_docx  (zip + quick-xml, word/document.xml <w:t> runs)
  pdf.rs      lopdf
deps NOT optional, NOT feature-gated: zeus-agent/Cargo.toml:50-53
  zip · quick-xml · calamine · lopdf   (plain workspace deps)
pub mod document_extract  — lib.rs:20, no #[cfg]
```

Our bridge takes `zeus-agent` at the same pin with `default-features = false`
(Cargo.toml:49) — and the dropped default set is `["audio","matrix","voice",
"automation"]`. **Document extraction is in none of them.** It is compiled into
the phone today.

`read_file` is in `PHONE_TOOLS` (bridge:892) and there is **no bridge-local
`read_file`** (`grep -c` = 0, POS ctl `into_core_attachments` = 1). So the tool
the model calls on a staged path is the agent's, extraction included, truncated
at `MAX_CONTENT_BYTES`.

**Consequence: a `.pdf`, `.docx`, `.txt` or `.md` picked today is staged,
referenced, and readable by the model with its text extracted.** `.txt`/`.md`
need no extractor at all — the UTF-8 fallback path serves them.

### Anthropic also accepts a PDF as a content part

`multimodal.rs:319` — `format_anthropic_attachment` routes
`application/pdf` → `format_anthropic_document` (`"type":"document"`, base64).
OpenAI (`:388`) and Gemini (`:400`) return `None` for it.

🔴 **Do not take this branch.** It is Anthropic-only, so the same picked PDF
would silently reach the model on one provider and vanish on another — the
provider-conditional behaviour the dialect table exists to hide. The
stage→`read_file` route works on *every* provider including Ollama, and its
content arrives on the tool channel, which is the security invariant at
bridge:1058 (content the model CHOSE to open, not prompt text it might obey).

## So what is actually missing

1. **The picker cannot reach photos.** `PhotosPicker`/`PHPicker`/`UIImagePicker`
   = 0 in `Sources/` (POS ctl `fileImporter` = 3, live at SessionView:439).
   `.fileImporter(allowedContentTypes: [.item])` is Files-only.
2. **Nothing routes by kind.** `RootView:833` sends every pick to
   `stageAttachmentSync`. After E1 the image channel exists and is unreachable
   from the UI.
3. **The E1 refusal still wears a fault's clothes** (`TransportError.embedded`
   → `"LOCAL CORE ERROR — …"`). Unchanged from the prior receipt; still the
   held commit.

## The cut, in dependency order

- **E1b (held)** — typed-refusal arm, so a non-image on the vision channel
  reads as a refusal rather than a core fault.
- **E2a — route by kind at the pick site.** `image/*` → `send(images:)`;
  everything else → `stage_attachment` (unchanged behaviour, now deliberate).
  The routing predicate must be the core's `is_image` reached through the
  bridge, not a Swift mime list — same no-second-source rule as E1.
- **E2b — `PhotosPicker` beside `fileImporter`**, plus widening the importer's
  content types from `[.item]` to a stated set. `NSPhotoLibraryUsageDescription`
  stays absent and pinned absent: `PhotosPicker` is out-of-process.

## Honesty obligation carried into E2

A picked `.zip`/`.mp3`/`.bin` matches neither channel: not an image, and
`read_file` on it returns the NUL-rejection path rather than text. That is the
`binary_files_are_named_but_not_content_indexed` shape (bridge:1723) arriving at
the picker. It must refuse **at the door with the extension named**, not stage
silently — the same class as the toast that claimed a file was indexed.
