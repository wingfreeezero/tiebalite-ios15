import Foundation
import UserNotifications

/// Baidu Tieba returns error_code 1101 for a forum that is already signed
/// today. Both /c/c/forum/msign and /c/c/forum/sign use it. It is a
/// successful state, never a failure.
private let alreadySignedErrorCode = 1101

// 与 commonParams 同款：固定 en_US_POSIX + Gregorian，签到"今天"判定
// 不受地区/日历设置影响。
private let autoSignDayFormatter: DateFormatter = TiebaDateFormats.fixed("yyyyMdd")

/// 自动签到：BGProcessingTask 工作体、签到协调状态（day-scoped、uid 命名空间）、
/// 签到提醒本地通知。
extension TiebaBackgroundSync {
  func performAutoSign() async throws {
    await ensureSignContext()
    let snapshot = TiebaBackgroundSnapshot.shared
    guard !snapshot.bduss.isEmpty else { return }
    guard !snapshot.forumIds.isEmpty else { return }

    let day = dayKey()

    // Coordination with the foreground sign channel:
    // 1. Forums a native auto-sign already completed today are persisted under
    //    `autoSignSuccessKey(uid)`. Skip them so a re-run (or a run that fires
    //    after the user signed manually in the foreground) does not re-hit the
    //    server.
    // 2. The server is idempotent: msign returns error_code 1101 for forums
    //    already signed today (by this app or another client). Those are
    //    classified as "已签到" (successful state), NOT as failures, so the
    //    completion notification never misreports "失败 N".
    var targets = snapshot.forumIds
    let alreadySignedToday = loadAutoSignSuccessIds(uid: snapshot.uid, day: day)
    if !alreadySignedToday.isEmpty {
      targets = targets.filter { !alreadySignedToday.contains($0) }
    }
    if targets.isEmpty {
      return
    }

    let list = try await TiebaSignAPI.msign(forumIds: targets)

    var success = 0
    var fail = 0
    var alreadySigned = 0
    var exp = 0
    var successIds = Set(alreadySignedToday)

    for item in list {
      let code = int(item["error_code"])
      if code == alreadySignedErrorCode {
        alreadySigned += 1
        recordSignSuccess(item["forum_id"], in: &successIds)
      } else if code == 0 {
        success += 1
        exp += int(item["exp"])
        recordSignSuccess(item["forum_id"], in: &successIds)
      } else {
        fail += 1
      }
    }

    saveAutoSignSuccessIds(uid: snapshot.uid, day: day, ids: Array(successIds))
    saveLastAutoSignSummary(
      uid: snapshot.uid,
      day: day,
      success: success,
      fail: fail,
      alreadySigned: alreadySigned,
      exp: exp
    )

    if !list.isEmpty {
      let body: String
      if alreadySigned > 0 {
        body = "成功签到 \(success) 个吧，已签到 \(alreadySigned) 个，失败 \(fail) 个，获得 \(exp) 经验"
      } else {
        body = "成功签到 \(success) 个吧，失败 \(fail) 个，获得 \(exp) 经验"
      }
      sendNotification(
        "一键签到完成", body, identifier: "sign_complete",
        silent: TiebaPreferenceSnapshot.bool("signSilent", default: false)
      )
    }
  }

  private func recordSignSuccess(_ rawForumId: Any?, in ids: inout Set<String>) {
    let forumId = string(rawForumId)
    if !forumId.isEmpty { ids.insert(forumId) }
  }

  // MARK: - 签到前置与前台补签

  /// 自动签到的前置条件：tbs（签名令牌）与关注吧清单。
  ///
  /// 以前是 `guard !tbs.isEmpty, !forumIds.isEmpty else { return }` —— 两者任一为空就**静默返回**，
  /// 表现就是「开了自动签到，什么也没发生」。实际上两者都能现取：
  ///   * tbs 是 15 分钟级令牌，上次登录留下的经常已经空了/过期；
  ///   * forumIds 只有在关注列表同步过之后才有，冷装用户直接开自动签到就是空的。
  func ensureSignContext() async {
    let snapshot = TiebaBackgroundSnapshot.shared
    guard !snapshot.bduss.isEmpty else { return }
    if snapshot.tbs.isEmpty {
      _ = try? await TiebaSession.refreshTbs()
    }
    if snapshot.forumIds.isEmpty {
      _ = try? await TiebaFollowedForums.fetchAll(force: false)
    }
  }

  /// 前台补签：侧载包（TrollStore / SideStore 重签）基本拿不到 BGProcessingTask 的运行窗口
  /// —— 系统只把它当「有空再说」，App 被强杀过就更可能一整天不跑。所以冷启动/回前台时
  /// 自己再核一次：
  ///
  ///   偏好 `autoSign` 开着 + 今天已过 `autoSignTime` + 今天还没补过 → 直接跑一遍。
  ///
  /// 一天只补一次（`auto_sign_last_run_day` 记日键），环境不全（拿不到关注列表）就把标记撤掉，
  /// 下次前台再来。结果与后台同一条通道（`performAutoSign`），完成会发同一条本地通知。
  func runAutoSignCatchUpIfNeeded() async {
    guard TiebaPreferenceSnapshot.bool("autoSign", default: false) else { return }
    guard !TiebaBackgroundSnapshot.shared.bduss.isEmpty else { return }
    let day = dayKey()
    let markerKey = "tiebalite.native.auto_sign_last_run_day"
    if (defaults.string(forKey: markerKey) ?? "") == day { return }
    let time = TiebaPreferences.string("autoSignTime", default: "08:00")
    let parts = time.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, let due = todayDate(hour: parts[0], minute: parts[1]), Date() >= due else {
      return
    }
    // 先落标记再干活：避免回前台多次触发（以及 BGTask 恰好同时跑）时重复打服务器。
    defaults.set(day, forKey: markerKey)
    await ensureSignContext()
    guard !TiebaBackgroundSnapshot.shared.forumIds.isEmpty else {
      defaults.removeObject(forKey: markerKey)
      return
    }
    do {
      try await performAutoSign()
      Self.log.info("autoSign foreground catch-up finished")
    } catch {
      Self.log.error(
        "autoSign foreground catch-up failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// 今天的 hh:mm（不跨天）；取不到（日历异常）返回 nil。
  private func todayDate(hour: Int, minute: Int) -> Date? {
    var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    components.hour = hour
    components.minute = minute
    return Calendar.current.date(from: components)
  }

  // Auto-sign coordination state (day-scoped, uid-namespaced)

  // getLastAutoSignSummary / clearAutoSignSummary 已于 2026-08-25 删除：
  // 全仓零引用（JS 侧从未接桥，前台签到走自己的协调状态），保留
  // saveLastAutoSignSummary / clearBackgroundSnapshot 的写路径。
  private func dayKey(_ date: Date = Date()) -> String {
    autoSignDayFormatter.string(from: date)
  }

  private func loadAutoSignSuccessIds(uid: String, day: String) -> [String] {
    guard let raw = defaults.string(forKey: autoSignSuccessKey(uid)),
          let json = decodeJSON(raw) as? [String: Any],
          json["day"] as? String == day
    else {
      return []
    }
    return json["ids"] as? [String] ?? []
  }

  private func saveAutoSignSuccessIds(uid: String, day: String, ids: [String]) {
    saveJSON(["day": day, "ids": ids], forKey: autoSignSuccessKey(uid))
  }

  private func saveLastAutoSignSummary(
    uid: String,
    day: String,
    success: Int,
    fail: Int,
    alreadySigned: Int,
    exp: Int
  ) {
    let payload: [String: Any] = [
      "day": day,
      "success": success,
      "fail": fail,
      "alreadySigned": alreadySigned,
      "exp": exp,
      "timestamp": Int(Date().timeIntervalSince1970 * 1000)
    ]
    saveJSON(payload, forKey: autoSignSummaryKey(uid))
  }

  func scheduleSignReminder(hour: Int, minute: Int) {
    var date = DateComponents()
    date.hour = hour
    date.minute = minute
    // 固定 id 重排即覆盖（同 id 的 pending 请求被替换），无需先 remove。
    TiebaNotificationCenter.shared.deliver(
      identifier: "auto_sign_reminder",
      title: "一键签到",
      body: "已安排，将在系统空闲时尝试",
      playSound: true,
      badge: 1,
      dataType: "auto_sign_reminder",
      trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
    )
  }

  func cancelSignReminder() {
    TiebaNotificationCenter.shared.cancel(identifier: "auto_sign_reminder")
  }
}
