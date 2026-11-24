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
/// Dedicated hardware live-frame scrub engine built directly on KSPlayer's `FormatContext`
/// and synchronous `VideoToolboxDecode` (auto-falling back to `FFmpegDecode` for AV1/VP9/Hi10P).
///
/// Smoothness optimizations:
/// - Runs exclusively on a `.userInteractive` serial `DispatchQueue` (never blocks Swift Concurrency).
/// - Downscales decoded 4K/HDR frames on GPU via `CIContext` to max 960px wide (~2MB RGBA, <1.2ms)
///   with automatic HDR10/HLG tone-mapping.
/// - Atomic generation counter immediately preempts superseded requests mid-packet-loop.
/// - Smart reverse-GOP keyframe stepping prevents reverse scrubbing from sticking inside 4–6s GOPs,
///   and duplicate-PTS detection skips redundant GPU renders.
public final class LiveKeyframeScrubEngine: @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "local.personal.auratv.live-scrub", qos: .userInteractive)
    private let latestGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    // State exclusively accessed on `workQueue`
    private var preparedURL: URL?
    private var formatContext: FormatContext?
    private var videoTrack: FFmpegAssetTrack?
    private var decoder: (any DecodeProtocol)?
    private var scrubOptions: KSOptions?
    private var usingSoftwareFallback: Bool = false
    private var isClosed: Bool = false

    private var lastRenderedPTS: Int64 = Int64.min
    private var lastRenderedTime: TimeInterval = -.infinity
    private var lastRequestedTarget: TimeInterval = -.infinity

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
        decoder = nil
        formatContext = nil
        videoTrack = nil
        scrubOptions = nil
        if d != nil || ctx != nil {
            workQueue.async {
                d?.shutdown()
                ctx?.close()
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
        }
    }

    public func prepare(url: URL) async {
        let alreadyPrepared: Bool = await withCheckedContinuation { cont in
            workQueue.async { [self] in
                cont.resume(returning: !isClosed && preparedURL == url && formatContext != nil && decoder != nil)
            }
        }
        if alreadyPrepared { return }

        let opts = KSOptions()
        opts.seekInterruptIO = true
        opts.seekFlags = 1 // AVSEEK_FLAG_BACKWARD
        opts.isAccurateSeek = false
        opts.autoSelectEmbedSubtitle = false
        opts.subtitleDisable = true
        opts.formatContextOptions["probesize"] = 2 * 1024 * 1024
        opts.formatContextOptions["analyzeduration"] = 1_000_000
        opts.decoderOptions["threads"] = "1"

        guard let ctx = try? await FormatContext(url: url, options: opts) else {
            return
        }

        guard let vTrack = ctx.assetTracks.first(where: { $0.mediaType == .video && !$0.isImage && !$0.isStillImage })
            ?? ctx.assetTracks.first(where: { $0.mediaType == .video }) else {
            ctx.close()
            return
        }

        for track in ctx.assetTracks {
            track.isEnabled = (track.trackID == vTrack.trackID)
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

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            workQueue.async { [self] in
                if isClosed {
                    createdDecoder.shutdown()
                    ctx.close()
                    cont.resume()
                    return
                }
                teardownOnQueue()
                preparedURL = url
                formatContext = ctx
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
        videoTrack = nil
        scrubOptions = nil
        preparedURL = nil
        usingSoftwareFallback = false
        lastRenderedPTS = Int64.min
        lastRenderedTime = -.infinity
        lastRequestedTarget = -.infinity
    }

    private func decodeOnQueue(targetTime: TimeInterval, generation: UInt64) -> ScrubDecodeOutcome {
        guard let ctx = formatContext,
              let vTrack = videoTrack else {
            return .unavailable
        }

        let movingBackward = (lastRequestedTarget.isFinite && targetTime < lastRequestedTarget - 0.15)
        lastRequestedTarget = targetTime

        var frame = seekAndDecodeSingleFrame(ctx: ctx, vTrack: vTrack, seekTime: targetTime, generation: generation)

        // Reverse-GOP smoothing: when rewinding and AVSEEK_FLAG_BACKWARD lands on the exact same keyframe
        // already on screen, nudge back past that keyframe once so reverse frames glide smoothly!
        if movingBackward,
           let f = frame,
           f.timestamp != Int64.min,
           f.timestamp == lastRenderedPTS,
           lastRenderedTime.isFinite,
           lastRenderedTime > 1.0,
           currentGeneration() == generation,
           !isClosed {
            let earlierTarget = max(0, lastRenderedTime - 1.2)
            if let earlierFrame = seekAndDecodeSingleFrame(ctx: ctx, vTrack: vTrack, seekTime: earlierTarget, generation: generation) {
                frame = earlierFrame
            }
        }

        guard let decoded = frame else { return .unavailable }
        if currentGeneration() != generation || isClosed { return .unavailable }

        let actualTime: TimeInterval
        if decoded.timestamp != Int64.min && decoded.timestamp >= 0 {
            let sec = vTrack.seconds(for: decoded.timestamp)
            actualTime = (sec.isFinite && sec >= 0) ? sec : targetTime
        } else {
            actualTime = targetTime
        }

        // Duplicate-PTS fast skip: avoids redundant GPU render when still inside same GOP
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

    private func seekAndDecodeSingleFrame(
        ctx: FormatContext,
        vTrack: FFmpegAssetTrack,
        seekTime: TimeInterval,
        generation: UInt64
    ) -> VideoVTBFrame? {
        guard var activeDecoder = decoder else { return nil }

        let seekResult = ctx.performSeek(time: seekTime, flags: 1, streamIndex: vTrack.trackID)
        if seekResult < 0 {
            let fallbackSeek = ctx.performSeek(time: seekTime, flags: 1, streamIndex: -1)
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

        while totalPackets < 160 && videoPacketsFed < 12 && decodedFrame == nil {
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
                decodedFrame = localFrame
                break
            }

            if localError {
                consecutiveErrors += 1
                if consecutiveErrors >= 2 && !usingSoftwareFallback, let opts = scrubOptions {
                    activeDecoder.shutdown()
                    let swDecoder = FFmpegDecode(assetTrack: vTrack, options: opts)
                    self.decoder = swDecoder
                    self.usingSoftwareFallback = true
                    activeDecoder = swDecoder

                    activeDecoder.decodeFrame(from: corePkt) { result in
                        if case .success(let meFrame) = result, let vFrame = meFrame as? VideoVTBFrame {
                            decodedFrame = vFrame
                        }
                    }
                }
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

    public func prepare(url: URL) async {
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
