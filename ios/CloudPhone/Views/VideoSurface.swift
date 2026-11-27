import SwiftUI
import UIKit
import AVFoundation

/// Vista UIKit que muestra el vídeo del Android, traduce los toques a coordenadas normalizadas
/// (multitáctil) y puede recibir el teclado del iPhone (UIKeyInput).
@MainActor
final class VideoUIView: UIView, UIKeyInput {
    var videoSize: CGSize = .zero { didSet { setNeedsLayout() } }
    var onTouch: (@MainActor (String, Int, Double, Double) -> Void)?
    var onText: (@MainActor (String) -> Void)?
    var onKey: (@MainActor (String) -> Void)?

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var active: [UITouch: Int] = [:]

    // Ajustes del teclado: sin autocorrección para que el texto llegue tal cual al Android
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== layer else { return }
        displayLayer?.removeFromSuperlayer()
        displayLayer = layer
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }

    /// Rectángulo que ocupa realmente la imagen dentro de la vista (aspect-fit).
    private var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    private func normalized(_ touch: UITouch) -> (Double, Double) {
        let p = touch.location(in: self)
        let r = videoRect
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        let x = min(1, max(0, Double((p.x - r.minX) / r.width)))
        let y = min(1, max(0, Double((p.y - r.minY) / r.height)))
        return (x, y)
    }

    // MARK: Toques

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            var id = 0
            let used = Set(active.values)
            while used.contains(id) { id += 1 }
            active[t] = id
            let (x, y) = normalized(t)
            onTouch?("down", id, x, y)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let id = active[t] else { continue }
            let (x, y) = normalized(t)
            onTouch?("move", id, x, y)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches {
            guard let id = active[t] else { continue }
            let (x, y) = normalized(t)
            onTouch?("up", id, x, y)
            active[t] = nil
        }
    }

    // MARK: Teclado (UIKeyInput)

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" { onKey?("enter") } else { onText?(text) }
    }

    func deleteBackward() { onKey?("del") }
}

struct VideoSurface: UIViewRepresentable {
    @ObservedObject var stream: StreamClient
    @Binding var keyboardActive: Bool

    func makeUIView(context: Context) -> VideoUIView {
        let v = VideoUIView(frame: .zero)
        v.attach(stream.display.layer)
        v.onTouch = { [weak stream] action, id, x, y in
            stream?.touch(action, id: id, x: x, y: y)
        }
        v.onText = { [weak stream] text in
            stream?.text(text)
        }
        v.onKey = { [weak stream] key in
            stream?.key(key)
        }
        return v
    }

    func updateUIView(_ view: VideoUIView, context: Context) {
        view.videoSize = stream.videoSize
        if keyboardActive {
            if !view.isFirstResponder { _ = view.becomeFirstResponder() }
        } else if view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }
}
