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
        // Copias temporales en claro que quedaron de una sesión anterior.
        TempFiles.cleanAtLaunch()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        Notifier.registerCategories()
        AppLock.shared.lockIfNeeded()
    }

    private func updateLockOverlay(_ phase: ScenePhase? = nil) {
        let phase = phase ?? scenePhase
        LockOverlay.shared.update(visible: lock.locked || phase != .active && settings.faceIDLock)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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
            // La tapa del bloqueo va en su propia ventana (LockOverlay): así cubre
            // también las hojas y la captura del selector de apps.
            .onChange(of: lock.locked, initial: true) { _, _ in updateLockOverlay() }
            .onChange(of: settings.faceIDLock) { _, _ in updateLockOverlay() }
            .onOpenURL { url in
                // "Abrir en Eugenia" desde Archivos, Mail, WhatsApp… (CFBundleDocumentTypes).
                if url.isFileURL { router.pendingImportURL = url }
            }
            .onChange(of: scenePhase) { _, phase in
                updateLockOverlay(phase)
                switch phase {
                case .background:
                    AppLock.shared.lockIfNeeded()
                case .active:
                    Task { await AppLock.shared.autoUnlock() }
                    // Apple Intelligence activado mientras tanto: reintentar SOLO los
                    // resúmenes que fallaron por eso (antes, cualquier fallo se
                    // reprocesaba en cada vuelta a la app: batería y calor para nada).
                    if Summarizer.isAvailable {
                        for n in Store.shared.notes where n.state == NoteState.failed
                            && n.failureCode == "modelUnavailable" && !n.transcript.isEmpty {
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
