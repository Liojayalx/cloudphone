import Foundation
import SwiftUI
import UIKit

/// Conexión WebSocket con el servidor: recibe el vídeo H.264 de la pantalla Android y envía los controles.
///
/// Protocolo (ver server/src/stream/hub.js):
///  - binario [0x01][ancho u32][alto u32]                    sesión de vídeo nueva (inicio / rotación)
///  - binario [0x02][flags][pts u64][payload Annex B]         flags: bit0 = SPS/PPS, bit1 = fotograma clave
///  - texto JSON: hello | pong | clipboard | error | closed
@MainActor
final class StreamClient: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        case reconnecting(attempt: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var rttMs: Int?
    @Published private(set) var fps: Int = 0
    @Published private(set) var serverMessage: String?
    @Published private(set) var androidRoot: Bool?

    let display = H264Display()

    private var settings = ServerSettings()
    private var token = ""
    private var session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = 0
    private var attempt = 0
    private var wantConnected = false
    private var frameCounter = 0
    private var fpsTimer: Timer?

    init() {
        display.onNeedKeyframe = { [weak self] in
            Task { @MainActor in self?.send(["t": "keyframe"]) }
        }
    }

    // MARK: Ciclo de vida

    func connect(settings: ServerSettings, token: String) {
        self.settings = settings
        self.token = token
        wantConnected = true
        attempt = 0
        startFpsTimer()
        open()
    }

    func disconnect() {
        wantConnected = false
        retryTask?.cancel()
        teardown()
        state = .idle
        fps = 0
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    /// Reconecta de inmediato (por ejemplo al volver la app a primer plano).
    func reconnectNow() {
        guard wantConnected else { return }
        retryTask?.cancel()
        attempt = 0
        open()
    }

    private func startFpsTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fps = self.frameCounter
                self.frameCounter = 0
            }
        }
    }

    private func teardown() {
        generation += 1
        receiveTask?.cancel(); receiveTask = nil
        pingTask?.cancel(); pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func open() {
        teardown()
        let host = settings.cleanHost
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "ws://\(hostPart):\(settings.port)/stream/\(settings.instanceId)") else {
            state = .failed("Dirección del servidor no válida")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        state = attempt > 0 ? .reconnecting(attempt: attempt) : .connecting
        serverMessage = nil
        display.reset()

        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 32 * 1024 * 1024
        task = t
        let gen = generation
        t.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task: t, gen: gen) }
        pingTask = Task { [weak self] in await self?.pingLoop(gen: gen) }
    }

    // MARK: Recepción

    private func receiveLoop(task: URLSessionWebSocketTask, gen: Int) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                guard gen == generation else { return }
                switch message {
                case .data(let d): handleBinary(d)
                case .string(let s): handleText(s)
                @unknown default: break
                }
            }
        } catch {
            guard gen == generation else { return }
            handleDisconnect(task: task, error: error)
        }
    }

    private func handleBinary(_ data: Data) {
        let b = [UInt8](data)
        guard let type = b.first else { return }
        if type == 1, b.count >= 9 {
            let w = Int(be32(b, 1)), h = Int(be32(b, 5))
            videoSize = CGSize(width: w, height: h)
            display.sessionChanged()
        } else if type == 2, b.count > 10 {
            let flags = b[1]
            let pts = Int64(bitPattern: be64(b, 2))
            let payload = Array(b[10...])
            if flags & 1 != 0 {
                display.handleConfig(payload)
            } else {
                display.handleFrame(payload, isKey: flags & 2 != 0, ptsMicros: pts)
                frameCounter += 1
                if state != .streaming {
                    state = .streaming
                    attempt = 0
                }
            }
        }
    }

    private func handleText(_ s: String) {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "hello":
            androidRoot = obj["root"] as? Bool
        case "pong":
            if let ts = obj["ts"] as? Double {
                rttMs = max(0, Int(Date().timeIntervalSince1970 * 1000 - ts))
            }
        case "error":
            serverMessage = obj["message"] as? String
        case "closed":
            serverMessage = obj["reason"] as? String
        case "clipboard":
            if let text = obj["text"] as? String { UIPasteboard.general.string = text }
        default: break
        }
    }

    // MARK: Desconexión y reconexión

    private func handleDisconnect(task: URLSessionWebSocketTask, error: Error) {
        teardown()
        guard wantConnected else { return }

        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 {
            wantConnected = false
            state = .failed("Servidor: este iPhone no está autorizado. Vuelve a emparejarlo en Ajustes.")
            return
        }
        guard settings.autoReconnect else {
            state = .failed(serverMessage ?? "Conexión perdida")
            return
        }
        attempt += 1
        if settings.maxReconnectAttempts > 0 && attempt > settings.maxReconnectAttempts {
            state = .failed(serverMessage ?? "No se pudo reconectar tras \(settings.maxReconnectAttempts) intentos")
            return
        }
        state = .reconnecting(attempt: attempt)
        let delay = min(10.0, pow(2.0, Double(min(attempt - 1, 4))))   // 1, 2, 4, 8, 10 s
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.wantConnected else { return }
                self.open()
            }
        }
    }

    // MARK: Ping / latencia

    private func pingLoop(gen: Int) async {
        while !Task.isCancelled && gen == generation {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, gen == generation else { return }
            var msg: [String: Any] = ["t": "ping", "ts": Date().timeIntervalSince1970 * 1000]
            if let rttMs { msg["rtt"] = rttMs }
            send(msg)
        }
    }

    // MARK: Envío de controles

    func send(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// x, y normalizados (0...1) sobre la imagen del Android.
    func touch(_ action: String, id: Int, x: Double, y: Double) {
        send(["t": "touch", "a": action, "id": id, "x": x, "y": y, "p": action == "up" ? 0.0 : 1.0])
    }

    func key(_ name: String) { send(["t": "key", "k": name]) }
    func text(_ s: String) { send(["t": "text", "text": s]) }
    func rotate() { send(["t": "rotate"]) }
    func notifications() { send(["t": "notif"]) }

    func applyQuality(_ preset: QualityPreset) {
        guard let p = preset.params else { return }
        send(["t": "quality", "fps": p.fps, "bitrateKbps": p.kbps])
    }

    func pasteToAndroid(_ s: String) { send(["t": "clipboard", "text": s, "paste": true]) }

    // MARK: Utilidades

    private func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    private func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (UInt64(be32(b, o)) << 32) | UInt64(be32(b, o + 4))
    }
}
