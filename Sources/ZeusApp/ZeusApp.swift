import SwiftUI

@main
struct ZeusApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    var body: some View {
        Text("Zeus")
            .font(.system(.largeTitle, design: .monospaced))
    }
}
