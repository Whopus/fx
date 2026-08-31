import Combine
import Foundation

/// The work being represented by the island. Add new product workflows here
/// without teaching the avatar how those workflows operate.
enum CuratezTaskKind: String, Equatable, Sendable {
    case generic
    case captureText
    case captureLink
    case captureVideo
    case captureImage
    case browserSnapshot
}

/// A task's lifecycle. The avatar mapping below is the single place where a
/// product state becomes a facial expression and a motion style.
enum CuratezTaskStatus: String, Equatable, Sendable {
    case idle
    case ready
    case processing
    case succeeded
    case needsAttention
    case failed
    case paused
}

struct CuratezIslandActivity: Equatable, Sendable {
    var task: CuratezTaskKind
    var status: CuratezTaskStatus

    static let idle = CuratezIslandActivity(task: .generic, status: .idle)
    static let captureReady = CuratezIslandActivity(task: .generic, status: .ready)
}

enum BloubExpression: Equatable, Sendable {
    case neutral
    case attentive
    case excited
    case curious
    case shy
    case focused
    case pleased
    case surprised
    case concerned
    case sleeping
}

enum BloubMotion: Equatable, Sendable {
    case breathe
    case think
    case celebrate
    case pulse
    case shake
    case doze
}

struct BloubPresentation: Equatable, Sendable {
    let expression: BloubExpression
    let motion: BloubMotion
    let showsNotificationDot: Bool
    let accessibilityLabel: String
}

extension CuratezIslandActivity {
    var bloubPresentation: BloubPresentation {
        switch status {
        case .idle:
            BloubPresentation(
                expression: .neutral,
                motion: .breathe,
                showsNotificationDot: false,
                accessibilityLabel: "Curatez 空闲"
            )
        case .ready:
            BloubPresentation(
                expression: .attentive,
                motion: .breathe,
                showsNotificationDot: false,
                accessibilityLabel: "Curatez 正在等待采集"
            )
        case .processing:
            BloubPresentation(
                expression: .focused,
                motion: .think,
                showsNotificationDot: false,
                accessibilityLabel: "Curatez 正在处理\(task.accessibilityName)"
            )
        case .succeeded:
            BloubPresentation(
                expression: .pleased,
                motion: .celebrate,
                showsNotificationDot: false,
                accessibilityLabel: "\(task.accessibilityName)已完成"
            )
        case .needsAttention:
            BloubPresentation(
                expression: .surprised,
                motion: .pulse,
                showsNotificationDot: true,
                accessibilityLabel: "\(task.accessibilityName)等待确认"
            )
        case .failed:
            BloubPresentation(
                expression: .concerned,
                motion: .shake,
                showsNotificationDot: false,
                accessibilityLabel: "\(task.accessibilityName)失败"
            )
        case .paused:
            BloubPresentation(
                expression: .sleeping,
                motion: .doze,
                showsNotificationDot: false,
                accessibilityLabel: "Curatez 已暂停"
            )
        }
    }
}

private extension CuratezTaskKind {
    var accessibilityName: String {
        switch self {
        case .generic: "任务"
        case .captureText: "文本采集"
        case .captureLink: "链接采集"
        case .captureVideo: "视频采集"
        case .captureImage: "图片采集"
        case .browserSnapshot: "页面快照"
        }
    }
}

@MainActor
final class CuratezIslandActivityController: ObservableObject {
    @Published private(set) var activity: CuratezIslandActivity = .idle
    @Published private(set) var isIslandVisible = false

    private var resetTask: Task<Void, Never>?

    func setIslandVisible(_ isVisible: Bool) {
        guard isIslandVisible != isVisible else { return }
        isIslandVisible = isVisible
    }

    func set(_ activity: CuratezIslandActivity) {
        resetTask?.cancel()
        resetTask = nil
        self.activity = activity
    }

    /// Shows a short-lived result without letting an older delayed reset win
    /// over a newer task update.
    func showTransient(
        _ activity: CuratezIslandActivity,
        revertingTo fallback: CuratezIslandActivity,
        after delay: Duration = .seconds(1.8)
    ) {
        resetTask?.cancel()
        self.activity = activity
        resetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.activity = fallback
            self?.resetTask = nil
        }
    }
}
