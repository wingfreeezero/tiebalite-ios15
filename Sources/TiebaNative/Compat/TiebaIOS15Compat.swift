//
//  TiebaIOS15Compat.swift
//  TiebaLite iOS 15 移植层
//
//  这里只放「系统件在 iOS 15 上没有」的替身，形状尽量与系统一致，
//  调用点只改类型名，不改语义：
//
//    · TiebaContentUnavailableConfiguration / TiebaContentUnavailableView（iOS 17+）
//        → TiebaContentUnavailableConfiguration / TiebaContentUnavailableView
//    · iOS 26 液态玻璃总开关 TiebaGlass.isEnabled（移植版固定 false）
//

import UIKit

// MARK: - 液态玻璃总开关

/// iOS 26 液态玻璃的开关。
///
/// 移植版**固定关闭**：源码里所有 `#available(iOS 26.0, *)` 的玻璃分支都再与它取与，
/// 于是即使在 iOS 26 上，也一律走 iOS 17/18 的经典材质（UIVisualEffectView + UIBlurEffect），
/// 不会出现液态玻璃。
enum TiebaGlass {
  static let isEnabled = false
}

// MARK: - 空/错状态（替代 iOS 17 的 TiebaContentUnavailableView）

/// `TiebaContentUnavailableConfiguration` 的可移植替身。
///
/// 字段名与系统保持一致（`image` / `text` / `secondaryText` / `button` /
/// `imageProperties` / `textProperties` / `secondaryTextProperties` / `buttonProperties`），
/// 因此调用点只需要把类型名从 `TiebaContentUnavailableConfiguration` 换成这里。
struct TiebaContentUnavailableConfiguration {
  struct ImageProperties {
    var tintColor: UIColor?
    var maximumSize: CGSize = .zero
    var reservedLayoutSize: CGSize = .zero
  }

  struct TextProperties {
    var font: UIFont?
    var color: UIColor?
    var numberOfLines: Int = 0
  }

  struct ButtonProperties {
    var primaryAction: UIAction?
  }

  var image: UIImage?
  var text: String?
  var secondaryText: String?
  var button: UIButton.Configuration?
  var imageProperties = ImageProperties()
  var textProperties = TextProperties()
  var secondaryTextProperties = TextProperties()
  var buttonProperties = ButtonProperties()

  /// iOS 15 专用：`.loading()` 用转圈代替图标（系统版是系统自绘的加载态）。
  var showsSpinner = false

  static func empty() -> TiebaContentUnavailableConfiguration {
    TiebaContentUnavailableConfiguration()
  }

  static func loading() -> TiebaContentUnavailableConfiguration {
    var configuration = TiebaContentUnavailableConfiguration()
    configuration.showsSpinner = true
    return configuration
  }
}

/// `TiebaContentUnavailableView` 的可移植替身：竖排（转圈/图标）+ 标题 + 说明 + 可选按钮。
/// `configuration` 的语义与系统一致（赋值即刷新）。
final class TiebaContentUnavailableView: UIView {
  private let contentStack = UIStackView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let messageLabel = UILabel()
  private let actionButton = UIButton(type: .system)
  private var currentAction: UIAction?
  private var iconSizeConstraints: [NSLayoutConstraint] = []

  var configuration: TiebaContentUnavailableConfiguration {
    didSet { self.applyConfiguration() }
  }

  init(configuration: TiebaContentUnavailableConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    self.setUpSubviews()
    self.applyConfiguration()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("TiebaContentUnavailableView 只支持代码创建")
  }

  private func setUpSubviews() {
    self.contentStack.axis = .vertical
    self.contentStack.alignment = .center
    self.contentStack.spacing = 8
    self.contentStack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(self.contentStack)

    self.spinner.hidesWhenStopped = true

    self.iconView.contentMode = .scaleAspectFit

    self.titleLabel.textAlignment = .center
    self.titleLabel.numberOfLines = 0

    self.messageLabel.textAlignment = .center
    self.messageLabel.numberOfLines = 0

    self.contentStack.addArrangedSubview(self.spinner)
    self.contentStack.addArrangedSubview(self.iconView)
    self.contentStack.addArrangedSubview(self.titleLabel)
    self.contentStack.addArrangedSubview(self.messageLabel)
    self.contentStack.addArrangedSubview(self.actionButton)

    NSLayoutConstraint.activate([
      self.contentStack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      self.contentStack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: self.leadingAnchor, constant: 24),
      self.contentStack.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -24),
    ])
  }

  private func applyConfiguration() {
    let configuration = self.configuration

    if configuration.showsSpinner {
      self.spinner.isHidden = false
      self.spinner.startAnimating()
    } else {
      self.spinner.stopAnimating()
      self.spinner.isHidden = true
    }

    self.iconView.image = configuration.image
    self.iconView.isHidden = configuration.showsSpinner || configuration.image == nil
    if let tintColor = configuration.imageProperties.tintColor {
      self.iconView.tintColor = tintColor
    }

    NSLayoutConstraint.deactivate(self.iconSizeConstraints)
    self.iconSizeConstraints = []
    let maximumSize = configuration.imageProperties.maximumSize
    if maximumSize.width > 0, maximumSize.height > 0, !self.iconView.isHidden {
      self.iconSizeConstraints = [
        self.iconView.widthAnchor.constraint(lessThanOrEqualToConstant: maximumSize.width),
        self.iconView.heightAnchor.constraint(lessThanOrEqualToConstant: maximumSize.height),
      ]
      NSLayoutConstraint.activate(self.iconSizeConstraints)
    }

    self.titleLabel.text = configuration.text
    self.titleLabel.isHidden = (configuration.text?.isEmpty ?? true) || configuration.showsSpinner
    self.titleLabel.font = configuration.textProperties.font ?? UIFont.preferredFont(forTextStyle: .headline)
    self.titleLabel.textColor = configuration.textProperties.color ?? .label
    self.titleLabel.numberOfLines = configuration.textProperties.numberOfLines

    self.messageLabel.text = configuration.secondaryText
    self.messageLabel.isHidden = (configuration.secondaryText?.isEmpty ?? true) || configuration.showsSpinner
    self.messageLabel.font = configuration.secondaryTextProperties.font
      ?? UIFont.preferredFont(forTextStyle: .subheadline)
    self.messageLabel.textColor = configuration.secondaryTextProperties.color ?? .secondaryLabel
    self.messageLabel.numberOfLines = configuration.secondaryTextProperties.numberOfLines

    self.currentAction = configuration.buttonProperties.primaryAction
    self.actionButton.removeTarget(self, action: #selector(self.handleActionButton), for: .touchUpInside)
    if let buttonConfiguration = configuration.button {
      self.actionButton.configuration = buttonConfiguration
      self.actionButton.isHidden = false
      if self.currentAction != nil {
        self.actionButton.addTarget(self, action: #selector(self.handleActionButton), for: .touchUpInside)
      }
    } else {
      self.actionButton.isHidden = true
    }
  }

  @objc private func handleActionButton() {
    guard let action = self.currentAction else { return }
    action.handler(action)
  }
}
