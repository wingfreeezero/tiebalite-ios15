import Foundation

// iOS 15 移植说明：
// 原实现 `public struct TiebaLiveActivityKitAttributes: ActivityAttributes`
// 依赖 ActivityKit（iOS 16.1 起）。iOS 15 没有这个框架，强行 import 会让
// 主二进制的 LC_LOAD_DYLIB 带上 ActivityKit —— dyld 在 iOS 15 上会直接
// 报 "Library not loaded" 闪退（弱链接也保不住符号）。
//
// 因此移植版把 Live Activity 整条链路退化成「值类型 + 空实现」：
//   · 类型与字段原样保留（调用点、proto 映射、通知文案都不用改）；
//   · 只是不再有 ActivityAttributes 一致性，也不再向系统申请活动。
// 想恢复：从上游取回本文件与 TiebaLiveActivity.swift，并把部署目标改回 16.1+。

// Sendable 显式声明（public 值类型不会隐式推断）。
public struct TiebaLiveActivityKitAttributes: Sendable {
  public struct ContentState: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String?
    public var body: String?
    public var currentForum: String?
    public var status: String?
    public var progress: Double?
    public var date: Double?
    public var imageName: String?
    public var tintColorHex: String?
    public var leading: String?
    public var trailing: String?
    public var extra: [String: String]?

    public init(
      title: String,
      subtitle: String? = nil,
      body: String? = nil,
      currentForum: String? = nil,
      status: String? = nil,
      progress: Double? = nil,
      date: Double? = nil,
      imageName: String? = nil,
      tintColorHex: String? = nil,
      leading: String? = nil,
      trailing: String? = nil,
      extra: [String: String]? = nil
    ) {
      self.title = title
      self.subtitle = subtitle
      self.body = body
      self.currentForum = currentForum
      self.status = status
      self.progress = progress
      self.date = date
      self.imageName = imageName
      self.tintColorHex = tintColorHex
      self.leading = leading
      self.trailing = trailing
      self.extra = extra
    }
  }

  public var name: String
  public var extra: [String: String]?

  public init(name: String, extra: [String: String]? = nil) {
    self.name = name
    self.extra = extra
  }
}

extension TiebaLiveActivityKitAttributes.ContentState {
  /// 自由字典 → 值类型（原 TiebaLiveActivityManager.makeState 的语义，原样搬移）。
  /// 必须存在于非隔离上下文：模块侧 AsyncFunction 收到 [String: Any]（非 Sendable），
  /// 要在跨到主 actor 之前先归一，否则 Swift 6 报 "sending 'state'"。
  init(raw: [String: Any]) {
    self.init(
      title: raw["title"] as? String ?? "",
      subtitle: raw["subtitle"] as? String,
      body: raw["body"] as? String,
      currentForum: raw["currentForum"] as? String,
      status: raw["status"] as? String,
      progress: raw["progress"] as? Double,
      date: raw["date"] as? Double,
      imageName: raw["imageName"] as? String,
      tintColorHex: raw["tintColorHex"] as? String,
      leading: raw["leading"] as? String,
      trailing: raw["trailing"] as? String,
      extra: raw["extra"] as? [String: String]
    )
  }
}
