import Foundation

/// Cliente REST del servidor Cloud Phone (HTTP en la red local).
struct APIClient {
    var host: String
    var port: Int
    var token: String?

    private func url(_ path: String) throws -> URL {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { throw APIError(message: "Falta la dirección del servidor") }
        let hostPart = h.contains(":") && !h.hasPrefix("[") ? "[\(h)]" : h   // IPv6
        guard let u = URL(string: "http://\(hostPart):\(port)\(path)") else {
            throw APIError(message: "Dirección del servidor no válida")
        }
        return u
    }

    private func perform(_ req: URLRequest, upload: URL? = nil) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do {
            if let upload {
                (data, resp) = try await URLSession.shared.upload(for: req, fromFile: upload)
            } else {
                (data, resp) = try await URLSession.shared.data(for: req)
            }
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw APIError(message: "El servidor no responde (tiempo agotado)")
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                throw APIError(message: "No se puede conectar con \(host):\(port). ¿Está el servidor encendido y en la misma red?")
            default: throw APIError(message: e.localizedDescription)
            }
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "Respuesta no válida") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Error HTTP \(http.statusCode)"
            throw APIError(message: msg, status: http.statusCode)
        }
        return data
    }

    private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil,
                         auth: Bool = true, timeout: TimeInterval = 15) async throws -> Data {
        var req = URLRequest(url: try url(path), timeoutInterval: timeout)
        req.httpMethod = method
        if auth {
            guard let token, !token.isEmpty else { throw APIError(message: "Este iPhone no está emparejado", status: 401) }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(req)
    }

    // MARK: Endpoints

    func ping() async throws {
        _ = try await request("/api/ping", auth: false, timeout: 5)
    }

    func pair(code: String, deviceName: String) async throws -> PairResponse {
        let d = try await request("/api/pair", method: "POST", json: ["code": code, "deviceName": deviceName], auth: false)
        return try JSONDecoder().decode(PairResponse.self, from: d)
    }

    func status() async throws -> StatusResponse {
        try JSONDecoder().decode(StatusResponse.self, from: try await request("/api/status", timeout: 8))
    }

    func info(_ id: String) async throws -> InstanceInfo {
        try JSONDecoder().decode(InstanceInfo.self, from: try await request("/api/instances/\(id)/info", timeout: 20))
    }

    /// start | stop | restart (pueden tardar más de un minuto)
    func action(_ id: String, _ name: String) async throws {
        _ = try await request("/api/instances/\(id)/\(name)", method: "POST", json: [:], timeout: 300)
    }

    func setOrientation(_ id: String, landscape: Bool) async throws {
        _ = try await request("/api/instances/\(id)/orientation", method: "POST",
                              json: ["orientation": landscape ? "landscape" : "portrait"])
    }

    func uploadAPK(_ id: String, fileURL: URL, name: String) async throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "app.apk"
        var req = URLRequest(url: try url("/api/instances/\(id)/apk?name=\(encoded)"), timeoutInterval: 900)
        req.httpMethod = "POST"
        guard let token else { throw APIError(message: "Este iPhone no está emparejado", status: 401) }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await perform(req, upload: fileURL)
    }
}
