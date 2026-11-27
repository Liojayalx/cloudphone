import SwiftUI
import UniformTypeIdentifiers

/// Panel principal: tarjeta del dispositivo virtual con su estado y acciones.
@MainActor
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSettings = false
    @State private var showScreen = false
    @State private var info: InstanceInfo?
    @State private var showImporter = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !store.settings.isConfigured || !store.paired {
                        onboardingCard
                    } else if let inst = store.current {
                        deviceCard(inst)
                    } else {
                        emptyCard
                    }
                    if let toast {
                        Text(toast).font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Cloud Phone")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(store)
            }
            .fullScreenCover(isPresented: $showScreen) {
                PhoneScreenView().environmentObject(store)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { Task { await uploadAPK(url) } }
            }
            .task(id: store.paired) {
                while !Task.isCancelled {
                    await store.refresh()
                    if store.current?.isRunning == true { await loadInfo() } else { info = nil }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: Tarjetas

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.largeTitle).foregroundColor(Theme.accent)
            Text("Conecta con tu PC").font(.title3.weight(.semibold))
            Text("1. Instala y ejecuta el servidor Cloud Phone en tu PC con Windows.\n2. Abre Ajustes e introduce la IP y el puerto del servidor.\n3. Escribe el código de emparejamiento que muestra el panel del PC.")
                .font(.subheadline).foregroundColor(Theme.muted)
            Button { showSettings = true } label: {
                Text("Abrir ajustes").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .cardStyle()
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            if store.reachable == false {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundColor(Theme.warn)
                Text("Sin conexión con el servidor").font(.headline)
            } else {
                ProgressView()
                Text("Buscando dispositivos…").font(.headline)
            }
            if let e = store.lastError { Text(e).font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func deviceCard(_ inst: InstanceStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "iphone.gen3").font(.system(size: 34)).foregroundColor(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(inst.name).font(.title3.weight(.semibold))
                    Text(subtitle(inst)).font(.footnote).foregroundColor(Theme.muted)
                }
                Spacer()
                Menu {
                    Button { Task { await store.perform("start") } } label: { Label("Iniciar", systemImage: "play") }
                        .disabled(inst.state != "stopped")
                    Button { Task { await store.perform("restart") } } label: { Label("Reiniciar", systemImage: "arrow.clockwise") }
                        .disabled(!inst.isRunning)
                    Button(role: .destructive) { Task { await store.perform("stop") } } label: { Label("Apagar", systemImage: "power") }
                        .disabled(inst.state == "stopped")
                    Divider()
                    Button { showImporter = true } label: { Label("Instalar APK…", systemImage: "square.and.arrow.down") }
                        .disabled(!inst.isRunning)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .disabled(store.busyMessage != nil)
            }

            HStack(spacing: 8) {
                badge(inst.stateTitle, color: stateColor(inst.state))
                badge(rootText(inst), color: rootColor(inst))
                badge(store.reachable ? "Conectado" : "Sin red", color: store.reachable ? Theme.ok : Theme.bad)
            }

            if let msg = store.busyMessage ?? inst.busy.map({ "Operación en curso: \($0)…" }) {
                HStack(spacing: 8) { ProgressView(); Text(msg).font(.footnote).foregroundColor(Theme.muted) }
            }
            if let err = inst.error { Text(err).font(.footnote).foregroundColor(Theme.bad) }

            if inst.isRunning, let info { infoGrid(info) }

            Button {
                if inst.isRunning { showScreen = true } else { Task { await store.perform("start"); } }
            } label: {
                Text(inst.isRunning ? "Abrir dispositivo" : (inst.state == "stopped" ? "Iniciar Android" : "Espera…"))
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.busyMessage != nil || inst.busy != nil || inst.state == "starting" || inst.state == "stopping")

            if let e = store.lastError { Text(e).font(.footnote).foregroundColor(Theme.bad) }
        }
        .cardStyle()
    }

    private func infoGrid(_ i: InstanceInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow("Android", "\(i.androidVersion ?? "?") (API \(i.sdk ?? "?"))")
            infoRow("Modelo", i.model ?? "—")
            if let d = i.display { infoRow("Pantalla", "\(d.size ?? "—") · \(d.density ?? "—") dpi") }
            if let m = i.memoryTotalMB { infoRow("Memoria", "\(m) MB") }
            if let s = i.storage, let u = s.usedMB, let t = s.totalMB { infoRow("Almacenamiento", "\(u) / \(t) MB") }
            infoRow("Root", i.root.active ? "Activo (\(i.root.id ?? "uid=0"))" : "No disponible")
        }
        .padding(12)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.footnote).foregroundColor(Theme.muted).frame(width: 110, alignment: .leading)
            Text(v).font(.footnote)
            Spacer(minLength: 0)
        }
    }

    // MARK: Utilidades

    private func subtitle(_ inst: InstanceStatus) -> String {
        guard let c = inst.configured else { return inst.stateTitle }
        var s = "\(c.resolution.width)×\(c.resolution.height) · \(c.dpi) dpi · Android API \(c.apiLevel)"
        if let up = inst.uptimeSeconds, inst.isRunning { s += " · activo \(up / 60) min" }
        return s
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .foregroundColor(color)
            .overlay(Capsule().stroke(color.opacity(0.8), lineWidth: 1))
    }

    private func stateColor(_ s: String) -> Color {
        switch s {
        case "running": return Theme.ok
        case "starting", "stopping": return Theme.warn
        case "error": return Theme.bad
        default: return Theme.muted
        }
    }

    private func rootText(_ i: InstanceStatus) -> String {
        guard i.isRunning else { return i.root.requested ? "Root configurado" : "Sin root" }
        return i.root.active == true ? "Root activo" : "Sin root"
    }

    private func rootColor(_ i: InstanceStatus) -> Color {
        guard i.isRunning else { return Theme.muted }
        return i.root.active == true ? Theme.ok : Theme.warn
    }

    private func loadInfo() async {
        guard let id = store.current?.id else { return }
        if let i = try? await store.client.info(id) { info = i }
    }

    private func uploadAPK(_ url: URL) async {
        guard let id = store.current?.id else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        toast = "Subiendo \(url.lastPathComponent)…"
        do {
            try await store.client.uploadAPK(id, fileURL: url, name: url.lastPathComponent)
            toast = "\(url.lastPathComponent) instalado en el Android"
        } catch {
            toast = "No se pudo instalar: \(error.localizedDescription)"
        }
    }
}

extension View {
    func cardStyle() -> some View {
        self.padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line, lineWidth: 1))
    }
}
