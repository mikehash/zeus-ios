import SwiftUI

/// C — the session history sheet: a list over `core.sessions()`, and a tapped
/// row's transcript over `core.messages(sessionId:)`.
///
/// ── Why a sheet and not a fourth tab ───────────────────────────────────
///
/// `Tab` has three cases and the tab bar renders all of them (`RootView:9`).
/// A fourth would re-lay-out a screen the operator has learned, to reach a
/// surface consulted occasionally. The sheet is reached from the SESSION
/// header, which is where the operator already is when they want the previous
/// conversation — and it sits on the same overlay layer as the gateway editor,
/// one zIndex below it, because an editor is a decision and this is a lookup.
struct HistorySheet: View {

    /// The process's one core, passed in — never constructed here.
    ///
    /// Same note `NodesView.core` carries for the same measured reason: a
    /// handle built in this view would be a SECOND core over the same
    /// workspace directory. Optional because `EmbeddedCore.shared` is a
    /// `Result`, and a core that failed to initialise is exactly the state
    /// where an invented empty list would be most wrong — `nil` renders
    /// `NO CORE`, which is what happened.
    var core: ZeusCoreProtocol?

    @Binding var isPresented: Bool

    /// One reading, taken when the sheet appears. NOT a computed property
    /// over `core.sessions()`: a `var body` can be evaluated many times per
    /// frame, and an FFI call that reads a directory of `.jsonl` files does
    /// not belong on that path.
    @State private var sessions: [SessionInfo]?
    @State private var openID: String?
    @State private var rows: [History.Row]?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.r(0.2))
            if let openID {
                transcript(for: openID)
            } else {
                list
            }
        }
        .background(Theme.bg)
        .task { load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if openID != nil {
                Button {
                    openID = nil
                    rows = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(Theme.display(13, .regular))
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel("BACK TO SESSIONS")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("HISTORY")
                    .font(Theme.display(11, .bold))
                    .tracking(2.64)
                    .foregroundStyle(Theme.text)
                Text(summaryLine)
                    .font(Theme.mono(8.5))
                    .tracking(0.85)
                    .foregroundStyle(Theme.r(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(Theme.display(12, .regular))
                    .foregroundStyle(Theme.r(0.6))
            }
            .accessibilityLabel("CLOSE HISTORY")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The one string that says which of the three states we are in.
    private var summaryLine: String {
        if let failure { return failure }
        if openID != nil { return History.transcriptSummary(rowCount: rows?.count) }
        return History.listSummary(sessionCount: sessions?.count)
    }

    // MARK: - the list

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(History.newestFirst(sessions ?? []), id: \.id) { s in
                    Button {
                        open(s.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(History.rowTitle(for: s.id))
                                .font(Theme.mono(10))
                                .tracking(1.0)
                                .foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(History.ago(s.updatedAtRfc3339))
                                .font(Theme.mono(8.5))
                                .foregroundStyle(Theme.r(0.5))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    Divider().overlay(Theme.r(0.12)).padding(.leading, 20)
                }
            }
        }
    }

    // MARK: - the transcript

    private func transcript(for id: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows ?? []) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label(for: row.kind))
                            .font(Theme.display(8.5, .bold))
                            .tracking(1.7)
                            .foregroundStyle(tint(for: row.kind))
                        Text(row.text)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func label(for kind: History.Row.Kind) -> String {
        switch kind {
        case .user:      return "OPERATOR"
        case .assistant: return "ZEUS"
        case .tool:      return "TOOL"
        }
    }

    private func tint(for kind: History.Row.Kind) -> Color {
        switch kind {
        case .user:      return Theme.r(0.55)
        case .assistant: return Theme.accent
        case .tool:      return Theme.r(0.45)
        }
    }

    // MARK: - the two FFI calls

    /// Both readings run OFF the main thread and land back on it.
    ///
    /// `sessions()` reads a directory and parses every `.jsonl` header;
    /// `messages(id)` parses a whole transcript. Both are synchronous FFI
    /// into the core, which is why `remember` was moved off the main thread
    /// in C1 and why these are too.
    private func load() {
        guard let core else {
            sessions = nil
            failure = nil
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                let got = try core.sessions()
                await MainActor.run { sessions = got; failure = nil }
            } catch {
                await MainActor.run { sessions = nil; failure = "HISTORY UNREADABLE — \(error)" }
            }
        }
    }

    private func open(_ id: String) {
        openID = id
        rows = nil
        guard let core else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let got = try core.messages(sessionId: id)
                let mapped = History.rows(from: got)
                await MainActor.run { rows = mapped; failure = nil }
            } catch {
                await MainActor.run { rows = nil; failure = "TRANSCRIPT UNREADABLE — \(error)" }
            }
        }
    }
}
