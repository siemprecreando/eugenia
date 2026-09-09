import Foundation

/// Muestrea la huella de memoria durante un caso de prueba y se queda con el máximo.
///
/// El riesgo R11 del plan —jetsam por reuniones encadenadas— se decide en el PICO,
/// no en el valor con el que termina el proceso. Leer la huella una sola vez al final
/// es el error clásico: da un número bonito justo después de que el recolector haya
/// liberado lo que causó el problema.
final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    private var task: Task<Void, Never>?

    func start() {
        record()
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.record()
            }
        }
    }

    /// Devuelve el pico en MB y detiene el muestreo.
    @discardableResult
    func stop() -> Int {
        task?.cancel()
        task = nil
        record()
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    private func record() {
        let current = Self.footprintMB()
        guard current >= 0 else { return }
        lock.lock()
        peak = max(peak, current)
        lock.unlock()
    }

    /// Huella física del proceso, que es la métrica que mira el jetsam de iOS.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint) / 1_048_576
    }
}
