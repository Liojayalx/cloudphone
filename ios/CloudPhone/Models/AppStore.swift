import Foundation
import SwiftUI

/// Estado global de la app: ajustes, emparejamiento y estado de las instancias.
@MainActor
final class AppStore: ObservableObject {
    private static let settingsKey = "cloudphone.settings.v1"

    @Published var settings: ServerSettings {
        didSet { persist() }
    }
    @Published var paired: Bool
    @Published var instances: [InstanceStatus] = []
    @Published var reachable = false
    @Published var lastError: String?
    @Published var busyMessage: String?

    private(set) var token: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let s = try? JSONDecoder().decode(ServerSettings.self, from: data) {
            settings = s
        } else {
            settings = ServerSettings()
        }
        let saved = SecureStore.load()
        token = saved
        paired = saved != nil
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(d, forKey: Self.settingsKey)
        }
    }

    var client: APIClient { APIClient(host: settings.cleanHost, port: settings.port, token: token) }

    var current: InstanceStatus? {
        instances.first(where: { $0.id == settings.instanceId }) ?? instances.first
    }

    // MARK: Emparejamiento

    func pair(code: String) async throws {
        let c = APIClient(host: settings.cleanHost, port: settings.port, token: nil)
        let r = try await c.pair(code: code.trimmingCharacters(in: .whitespaces).uppercased(), deviceName: settings.deviceName)
        SecureStore.save(r.token)
        token = r.token
        paired = true
        await refresh()
    }

    func unpair() {
        SecureStore.save(nil)
        token = nil
        paired = false
        instances = []
    }

    // MARK: Estado

    func refresh() async {
        guard settings.isConfigured, paired else { return }
        do {
            let s = try await client.status()
            instances = s.instances
            // El ID de instancia lo manda el servidor: si el guardado no existe, usar el primero real
            if !s.instances.contains(where: { $0.id == settings.instanceId }), let first = s.instances.first {
                settings.instanceId = first.id
            }
            reachable = true
            lastError = nil
        } catch let e as APIError {
            reachable = e.status != nil
            lastError = e.message
            if e.status == 401 { unpair() }
        } catch {
            reachable = false
            lastError = error.localizedDescription
        }
    }

    func perform(_ action: String) async {
        guard let id = current?.id else { return }
        busyMessage = action == "start" ? "Iniciando Android…" : action == "stop" ? "Apagando…" : "Reiniciando…"
        do {
            try await client.action(id, action)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        busyMessage = nil
        await refresh()
    }
}
