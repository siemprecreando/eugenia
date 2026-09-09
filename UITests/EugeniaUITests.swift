import XCTest

/// Pruebas de interfaz en el SIMULADOR. Dos cosas a la vez:
///
///  1. Comprueban que la app se puede usar: que la lista se pinta, que se navega al
///     detalle y que la pantalla de grabación se abre sin reventar. Un `xcodebuild
///     build` verde no dice nada de esto — un `@EnvironmentObject` que falta hace que
///     la app se caiga al arrancar y compila igual de bien.
///
///  2. Dejan CAPTURAS como adjuntos del resultado, que CI extrae y publica. Es la
///     única manera de ver la interfaz sin un Mac y sin el iPhone.
///
/// Lo que NO prueban: audio real, transcripción y resumen. El simulador no tiene
/// micrófono útil en un runner sin sesión gráfica, ni Neural Engine, ni Apple
/// Intelligence. Eso se mide en el teléfono (plan 6.5).
final class EugeniaUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(demo: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if demo { app.launchArguments = ["--ui-demo"] }
        app.launch()
        return app
    }

    /// SwiftUI no garantiza CÓMO expone una fila de `List`: según la versión sale como
    /// botón, como celda o solo como texto. Buscar en un solo sitio hace que la prueba
    /// falle por un detalle de la plataforma y no por un fallo de la app.
    private func cualquiera(_ app: XCUIApplication, _ id: String) -> XCUIElement? {
        for consulta in [app.buttons, app.cells, app.staticTexts, app.otherElements] {
            let el = consulta[id]
            if el.waitForExistence(timeout: 5) { return el }
        }
        return nil
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Primer arranque: sin reuniones. Es literalmente lo primero que Sergio va a ver
    /// en el teléfono, así que conviene que esté bien.
    func test01ListaVacia() {
        let app = launch(demo: false)
        XCTAssertTrue(app.staticTexts["Sin reuniones todavía"].waitForExistence(timeout: 20),
                      "No apareció el estado vacío")
        XCTAssertTrue(app.buttons["record-button"].exists, "Falta el botón de grabar")
        shot(app, "01-lista-vacia")
    }

    /// Lista con reuniones y navegación al detalle.
    func test02ListaYDetalle() {
        let app = launch(demo: true)

        // La lista tarda: hay que esperar al arranque de la app antes de buscar la fila.
        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 30),
                      "La app no llegó a pintar la pantalla principal")
        shot(app, "02-lista")

        guard let fila = cualquiera(app, "note-Comité de producto") else {
            return XCTFail("La lista no se pobló con los datos de muestra")
        }
        fila.tap()

        // Se comprueba el CONTENIDO, no los títulos de sección: los encabezados de
        // `List` cambian de forma entre versiones de iOS y no valen como ancla.
        // Esto es el acuerdo del spike 4b: la tarea acabó en Javier y aparcada.
        let tarea = app.staticTexts["Cerrar el presupuesto del trimestre"]
        XCTAssertTrue(tarea.waitForExistence(timeout: 15),
                      "El detalle no muestra las tareas extraídas")
        shot(app, "03-detalle")

        app.swipeUp()
        shot(app, "04-detalle-transcripcion")
    }

    /// La pantalla de grabación arranca `AVAudioEngine` nada más aparecer. En un runner
    /// sin micrófono lo esperable es que falle — lo que se comprueba aquí es que FALLE
    /// BIEN: sin caerse, con el botón de salir disponible. Ese camino de error nunca se
    /// prueba a mano y es justo el que deja al usuario atrapado si está mal.
    func test03PantallaDeGrabacion() {
        let app = launch(demo: true)

        let boton = app.buttons["record-button"]
        XCTAssertTrue(boton.waitForExistence(timeout: 20))
        boton.tap()

        let salir = app.buttons["record-toggle"]
        XCTAssertTrue(salir.waitForExistence(timeout: 15), "No se abrió la pantalla de grabación")
        shot(app, "05-grabacion")

        // Falle o no, al usuario NUNCA se le enseña el volcado del NSError. La primera
        // captura de esta pantalla era un muro rojo con "Error Domain=SFSpeechError
        // Domain Code=1 ... UserInfo={...}". Esto lo impide de vuelta.
        let crudos = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Error Domain="))
        XCTAssertEqual(crudos.count, 0, "la pantalla enseña el NSError en crudo")

        salir.tap()
        // Si estaba grabando, el primer toque para; hace falta un segundo para cerrar.
        if salir.waitForExistence(timeout: 10) { salir.tap() }

        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 15),
                      "No se volvió a la lista al cerrar la grabación")
        shot(app, "06-vuelta-a-la-lista")
    }
}
