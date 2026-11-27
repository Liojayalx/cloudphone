import Foundation
import AVFoundation
import CoreMedia

/// Recibe paquetes H.264 en formato Annex B (como los envía scrcpy), los convierte a AVCC
/// y los entrega a un AVSampleBufferDisplayLayer, que usa el decodificador por hardware.
final class H264Display {
    let layer = AVSampleBufferDisplayLayer()

    /// Se llama cuando hace falta un fotograma clave nuevo (error del decodificador, etc.).
    var onNeedKeyframe: (() -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var waitingForKey = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Nueva sesión de captura (inicio o rotación): descarta lo pendiente y espera un fotograma clave.
    func sessionChanged() {
        layer.flush()
        waitingForKey = true
    }

    func reset() {
        layer.flushAndRemoveImage()
        formatDescription = nil
        sps = nil
        pps = nil
        waitingForKey = true
    }

    // MARK: Configuración (SPS/PPS)

    func handleConfig(_ payload: [UInt8]) {
        for nal in Self.splitAnnexB(payload) {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            default: break
            }
        }
        rebuildFormatDescription()
    }

    private func rebuildFormatDescription() {
        guard let sps, let pps else { return }
        var newDesc: CMVideoFormatDescription?
        let spsCount = sps.count
        let ppsCount = pps.count
        let status: OSStatus = sps.withUnsafeBufferPointer { (sp: UnsafeBufferPointer<UInt8>) -> OSStatus in
            return pps.withUnsafeBufferPointer { (pp: UnsafeBufferPointer<UInt8>) -> OSStatus in
                guard let spBase = sp.baseAddress, let ppBase = pp.baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [spBase, ppBase]
                let sizes: [Int] = [spsCount, ppsCount]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newDesc)
            }
        }
        if status == noErr, let newDesc {
            formatDescription = newDesc
        }
    }

    // MARK: Fotogramas

    func handleFrame(_ payload: [UInt8], isKey: Bool, ptsMicros: Int64) {
        if layer.status == .failed {
            layer.flush()
            waitingForKey = true
            onNeedKeyframe?()
        }
        if waitingForKey && !isKey { return }

        // Algunos codificadores incluyen SPS/PPS dentro del fotograma clave.
        var avcc = [UInt8]()
        avcc.reserveCapacity(payload.count + 16)
        for nal in Self.splitAnnexB(payload) {
            guard let first = nal.first else { continue }
            let type = first & 0x1F
            if type == 7 { sps = nal; rebuildFormatDescription(); continue }
            if type == 8 { pps = nal; rebuildFormatDescription(); continue }
            if type == 9 { continue }                       // delimitador de acceso
            let n = UInt32(nal.count)
            avcc.append(UInt8((n >> 24) & 0xFF))
            avcc.append(UInt8((n >> 16) & 0xFF))
            avcc.append(UInt8((n >> 8) & 0xFF))
            avcc.append(UInt8(n & 0xFF))
            avcc.append(contentsOf: nal)
        }
        guard !avcc.isEmpty, let formatDescription else { return }
        guard let sample = Self.makeSampleBuffer(avcc: avcc, format: formatDescription, ptsMicros: ptsMicros) else { return }
        if isKey { waitingForKey = false }
        layer.enqueue(sample)
    }

    // MARK: Utilidades

    /// Separa un flujo Annex B (00 00 01 / 00 00 00 01) en unidades NAL sin el prefijo.
    static func splitAnnexB(_ d: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var i = 0
        var start = -1
        let n = d.count
        while i + 2 < n {
            if d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start && d[end - 1] == 0 { end -= 1 }   // el cero previo es parte del prefijo de 4 bytes
                    if end > start { result.append(Array(d[start..<end])) }
                }
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if start >= 0 && start < n { result.append(Array(d[start..<n])) }
        return result
    }

    private static func makeSampleBuffer(avcc: [UInt8], format: CMVideoFormatDescription, ptsMicros: Int64) -> CMSampleBuffer? {
        let count = avcc.count
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block)
        guard st == kCMBlockBufferNoErr, let block else { return nil }
        st = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard st == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: ptsMicros, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = count
        var sample: CMSampleBuffer?
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard st == noErr, let sample else { return nil }

        // Mostrar de inmediato, sin esperar a la marca de tiempo (baja latencia).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
