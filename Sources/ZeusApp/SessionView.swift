import SwiftUI
import PhotosUI

/// What a pick produced: a staged path, or a reason it did not.
///
/// A named two-case enum rather than `Result<String, String>` — `String` does
/// not conform to `Error`, which the compiler said before this shipped, and
/// wrapping the reason in an error type to satisfy `Result` would be ceremony
/// around a value that is already a display string. The failure arm carries the
/// sentence the operator READS, so there is no layer between the refusal and
/// what is on screen.
enum StageOutcome: Equatable {
    case staged(String)

    /// An image, held for the vision channel rather than written to the
    /// workspace. A THIRD CASE rather than a staged path with a flag: the two
    /// outcomes have different destinations (`read_file` on a path vs bytes on
    /// the wire), and collapsing them is what forced the image route to refuse
    /// in the previous cut.
    case attachedImage(OutboundImage, name: String)

    case failed(String)
}

/// One turn in the session transcript.
///
/// The prototype's message objects (:411-412, :455-465) carry three fields:
/// `role` ('user' | 'agent'), `text`, and an optional `streaming` flag set
/// only on the trailing agent message while tokens arrive.
///
/// `role` is an enum for the same reason `Tab` and `AgentState` are: the
/// prototype's two string literals are the whole set, and a third would have
/// to break a `switch` rather than silently fall through a ternary.
struct Message: Identifiable, Equatable {
    enum Role: String, CaseIterable { case user, agent }

    let id = UUID()
    let role: Role
    var text: String
    var streaming: Bool = false
}

/// SessionTab, :855-903.
///
/// Structure carried: header row (orb + SESSION-01 + status line + badge),
/// scrolling transcript with role-asymmetric bubbles, composer whose trailing
/// button swaps between send and mic on whether the input trims to empty.
struct SessionView: View {
    let messages: [Message]
    let statusLine: String
    let state: AgentState
    /// The gateway-named session id, or `nil` before the first reply names
    /// one. Not defaulted to a string: a default here would reintroduce the
    /// exact defect this field removes.
    var sessionID: String? = nil
    /// Deep-link prefill, consumed once.
    ///
    /// A BINDING and not a plain value, because the view must be able to
    /// clear it: `zeus://session?prompt=x` twice in a row is two distinct
    /// user intents, and a non-clearing value would compare equal the second
    /// time and silently do nothing. The owner sets it; this view nils it
    /// the moment it has been applied.
    ///
    /// Declared ABOVE the closures deliberately: Swift's memberwise init
    /// fixes argument order to declaration order, and the call site reads
    /// `prefill:` before `onSend:`.
    var prefill: Binding<String?> = .constant(nil)

    /// NO DEFAULT. `= { _ in }` here would ship a composer that renders,
    /// accepts text, highlights SEND, takes the tap and does nothing — an
    /// empty closure is worse than an absent one because it is a lie with a
    /// tap target, indistinguishable from working software until an operator
    /// tries it. `prefill` above keeps its default for the opposite reason: a
    /// binding to nothing is a VALUE, not an unwired affordance.
    var onSend: (String, [OutboundImage]) -> Void

    /// What the voice affordance is doing right now.
    ///
    /// A VALUE, not a flag the view derives: the four states are decided by
    /// OS capability and two authorization grants, none of which a `View`
    /// body can read. Owned above, rendered here.
    var voiceState: VoiceState = .idle

    /// Tapping the mic. Toggles — the same button starts and stops.
    var onVoice: () -> Void = {}

    /// C — open the history sheet.
    ///
    /// NO DEFAULT, the `onSend` rule one affordance over: `= {}` here ships a
    /// button in the header that highlights, takes the tap and does nothing —
    /// indistinguishable from working software until an operator tries it.
    var onHistory: () -> Void

    /// Why sending is impossible right now, or `nil` if it is possible.
    ///
    /// A STRING rather than a Bool, because a disarmed composer with no reason
    /// is a dead button: the operator sees that it does not work and has no way
    /// to learn why. The value is `GatewayConfig.disarmReason` — today only
    /// `.local(.noProvider)` produces one.
    ///
    /// Rendered BEFORE the first send. The bridge would also refuse the turn
    /// (`BridgeError::NoProvider`), but discovering a configuration fact as a
    /// failed message in the transcript teaches the operator that the app is
    /// broken rather than that the setup is unfinished.
    /// NO DEFAULT, for the reason stated at `headerAccessibilityLabel`, one
    /// level up: a memberwise default lets the next call site omit readiness
    /// and silently render a live composer over an unarmed core. The sole
    /// production caller (`RootView:399`) passes it today; the `= nil` was a
    /// hole waiting for a second caller, not a convenience anyone used.
    var disarmReason: String?

    /// C1 — commit a transcript turn to Mnemosyne through the core's
    /// `remember(fact:)`.
    ///
    /// TAKES THE MESSAGE, NOT THE TEXT. The owner needs the role to decide
    /// nothing today — but a `(String) -> Void` here would make the call site
    /// the only place the role is known, and the leg that matters most for
    /// this feature is that the AGENT's reply gets written and not the
    /// operator's prompt. Passing the whole message keeps that assertion
    /// possible one level up, where the core handle lives.
    ///
    /// NO DEFAULT, same rule as `onSend` two properties up: an empty closure
    /// would ship a menu item that highlights, takes the tap, and writes
    /// nothing — a lie with a tap target on it.
    var onRemember: (Message) -> Void

    /// Live microphone energy, `0...1`, forwarded to the stage orb.
    ///
    /// Passed in rather than read here for the reason every other derivation
    /// on this screen is static: a `View` cannot be observed in-process, so a
    /// value computed inside a body is guardable only by screenshot. The
    /// producer is the ONE `VoiceInput` at `RootView:61` — this screen does
    /// not own a second microphone.
    var micLevel: Double = 0

    /// A transcript the operator SPOKE, committed once.
    ///
    /// 🔴 WHY THIS IS NOT `prefill`. The two carry different intents and only
    /// one of them may dispatch itself. `prefill` is also the deep-link
    /// channel (`RootView:460`), so arming auto-send on it would not add a
    /// voice behaviour — it would add a RELEASE auto-send to every `zeus://`
    /// URL any other app on the phone can fire, which is the precise threat
    /// `LaunchArgs.swift:177` documents and the reason the capture seam below
    /// is `#if DEBUG`. Discriminating by an origin flag riding alongside the
    /// text would put the authority to send inside a `Bool` a caller sets;
    /// two channels make the wrong dispatch unrepresentable instead.
    ///
    /// A `Binding` for the same single-shot reason `prefill` is: saying the
    /// same sentence twice is two intents, and a non-clearing value would
    /// compare equal the second time and silently do nothing.
    var voiceCommit: Binding<String?> = .constant(nil)

    // DECLARATION ORDER IS CALL-SITE ORDER, and that is load-bearing: Swift's
    // memberwise init fixes argument order to declaration order, so each
    // property's position in this file IS its position at the call site.
    // `onRemember:` was appended AFTER `disarmReason:` for that reason — it is
    // the newest parameter, so it goes last and every existing argument keeps
    // the position it already had.


    @State private var input: String = ""

    /// The transcript log is SECONDARY on this screen — the prototype demotes
    /// it behind a toggle (jsx:`showLog`) and the stage takes the body. False
    /// by default: the voice stage is the screen, not a mode of it.
    @State private var showLog: Bool = false

    /// The keyboard is SUMMONED, not resident (jsx:`showText`). The composer
    /// is a secondary path on a voice-first screen, so it is absent until
    /// asked for — and it keeps explicit send when it arrives.
    @State private var showKeyboard: Bool = false

    /// Whether the document picker is up.
    @State private var showPicker: Bool = false

    /// The photo the operator chose, before its bytes have been loaded.
    ///
    /// `PhotosPicker` binds to an ITEM, not to a presentation flag: the sheet
    /// is presented by the control itself, out of process, and the selection
    /// arrives asynchronously. Cleared on receipt so picking the same photo
    /// twice is two intents — the same single-shot reason `prefill` is a
    /// binding this view nils.
    @State private var photoItem: PhotosPickerItem? = nil

    /// The workspace-relative path of the staged file, if one is waiting.
    ///
    /// Owned here rather than pushed straight into `input`: the reference is
    /// not the operator's prose and must not land in a field they can edit into
    /// something else. It is composed onto the turn at SEND time, which is also
    /// why a staged file survives a `NoProvider` — the copy already happened,
    /// and the reference rides the next turn that has somewhere to go.
    @State private var attachment: OutboundAttachment? = nil

    /// Why the last pick failed, if it did. An empty file, a read refusal, or a
    /// staging error — said rather than swallowed, because a silent pick reads
    /// as "the app ignored my file."
    @State private var stageError: String? = nil

    /// Whether a provider is armed — for the STAGED line's wording only.
    ///
    /// NOT for `attachEnabled`. Staging works offline; the provider gates the
    /// model READING the file, so it changes what the line SAYS and never
    /// whether the control acts.
    var providerArmed: Bool = false

    /// Stage a picked file. Injected, because a `View` cannot own a core.
    ///
    /// Returns the workspace-relative path on success. `nil` means the stage
    /// failed and `stageError` carries the reason.
    var onStage: (URL) -> StageOutcome = { _ in .failed("NO CORE ON THIS DEVICE") }

    /// Stage bytes that arrived without a URL — the photo road.
    ///
    /// A SECOND seam rather than a URL the picker does not have: a
    /// `PhotosPickerItem` is loaded out-of-process and yields `Data`, and
    /// faking a `file://` URL to reuse `onStage` would send the security-scope
    /// and ubiquitous-status guards after a file that does not exist. Both
    /// seams meet again at `AttachDoor`, which is where they must not differ.
    var onStagePhoto: (String, Data) -> StageOutcome = { _, _ in .failed("NO CORE ON THIS DEVICE") }

    /// Whether the orb is currently allowed to speak replies.
    ///
    /// Passed in, not owned: the producer is the ONE reply `Narrator` at
    /// `RootView:84`, and a second source of truth here would let the glyph
    /// disagree with the synthesizer it claims to describe.
    var narrationOn: Bool = true

    /// Flip the narration preference. NO DEFAULT for the same reason `onSend`
    /// has none — an empty closure would ship a speaker glyph that toggles its
    /// own picture and changes nothing, which is the dead-control class this
    /// app retires.
    var onToggleNarration: () -> Void


    private var trimmed: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The header identifier, derived — never a literal.
    ///
    /// Three states, and the middle one is the point: before any turn the
    /// gateway has named nothing, so there IS no session id, and the honest
    /// render is an absence. A placeholder number would have the shape of
    /// data. Truncated to the first 8 characters because gateway ids are
    /// UUID-length and the row is 11pt tracked at 0.24em — the full value
    /// would push the status line out of the row.
    static func sessionTitle(for id: String?) -> String {
        guard let id, !id.isEmpty else { return Theme.joined(["SESSION", "—"]) }
        return Theme.joined(["SESSION", id.prefix(8).uppercased()])
    }

    /// Whether a send can proceed. THE predicate, used by both the button's
    /// `enabled:` and by `send()` — two call sites, one decision.
    ///
    /// `static` and pure for the reason `sessionTitle` is: a SwiftUI body is
    /// not observable in-process (this target has no ViewInspector), so a
    /// predicate left inline in the view is guardable only by screenshot.
    ///
    /// 🔴 APERTURE, stated because the guard is narrower than it looks: this
    /// function is tested; the two lines that CALL it are not. A mutation that
    /// replaces `enabled: SessionView.canSend(...)` with `enabled: true`
    /// survives the whole suite — measured, not feared (MUT-3 at this commit).
    /// One decision in one testable place is a smaller unguarded surface than
    /// two inline expressions, not a closed one.
    static func canSend(trimmedInput: String, disarmReason: String?) -> Bool {
        disarmReason == nil && !trimmedInput.isEmpty
    }

    // MARK: - Voice stage (jsx:911-film — SessionTab rebuilt voice-first)

    /// The one line under the stage orb.
    ///
    /// Mic state wins when it has something to say, because a denial is
    /// fixable and the operator can act on it. Otherwise the invitation —
    /// which names the control by the label the button actually carries, so
    /// the sentence and the tap target cannot drift apart.
    static func stageLine(voiceState: VoiceState, partial: String?) -> String {
        if let p = partial?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return p
        }
        if let line = voiceState.line { return line }
        return "TAP COMMS TO TRANSMIT"
    }

    /// Whether the stage orb should meter real audio.
    ///
    /// Clamped at the seam for the reason `HomeView.orbLevel` clamps: the
    /// renderer documents `0...1` and an argument may not inherit a
    /// producer's range by assumption. Off the tap, the value is the
    /// two-valued constant over a real reading — NOT a mic amplitude, because
    /// nothing is metering one.
    static func stageLevel(state: AgentState, voiceState: VoiceState, micLevel: Double) -> Double {
        if voiceState == .listening { return min(max(micLevel, 0), 1) }
        switch state {
        case .listening, .responding: return 0.7
        case .thinking, .ambient:     return 0.2
        }
    }

    /// 🔴 THE ATTACH ARM — now real, and real is why the reason changed.
    ///
    /// It shipped terminal-disabled for three phases because no picker and no
    /// ingest path existed: the prototype drew a paperclip that fabricated a
    /// filename (`CAPTURE-0142.JPG`), toasted `FILE INDEXED — SESSION CONTEXT`
    /// and appended "Received X — indexed to session context", all of it
    /// invented. None of that is transcribed now either; what landed instead is
    /// the capability the button was always claiming.
    ///
    /// ## What the pick actually does
    ///
    /// The file is COPIED into the workspace (`ZeusCore.stageAttachment`) and
    /// the turn carries a one-line REFERENCE to its path — never the bytes.
    /// The model opens it, if it chooses, with the confined `read_file` it
    /// already has, and the content comes back on the tool channel as DATA. A
    /// build that inlined the file into the turn text would put a body reading
    /// "ignore previous instructions" into the prompt as prose; this one
    /// cannot, because the composer never sees the content.
    ///
    /// ## Why it is not conditioned on the provider
    ///
    /// Staging is real work that survives a `NoProvider`: the copy succeeds
    /// offline, and the reference rides the next turn that has somewhere to go.
    /// So `attachEnabled` tracks the PICK-AND-STAGE path — which is always
    /// present in this build — and NOT provider state, exactly as it is not
    /// conditioned on link state. The provider gates the model READING the
    /// file, the way it gates every other message.
    static let attachReason = "ATTACH — STAGE A FILE INTO THE WORKSPACE"

    /// What a staged-but-unsent file says. STAGED, never RECEIVED.
    ///
    /// The honesty bar the whole arc has been held to: the file is on disk and
    /// nothing has read it yet. "Received" would claim the model saw it, which
    /// is the fabricated-toast defect with a true filename attached — worse,
    /// not better, because a real name makes the lie credible.
    /// Built through `Theme.joined`, not a hardcoded separator: `check_separator_debt`
    /// caught the literal form, and it was right — `Theme.separator` is
    /// NBSP-padded, so a retyped `·` renders a different glyph pair than every
    /// other identity strip on the screen.
    static func stagedLine(path: String, armed: Bool) -> String {
        Theme.joined(["STAGED", path,
                      armed ? "SENDS WITH NEXT MESSAGE" : "PENDING — NO PROVIDER ARMED"])
    }

    /// The text one turn actually carries: the operator's prose, plus a
    /// reference line when a file is staged.
    ///
    /// 🔴 A PATH, NEVER THE BYTES — the security invariant as a function. The
    /// content the model learns about the file it learns by CALLING `read_file`
    /// on this path, so it arrives on the tool channel as data. Composing the
    /// bytes in here instead would be the auto-execute surface wearing a
    /// convenience costume.
    ///
    /// Reference goes LAST, after the operator's words, so a file cannot
    /// prefix-frame the instruction it is attached to.
    static func turnText(typed: String, stagedPath: String?) -> String {
        guard let staged = stagedPath, !staged.isEmpty else { return typed }
        return "\(typed)\n\(attachmentReference(relPath: staged))"
    }

    /// Whether the attach control may act.
    ///
    /// Reads whether a stage path EXISTS, which in this build it does. Kept a
    /// named derivation rather than an inline `true` for the reason it was a
    /// named `false` before: a leg refuses a `link.`- or provider-conditioned
    /// spelling BY NAME, and both are live temptations that would re-assert the
    /// thing this arc spent three phases removing.
    static var attachEnabled: Bool { true }

    var body: some View {
        VStack(spacing: 0) {
            header
            // VOICE-FIRST. The stage is the screen's body by default and the
            // transcript is a toggle over it, inverting the pre-phase-3
            // layout where the log was the body and voice was a button on the
            // composer. The prototype makes the same inversion (jsx:`showLog`
            // false by default, orb centred).
            if showLog {
                transcript
            } else {
                stage
            }
            // The state SAID, above the composer, not merely glyphed. A
            // slashed icon tells an operator something is off; this tells
            // them WHICH thing and whether Settings can fix it. `.idle`
            // renders nothing at all — a persistent "ready" line would be
            // status chrome for a state that is just the absence of one.
            if let line = voiceState.line {
                Text(line)
                    .font(Theme.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(voiceState == .listening
                                     ? Theme.accent : Theme.w(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityLabel(line)
            }
            // SAID, not merely enforced. The same row the voice states use,
            // for the same reason: a disabled control tells the operator that
            // something is off, and only text tells them which thing and what
            // to do about it. `NO PROVIDER — SET ONE IN ROUTES` names the
            // destination, so the sentence is an instruction rather than a
            // diagnosis.
            // SAID. The attach control is dead with a reason, and the
            // reason is on the screen rather than only in an accessibility
            // label — the same rule BROADCAST/PING follow one tab over.
            // The staged file, said honestly. STAGED, never RECEIVED — the
            // arc's standing bar: a real filename attached to a false claim is
            // worse than a fabricated one, because it is credible.
            if let why = stageError {
                Text(why)
                    .font(Theme.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityLabel(why)
            }
            if let attachment {
                Text(attachment.line(armed: providerArmed))
                    .font(Theme.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(Theme.w(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityLabel(SessionView.attachReason)
            }
            if let reason = disarmReason {
                Text(reason)
                    .font(Theme.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityLabel(reason)
            }
            // SUMMONED, not resident. A voice-first screen that keeps a
            // permanent text field says the keyboard is the primary path;
            // the field arrives when asked for and keeps EXPLICIT send when
            // it does — `onSubmit(send)` and the SEND button, both guarded by
            // `canSend`. The keyboard arm is deliberately the one that does
            // not auto-commit.
            if showKeyboard {
                composer
            }
            stageControls
        }
        // Apply on APPEAR as well as on change: a deep link arriving on a
        // cold start sets the value before this view exists, so an
        // `onChange`-only wiring would drop the very first link the app ever
        // receives — the one case a user is most likely to try.
        .onAppear {
            applyPrefill()
            applyVoiceCommit()
        }
        .onChange(of: photoItem) { _, item in receivePhoto(item) }
        .onChange(of: prefill.wrappedValue) { _, _ in applyPrefill() }
        .onChange(of: voiceCommit.wrappedValue) { _, _ in applyVoiceCommit() }
        // `.fileImporter` over a hand-rolled `UIDocumentPickerViewController`
        // wrapper: it IS that controller, presented by SwiftUI, and it hands
        // back a security-scoped URL with the same semantics. A
        // `UIViewControllerRepresentable` would add a file of ceremony to reach
        // the identical API.
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            stageError = nil
            switch result {
            case .failure(let e):
                stageError = "PICK FAILED — \(e.localizedDescription.uppercased())"
            case .success(let urls):
                guard let url = urls.first else { return }
                switch onStage(url) {
                case .staged(let rel): attachment = .staged(rel)
                case .attachedImage(let img, let name): attachment = .image(img, name: name)
                case .failed(let why): stageError = why
                }
            }
        }
    }

    /// Commit a SPOKEN turn. The voice arm auto-sends; the keyboard arm does
    /// not (jsx:447 vs jsx:1001-1003).
    ///
    /// It calls `send()` — the SAME function the SEND button and the return
    /// key call — rather than reaching past it to `onSend`, so `canSend`'s
    /// refusal of a disarmed composer applies identically. A path that
    /// assembled its own turn would bypass the one decision this screen has.
    ///
    /// NOT `#if DEBUG`: unlike the capture seam, this arm is reachable only
    /// from an utterance `VoiceTranscript.accepted` already accepted on THIS
    /// device, and it never carries a value another app can set.
    ///
    /// Single-shot: the binding is nilled BEFORE the send, so a re-render
    /// triggered by the send cannot re-enter it.
    private func applyVoiceCommit() {
        guard let spoken = voiceCommit.wrappedValue,
              !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        voiceCommit.wrappedValue = nil
        input = spoken
        send()
    }

    /// Load a picked photo's bytes and push them through the shared door.
    ///
    /// ASYNC because `loadTransferable` is: the item is a reference into
    /// another process and the bytes have to be fetched. The `Task` is why the
    /// selection is cleared inside it rather than at the call — clearing first
    /// would nil the item this closure is about to read.
    ///
    /// A nil load is SAID, not swallowed. An iCloud photo that is not on the
    /// device returns nothing, and a picker that visibly did nothing reads as
    /// "the app ignored my photo" — the same rule the file road's
    /// `stageError` follows.
    private func receivePhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        stageError = nil
        Task {
            defer { photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
                stageError = "COULDN'T LOAD THAT PHOTO — IT MAY NOT BE ON THIS DEVICE"
                return
            }
            // The name is for the OPERATOR's line; the bytes are the message.
            // Its extension still matters, because it is what the UTI table
            // reads to name a candidate mime for the core to judge.
            let name = item.supportedContentTypes.first?.preferredFilenameExtension
                .map { "PHOTO.\($0)" } ?? "PHOTO.JPG"
            switch onStagePhoto(name, data) {
            case .staged(let rel): attachment = .staged(rel)
            case .attachedImage(let img, let nm): attachment = .image(img, name: nm)
            case .failed(let why): stageError = why
            }
        }
    }

    /// Move a pending prefill into the composer, then clear it.
    ///
    /// REPLACES rather than appends. A deep link is a fresh intent, not a
    /// continuation of half-typed text; appending would splice a URL's words
    /// onto a sentence the user was mid-way through and send the result on
    /// one tap.
    ///
    /// The clear is what makes the binding single-shot — see `prefill`.
    private func applyPrefill() {
        guard let pending = prefill.wrappedValue, !pending.isEmpty else { return }
        input = pending
        prefill.wrappedValue = nil

        // CAPTURE SEAM, `#if DEBUG` and inert unless `-zeusAutoSend` is passed.
        // Calls `send` — the SAME function the SEND button's `action:` calls —
        // so `canSend`'s refusal of a disarmed composer applies here
        // identically. A seam that assembled its own turn would be measuring
        // itself rather than the production path. Single-shot by inheritance:
        // `prefill` is nilled above, so this fires once per deep link and not
        // on the re-render that follows.
        #if DEBUG
        if LaunchArgs.autoSend { send() }
        #endif
    }

    // MARK: - Header (:868-878)

    private var header: some View {
        HStack(spacing: 10) {
            OrbGlyph(diameter: 34, mode: state.orbMode)

            VStack(alignment: .leading, spacing: 2) {
                Text(SessionView.sessionTitle(for: sessionID))
                    .font(Theme.display(11, .bold))
                    .tracking(2.64)                       // 0.24em at 11pt
                    .foregroundStyle(Theme.text)
                Text(statusLine)
                    .font(Theme.mono(8.5))
                    .tracking(0.85)                       // 0.1em at 8.5pt
                    .foregroundStyle(Theme.r(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The pill reads the readiness-composed pair, same derivation as
            // the home AGENT tile. `disarmReason` is already in scope here and
            // is the value the composer below gates on.
            Button(action: onHistory) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Theme.display(13, .regular))
                    .foregroundStyle(Theme.r(0.55))
            }
            .accessibilityLabel("SESSION HISTORY")

            Badge(text: headerBadge.text, color: headerBadge.tint)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // ONE element, not four. Unmerged, VoiceOver reads the orb, the title,
        // the status line and the badge as separate stops — four swipes to
        // learn one thing. `.combine` concatenates the children's labels in
        // layout order, which is why the value below is applied to the group
        // and not to any child.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SessionView.headerAccessibilityLabel(
            sessionID: sessionID, status: statusLine, state: state,
            disarmReason: disarmReason))
    }

    /// The whole header as one spoken string.
    ///
    /// PHASE IS RECOVERABLE FROM THIS WHEN ARMED, AND DELIBERATELY NOT WHEN
    /// UNARMED. `state.badgeText` is four distinct strings over the four
    /// `AgentState` cases, so an armed label differs across every state — that
    /// difference is what makes "reads the engine phase" measurable rather than
    /// aspirational, and it is asserted directly rather than described here.
    /// Unarmed, all four collapse onto ONE PROSE SENTENCE (not `UNARMED` — the
    /// spoken arm is words, see `unarmedSpokenLabel`): the phase is not wrong, it is
    /// not answering the question, and announcing "reasoning" over a core with
    /// no route to a model is the spoken form of the green-pill lie. The
    /// injectivity leg is therefore TWO-ARMED — armed count ==
    /// `AgentState.allCases.count`, unarmed EQUAL to the literal for each of
    /// the four phases — with the arms asserted unequal so neither can pass on
    /// a constant. Count-1 alone is not enough: a function returning `""` has
    /// count 1 and says nothing, so the unarmed arm asserts the STRING.
    ///
    /// The badge and the status line are both carried because they answer
    /// different questions: phase (what the agent is doing) and topology (can
    /// we reach the gateway). Collapsing them would be the four-state link
    /// probe folding down to two, one surface over — `NOMINAL` beside
    /// `UNREACHABLE` is not a contradiction, it is two facts.
    ///
    /// The orb contributes nothing: it is `.accessibilityHidden(true)` at its
    /// call site, so `.combine` skips it. That is deliberate — the orb renders
    /// the same energy the badge names, and announcing both would say one
    /// thing twice.
    ///
    /// `disarmReason` is REQUIRED, not defaulted. A default would let a call
    /// site omit it and silently announce a phase over an unarmed core — the
    /// exact defect this parameter exists to close, reintroduced by omission.
    /// Four of the five callers are tests, and the fifth is the render at
    /// `:219`; making them all state the readiness is the point.
    /// The spoken payload when the core is unarmed. ZM's words, verbatim.
    ///
    /// NOT the pill's `UNARMED`, and not a composition of the caps strings:
    /// this is prose because it is spoken, and it carries the repair because
    /// the label is the screen-reader operator's ONLY channel to this screen.
    /// The general rule — a slot that cannot act must not name a repair — has
    /// its exception exactly here: this slot IS the operator's channel, so
    /// withholding the repair would leave them with a state and no route out
    /// of it. The visual pill withholds it because the screen around it says
    /// it in a slot that can act.
    ///
    /// It REPLACES the composition rather than appending to it. Title and
    /// status are answers to questions that presuppose an armed core; reading
    /// "SESSION ABC12345, LINKED, agent unarmed" spends two clauses on
    /// topology before reaching the one fact that matters. The visual header
    /// keeps them because the eye takes a pill in parallel with the text; a
    /// voice is serial and pays for every word.
    ///
    /// THE COST, AND ITS TRIGGER — recorded so the next author inherits the
    /// condition rather than the conclusion. Replacing the composition drops
    /// the session id from the spoken label. That is free TODAY because this
    /// screen shows one session and there is nothing to disambiguate it from.
    /// The moment a build puts two or more sessions in one navigable list,
    /// the unarmed labels of all of them are identical by ear — four phases
    /// times N sessions collapsing onto one sentence — and the suffix form
    /// (`"\(Self.unarmedSpokenLabel) \(title)."`) comes back. The trigger is
    /// a second session reachable from a list, not a redesign.
    static let unarmedSpokenLabel = "Agent unarmed. Set a provider in Routes."

    static func headerAccessibilityLabel(sessionID: String?,
                                         status: String,
                                         state: AgentState,
                                         disarmReason: String?) -> String {
        guard disarmReason == nil else { return Self.unarmedSpokenLabel }
        let title = sessionTitle(for: sessionID)
            .replacingOccurrences(of: Theme.separator, with: " ")
            .replacingOccurrences(of: "—", with: "not yet assigned")
        let badge = ReadinessBadge.forState(state, disarmReason: disarmReason)
        return "\(title.trimmingCharacters(in: .whitespaces)), \(status), \(badge.text)"
    }

    /// The header pill's badge, composed over (readiness, phase).
    private var headerBadge: ReadinessBadge {
        ReadinessBadge.forState(state, disarmReason: disarmReason)
    }

    // MARK: - Voice stage body

    /// The default body: orb, the one status line, the last two turns.
    ///
    /// Only the last two, because the stage is a GLANCE surface — the full
    /// log is one toggle away and duplicating it here would make the toggle
    /// meaningless.
    private var stage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            DeviceOrb(mode: state.orbMode,
                      level: SessionView.stageLevel(state: state,
                                                    voiceState: voiceState,
                                                    micLevel: micLevel))
                .frame(width: 200, height: 200)
                .accessibilityHidden(true)

            Text(SessionView.stageLine(voiceState: voiceState, partial: nil))
                .font(Theme.mono(10))
                .tracking(1.2)
                .foregroundStyle(voiceState == .listening ? Theme.accent : Theme.w(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 10)

            VStack(spacing: 10) {
                ForEach(messages.suffix(2)) { m in
                    bubbleRow(m)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The hero row: COMMS, the keyboard summons, the transcript toggle, and
    /// the terminal-disabled attach.
    private var stageControls: some View {
        HStack(spacing: 12) {
            // ATTACH — disabled on verb-absence. `enabled:` reads the named
            // derivation so a leg can refuse a `link`-conditioned spelling.
            accentButton(symbol: "paperclip",
                         label: SessionView.attachReason,
                         enabled: SessionView.attachEnabled,
                         action: { showPicker = true })

            // PHOTOS — beside the file importer, never instead of it. A
            // `PhotosPicker` and not a `UIImagePickerController`: it runs
            // OUT OF PROCESS, so the app never gains photo-library access and
            // `NSPhotoLibraryUsageDescription` stays absent from the manifest.
            // Adding that key would be a permission prompt for a capability
            // this build does not have and does not need — pinned absent by a
            // leg for exactly that reason.
            //
            // Not wrapped in `accentButton`: that helper builds a `Button`,
            // and `PhotosPicker` IS the control that presents the sheet. A
            // button that set a flag would need a second presentation path.
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(Theme.display(19, .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(minWidth: Theme.controlSize, minHeight: Theme.controlSize)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            }
            .accessibilityLabel("Attach a photo")

            // COMMS is the hero: the one control the screen exists for.
            accentButton(symbol: voiceSymbol,
                         label: voiceLabel,
                         enabled: voiceState.isActionable,
                         action: onVoice)

            accentButton(symbol: "keyboard",
                         label: showKeyboard ? "Hide keyboard" : "Show keyboard",
                         action: { showKeyboard.toggle() })

            // NARRATION MUTE — the first production site for this control
            // outside `Commissioning.swift`, which owned the only one and
            // took it away with the screen. Placed on the stage row because
            // this is the screen where the orb speaks.
            accentButton(symbol: narrationOn ? "speaker.wave.2" : "speaker.slash",
                         label: narrationOn ? "Mute narration voice"
                                            : "Unmute narration voice",
                         action: onToggleNarration)

            accentButton(symbol: "list.bullet",
                         label: showLog ? "Hide transcript" : "Show transcript",
                         action: { showLog.toggle() })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Transcript (:879-898)

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { m in
                        bubbleRow(m)
                            .id(m.id)
                            // C1 — REMEMBER lives on the bubble, not the
                            // composer, and that is the placement decision.
                            // The composer holds text the operator has not
                            // sent yet; a REMEMBER there would write a draft
                            // and call it a memory. The thing worth keeping is
                            // a turn that already happened, and the bubble is
                            // the only surface that names WHICH one.
                            //
                            // Suppressed while `streaming`: the text is still
                            // arriving, so a write here commits a prefix of a
                            // reply — and the toast would report success over
                            // a truncated fact.
                            .contextMenu {
                                if !m.streaming {
                                    Button {
                                        onRemember(m)
                                    } label: {
                                        Label("Remember this", systemImage: "brain")
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func bubbleRow(_ m: Message) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if m.role == .agent {
                OrbGlyph(diameter: 24, mode: .dormant).padding(.bottom, 2)
            }
            bubble(m)
            if m.role == .user { Color.clear.frame(width: 0) }
        }
        .frame(maxWidth: .infinity,
               alignment: m.role == .user ? .trailing : .leading)
    }

    /// The corner radii are asymmetric per role in the source
    /// (`12px 12px 3px 12px` for user, `12px 12px 12px 3px` for agent) — the
    /// tail sits on the speaker's side.
    @ViewBuilder
    private func bubble(_ m: Message) -> some View {
        let isUser = m.role == .user
        HStack(alignment: .bottom, spacing: 0) {
            Text(m.text)
                .font(Theme.body(14))
                .foregroundStyle(Theme.text)
            if m.streaming { StreamingCaret() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isUser ? Theme.r(0.08) : Theme.w(0.04))
        .overlay(
            BubbleShape(tailOnTrailing: isUser)
                .stroke(isUser ? Theme.r(0.25) : Theme.w(0.07),
                        lineWidth: Theme.hairline)
        )
        .clipShape(BubbleShape(tailOnTrailing: isUser))
        .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - Composer (:900-914)

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("", text: $input, prompt:
                Text("Message ZEUS")
                    .foregroundStyle(Theme.w(0.3))
            )
            .font(Theme.body(14))
            .foregroundStyle(Theme.text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            // 44pt is the touch-target FLOOR here too — but unlike the resume
            // bar (`HomeView.resumeBar`), this row ALSO overflows, and that is
            // measured rather than reasoned: `body(14)` on `.body` at AX5 is
            // 39.3pt of glyph and 46.9pt of LINE against a 44pt frame. Pinned
            // to `height` it clips the caret line — the field the user types
            // into, so the clip lands on their own words as they write them.
            // `testTheRealControlRowsAtAX5` asserts this direction strictly.
            .frame(minHeight: Theme.controlSize)
            .background(Theme.w(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .stroke(Theme.w(0.08), lineWidth: Theme.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            .onSubmit(send)

            // The button IDENTITY changes with the input, not just its icon —
            // send and voice are different actions, so this is a branch and
            // not a conditional label.
            if trimmed.isEmpty {
                // The symbol reports the state rather than always claiming a
                // mic: `.unavailable` renders a slashed mic and does not arm,
                // because a normal-looking mic button whose tap cannot work is
                // the silent non-action this cut exists to retire.
                accentButton(symbol: voiceSymbol,
                             label: voiceLabel,
                             enabled: voiceState.isActionable,
                             action: onVoice)
            } else {
                // `enabled` carries the disarm: with no provider the arrow is
                // visibly dead rather than absent. Hiding it would make the
                // composer look like a build without sending at all, which is
                // a different (and unfixable-looking) claim.
                accentButton(symbol: "arrow.up",
                             label: "Send",
                             enabled: SessionView.canSend(trimmedInput: trimmed,
                                                          disarmReason: disarmReason),
                             action: send)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// The mic glyph for the current voice state.
    ///
    /// `.listening` shows a stop, not a pulsing mic: the button IS the stop,
    /// and an animated mic would be a level meter with nothing metering it.
    private var voiceSymbol: String {
        switch voiceState {
        case .idle:        return "mic"
        case .listening:   return "stop.fill"
        case .denied:      return "mic.slash"
        case .unavailable: return "mic.slash"
        }
    }

    /// VoiceOver reads the STATE, because the glyph difference is the only
    /// thing a sighted operator has and a label of "Comms" in all four cases
    /// would make three of them indistinguishable without sight.
    private var voiceLabel: String {
        switch voiceState {
        case .idle:        return "Start voice input"
        case .listening:   return "Stop voice input"
        case .denied:      return "Microphone denied — open Settings"
        case .unavailable: return "Voice unavailable on this device"
        }
    }

    private func accentButton(symbol: String,
                              label: String,
                              enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.display(19, .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(minWidth: Theme.controlSize, minHeight: Theme.controlSize)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
    }

    private func send() {
        // Guarded HERE as well as by `.disabled`, because `.onSubmit` fires on
        // the keyboard's return key and does not consult the button's disabled
        // state. Without this, hitting return would send a turn the UI just
        // said was impossible.
        let t = trimmed
        guard SessionView.canSend(trimmedInput: t, disarmReason: disarmReason) else { return }
        // 🔴 THE REFERENCE, COMPOSED HERE AND NOWHERE ELSE. The staged path
        // joins the turn at the moment of send — a PATH, never the file's
        // bytes. `attachmentReference` is the bridge's own builder, so the
        // marker is one literal with two readers rather than a string this
        // file retypes.
        onSend(SessionView.turnText(typed: t, stagedPath: attachment?.stagedPath),
               attachment?.images ?? [])
        // Consumed: a staged file rides exactly ONE turn. Leaving it set would
        // silently re-attach it to every subsequent message, which the operator
        // never asked for and the transcript would not explain.
        attachment = nil
        input = ""
    }
}

/// The blinking token caret, :889-895 — 2.5pt wide, ACC2, 0.8s cycle.
private struct StreamingCaret: View {
    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(Theme.accent2)
            .frame(width: 2.5, height: 12)
            .offset(y: 2)
            .padding(.leading, 2)
            .opacity(on ? 1 : 0)
            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                       value: on)
            .onAppear { on = false }
    }
}

/// Bubble with one squared corner on the speaker's side.
private struct BubbleShape: Shape {
    let tailOnTrailing: Bool
    private let big: CGFloat = 12
    private let small: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect,
             cornerRadii: RectangleCornerRadii(
                topLeading: big,
                bottomLeading: tailOnTrailing ? big : small,
                bottomTrailing: tailOnTrailing ? small : big,
                topTrailing: big))
    }
}

/// The orb, at glyph scale.
///
/// PORTED. This was a gradient-disc placeholder until the `DeviceOrb` renderer
/// landed; it is now the real renderer at `OrbTuning.glyph` density (10 x 16 =
/// 187 points), which is the honest ceiling for a 24-34pt disc — a 1855-point
/// cloud cannot resolve at this size, so drawing it would be cost with no
/// visible return.
///
/// The two call sites (34pt session header, 24pt bubble avatar) pass the
/// agent's live mode through, so the glyph breathes with the same state
/// machine as a full-size orb rather than being decorative.
struct OrbGlyph: View {
    let diameter: CGFloat
    var mode: DeviceOrb.Mode = .dormant

    var body: some View {
        DeviceOrb(mode: mode, tuning: .glyph)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}
