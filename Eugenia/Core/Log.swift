import Foundation
import OSLog

/// Traza estructurada del proyecto. Plan, sección 6.5.
///
/// REGLA: nada de `print`. Todo pasa por aquí, porque el banco de pruebas lee el
/// syslog desde Linux con `pymobiledevice3 syslog live` y agrupa por categoría.
///
/// TRAMPA IMPORTANTE: `os_log` redacta por defecto cualquier interpolación dinámica.
/// Sin `privacy: .public` el syslog muestra literalmente `<private>` y la traza no
/// sirve vista desde fuera del dispositivo. Por eso los helpers de abajo marcan
/// `.public` de forma explícita.
///
/// CONTRAPARTIDA: el contenido de las reuniones NO se registra nunca, ni en Debug.
/// Se registran identificadores, duraciones, contadores y errores. Nunca texto de
/// transcripción ni nombres de hablantes.
enum Log {
    static let subsystem = "com.eugenia.app"

    static let capture   = Logger(subsystem: subsystem, category: "capture")
    static let asr       = Logger(subsystem: subsystem, category: "asr")
    static let summarize = Logger(subsystem: subsystem, category: "summarize")
    static let storage   = Logger(subsystem: subsystem, category: "storage")
    static let diag      = Logger(subsystem: subsystem, category: "diag")

    /// Marca de evento legible desde el syslog. `caseId` permite recortar la ventana
    /// temporal de un caso de prueba concreto (ver DiagnosticsReport.LogWindow).
    ///
    /// `detail` va ANTES que `caseId` a propósito: es el que se usa casi siempre, y
    /// así se puede pasar sin etiqueta. Un parámetro con etiqueta y valor por defecto
    /// no se puede pasar posicionalmente, que era el error de la primera versión.
    static func event(_ logger: Logger, _ name: String, _ detail: String = "", caseId: String? = nil) {
        if let caseId {
            logger.notice("EV \(name, privacy: .public) case=\(caseId, privacy: .public) \(detail, privacy: .public)")
        } else {
            logger.notice("EV \(name, privacy: .public) \(detail, privacy: .public)")
        }
    }

    /// Registra un fallo SIN volcar la descripción libre del error.
    ///
    /// SEGURIDAD — esto no es paranoia de estilo. La primera versión hacía
    /// `String(describing: error)`, y los errores de `FoundationModels` pueden llevar
    /// dentro el prompt que los provocó. El prompt es el fragmento de transcripción.
    /// Resultado: contenido de reuniones en el syslog del dispositivo, legible por
    /// cualquier ordenador emparejado. Justo lo que el producto promete que no ocurre.
    ///
    /// Aquí se registra el TIPO del error y, si es un `NSError`, su dominio y código.
    /// Eso identifica el fallo sin arrastrar datos: para diagnosticar sirve igual.
    static func failure(_ logger: Logger, _ name: String, _ error: Error, caseId: String? = nil) {
        let ns = error as NSError
        let text = "\(type(of: error)) domain=\(ns.domain) code=\(ns.code)"
        if let caseId {
            logger.error("ER \(name, privacy: .public) case=\(caseId, privacy: .public) \(text, privacy: .public)")
        } else {
            logger.error("ER \(name, privacy: .public) \(text, privacy: .public)")
        }
    }
}
