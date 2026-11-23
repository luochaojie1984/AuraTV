import Foundation
import Combine

/// 仿安卓 MX Player 的三段非线性加速长按跳转控制器。
/// 只产出「目标时间」，真正的预览帧解码由播放引擎按 Latest-Wins 执行。
@MainActor
public final class MXScrubController: ObservableObject {
    @Published public private(set) var isScrubbing: Bool = false
    @Published public private(set) var targetTime: TimeInterval = 0
    @Published public private(set) var deltaSeconds: TimeInterval = 0

    private var pressStartTime: Date?
    private var scrubTask: Task<Void, Never>?
    private var previewDecodeTask: Task<Void, Never>?
    private let throttleIntervalNs: UInt64 = 130_000_000 // ~7.7 fps 实时刷新主画面

    public init() {}

    /// 仿安卓 MX Player 三段非线性加速曲线
    private func secondsPerTick(elapsedHold: TimeInterval) -> TimeInterval {
        switch elapsedHold {
        case ..<1.5: return 2.0    // 约 15s/秒（精细找镜头）
        case ..<4.0: return 6.0    // 约 45s/秒（中速巡航）
        default:     return 16.0   // 约 120s/秒（高速冲刺）
        }
    }

    public func beginHold(
        direction: ScrubDirection,
        currentPlaybackTime: TimeInterval,
        duration: TimeInterval,
        onPreviewFrame: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        isScrubbing = true
        targetTime = currentPlaybackTime
        deltaSeconds = 0
        pressStartTime = Date()

        scrubTask?.cancel()
        scrubTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let holdElapsed = Date().timeIntervalSince(self.pressStartTime ?? Date())
                let step = self.secondsPerTick(elapsedHold: holdElapsed) * Double(direction.rawValue)
                self.targetTime = min(max(0, self.targetTime + step), max(0, duration))
                self.deltaSeconds = self.targetTime - currentPlaybackTime

                // Latest-Wins：来新目标立刻取消未完成的旧预览帧解码，防 SMB/WebDAV 堆积
                let requestTime = self.targetTime
                self.previewDecodeTask?.cancel()
                self.previewDecodeTask = Task {
                    await onPreviewFrame(requestTime)
                }

                try? await Task.sleep(nanoseconds: self.throttleIntervalNs)
            }
        }
    }

    public func endHold(onCommit: @escaping (TimeInterval) async -> Void) {
        scrubTask?.cancel()
        scrubTask = nil
        previewDecodeTask?.cancel()
        previewDecodeTask = nil
        let finalTarget = targetTime
        isScrubbing = false
        Task {
            await onCommit(finalTarget)
        }
    }

    public func cancelHold() {
        scrubTask?.cancel()
        scrubTask = nil
        previewDecodeTask?.cancel()
        previewDecodeTask = nil
        isScrubbing = false
        deltaSeconds = 0
    }
}
