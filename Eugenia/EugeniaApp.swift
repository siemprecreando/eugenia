import SwiftUI
import UserNotifications

@main
struct EugeniaApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Antes de terminar de arrancar: iOS exige registrar las tareas de fondo aquí.
        ProcessingQueue.registerBackgroundTask()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        Notifier.registerCategories()
        AppLock.shared.lockIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if lock.locked || scenePhase != .active && settings.faceIDLock {
                    // Tapa el contenido: también en la captura del selector de apps.
                    LockScreen()
                }
            }
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(router)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-demo") {
                    // Capturas y pruebas de interfaz: datos de muestra en memoria.
                    // Excluyente con el banco de pruebas a propósito — si corrieran
                    // los dos, el informe del diagnóstico saldría con notas falsas.
                    store.seedDemo()
                    return
                }
                // Banco de pruebas remoto (plan 6.5). Si Linux dejó un run.json, se
                // ejecuta la suite antes de que nadie toque la interfaz.
                await DiagnosticsRunner.runIfRequested()
                #endif
                ProcessingQueue.shared.bootstrap()
                CalendarService.shared.scheduleSuggestions()
                Log.event(Log.diag, "app.ready",
                          "llm=\(Summarizer.availabilityDescription()) notes=\(Store.shared.notes.count)")
            }
            .onOpenURL { url in
                // "Abrir en Eugenia" desde Archivos, Mail, WhatsApp… (CFBundleDocumentTypes).
                if url.isFileURL { router.pendingImportURL = url }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    AppLock.shared.lockIfNeeded()
                case .active:
                    Task { await AppLock.shared.unlock() }
                    // Apple Intelligence activado mientras tanto: reintentar los resúmenes
                    // que fallaron solo por eso.
                    if Summarizer.isAvailable {
                        for n in Store.shared.notes where n.state == NoteState.failed
                            && n.summaryOverview.isEmpty && !n.transcript.isEmpty {
                            ProcessingQueue.shared.retry(n.id)
                        }
                    }
                    ProcessingQueue.shared.kick()
                    CalendarService.shared.scheduleSuggestions()
                default: break
                }
            }
        }
    }
}

private struct LockScreen: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle)
                Text("Eugenia está bloqueada")
                Button("Desbloquear") { Task { await AppLock.shared.unlock() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityIdentifier("lock-screen")
    }
}
