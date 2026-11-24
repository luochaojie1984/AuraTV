import Foundation
import CoreGraphics
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

/// A decoded video preview frame returned by `LiveKeyframeScrubEngine`.
public struct ScrubPreviewFrame: Sendable {
    public let cgImage: CGImage
    public let actualTime: TimeInterval

    public init(cgImage: CGImage, actualTime: TimeInterval) {
        self.cgImage = cgImage
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

/// Zero-overhead CoreAnimation layer presenter for full-screen live scrub frames.
/// Swaps `CALayer.contents` directly with animations disabled (< 0.1ms) without triggering SwiftUI
/// view-tree diffing on `PlayerScreenView` at 25–60 fps!
@MainActor
public final class ScrubFramePresenter {
    fileprivate weak var canvasView: ScrubCanvasView?
    private var pendingImage: CGImage?
    public private(set) var isVisible: Bool = false

    public init() {}

    fileprivate func attach(_ view: ScrubCanvasView) {
        canvasView = view
        if let pendingImage, isVisible {
            apply(pendingImage, to: view)
        } else {
            view.isHidden = !isVisible
        }
    }

    public func present(_ cgImage: CGImage) {
        pendingImage = cgImage
        isVisible = true
        if let view = canvasView {
            apply(cgImage, to: view)
        }
    }

    public func clear() {
        pendingImage = nil
        isVisible = false
        guard let view = canvasView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.contents = nil
        view.isHidden = true
        CATransaction.commit()
    }

    private func apply(_ image: CGImage, to view: ScrubCanvasView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.contents = image
        view.isHidden = false
        CATransaction.commit()
    }
}

final class ScrubCanvasView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        isHidden = true
        layer.contentsGravity = .resizeAspect
        layer.masksToBounds = true
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    private let microWindowBytes: Int = 384 * 1024
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

    override func read(buffer buf: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let buf, size > 0, cursor < totalSize else {
            return Self.averrorEOF
        }

        let want = Int(min(Int64(size), totalSize - cursor))
        guard want > 0 else { return Self.averrorEOF }

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

        // 3. Sliding 384 KB micro-buffer hit
        if microStart >= 0,
           cursor >= microStart,
           (cursor + Int64(want)) <= (microStart + Int64(microData.count)) {
            Self.copySlice(from: microData, localStart: Int(cursor - microStart), count: want, into: buf)
            cursor += Int64(want)
            return Int32(want)
        }

        // 4. Single SMB pread window fetch
        let fetchLen = Int(min(Int64(max(want, microWindowBytes)), totalSize - cursor))
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

    private let maxPreviewWidth: CGFloat = 960

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
        opts.decoderOptions["threads"] = "1"

        var openedCtx: FormatContext?
        var openedAVIO: ScrubAVIOContext?

        if let directReader {
            let avio = ScrubAVIOContext(reader: directReader)
            if let directCtx = try? await FormatContext(io: .right(avio), options: opts),
               directCtx.assetTracks.contains(where: { $0.mediaType == .video }) {
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

    public func decodePreviewFrame(at targetTime: TimeInterval) async -> ScrubDecodeOutcome {
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
                let outcome = decodeOnQueue(targetTime: max(0, targetTime), generation: myGen)
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

    private func decodeOnQueue(targetTime: TimeInterval, generation: UInt64) -> ScrubDecodeOutcome {
        guard let ctx = formatContext,
              let vTrack = videoTrack else {
            return .unavailable
        }

        let movingBackward = (lastRequestedTarget.isFinite && targetTime < lastRequestedTarget - 0.15)
        let movingForward = !movingBackward
        lastRequestedTarget = targetTime

        var frame: VideoVTBFrame?

        // Path A: Fluid continuous forward stepping without seeking or flushing VideoToolbox (< 3-8ms per frame).
        let priorCursor = demuxerCursorTime
        if movingForward,
           demuxerIsContinuous,
           priorCursor.isFinite,
           targetTime > priorCursor,
           (targetTime - priorCursor) <= 2.2 {
            if let stepped = stepForwardWithoutSeek(
                ctx: ctx,
                vTrack: vTrack,
                targetTime: targetTime,
                generation: generation,
                maxVideoFrames: 36
            ) {
                let steppedTime = frameSeconds(stepped, vTrack: vTrack, fallback: targetTime)
                if steppedTime >= priorCursor && steppedTime >= targetTime - 1.2 {
                    frame = stepped
                }
            }
            if currentGeneration() != generation || isClosed {
                demuxerIsContinuous = false
                return .unavailable
            }
        }

        // Path B: Keyframe seek + anti-GOP-freeze resolution when jumping forward > 2.2s, rewinding, or starting hold.
        if frame == nil {
            demuxerIsContinuous = false
            var primary = seekAndDecodeSingleFrame(
                ctx: ctx,
                vTrack: vTrack,
                seekTime: targetTime,
                flags: 1,
                generation: generation
            )

            if movingForward, let f1 = primary {
                let t1 = frameSeconds(f1, vTrack: vTrack, fallback: targetTime)
                let gap = targetTime - t1
                let samePTS = (f1.timestamp != Int64.min && f1.timestamp == lastRenderedPTS)
                let initialSnap = (!lastRenderedTime.isFinite && gap > 0.25 && gap <= 2.5)

                if (samePTS && gap <= 2.5) || initialSnap {
                    // Advance smoothly from the GOP keyframe up toward targetTime instead of freezing or jumping back.
                    if let stepped = stepForwardWithoutSeek(
                        ctx: ctx,
                        vTrack: vTrack,
                        targetTime: targetTime,
                        generation: generation,
                        maxVideoFrames: 48
                    ) {
                        primary = stepped
                    }
                } else if samePTS && gap > 2.5 {
                    // Long GOP at high speed: jump forward to the next I-frame with flags=0 so visuals always advance.
                    if let nextIFrame = seekAndDecodeSingleFrame(
                        ctx: ctx,
                        vTrack: vTrack,
                        seekTime: max(targetTime, t1 + 0.5),
                        flags: 0,
                        generation: generation
                    ) {
                        primary = nextIFrame
                    }
                }
            } else if movingBackward,
                      let f1 = primary,
                      f1.timestamp != Int64.min,
                      f1.timestamp == lastRenderedPTS,
                      lastRenderedTime.isFinite,
                      lastRenderedTime > 0.4,
                      currentGeneration() == generation,
                      !isClosed {
                if let earlier1 = seekAndDecodeSingleFrame(
                    ctx: ctx,
                    vTrack: vTrack,
                    seekTime: max(0, lastRenderedTime - 0.6),
                    flags: 1,
                    generation: generation
                ) {
                    if earlier1.timestamp != lastRenderedPTS || lastRenderedTime <= 2.5 {
                        primary = earlier1
                    } else if let earlier2 = seekAndDecodeSingleFrame(
                        ctx: ctx,
                        vTrack: vTrack,
                        seekTime: max(0, lastRenderedTime - 2.8),
                        flags: 1,
                        generation: generation
                    ) {
                        primary = earlier2
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
        maxVideoFrames: Int
    ) -> VideoVTBFrame? {
        guard decoder != nil else { return nil }

        var totalPackets = 0
        var videoFramesDecoded = 0
        var consecutiveErrors = 0
        var bestFrame: VideoVTBFrame?
        var bestTime: TimeInterval = -.infinity

        while totalPackets < 220 && videoFramesDecoded < maxVideoFrames {
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

        while totalPackets < 160 && videoPacketsFed < 16 && decodedFrame == nil {
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

    public func decodePreviewFrame(at targetTime: TimeInterval) async -> ScrubDecodeOutcome {
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
