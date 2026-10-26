import Foundation

// iOS 15 移植说明：
// 原实现 `import ActivityKit` + `Activity<TiebaLiveActivityKitAttributes>`（iOS 16.1 起）。
// 部署底线降到 15 后，主二进制里会带一条到 ActivityKit 的 LC_LOAD_DYLIB，
// iOS 15 的 dyld 找不到这个框架会直接拒绝启动。这里保留完全相同的调用面
// （TiebaLiveActivityManager / Payload / Alert / DismissalPolicy），
// 但一律空转：areActivitiesEnabled() 恒 false，start() 抛 .disabled。
// 想恢复：取回上游实现，并把 minimum_os_version 改回 16.1 以上。

/// start 的完整载荷投影：模块侧 AsyncFunction 收到的是自由字典 [String: Any]
/// （非 Sendable），而管理器在主 actor——跨域前先在调用队列把字典归一成值类型，
/// 字典一个字段都不进主 actor（否则 Swift 6 判 sending 'state'）。
struct TiebaLiveActivityPayload: Sendable {
  let name: String
  let extra: [String: String]?
  let state: TiebaLiveActivityKitAttributes.ContentState

  init(raw: [String: Any]) {
    self.name = raw["name"] as? String ?? "TiebaLiteSign"
    self.extra = raw["extra"] as? [String: String]
    self.state = TiebaLiveActivityKitAttributes.ContentState(raw: raw)
  }
}

/// 结束时的锁屏/灵动岛通知（值类型：标题 + 正文）。
struct TiebaLiveActivityAlert: Sendable {
  let title: String
  let body: String
}

/// Live Activity 结束时的撤除策略。字符串在类型上无处可查，这里封闭成枚举。
enum TiebaLiveActivityDismissalPolicy: Sendable {
  /// 立刻从锁屏与通知中心撤掉（中断残留清理用）。
  case immediate
  /// 系统默认。
  case `default`
}

@MainActor
final class TiebaLiveActivityManager {
  static let shared = TiebaLiveActivityManager()

  private init() {}

  nonisolated static func areActivitiesEnabled() -> Bool {
    false
  }

  func start(payload: TiebaLiveActivityPayload) throws -> String {
    throw TiebaLiveActivityError.disabled
  }

  func update(activityId: String, state: TiebaLiveActivityKitAttributes.ContentState) async {
  }

  func end(
    activityId: String,
    state: TiebaLiveActivityKitAttributes.ContentState,
    dismissalPolicy: TiebaLiveActivityDismissalPolicy,
    alert: TiebaLiveActivityAlert? = nil
  ) async {
  }

  /// 结束「签到」类中断残留的活动（iOS 15 上无活动可结束）。
  func endAllInterrupted() async {
  }

  func endAll(
    state: TiebaLiveActivityKitAttributes.ContentState,
    dismissalPolicy: TiebaLiveActivityDismissalPolicy
  ) async {
  }
}

enum TiebaLiveActivityError: LocalizedError {
  case disabled

  var errorDescription: String? {
    switch self {
    case .disabled:
      return "Live Activities are not available in this iOS 15 build."
    }
  }
}
