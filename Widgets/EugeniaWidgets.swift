import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Extensión de widgets: Live Activity + Dynamic Island mientras se graba, y el
/// control "Grabar" del Centro de Control / pantalla bloqueada / botón de Acción.
///
/// Sin App Groups (exigen cuenta de pago, plan 6.4): la extensión no lee datos de la
/// app. Todo lo que muestra le llega en el `ContentState` de la actividad.
@main
struct EugeniaWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordControl()
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.interrupted ? "pause.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                    if context.state.interrupted {
                        Text("En pausa: llamada o aviso").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(timerInterval: context.state.timerStart...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                    }
                }
                Spacer()
                LevelBars(level: context.state.level)
                Button(intent: StopRecordingIntent()) {
                    Image(systemName: "stop.fill")
                }
                .tint(.red)
                .accessibilityLabel("Detener grabación")
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.timerStart...Date.distantFuture, countsDown: false)
                        .monospacedDigit().frame(width: 60)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        LevelBars(level: context.state.level)
                        Spacer()
                        Button(intent: StopRecordingIntent()) {
                            Label("Detener", systemImage: "stop.fill")
                        }.tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            } compactTrailing: {
                Text(timerInterval: context.state.timerStart...Date.distantFuture, countsDown: false)
                    .monospacedDigit().frame(width: 44)
            } minimal: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
        }
    }
}

struct LevelBars: View {
    let level: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Capsule()
                    .fill(Double(i) / 5 < level ? Color.red : Color.gray.opacity(0.4))
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
        .accessibilityHidden(true)
    }
}

struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.eugenia.app.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Grabar reunión", systemImage: "mic.circle.fill")
            }
        }
        .displayName("Grabar reunión")
        .description("Abre Eugenia y empieza a grabar.")
    }
}
