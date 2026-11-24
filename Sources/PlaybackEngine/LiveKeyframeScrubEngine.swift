import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import CoreMedia
import AVFoundation
import os

#if canImport(KSPlayer) && !targetEnvironment(simulator)
import KSPlayer
#if canImport(Libavcodec)
import Libavcodec
#endif
#endif

/// A decoded video preview frame returned by `LiveKeyframeScrubEngine`.
/// Stores a downscaled `CGImage` (Sendable under Swift 6) for zero-hitch full-screen display.
public struct ScrubPreviewFrame: Sendable {
    public let cgImage: CGImage
    public let actualTime: TimeInterval

    public init(cgImage: CGImage, actualTime: TimeInterval) {
        self.cgImage = cgImage
        self.actualTime = actualTime
    }
}

#if canImport(KSPlayer) && !targetEnvironment(simulator)
/// Dedicated hardware live-frame scrub engine built directly on KSPlayer's `FormatContext`
/// and synchronous `VideoToolboxDecode` (with automatic `FFmpegDecode` fallback for AV1/VP9/Hi10P).
///
/// Architecture:
/// - Opens a lightweight, video-only `FormatContext` against the same `LocalHTTPStreamProxy` URL,
///   so pinned Head/Tail 4MB index blocks (`Cues` / `moov`) hit RAM in <1ms with zero extra SMB open cost.
/// - Runs all blocking FFmpeg seek/read/decode work on a dedicated `.userInteractive` serial `DispatchQueue`
///   so Swift Concurrency's cooperative thread pool is NEVER starved.
/// - Uses an atomic generation counter so superseded scrub requests bail out immediately mid-loop.
/// - Downscales decoded 4K/HDR `CVPixelBuffer` frames on GPU via `CIContext` to max 1280px wide,
///   automatically tone-mapping HDR10/HLG/10-bit frames while keeping memory under ~4MB per frame.
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

    private lazy var ciContext: CIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    private let maxPreviewWidth: CGFloat = 1280

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

    /// Pre-opens the lightweight video-only demuxer & synchronous VideoToolbox decoder in background
    /// right after playback starts, so the VERY FIRST fast-forward click renders a live frame in ~20ms.
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
        // Fast header probe (hits pinned Head 4MB in RAM on LocalHTTPStreamProxy)
        opts.formatContextOptions["probesize"] = 2 * 1024 * 1024
        opts.formatContextOptions["analyzeduration"] = 1_000_000
        // Single-thread software decode fallback eliminates FFmpeg frame-threading queue delay
        opts.decoderOptions["threads"] = "1"

        guard let ctx = try? await FormatContext(url: url, options: opts) else {
            return
        }

        // Pick primary video track, skipping embedded JPEG/PNG cover-art streams
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

    /// Decodes the nearest keyframe at `targetTime` and returns a GPU-downscaled `CGImage`.
    /// Returns `nil` if superseded by a newer request, cancelled, or not yet ready.
    public func decodePreviewFrame(at targetTime: TimeInterval) async -> ScrubPreviewFrame? {
        let myGen = latestGeneration.withLock { gen -> UInt64 in
            gen &+= 1
            return gen
        }

        return await withCheckedContinuation { cont in
            workQueue.async { [self] in
                if isClosed || currentGeneration() != myGen {
                    cont.resume(returning: nil)
                    return
                }
                let frame = decodeOnQueue(targetTime: max(0, targetTime), generation: myGen)
                cont.resume(returning: frame)
            }
        }
    }

    /// Cancels any in-flight packet loop and releases FFmpeg/VideoToolbox resources cleanly.
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
    }

    private func decodeOnQueue(targetTime: TimeInterval, generation: UInt64) -> ScrubPreviewFrame? {
        guard let ctx = formatContext,
              let vTrack = videoTrack,
              var activeDecoder = decoder else {
            return nil
        }

        // 1. Seek directly to nearest backward I-frame on video stream
        let seekResult = ctx.performSeek(time: targetTime, flags: 1, streamIndex: vTrack.trackID)
        if seekResult < 0 {
            let fallbackSeek = ctx.performSeek(time: targetTime, flags: 1, streamIndex: -1)
            if fallbackSeek < 0 {
                return nil
            }
        }
        activeDecoder.doFlushCodec()

        if currentGeneration() != generation || isClosed { return nil }

        // 2. Read video keyframe packet(s) and synchronously decode first displayable frame
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
                    // Container lacks keyframe flags (some raw TS streams) -> decode anyway
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
                // If hardware VideoToolbox rejects this profile (e.g., H.264 Hi10P), auto-fallback to FFmpegDecode
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

        guard let frame = decodedFrame else { return nil }
        if currentGeneration() != generation || isClosed { return nil }

        guard let cgImage = renderPreviewCGImage(from: frame, rotation: vTrack.rotation) else {
            return nil
        }

        let actualTime: TimeInterval
        if frame.timestamp != Int64.min && frame.timestamp >= 0 {
            let sec = vTrack.seconds(for: frame.timestamp)
            actualTime = (sec.isFinite && sec >= 0) ? sec : targetTime
        } else {
            actualTime = targetTime
        }

        return ScrubPreviewFrame(cgImage: cgImage, actualTime: actualTime)
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

        // Software pixel buffer fallback (planar YUV without CVPixelBuffer)
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
/// Simulator fallback backed by `AVAssetImageGenerator` with infinite keyframe tolerance.
public final class LiveKeyframeScrubEngine: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AVAssetImageGenerator?>(initialState: nil)

    public init() {}

    public var isReady: Bool {
        lock.withLock { $0 != nil }
    }

    public func prepare(url: URL) async {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        lock.withLock { $0 = generator }
    }

    public func decodePreviewFrame(at targetTime: TimeInterval) async -> ScrubPreviewFrame? {
        guard let generator = lock.withLock({ $0 }) else { return nil }
        let cmTime = CMTime(seconds: max(0, targetTime), preferredTimescale: 600)
        do {
            let (image, actual) = try await generator.image(at: cmTime)
            let sec = actual.isNumeric ? actual.seconds : targetTime
            return ScrubPreviewFrame(cgImage: image, actualTime: sec)
        } catch {
            return nil
        }
    }

    public func close() async {
        let generator = lock.withLock { current -> AVAssetImageGenerator? in
            let saved = current
            current = nil
            return saved
        }
        generator?.cancelAllCGImageGeneration()
    }
}
#endif
