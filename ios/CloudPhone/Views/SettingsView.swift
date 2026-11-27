import SwiftUI

/// Ajustes: servidor, emparejamiento, calidad de streaming y opciones de reconexión.
@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var portText = ""
    @State private var code = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP del PC (ej. 192.168.1.50)", text: $store.settings.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Puerto", text: $portText)
                        .keyboardType(.numberPad)
                        .onChange(of: portText) { v in
                            if let p = Int(v), (1024...65535).contains(p) { store.settings.port = p }
                        }
                    Button {
                        Task { await testConnection() }
                    } label: { Label("Probar conexión", systemImage: "antenna.radiowaves.left.and.right") }
                    .disabled(working || !store.settings.isConfigured)
                } header: {
                    Text("Servidor")
                } footer: {
                    Text("Usa la IP de tu PC en la red Wi-Fi (o la de Tailscale/VPN para conectarte desde fuera). La conexión no está cifrada: no uses redes públicas.")
                }

                Section {
                    if store.paired {
                        Label("Este iPhone está emparejado", systemImage: "checkmark.seal.fill").foregroundColor(Theme.ok)
                        Button("Desemparejar", role: .destructive) { store.unpair() }
                    } else {
                        TextField("Código de emparejamiento", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        TextField("Nombre de este iPhone", text: $store.settings.deviceName)
                        Button {
                            Task { await pair() }
                        } label: { Label("Emparejar", systemImage: "link") }
                        .disabled(working || code.count < 6 || !store.settings.isConfigured)
                    }
                } header: {
                    Text("Emparejamiento")
                } footer: {
                    Text("El código aparece en el panel de administración del PC (pestaña Dispositivos) y es de un solo uso.")
                }

                Section {
                    Picker("Calidad", selection: $store.settings.quality) {
                        ForEach(QualityPreset.allCases) { q in Text(q.title).tag(q) }
                    }
                } header: {
                    Text("Streaming")
                } footer: {
                    Text("Baja: 24 fps · 1,5 Mbps. Equilibrada: 30 fps · 4 Mbps. Alta: 60 fps · 8 Mbps. «Predeterminada» usa la configuración del servidor. Se aplica al abrir el dispositivo.")
                }

                Section {
                    Toggle("Reconectar automáticamente", isOn: $store.settings.autoReconnect)
                    if store.settings.autoReconnect {
                        Stepper(value: $store.settings.maxReconnectAttempts, in: 0...50) {
                            Text(store.settings.maxReconnectAttempts == 0
                                 ? "Intentos: sin límite"
                                 : "Intentos: \(store.settings.maxReconnectAttempts)")
                        }
                    }
                    TextField("ID de la instancia", text: $store.settings.instanceId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Conexión")
                }

                if let message {
                    Section { Text(message).foregroundColor(messageIsError ? Theme.bad : Theme.ok) }
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hecho") { dismiss() } }
            }
            .onAppear { portText = String(store.settings.port) }
        }
    }

    private func testConnection() async {
        working = true
        defer { working = false }
        do {
            try await APIClient(host: store.settings.cleanHost, port: store.settings.port, token: nil).ping()
            show("El servidor responde correctamente", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func pair() async {
        working = true
        defer { working = false }
        do {
            try await store.pair(code: code)
            code = ""
            show("Emparejado correctamente", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}
