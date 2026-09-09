import XCTest
@testable import Eugenia

@MainActor
final class StoreTests: XCTestCase {

    /// Guardar y releer no puede perder nada. Es lo único que separa "tengo mis
    /// reuniones" de "tenía mis reuniones".
    func testSaveAndReloadRoundTrip() throws {
        let store = Store.shared
        let id = UUID()
        let note = Note(id: id,
                        title: "Comité de producto",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        duration: 2_730,
                        language: "es",
                        audioFileName: "\(id.uuidString).m4a",
                        transcript: "Marta se encarga del presupuesto.",
                        summaryOverview: "Se repartió el presupuesto.",
                        decisions: ["Presupuesto a Marta"],
                        actionItems: [StoredActionItem(text: "Preparar presupuesto",
                                                       assignee: "Marta",
                                                       status: "confirmado",
                                                       atSeconds: 182)],
                        state: "summarized",
                        failure: nil)
        store.save(note)
        store.load()

        let reloaded = try XCTUnwrap(store.notes.first { $0.id == id })
        XCTAssertEqual(reloaded, note, "la nota releída no es idéntica a la guardada")

        store.delete(note)
        store.load()
        XCTAssertNil(store.notes.first { $0.id == id })
    }

    /// El audio y el índice NO pueden vivir en Documents/: UIFileSharingEnabled lo
    /// expone entero por AFC y en la app Archivos (hallazgo S4 de la revisión de
    /// seguridad). Si alguien los mueve de vuelta, esta prueba lo caza.
    func testMeetingDataIsNotInTheSharedDocumentsFolder() {
        let store = Store.shared
        let documents = store.documents.standardizedFileURL.path
        let audio = store.audioDirectory.standardizedFileURL.path

        XCTAssertFalse(audio.hasPrefix(documents),
                       "el audio de las reuniones está en Documents/, que AFC expone: \(audio)")
        XCTAssertTrue(store.diagnosticsDirectory.standardizedFileURL.path.hasPrefix(documents),
                      "los diagnósticos SÍ deben estar en Documents/, que es como salen del teléfono")
    }
}
