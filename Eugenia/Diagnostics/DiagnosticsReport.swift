import Foundation

/// Formato del informe que consume `scripts/devtest.sh` desde Linux.
/// Plan, sección 6.5. Dos decisiones deliberadas del formato:
///
///  1. El umbral esperado VIAJA DENTRO del informe. Un fallo tiene que ser legible
///     sin abrir otro fichero para averiguar contra qué se comparaba.
///  2. Cada caso lleva su ventana temporal de log, para que el script recorte del
///     syslog exactamente los segundos del caso que falló.
struct DiagnosticsReport: Codable {
    struct Run: Codable {
        var id: String
        var commit: String
        var device: String
        var os: String
        var startedAt: Date
        var finishedAt: Date?
    }

    struct Env: Codable {
        var appleIntelligence: Bool
        var modelAvailability: String
        var thermalState: String
        var batteryLevel: Double
        var freeDiskMB: Int
    }

    struct LogWindow: Codable {
        var category: String
        var from: Date
        var to: Date
    }

    struct Case: Codable {
        var id: String
        var status: String                 // pass | fail | skipped | error
        var metrics: [String: Double]
        var expected: [String: Threshold]
        var artifacts: [String]
        var logWindow: LogWindow
        var message: String?
    }

    struct Threshold: Codable {
        var max: Double?
        var min: Double?
    }

    struct Summary: Codable {
        var passed: Int
        var failed: Int
        var skipped: Int
    }

    var run: Run
    var env: Env
    var cases: [Case]
    var summary: Summary
}

/// Plan de pruebas que Linux empuja por AFC a `Documents/diagnostics/run.json`.
struct DiagnosticsSuite: Codable {
    struct Case: Codable {
        var id: String
        /// Ruta relativa dentro de `Documents/diagnostics/audio/`
        var audioFile: String
        var language: String
        /// Transcripción de referencia, opcional. Si está, se calcula WER.
        var referenceTranscript: String?
        var expected: [String: DiagnosticsReport.Threshold]
        /// asr | summarize | pipeline
        var kind: String
    }
    var suite: String
    var cases: [Case]
}

enum ReportStamp {
    /// Marca ordenable y SEGURA COMO NOMBRE DE FICHERO: 20260908-175530.
    /// Nada de ISO8601 aquí: lleva dos puntos, y un ':' en una ruta que además viaja
    /// por AFC hasta Linux es problema seguro.
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
}
