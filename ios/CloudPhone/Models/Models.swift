import Foundation

// MARK: - Ajustes del usuario

enum QualityPreset: String, Codable, CaseIterable, Identifiable {
    case serverDefault, low, balanced, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .serverDefault: return "Predeterminada del servidor"
        case .low: return "Baja (ahorra datos)"
        case .balanced: return "Equilibrada"
        case .high: return "Alta"
        }
    }

    /// nil = usar lo que tenga configurado el servidor
    var params: (fps: Int, kbps: Int)? {
        switch self {
        case .serverDefault: return nil
        case .low: return (24, 1500)
        case .balanced: return (30, 4000)
        case .high: return (60, 8000)
        }
    }
}

struct ServerSettings: Codable, Equatable {
    var host: String = ""
    var port: Int = 8443
    var instanceId: String = "phone1"
    var deviceName: String = "iPhone"
    var autoReconnect: Bool = true
    var maxReconnectAttempts: Int = 0      // 0 = sin límite
    var quality: QualityPreset = .serverDefault

    var isConfigured: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
    var cleanHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Respuestas del servidor

struct ErrorBody: Decodable { let error: String? }

struct Resolution: Codable, Equatable { let width: Int; let height: Int }

struct RootStatus: Codable, Equatable {
    let requested: Bool
    let active: Bool?
}

struct Configured: Codable, Equatable {
    let resolution: Resolution
    let dpi: Int
    let orientation: String
    let ramMB: Int
    let cpuCores: Int
    let storageGB: Int
    let apiLevel: Int
}

struct InstanceStatus: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let state: String            // stopped | starting | running | stopping | error
    let busy: String?
    let error: String?
    let root: RootStatus
    let configured: Configured?
    let uptimeSeconds: Int?

    var isRunning: Bool { state == "running" }

    var stateTitle: String {
        switch state {
        case "running": return "En marcha"
        case "starting": return "Iniciando…"
        case "stopping": return "Apagando…"
        case "stopped": return "Apagado"
        case "error": return "Error"
        default: return state
        }
    }
}

struct StatusResponse: Decodable {
    let version: String
    let instances: [InstanceStatus]
}

struct InstanceInfo: Decodable {
    struct Root: Decodable { let active: Bool; let id: String?; let suExists: Bool? }
    struct Display: Decodable { let size: String?; let density: String? }
    struct Storage: Decodable { let totalMB: Int?; let usedMB: Int?; let freeMB: Int? }
    let androidVersion: String?
    let sdk: String?
    let model: String?
    let buildType: String?
    let abi: String?
    let root: Root
    let display: Display?
    let memoryTotalMB: Int?
    let storage: Storage?
}

struct PairResponse: Decodable { let token: String; let deviceId: String }

struct APIError: LocalizedError {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
}
