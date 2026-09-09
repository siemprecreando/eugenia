import SwiftUI

@main
struct EugeniaApp: App {
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task {
                    #if DEBUG
                    // Banco de pruebas remoto (plan 6.5). Si Linux dejó un run.json,
                    // se ejecuta la suite antes de que nadie toque la interfaz.
                    await DiagnosticsRunner.runIfRequested()
                    #endif
                    Log.event(Log.diag, "app.ready", "llm=\(Summarizer.availabilityDescription()) notes=\(Store.shared.notes.count)")
                }
        }
    }
}
