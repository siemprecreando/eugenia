import EventKit
import Foundation
import LocalAuthentication
import SwiftUI
import UIKit
import UserNotifications

/// Calendario (plan, Fase 4): detectar la reunión en curso para rellenar título y
/// asistentes, y avisar antes de las próximas para ofrecer grabarlas. Todo local:
/// EventKit lee el calendario del propio iPhone.
@MainActor
final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    struct Meeting {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var attendees: [String]
    }

    /// La reunión que está ocurriendo ahora (o empieza en los próximos 10 minutos).
    func currentMeeting(now: Date = Date()) -> Meeting? {
        guard hasAccess else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600),
                                                 end: now.addingTimeInterval(600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate <= now.addingTimeInterval(600) && $0.endDate > now }
            .sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
            .first.map(Self.meeting)
    }

    func upcoming(hours: Double = 24, now: Date = Date()) -> [Meeting] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(hours * 3600), calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay }.map(Self.meeting)
    }

    private static func meeting(_ e: EKEvent) -> Meeting {
        Meeting(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Reunión",
                start: e.startDate, end: e.endDate,
                attendees: (e.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty })
    }

    /// Programa un aviso local un minuto antes de cada reunión de las próximas 24 h
    /// (solo reuniones con asistentes: una cita de dentista no es una reunión).
    func scheduleSuggestions() {
        guard AppSettings.shared.calendarSuggestions, hasAccess else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let old = pending.map(\.identifier).filter { $0.hasPrefix("meeting-") }
            center.removePendingNotificationRequests(withIdentifiers: old)
            Task { @MainActor in
                for m in CalendarService.shared.upcoming() where !m.attendees.isEmpty && m.start > Date().addingTimeInterval(90) {
                    Notifier.meetingSoon(title: m.title, eventID: m.id, at: m.start.addingTimeInterval(-60))
                }
            }
        }
    }
}

/// Bloqueo con Face ID (plan, Fase 4). Con el ajuste activo, la app pide Face ID al
/// volver a primer plano y, mientras tanto, tapa el contenido (también en el
/// selector de apps, donde iOS guarda una captura).
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @Published private(set) var locked = false

    /// Face ID se pide solo UNA vez por vuelta a primer plano. La hoja de Face ID pone
    /// la app en inactiva; al cancelarla vuelve a activa y, sin esto, se volvía a
    /// pedir en bucle. El botón "Desbloquear" llama a `unlock()` directamente.
    private var autoPrompted = false

    func lockIfNeeded() {
        if AppSettings.shared.faceIDLock { locked = true }
        autoPrompted = false
    }

    func autoUnlock() async {
        guard locked, !autoPrompted else { return }
        autoPrompted = true
        await unlock()
    }

    func unlock() async {
        guard locked else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = String(localized: "Usar código")
        var error: NSError?
        // `.deviceOwnerAuthentication` = Face ID con el código del iPhone como respaldo.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            locked = false           // sin Face ID ni código no hay con qué bloquear
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: String(localized: "Desbloquea tus reuniones"))
            if ok { locked = false }
        } catch {
            Log.failure(Log.system, "applock", error)
        }
    }
}

/// La tapa del bloqueo vive en su PROPIA ventana, por encima de todo (revisión de
/// seguridad 2026-09-18). Dentro del árbol de vistas no tapaba las hojas —preguntar a
/// la IA, compartir, grabar—, que SwiftUI presenta por encima: su contenido se veía
/// en la captura del selector de apps y se podía usar antes de Face ID.
@MainActor
final class LockOverlay {
    static let shared = LockOverlay()
    private var window: UIWindow?

    func update(visible: Bool) {
        if visible {
            guard window == nil,
                  let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState != .unattached })
            else { return }
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            w.rootViewController = UIHostingController(rootView: LockScreen())
            w.isHidden = false
            window = w
            // Lo de debajo no existe para VoiceOver mientras está tapado.
            for other in scene.windows where other !== w { other.accessibilityElementsHidden = true }
        } else if let w = window {
            for other in w.windowScene?.windows ?? [] where other !== w { other.accessibilityElementsHidden = false }
            w.isHidden = true
            window = nil
        }
    }
}

struct LockScreen: View {
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
