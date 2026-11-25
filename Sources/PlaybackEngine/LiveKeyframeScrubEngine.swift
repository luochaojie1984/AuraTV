import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import CoreImage
import CoreMedia
import AVFoundation
import SwiftUI
import UIKit
import QuartzCore
import os

#if canImport(KSPlayer) && !targetEnvironment(simulator)
import KSPlayer
#if canImport(Libavcodec)
import Libavcodec
#endif
#if canImport(Libavformat)
import Libavformat
#endif
#endif

/// Wraps a VideoToolbox `CVPixelBuffer` for zero-copy cross-actor transport to the GPU display layer.
public final class SendablePixelBuffer: @unchecked Sendable {
    public let buffer: CVPixelBuffer

    public init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}

public enum ScrubFrameContent: Sendable {
    case pixelBuffer(SendablePixelBuffer, rotation: UInt16)
    case cgImage(CGImage)
}

/// A decoded video preview frame returned by `LiveKeyframeScrubEngine`.
public struct ScrubPreviewFrame: Sendable {
    public let content: ScrubFrameContent
    public let actualTime: TimeInterval

    public var cgImage: CGImage? {
        if case .cgImage(let img) = content { return img }
        return nil
    }

    public init(cgImage: CGImage, actualTime: TimeInterval) {
        self.content = .cgImage(cgImage)
        self.actualTime = actualTime
    }

    public init(pixelBuffer: CVPixelBuffer, rotation: UInt16 = 0, actualTime: TimeInterval) {
        self.content = .pixelBuffer(SendablePixelBuffer(pixelBuffer), rotation: rotation)
        self.actualTime = actualTime
    }
}

/// Result of a preview decode request: distinguishes a freshly rendered frame from an unchanged GOP frame
/// so the caller avoids redundant UI updates and never falls back to a slow main-player seek when unchanged.
public enum ScrubDecodeOutcome: Sendable {
    case frame(ScrubPreviewFrame)
    case unchanged(actualTime: TimeInterval)
    case unavailable
}

/// Zero-copy CoreAnimation / AVSampleBufferDisplayLayer presenter for full-screen live scrub frames.
/// Enqueues VideoToolbox `CVPixelBuffer` directly onto the GPU (~0.2ms, zero CIContext CPU readback)
/// without triggering SwiftUI view-tree diffing on `PlayerScreenView` at 24–60 fps.
@MainActor
public final class ScrubFramePresenter {
    fileprivate weak var canvasView: ScrubCanvasView?
    private var pendingContent: ScrubFrameContent?
    public private(set) var isVisible: Bool = false

    public init() {}

    fileprivate func attach(_ view: ScrubCanvasView) {
        canvasView = view
        if let pendingContent, isVisible {
            view.present(pendingContent)
        } else {
            view.clear()
        }
    }

    public func present(_ frame: ScrubPreviewFrame) {
        present(frame.content)
    }

    public func present(_ content: ScrubFrameContent) {
        pendingContent = content
        isVisible = true
        canvasView?.present(content)
    }

    public func present(_ cgImage: CGImage) {
        present(.cgImage(cgImage))
    }

    public func clear() {
        pendingContent = nil
        isVisible = false
        canvasView?.clear()
    }
}

final class ScrubCanvasView: UIView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var currentRotation: UInt16 = 0
    private lazy var fallbackCIContext = CIContext(options: [.useSoftwareRenderer: false])

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        isHidden = true

        layer.contentsGravity = .resizeAspect
        layer.masksToBounds = true
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear

        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        displayLayer.isHidden = true
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyDisplayLayout(for: currentRotation)
    }

    func present(_ content: ScrubFrameContent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch content {
        case .pixelBuffer(let box, let rotation):
            if let sampleBuffer = Self.makeSampleBuffer(from: box.buffer) {
                layer.contents = nil
                if currentRotation != rotation || displayLayer.bounds.isEmpty {
                    currentRotation = rotation
                    applyDisplayLayout(for: rotation)
                }
                displayLayer.isHidden = false
                isHidden = false
                CATransaction.commit()

                let renderer = displayLayer.sampleBufferRenderer
                if renderer.status == .failed {
                    renderer.flush()
                }
                renderer.enqueue(sampleBuffer)
                return
            }

            // Graceful fallback only if CMSampleBuffer creation unexpectedly fails
            var ciImage = CIImage(cvPixelBuffer: box.buffer)
            if rotation == 90 { ciImage = ciImage.oriented(.right) }
            else if rotation == 180 { ciImage = ciImage.oriented(.down) }
            else if rotation == 270 { ciImage = ciImage.oriented(.left) }
            displayLayer.isHidden = true
            layer.contents = fallbackCIContext.createCGImage(ciImage, from: ciImage.extent.integral)
            isHidden = false

        case .cgImage(let image):
            displayLayer.isHidden = true
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            layer.contents = image
            isHidden = false
        }

        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        displayLayer.isHidden = true
        isHidden = true
        CATransaction.commit()
    }

    private func applyDisplayLayout(for rotation: UInt16) {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.position = CGPoint(x: b.midX, y: b.midY)
        switch rotation {
        case 90:
            displayLayer.bounds = CGRect(x: 0, y: 0, width: b.height, height: b.width)
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))
        case 180:
            displayLayer.bounds = b
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: .pi))
        case 270:
            displayLayer.bounds = CGRect(x: 0, y: 0, width: b.height, height: b.width)
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2))
        default:
            displayLayer.bounds = b
            displayLayer.setAffineTransform(.identity)
        }
        CATransaction.commit()
    }

    private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let bufStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard bufStatus == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}

/// SwiftUI wrapper hosting `ScrubCanvasView`. Created once and updated directly via `ScrubFramePresenter`.
public struct ScrubFrameDisplayView: UIViewRepresentable {
    public let presenter: ScrubFramePresenter

    public init(presenter: ScrubFramePresenter) {
        self.presenter = presenter
    }

    public func makeUIView(context: Context) -> UIView {
        let view = ScrubCanvasView()
        presenter.attach(view)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        if let canvas = uiView as? ScrubCanvasView {
            presenter.attach(canvas)
        }
    }
}

#if canImport(KSPlayer) && !targetEnvironment(simulator)
/// Custom zero-HTTP `AbstractAVIOContext` reading directly from a persistent SMB file handle.
/// Pins the first/last 2 MB (MKV Cues / MP4 `moov`) in RAM and maintains a 384 KB micro-buffer
/// so sequential forward frames & GOP seeks bypass loopback TCP sockets completely.
private final class ScrubAVIOContext: AbstractAVIOContext, @unchecked Sendable {
    private let reader: any SynchronousRandomAccessReader
    private let lock = NSLock()
    private var cursor: Int64 = 0
    private let totalSize: Int64
    private var isClosed: Bool = false

    private let edgePinBytes: Int = 2 * 1024 * 1024
    private var headCache: Data?
    private var tailCacheStart: Int64 = -1
    private var tailCache: Data?

    private var isOpenPhase: Bool = true
    private var didInspectMP4Moov: Bool = false
    private var openMoovStart: Int64 = -1
    private var openMoovData: Data?
    private let openWindowBytes: Int = 2 * 1024 * 1024

    private let microWindowBytes: Int = 512 * 1024
    private var microStart: Int64 = -1
    private var microData: Data = Data()

    private static let averrorEOF: Int32 = -541478725

    init(reader: any SynchronousRandomAccessReader) {
        self.reader = reader
        self.totalSize = max(0, reader.totalSize)
        super.init(bufferSize: 64 * 1024)
    }

    deinit {
        close()
    }

    override func fileSize() -> Int64 {
        totalSize
    }

    override func seek(offset: Int64, whence w: Int32) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if (w & 0x10000) != 0 { // AVSEEK_SIZE
            return totalSize
        }
        guard !isClosed else { return -1 }
        let base = w & 0xFF
        let target: Int64
        switch base {
        case 0: // SEEK_SET
            target = offset
        case 1: // SEEK_CUR
            target = cursor + offset
        case 2: // SEEK_END
            target = totalSize + offset
        default:
            return -1
        }
        guard target >= 0 else { return -1 }
        cursor = min(target, totalSize)
        return cursor
    }

    func finishOpenPhase() {
        lock.lock()
        isOpenPhase = false
        openMoovData = nil
        openMoovStart = -1
        lock.unlock()
    }

    private func readHeaderByteRangeLocked(offset: Int64, length: Int) -> Data? {
        if let hc = headCache,
           offset >= 0,
           Int(offset) < hc.count,
           (offset + Int64(length)) <= Int64(hc.count) {
            let base = hc.startIndex
            return Data(hc[(base + Int(offset))..<(base + Int(offset) + length)])
        }
        return try? reader.readSync(offset: offset, length: length)
    }

    private func preloadMP4MoovLocked() {
        didInspectMP4Moov = true
        guard totalSize >= 24 else { return }

        if headCache == nil {
            let headLen = Int(min(totalSize, Int64(edgePinBytes)))
            headCache = try? reader.readSync(offset: 0, length: headLen)
        }
        guard let hc = headCache, hc.count >= 12 else { return }
        let magic = hc.withUnsafeBytes { raw -> UInt32 in
            guard let ptr = raw.baseAddress else { return 0 }
            return ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian
        }
        guard magic == 0x66747970 else { return } // "ftyp"

        var off: Int64 = 0
        for _ in 0..<16 {
            guard off + 8 <= totalSize else { break }
            let hdrLen = Int(min(16, totalSize - off))
            guard let hdr = readHeaderByteRangeLocked(offset: off, length: hdrLen), hdr.count >= 8 else { break }
            let (rawSize, boxType) = hdr.withUnsafeBytes { raw -> (UInt32, UInt32) in
                let p = raw.baseAddress!
                return (
                    p.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian,
                    p.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian
                )
            }
            var boxSize = Int64(rawSize)
            if boxSize == 1 {
                guard hdr.count >= 16 else { break }
                let ext = hdr.withUnsafeBytes { raw -> UInt64 in
                    raw.baseAddress!.loadUnaligned(fromByteOffset: 8, as: UInt64.self).bigEndian
                }
                boxSize = ext <= UInt64(Int64.max) ? Int64(ext) : Int64.max
            } else if boxSize == 0 {
                boxSize = totalSize - off
            }
            guard boxSize >= 8 else { break }

            if boxType == 0x6D6F6F76 { // "moov"
                let maxMoovBytes: Int64 = 24 * 1024 * 1024
                guard boxSize <= maxMoovBytes else { break }
                var buf = Data()
                buf.reserveCapacity(Int(boxSize))
                var pos = off
                let end = min(totalSize, off + boxSize)
                let step = Int64(openWindowBytes)
                while pos < end {
                    let wantChunk = Int(min(step, end - pos))
                    guard let chunk = try? reader.readSync(offset: pos, length: wantChunk), !chunk.isEmpty else {
                        return
                    }
                    buf.append(chunk)
                    pos += Int64(chunk.count)
                }
                if !buf.isEmpty {
                    openMoovStart = off
                    openMoovData = buf
                }
                return
            }

            guard off <= totalSize - boxSize else { break }
            off += boxSize
        }
    }

    override func read(buffer buf: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let buf, size > 0, cursor < totalSize else {
            return Self.averrorEOF
        }

        let want = Int(min(Int64(size), totalSize - cursor))
        guard want > 0 else { return Self.averrorEOF }

        if isOpenPhase && !didInspectMP4Moov {
            preloadMP4MoovLocked()
        }

        // 0. Open-phase preloaded MP4 moov cache (covers large/tail 10-14 MB moov in bulk SMB reads)
        if openMoovStart >= 0,
           let moov = openMoovData,
           cursor >= openMoovStart,
           (cursor + Int64(want)) <= (openMoovStart + Int64(moov.count)) {
            Self.copySlice(from: moov, localStart: Int(cursor - openMoovStart), count: want, into: buf)
            cursor += Int64(want)
            return Int32(want)
        }

        // 1. Head cache (0..<2MB)
        if cursor < Int64(edgePinBytes) {
            if headCache == nil {
                let len = Int(min(totalSize, Int64(edgePinBytes)))
                headCache = try? reader.readSync(offset: 0, length: len)
            }
            if let hc = headCache,
               Int(cursor) < hc.count,
               (cursor + Int64(want)) <= Int64(hc.count) {
                Self.copySlice(from: hc, localStart: Int(cursor), count: want, into: buf)
                cursor += Int64(want)
                return Int32(want)
            }
        }

        // 2. Tail cache (last 2MB)
        let tailEdge = max(Int64(0), totalSize - Int64(edgePinBytes))
        if cursor >= tailEdge {
            if tailCache == nil {
                let len = Int(totalSize - tailEdge)
                if len > 0, let tc = try? reader.readSync(offset: tailEdge, length: len) {
                    tailCacheStart = tailEdge
                    tailCache = tc
                }
            }
            if let tc = tailCache,
               tailCacheStart >= 0,
               cursor >= tailCacheStart,
               (cursor + Int64(want)) <= (tailCacheStart + Int64(tc.count)) {
                Self.copySlice(from: tc, localStart: Int(cursor - tailCacheStart), count: want, into: buf)
                cursor += Int64(want)
                return Int32(want)
            }
        }

        // 3. Sliding 512 KB micro-buffer hit
        if microStart >= 0,
           cursor >= microStart,
           (cursor + Int64(want)) <= (microStart + Int64(microData.count)) {
            Self.copySlice(from: microData, localStart: Int(cursor - microStart), count: want, into: buf)
            cursor += Int64(want)
            return Int32(want)
        }

        // 4. Single SMB pread window fetch (2 MB during open, 512 KB during scrub)
        let windowSize = isOpenPhase ? openWindowBytes : microWindowBytes
        let fetchLen = Int(min(Int64(max(want, windowSize)), totalSize - cursor))
        guard let fetched = try? reader.readSync(offset: cursor, length: fetchLen), !fetched.isEmpty else {
            return Self.averrorEOF
        }
        microStart = cursor
        microData = fetched
        let n = min(want, fetched.count)
        Self.copySlice(from: fetched, localStart: 0, count: n, into: buf)
        cursor += Int64(n)
        return Int32(n)
    }

    override func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        isOpenPhase = false
        openMoovData = nil
        openMoovStart = -1
        headCache = nil
        tailCache = nil
        tailCacheStart = -1
        microStart = -1
        microData = Data()
        lock.unlock()
        reader.closeSync()
    }

    @inline(__always)
    private static func copySlice(from source: Data, localStart: Int, count: Int, into dest: UnsafeMutablePointer<UInt8>) {
        source.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            dest.update(from: base.advanced(by: localStart), count: count)
        }
    }
}

/// Dedicated hardware live-frame scrub engine built directly on KSPlayer's `FormatContext`
/// and synchronous `VideoToolboxDecode` (auto-falling back to `FFmpegDecode` for AV1/VP9/Hi10P).
///
/// Smoothness optimizations:
/// - Reads directly via `ScrubAVIOContext` + persistent `SMB2RandomAccessFile` (zero HTTP/TCP churn).
/// - Hybrid sequential-forward stepping + anti-GOP-freeze keyframe jumping prevents GOP freezes and
///   yields rapid continuous frame updates across both low-speed and high-speed fast-forward.
/// - Downscales decoded 4K/HDR frames on GPU via `CIContext` to max 960px wide with HDR tone-mapping.
public final class LiveKeyframeScrubEngine: @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "local.personal.auratv.live-scrub", qos: .userInteractive)
    private let latestGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    // State exclusively accessed on `workQueue`
    private var preparedURL: URL?
    private var formatContext: FormatContext?
    private var avioContext: ScrubAVIOContext?
    private var videoTrack: FFmpegAssetTrack?
    private var decoder: (any DecodeProtocol)?
    private var scrubOptions: KSOptions?
    private var usingSoftwareFallback: Bool = false
    private var isClosed: Bool = false

    private var lastRenderedPTS: Int64 = Int64.min
    private var lastRenderedTime: TimeInterval = -.infinity
    private var lastRequestedTarget: TimeInterval = -.infinity
    private var demuxerIsContinuous: Bool = false
    private var demuxerCursorTime: TimeInterval = -.infinity

    private lazy var ciContext: CIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    private let maxPreviewWidth: CGFloat = 720

    public init() {}

    deinit {
        latestGeneration.withLock { $0 &+= 1 }
        let d = decoder
        let ctx = formatContext
        let avio = avioContext
        decoder = nil
        formatContext = nil
        avioContext = nil
        videoTrack = nil
        scrubOptions = nil
        if d != nil || ctx != nil || avio != nil {
            workQueue.async {
                d?.shutdown()
                ctx?.close()
                avio?.close()
            }
        }
    }

    public var isReady: Bool {
        workQueue.sync {
            !isClosed && formatContext != nil && videoTrack != nil && decoder != nil
        }
    }

    public func resetTracking() {
        workQueue.async { [self] in
            lastRenderedPTS = Int64.min
            lastRenderedTime = -.infinity
            lastRequestedTarget = -.infinity
            demuxerIsContinuous = false
            demuxerCursorTime = -.infinity
        }
    }

    public func prepare(url: URL, directReader: (any SynchronousRandomAccessReader)? = nil) async {
        let alreadyPrepared: Bool = await withCheckedContinuation { cont in
            workQueue.async { [self] in
                cont.resume(returning: !isClosed && preparedURL == url && formatContext != nil && decoder != nil)
            }
        }
        if alreadyPrepared {
            directReader?.closeSync()
            return
        }

        let opts = KSOptions()
        opts.seekInterruptIO = true
        opts.seekFlags = 1 // AVSEEK_FLAG_BACKWARD
        opts.isAccurateSeek = false
        opts.autoSelectEmbedSubtitle = false
        opts.subtitleDisable = true
        opts.formatContextOptions["probesize"] = 512 * 1024
        opts.formatContextOptions["analyzeduration"] = 500_000
        opts.decoderOptions["threads"] = "4"
        opts.videoSoftDecodeThreadCount = 4

        var openedCtx: FormatContext?
        var openedAVIO: ScrubAVIOContext?

        if let directReader {
            let avio = ScrubAVIOContext(reader: directReader)
            if let directCtx = try? await FormatContext(io: .right(avio), options: opts),
               directCtx.assetTracks.contains(where: { $0.mediaType == .video }) {
                avio.finishOpenPhase()
                openedCtx = directCtx
                openedAVIO = avio
            } else {
                avio.close()
            }
        }

        if openedCtx == nil {
            openedCtx = try? await FormatContext(url: url, options: opts)
        }

        guard let ctx = openedCtx else { return }

        guard let vTrack = ctx.assetTracks.first(where: { $0.mediaType == .video && !$0.isImage && !$0.isStillImage })
            ?? ctx.assetTracks.first(where: { $0.mediaType == .video }) else {
            ctx.close()
            openedAVIO?.close()
            return
        }

        for track in ctx.assetTracks {
            let isVideo = (track.trackID == vTrack.trackID)
            track.isEnabled = isVideo
            #if canImport(Libavcodec) && canImport(Libavformat)
            if !isVideo, let stream = track.stream {
                stream.pointee.discard = AVDISCARD_ALL
            }
            #endif
        }

        let createdDecoder: any DecodeProtocol
        let isSW: Bool
        if let vt = VideoToolboxDecode(assetTrack: vTrack, options: opts, asynchronous: false) {
            createdDecoder = vt
            isSW = false
        } else {
            createdDecoder = FFmpegDecode(assetTrack: vTrack, options: opts)
            isSW = true
        }

        let finalAVIO = openedAVIO
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            workQueue.async { [self] in
                if isClosed {
                    createdDecoder.shutdown()
                    ctx.close()
                    finalAVIO?.close()
                    cont.resume()
                    return
                }
                teardownOnQueue()
                preparedURL = url
                formatContext = ctx
                avioContext = finalAVIO
                videoTrack = vTrack
                decoder = createdDecoder
                scrubOptions = opts
                usingSoftwareFallback = isSW
                cont.resume()
            }
        }
    }

    public func decodePreviewFrame(at targetTime: TimeInterval, requestedSpeed: Double = 8.0) async -> ScrubDecodeOutcome {
        let myGen = latestGeneration.withLock { gen -> UInt64 in
            gen &+= 1
            return gen
        }

        return await withCheckedContinuation { cont in
            workQueue.async { [self] in
                if isClosed || currentGeneration() != myGen {
                    cont.resume(returning: .unavailable)
                    return
                }
                let outcome = decodeOnQueue(
                    targetTime: max(0, targetTime),
                    requestedSpeed: max(1.0, requestedSpeed),
                    generation: myGen
                )
                cont.resume(returning: outcome)
            }
        }
    }

    public func close() async {
        latestGeneration.withLock { $0 &+= 1 }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            workQueue.async { [self] in
                isClosed = true
                teardownOnQueue()
                cont.resume()
            }
        }
    }

    private func currentGeneration() -> UInt64 {
        latestGeneration.withLock { $0 }
    }

    private func teardownOnQueue() {
        decoder?.shutdown()
        decoder = nil
        formatContext?.close()
        formatContext = nil
        avioContext?.close()
        avioContext = nil
        videoTrack = nil
        scrubOptions = nil
        preparedURL = nil
        usingSoftwareFallback = false
        lastRenderedPTS = Int64.min
        lastRenderedTime = -.infinity
        lastRequestedTarget = -.infinity
        demuxerIsContinuous = false
        demuxerCursorTime = -.infinity
    }

    private func frameSeconds(_ frame: VideoVTBFrame, vTrack: FFmpegAssetTrack, fallback: TimeInterval) -> TimeInterval {
        if frame.timestamp != Int64.min && frame.timestamp >= 0 {
            let sec = vTrack.seconds(for: frame.timestamp)
            if sec.isFinite && sec >= 0 {
                return sec
            }
        }
        return fallback
    }

    private func decodeOnQueue(targetTime: TimeInterval, requestedSpeed: Double, generation: UInt64) -> ScrubDecodeOutcome {
        guard let ctx = formatContext,
              let vTrack = videoTrack else {
            return .unavailable
        }

        let movingBackward = (lastRequestedTarget.isFinite && targetTime < lastRequestedTarget - 0.15)
        let movingForward = !movingBackward
        lastRequestedTarget = targetTime

        var frame: VideoVTBFrame?
        let preferSequential = !usingSoftwareFallback && requestedSpeed <= 20.0

        if movingForward {
            // Strict monotonic pacing guard: wait cleanly when already ahead of requested targetTime
            if demuxerIsContinuous, lastRenderedTime.isFinite, targetTime <= demuxerCursorTime + 0.02 {
                return .unchanged(actualTime: lastRenderedTime)
            }

            // Path A: Continuous zero-flush sequential forward decoding (silky 20-30fps motion)
            let priorCursor = demuxerCursorTime
            let maxStepGap = preferSequential ? 6.5 : (usingSoftwareFallback ? 1.5 : 3.0)
            let stepBudget: TimeInterval = preferSequential ? 0.045 : 0.075
            if demuxerIsContinuous,
               priorCursor.isFinite,
               targetTime > priorCursor,
               (targetTime - priorCursor) <= maxStepGap {
                if let stepped = stepForwardWithoutSeek(
                    ctx: ctx,
                    vTrack: vTrack,
                    targetTime: targetTime,
                    generation: generation,
                    maxVideoFrames: usingSoftwareFallback ? 18 : 48,
                    timeBudget: stepBudget
                ) {
                    let steppedTime = frameSeconds(stepped, vTrack: vTrack, fallback: targetTime)
                    if steppedTime > priorCursor + 0.01 {
                        frame = stepped
                    }
                }
                if currentGeneration() != generation || isClosed {
                    demuxerIsContinuous = false
                    return .unavailable
                }
            }

            // Path B: Keyframe seek + smooth intra-GOP step-up without burst jumps
            if frame == nil {
                demuxerIsContinuous = false
                var primary = seekAndDecodeSingleFrame(
                    ctx: ctx,
                    vTrack: vTrack,
                    seekTime: targetTime,
                    flags: 1,
                    generation: generation
                )

                if let f1 = primary {
                    let t1 = frameSeconds(f1, vTrack: vTrack, fallback: targetTime)
                    let behindLast = lastRenderedTime.isFinite && (t1 <= lastRenderedTime + 0.04)
                    let stepFromCursor = lastRenderedTime.isFinite ? lastRenderedTime : t1
                    let forwardGap = targetTime - t1

                    if behindLast {
                        if preferSequential,
                           forwardGap <= 6.5,
                           targetTime > stepFromCursor,
                           let stepped = stepForwardWithoutSeek(
                               ctx: ctx,
                               vTrack: vTrack,
                               targetTime: targetTime,
                               generation: generation,
                               maxVideoFrames: 64,
                               timeBudget: 0.065
                           ) {
                            primary = stepped
                        } else if let nextIFrame = seekAndDecodeSingleFrame(
                            ctx: ctx,
                            vTrack: vTrack,
                            seekTime: max(targetTime, stepFromCursor + 0.5),
                            flags: 0,
                            generation: generation
                        ) {
                            primary = nextIFrame
                        }
                    } else if !lastRenderedTime.isFinite,
                              !usingSoftwareFallback,
                              forwardGap > 0.15,
                              forwardGap <= 6.0,
                              let stepped = stepForwardWithoutSeek(
                                  ctx: ctx,
                                  vTrack: vTrack,
                                  targetTime: targetTime,
                                  generation: generation,
                                  maxVideoFrames: 72,
                                  timeBudget: 0.09
                              ) {
                        primary = stepped
                    }
                }

                frame = primary
            }
        } else {
            // Moving backward (rewind)
            demuxerIsContinuous = false
            var primary = seekAndDecodeSingleFrame(
                ctx: ctx,
                vTrack: vTrack,
                seekTime: targetTime,
                flags: 1,
                generation: generation
            )

            if let f1 = primary,
               lastRenderedTime.isFinite,
               lastRenderedTime > 0.5,
               currentGeneration() == generation,
               !isClosed {
                let t1 = frameSeconds(f1, vTrack: vTrack, fallback: targetTime)
                let stuckOnSameGOP = (f1.timestamp != Int64.min && f1.timestamp == lastRenderedPTS)
                    || (t1 >= lastRenderedTime - 0.05)
                if stuckOnSameGOP && (lastRenderedTime - targetTime) >= 0.8 {
                    if let earlier1 = seekAndDecodeSingleFrame(
                        ctx: ctx,
                        vTrack: vTrack,
                        seekTime: max(0, lastRenderedTime - 1.2),
                        flags: 1,
                        generation: generation
                    ) {
                        let e1Time = frameSeconds(earlier1, vTrack: vTrack, fallback: targetTime)
                        if (earlier1.timestamp != lastRenderedPTS && e1Time < lastRenderedTime - 0.05) || lastRenderedTime <= 3.0 {
                            primary = earlier1
                        } else if let earlier2 = seekAndDecodeSingleFrame(
                            ctx: ctx,
                            vTrack: vTrack,
                            seekTime: max(0, lastRenderedTime - 9.0),
                            flags: 1,
                            generation: generation
                        ) {
                            primary = earlier2
                        }
                    }
                }
            }

            frame = primary
        }

        guard let decoded = frame else {
            demuxerIsContinuous = false
            return .unavailable
        }
        if currentGeneration() != generation || isClosed {
            demuxerIsContinuous = false
            return .unavailable
        }

        let actualTime = frameSeconds(decoded, vTrack: vTrack, fallback: targetTime)
        demuxerIsContinuous = true
        demuxerCursorTime = actualTime

        if decoded.timestamp != Int64.min && decoded.timestamp == lastRenderedPTS {
            return .unchanged(actualTime: actualTime)
        }
        if movingForward, lastRenderedTime.isFinite, actualTime < lastRenderedTime - 0.05 {
            demuxerCursorTime = lastRenderedTime
            return .unchanged(actualTime: lastRenderedTime)
        }
        if movingBackward, lastRenderedTime.isFinite, actualTime > lastRenderedTime + 0.05 {
            demuxerCursorTime = lastRenderedTime
            return .unchanged(actualTime: lastRenderedTime)
        }

        if let cvBuffer = decoded.pixelBuffer.cvPixelBuffer {
            lastRenderedPTS = decoded.timestamp
            lastRenderedTime = actualTime
            return .frame(ScrubPreviewFrame(pixelBuffer: cvBuffer, rotation: vTrack.rotation, actualTime: actualTime))
        }

        guard let cgImage = renderPreviewCGImage(from: decoded, rotation: vTrack.rotation) else {
            return .unavailable
        }

        lastRenderedPTS = decoded.timestamp
        lastRenderedTime = actualTime
        return .frame(ScrubPreviewFrame(cgImage: cgImage, actualTime: actualTime))
    }

    private func decodeVideoPacket(
        _ corePkt: UnsafeMutablePointer<AVPacket>,
        vTrack: FFmpegAssetTrack,
        consecutiveErrors: inout Int
    ) -> VideoVTBFrame? {
        guard var activeDecoder = decoder else { return nil }
        var localFrame: VideoVTBFrame?
        var localError = false

        activeDecoder.decodeFrame(from: corePkt) { result in
            switch result {
            case .success(let meFrame):
                if let vFrame = meFrame as? VideoVTBFrame {
                    localFrame = vFrame
                }
            case .failure:
                localError = true
            }
        }

        if let localFrame {
            consecutiveErrors = 0
            return localFrame
        }

        if localError {
            consecutiveErrors += 1
            if consecutiveErrors >= 2 && !usingSoftwareFallback, let opts = scrubOptions {
                activeDecoder.shutdown()
                let swDecoder = FFmpegDecode(assetTrack: vTrack, options: opts)
                self.decoder = swDecoder
                self.usingSoftwareFallback = true
                activeDecoder = swDecoder

                var swFrame: VideoVTBFrame?
                activeDecoder.decodeFrame(from: corePkt) { result in
                    if case .success(let meFrame) = result, let vFrame = meFrame as? VideoVTBFrame {
                        swFrame = vFrame
                    }
                }
                return swFrame
            }
        }
        return nil
    }

    private func stepForwardWithoutSeek(
        ctx: FormatContext,
        vTrack: FFmpegAssetTrack,
        targetTime: TimeInterval,
        generation: UInt64,
        maxVideoFrames: Int,
        timeBudget: TimeInterval = 0.05
    ) -> VideoVTBFrame? {
        guard decoder != nil else { return nil }

        var totalPackets = 0
        var videoFramesDecoded = 0
        var consecutiveErrors = 0
        var bestFrame: VideoVTBFrame?
        var bestTime: TimeInterval = -.infinity

        let deadline = CFAbsoluteTimeGetCurrent() + timeBudget
        while totalPackets < 260 && videoFramesDecoded < maxVideoFrames && CFAbsoluteTimeGetCurrent() < deadline {
            if currentGeneration() != generation || isClosed { return nil }
            guard let packet = ctx.read() else { break }
            totalPackets += 1

            guard let pktTrack = packet.assetTrack,
                  pktTrack.trackID == vTrack.trackID,
                  let corePkt = packet.corePacket else {
                continue
            }

            if let decoded = decodeVideoPacket(corePkt, vTrack: vTrack, consecutiveErrors: &consecutiveErrors) {
                videoFramesDecoded += 1
                let sec = frameSeconds(decoded, vTrack: vTrack, fallback: targetTime)
                if !bestTime.isFinite || sec >= bestTime {
                    bestFrame = decoded
                    bestTime = sec
                }
                if sec >= targetTime - 0.03 {
                    break
                }
            }
        }

        return bestFrame
    }

    private func seekAndDecodeSingleFrame(
        ctx: FormatContext,
        vTrack: FFmpegAssetTrack,
        seekTime: TimeInterval,
        flags: Int32,
        generation: UInt64
    ) -> VideoVTBFrame? {
        guard let activeDecoder = decoder else { return nil }

        let seekResult = ctx.performSeek(time: max(0, seekTime), flags: flags, streamIndex: vTrack.trackID)
        if seekResult < 0 {
            let fallbackSeek = ctx.performSeek(time: max(0, seekTime), flags: flags, streamIndex: -1)
            if fallbackSeek < 0 {
                return nil
            }
        }
        activeDecoder.doFlushCodec()

        if currentGeneration() != generation || isClosed { return nil }

        var seenKeyframe = false
        var totalPackets = 0
        var videoPacketsFed = 0
        var consecutiveErrors = 0
        var decodedFrame: VideoVTBFrame?

        while totalPackets < 240 && videoPacketsFed < 32 && decodedFrame == nil {
            if currentGeneration() != generation || isClosed { return nil }
            guard let packet = ctx.read() else { break }
            totalPackets += 1

            guard let pktTrack = packet.assetTrack,
                  pktTrack.trackID == vTrack.trackID,
                  let corePkt = packet.corePacket else {
                continue
            }

            if !seenKeyframe {
                if corePkt.pointee.isKeyFrame {
                    seenKeyframe = true
                } else if totalPackets < 80 {
                    continue
                } else {
                    seenKeyframe = true
                }
            }

            videoPacketsFed += 1
            if let decoded = decodeVideoPacket(corePkt, vTrack: vTrack, consecutiveErrors: &consecutiveErrors) {
                decodedFrame = decoded
                break
            }
        }

        return decodedFrame
    }

    private func renderPreviewCGImage(from frame: VideoVTBFrame, rotation: UInt16) -> CGImage? {
        if let cvBuffer = frame.pixelBuffer.cvPixelBuffer {
            var ciImage = CIImage(cvPixelBuffer: cvBuffer)
            if rotation == 90 {
                ciImage = ciImage.oriented(.right)
            } else if rotation == 180 {
                ciImage = ciImage.oriented(.down)
            } else if rotation == 270 {
                ciImage = ciImage.oriented(.left)
            }

            let extent = ciImage.extent
            guard extent.width > 0, extent.height > 0 else { return nil }

            if extent.width > maxPreviewWidth {
                let scale = maxPreviewWidth / extent.width
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }

            let targetRect = ciImage.extent.integral
            return ciContext.createCGImage(
                ciImage,
                from: targetRect,
                format: .RGBA8,
                colorSpace: srgbColorSpace
            )
        }

        guard let rawCG = frame.pixelBuffer.cgImage() else { return nil }
        if CGFloat(rawCG.width) <= maxPreviewWidth && rotation == 0 {
            return rawCG
        }
        var ciImage = CIImage(cgImage: rawCG)
        if rotation == 90 {
            ciImage = ciImage.oriented(.right)
        } else if rotation == 180 {
            ciImage = ciImage.oriented(.down)
        } else if rotation == 270 {
            ciImage = ciImage.oriented(.left)
        }
        let extent = ciImage.extent
        if extent.width > maxPreviewWidth {
            let scale = maxPreviewWidth / extent.width
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ciContext.createCGImage(
            ciImage,
            from: ciImage.extent.integral,
            format: .RGBA8,
            colorSpace: srgbColorSpace
        )
    }
}

#else
/// Simulator fallback backed by `AVAssetImageGenerator` (Swift 6 strict-concurrency & async safe).
public final class LiveKeyframeScrubEngine: @unchecked Sendable {
    private final class GeneratorBox: @unchecked Sendable {
        let generator: AVAssetImageGenerator
        init(_ generator: AVAssetImageGenerator) { self.generator = generator }
    }

    private let boxLock = OSAllocatedUnfairLock<GeneratorBox?>(initialState: nil)

    public init() {}

    public var isReady: Bool {
        boxLock.withLock { $0 != nil }
    }

    public func resetTracking() {}

    public func prepare(url: URL, directReader: (any SynchronousRandomAccessReader)? = nil) async {
        directReader?.closeSync()
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 540)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let box = GeneratorBox(gen)
        boxLock.withLock { $0 = box }
    }

    public func decodePreviewFrame(at targetTime: TimeInterval, requestedSpeed: Double = 8.0) async -> ScrubDecodeOutcome {
        _ = requestedSpeed
        guard let box = boxLock.withLock({ $0 }) else { return .unavailable }
        let cmTime = CMTime(seconds: max(0, targetTime), preferredTimescale: 600)
        do {
            let (image, actual) = try await box.generator.image(at: cmTime)
            let sec = actual.isNumeric ? actual.seconds : targetTime
            return .frame(ScrubPreviewFrame(cgImage: image, actualTime: sec))
        } catch {
            return .unavailable
        }
    }

    public func close() async {
        let box = boxLock.withLock { current -> GeneratorBox? in
            let saved = current
            current = nil
            return saved
        }
        box?.generator.cancelAllCGImageGeneration()
    }
}
#endif
