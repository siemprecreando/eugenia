import Foundation
import UIKit
import UserNotifications

// MARK: - Avisos locales (plan 5.8)

/// Notificaciones LOCALES: no necesitan entitlement de pago ni servidor (plan 6.4).
/// El aviso de "resumen listo" lleva la acción "Enviar al CRM", que es el punto de
/// consentimiento explícito para que algo salga del teléfono.
enum Notifier {
    static let summaryCategory = "SUMMARY_READY"
    static let meetingCategory = "MEETING_SOON"
    static let sendAction = "SEND_CRM"
    static let recordAction = "RECORD_NOW"

    static func registerCategories() {
        let send = UNNotificationAction(identifier: sendAction, title: String(localized: "Enviar al CRM"),
                                        options: [.foreground])
        let record = UNNotificationAction(identifier: recordAction, title: String(localized: "Grabar"),
                                          options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: summaryCategory, actions: [send], intentIdentifiers: []),
            UNNotificationCategory(identifier: meetingCategory, actions: [record], intentIdentifiers: [])
        ])
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func summaryReady(_ note: Note) {
        // Si el usuario está mirando la app, no hace falta avisar.
        guard UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = String(localized: "Resumen listo")
        // Solo el TÍTULO de la reunión, nunca contenido: la notificación se ve en la
        // pantalla bloqueada.
        c.body = AppSettings.shared.hideTitlesOnLockScreen ? String(localized: "Una reunión está lista.") : note.title
        c.categoryIdentifier = summaryCategory
        c.userInfo = ["noteID": note.id.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "summary-\(note.id.uuidString)", content: c, trigger: nil))
    }

    @MainActor
    static func meetingSoon(title: String, eventID: String, at date: Date) {
        let c = UNMutableNotificationContent()
        c.title = String(localized: "¿Grabar la reunión?")
        c.body = AppSettings.shared.hideTitlesOnLockScreen ? String(localized: "Empieza una reunión del calendario.") : title
        c.categoryIdentifier = meetingCategory
        c.userInfo = ["eventID": eventID, "title": title]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "meeting-\(eventID)-\(Int(date.timeIntervalSince1970))", content: c,
                                  trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}

/// Recibe las acciones de las notificaciones.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await MainActor.run {
            if let s = info["noteID"] as? String, let id = UUID(uuidString: s) {
                if action == Notifier.sendAction {
                    ShortcutRunner.sendToCRM(noteID: id)
                } else {
                    AppRouter.shared.open(noteID: id)
                }
            } else if action == Notifier.recordAction || info["eventID"] != nil {
                let title = info["title"] as? String
                AppRouter.shared.startRecording(title: title, eventID: info["eventID"] as? String)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

/// Destino de navegación: una nota y, opcionalmente, el segundo del audio al que saltar.
struct NoteRoute: Hashable {
    var id: UUID
    var at: Double?
}

/// Navegación pedida desde fuera de la UI (notificaciones, intents, URLs).
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var path: [NoteRoute] = []
    @Published var showRecorder = false
    @Published var pendingImportURL: URL?
    var pendingTitle: String?
    var pendingEventID: String?
    /// Cambia en cada petición de grabar. Si la pantalla de grabación YA estaba abierta
    /// (lo normal tras parar la anterior), `showRecorder` no cambia y la petición de
    /// Siri, el botón de acción o el aviso se perdía (revisión 2026-09-18).
    @Published private(set) var recordRequest = UUID()

    func open(noteID: UUID, at: Double? = nil) {
        path = [NoteRoute(id: noteID, at: at)]
    }

    func startRecording(title: String? = nil, eventID: String? = nil) {
        pendingTitle = title
        pendingEventID = eventID
        showRecorder = true
        recordRequest = UUID()
    }
}

// MARK: - Atajos (plan 5.8)

/// La integración con CRMs la hace el usuario con Atajos, en su teléfono y con sus
/// credenciales. Nosotros solo lanzamos SU atajo. El atajo lee la nota con las
/// acciones de la app ("Obtener última nota", "Exportar nota"), así que por la URL no
/// viaja ningún contenido de la reunión.
enum ShortcutRunner {
    @MainActor
    static func sendToCRM(noteID: UUID) {
        let settings = AppSettings.shared
        guard settings.dataOutConsent, !settings.crmShortcutName.isEmpty else {
            AppRouter.shared.open(noteID: noteID)
            return
        }
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "run-shortcut"
        c.queryItems = [URLQueryItem(name: "name", value: settings.crmShortcutName),
                        URLQueryItem(name: "input", value: "text"),
                        URLQueryItem(name: "text", value: noteID.uuidString)]
        if let url = c.url {
            Log.event(Log.system, "shortcut.run")
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Retención (plan 8.2)

/// Borra el AUDIO (no la transcripción ni el resumen) de las reuniones ya resumidas
/// que superan la antigüedad elegida. Las favoritas no se tocan. 0 = nunca.
enum RetentionPolicy {
    nonisolated static func candidates(_ notes: [Note], days: Int, now: Date = Date()) -> [Note] {
        guard days > 0 else { return [] }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        return notes.filter {
            $0.state == NoteState.summarized && $0.audioState == "present" && !$0.isFavorite
                && !$0.allAudioFiles.isEmpty && $0.createdAt < limit
        }
    }

    @MainActor
    static func sweep() {
        let victims = candidates(Store.shared.notes, days: AppSettings.shared.audioRetentionDays)
        for n in victims {
            Store.shared.deleteAudio(of: n)
            Store.shared.update(n.id) { $0.audioState = "deleted" }
        }
        if !victims.isEmpty { Log.event(Log.storage, "retention.sweep", "notes=\(victims.count)") }
    }
}
