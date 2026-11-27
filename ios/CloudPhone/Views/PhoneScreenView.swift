import SwiftUI
import UIKit

/// Pantalla del Android virtual: vídeo en tiempo real, barra de navegación y herramientas.
@MainActor
struct PhoneScreenView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var stream = StreamClient()

    @State private var fullscreen = false
    @State private var keyboard = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface(stream: stream, keyboardActive: $keyboard)
                .ignoresSafeArea(edges: fullscreen ? .all : [])

            if stream.state != .streaming {
                statusOverlay
            }

            VStack(spacing: 0) {
                if !fullscreen { topBar }
                Spacer()
                if !fullscreen { navBar }
            }

            if fullscreen {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation { fullscreen = false }
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .foregroundColor(.white)
                        .opacity(0.55)
                        .padding(.trailing, 12)
                    }
                    Spacer()
                }
            }
        }
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        .onAppear { connect() }
        .onDisappear { stream.disconnect() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { stream.reconnectNow() }
        }
    }

    private func connect() {
        guard let token = store.token else { return }
        var s = store.settings
        if let id = store.current?.id { s.instanceId = id }   // siempre el ID real que informa el servidor
        stream.connect(settings: s, token: token)
        if store.settings.quality != .serverDefault {
            // La calidad se aplica en cuanto la sesión de vídeo está activa.
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                stream.applyQuality(store.settings.quality)
            }
        }
    }

    // MARK: Estado

    private var statusOverlay: some View {
        VStack(spacing: 12) {
            switch stream.state {
            case .connecting:
                ProgressView().tint(.white)
                Text("Conectando con el servidor…")
            case .reconnecting(let n):
                ProgressView().tint(.white)
                Text("Reconectando (intento \(n))…")
                if let m = stream.serverMessage { Text(m).font(.footnote).foregroundColor(Theme.muted) }
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(Theme.warn)
                Text(msg).multilineTextAlignment(.center)
                Button("Reintentar") { connect() }
                    .buttonStyle(.borderedProminent)
            case .streaming, .idle:
                Text("Esperando imagen…")
            }
        }
        .foregroundColor(.white)
        .padding(24)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    // MARK: Barras

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: { Image(systemName: "xmark") }

            VStack(alignment: .leading, spacing: 1) {
                Text(store.current?.name ?? "Cloud Phone").font(.subheadline.weight(.semibold))
                Text(statusLine).font(.caption2).foregroundColor(Theme.muted)
            }
            Spacer()

            Button { keyboard.toggle() } label: {
                Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
            }
            Button { stream.rotate() } label: { Image(systemName: "rotate.right") }
            Button { withAnimation { fullscreen = true } } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            Menu {
                Button { stream.notifications() } label: { Label("Notificaciones", systemImage: "bell") }
                Button { stream.key("power") } label: { Label("Encender/apagar pantalla", systemImage: "power") }
                Button { stream.key("volup") } label: { Label("Volumen +", systemImage: "speaker.plus") }
                Button { stream.key("voldown") } label: { Label("Volumen −", systemImage: "speaker.minus") }
                Button {
                    if let s = UIPasteboard.general.string { stream.pasteToAndroid(s) }
                } label: { Label("Pegar texto del iPhone", systemImage: "doc.on.clipboard") }
                Menu("Calidad de vídeo") {
                    ForEach(QualityPreset.allCases.filter { $0 != .serverDefault }) { q in
                        Button(q.title) { stream.applyQuality(q) }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .font(.body)
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var statusLine: String {
        var parts: [String] = []
        switch stream.state {
        case .streaming: parts.append("En directo")
        case .connecting: parts.append("Conectando")
        case .reconnecting: parts.append("Reconectando")
        case .failed: parts.append("Sin conexión")
        case .idle: parts.append("Inactivo")
        }
        if stream.videoSize.width > 0 { parts.append("\(Int(stream.videoSize.width))×\(Int(stream.videoSize.height))") }
        if stream.state == .streaming { parts.append("\(stream.fps) fps") }
        if let r = stream.rttMs { parts.append("\(r) ms") }
        if stream.androidRoot == true { parts.append("root") }
        return parts.joined(separator: " · ")
    }

    private var navBar: some View {
        HStack {
            navButton("chevron.backward") { stream.key("back") }
            Spacer()
            navButton("circle") { stream.key("home") }
            Spacer()
            navButton("square") { stream.key("recents") }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.white)
                .frame(width: 56, height: 40)
                .contentShape(Rectangle())
        }
    }
}
