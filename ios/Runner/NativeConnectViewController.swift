import UIKit
import Photos
import ImageIO
import CoreLocation

enum NativeHomeQuickDownloadEntryAction: Equatable {
  case configure
  case start
}

enum NativeHomeQuickDownloadEntryPolicy {
  static func action(ruleIsEnabled: Bool) -> NativeHomeQuickDownloadEntryAction {
    ruleIsEnabled ? .start : .configure
  }
}




enum NativeGalleryDownloadRunDisposition {
  case finished
  case terminatedByUser
  case interruptedRecoverable
}


enum NativeGalleryHeaderIcon {
  case back
  case share
  case downloads
}


final class NativeTopHeaderFrameView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear
    layer.cornerRadius = 0
    layer.borderWidth = 0
    layer.shadowOpacity = 0
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class NativeGalleryHeaderIconButton: UIButton {
  init(icon: NativeGalleryHeaderIcon, accessibilityLabel: String) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    configuration = .plain()
    configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    tintColor = NativeLuxuryTheme.ink
    backgroundColor = NativeTopChromeIconButtonStylePolicy.usesFilledBackground
      ? NativeLuxuryTheme.warmFill
      : .clear
    layer.cornerRadius = NativeTopChromeIconButtonStylePolicy.sideLength / 2
    layer.borderWidth = NativeTopChromeIconButtonStylePolicy.usesBorder ? 1 : 0
    layer.borderColor = NativeTopChromeIconButtonStylePolicy.usesBorder
      ? NativeLuxuryTheme.hairline.cgColor
      : UIColor.clear.cgColor
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = NativeTopChromeIconButtonStylePolicy.usesShadow ? 0.05 : 0
    layer.shadowRadius = NativeTopChromeIconButtonStylePolicy.usesShadow ? 8 : 0
    layer.shadowOffset = NativeTopChromeIconButtonStylePolicy.usesShadow ? CGSize(width: 0, height: 2) : .zero
    self.accessibilityLabel = accessibilityLabel
    setImage(Self.image(for: icon), for: .normal)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: NativeTopChromeIconButtonStylePolicy.sideLength),
      heightAnchor.constraint(equalToConstant: NativeTopChromeIconButtonStylePolicy.sideLength),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func image(for icon: NativeGalleryHeaderIcon) -> UIImage? {
    let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)
    switch icon {
    case .back:
      return UIImage(systemName: "chevron.left", withConfiguration: config)
    case .share:
      return UIImage(systemName: "point.3.connected.trianglepath.dotted", withConfiguration: config)
        ?? UIImage(systemName: "square.and.arrow.up", withConfiguration: config)
    case .downloads:
      return UIImage(systemName: "tray.full", withConfiguration: config)
    }
  }
}


enum NativeHomeRememberedCameraPresence: Equatable {
  case none
  case communicating
  case online
  case scanning
  case offline
}

enum NativeHomeRememberedCameraPresencePolicy {
  static func presence(
    rememberedPeripheralID: UUID?,
    discoveredCameraIDs: [UUID],
    status: String,
    isBusy: Bool,
    hasActiveRememberedCameraSession: Bool
  ) -> NativeHomeRememberedCameraPresence {
    guard let rememberedPeripheralID else {
      return .none
    }
    if hasActiveRememberedCameraSession {
      return .communicating
    }
    if discoveredCameraIDs.contains(rememberedPeripheralID) {
      return .online
    }

    let trimmedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
    if isBusy || trimmedStatus.contains("搜索") || trimmedStatus.contains("等待蓝牙") {
      return .scanning
    }
    if trimmedStatus.contains("未找到") || trimmedStatus.contains("未发现") {
      return .offline
    }
    return .scanning
  }
}

enum NativeHomeRememberedGalleryResumePolicy {
  static let maxAutoResumeAgeSeconds: TimeInterval = 10 * 60

  static func shouldAutoResume(
    pendingSession: CameraPendingRememberedCameraSession?,
    pendingResume: CameraPendingRememberedGalleryResume?,
    hasRememberedCamera: Bool,
    isEnteringGalleryFromRememberedCamera: Bool,
    hasConnectFlowTask: Bool,
    isBlockedByPrompt: Bool,
    now: Date = Date()
  ) -> Bool {
    guard hasRememberedCamera,
          !isEnteringGalleryFromRememberedCamera,
          !hasConnectFlowTask,
          !isBlockedByPrompt,
          let pendingResume,
          now.timeIntervalSince(pendingResume.requestedAt) <= maxAutoResumeAgeSeconds else {
      return false
    }
    guard let pendingSession else {
      return true
    }
    return now.timeIntervalSince(pendingSession.observedAt) <= maxAutoResumeAgeSeconds
  }

  static func shouldClearStaleSession(
    pendingSession: CameraPendingRememberedCameraSession?,
    pendingResume: CameraPendingRememberedGalleryResume?,
    now: Date = Date()
  ) -> Bool {
    guard let lastObservedAt = lastObservedAt(
      pendingSession: pendingSession,
      pendingResume: pendingResume
    ) else {
      return false
    }
    return now.timeIntervalSince(lastObservedAt) > maxAutoResumeAgeSeconds
  }

  static func resumeReason(
    pendingSession: CameraPendingRememberedCameraSession?,
    pendingResume: CameraPendingRememberedGalleryResume?
  ) -> String {
    pendingResume?.reason ?? pendingSession?.reason ?? "gallery"
  }

  private static func lastObservedAt(
    pendingSession: CameraPendingRememberedCameraSession?,
    pendingResume: CameraPendingRememberedGalleryResume?
  ) -> Date? {
    let lastObservedAt = max(
      pendingSession?.observedAt ?? .distantPast,
      pendingResume?.requestedAt ?? .distantPast
    )
    return lastObservedAt > .distantPast ? lastObservedAt : nil
  }
}

enum NativeHomeCameraCardCopyPolicy {
  static let pairedActionTitle = "进入相册"
  static let resumeActionTitle = "继续相册"
  static let disconnectActionTitle = "断开相机"
  static let unpairedActionTitle = "配对"

  static func unpairedDetailText(rssi: Int, shortID: String) -> String {
    "未配对 · 信号 \(rssi) dB · \(shortID)"
  }

  static func pairedDetailText(for presence: NativeHomeRememberedCameraPresence) -> String {
    switch presence {
    case .none:
      return "已配对"
    case .communicating:
      return "已配对 · 通讯中"
    case .online:
      return "已配对 · 在线"
    case .scanning:
      return "已配对 · 正在搜索"
    case .offline:
      return "已配对 · 未在线"
    }
  }
}

enum NativeHomeAndroidParityCopy {
  static let brandTitle = "CAMTRANSFER"
  static let screenTitle = "连接相机"
  static let idleModeLabel = "蓝牙配对"
  static let pairedModeLabel = "已配对"
  static let connectedModeLabel = "已连接"
  static let connectingModeLabel = "连接中"
  static let needsAttentionModeLabel = "需要处理"
  static let cameraProfileTitle = "CAMERA PROFILE"
  static let savedCameraLabel = "已保存相机"
  static let startPairingTitle = "开始配对"
  static let utilitySectionTitle = "接入方式"
  static let wiredAccessLabel = "有线接入"
  static let auxiliarySectionTitle = "辅助工具"
  static let diagnosticActionLabel = "诊断日志"
  static let disclaimerLabel = "使用须知"
  static let disclaimerText = "免责声明：相机连接、Wi-Fi 切换和照片导入会根据设备状态执行。"
  static let cameraMenuPath = "网络/USB设置 - 蓝牙/智能手机设置 - 配对注册"
  static let pairingPreparationTitles = ["进入配对注册界面", "取消旧的蓝牙配对"]
  static let auxiliaryActionLabels = [diagnosticActionLabel, disclaimerLabel]

  static func modeLabel(hasRememberedCamera: Bool, isBusy: Bool, status: String) -> String {
    if hasRememberedCamera {
      return isBusy ? connectingModeLabel : pairedModeLabel
    }
    let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("失败") || trimmed.contains("错误") {
      return needsAttentionModeLabel
    }
    return isBusy ? connectingModeLabel : idleModeLabel
  }

  static func statusPanelDetail(for presence: NativeHomeRememberedCameraPresence) -> String {
    switch presence {
    case .communicating:
      return "相机仍停留在传输状态，可以继续相册，或主动断开相机。"
    case .online:
      return "相机已经在线，可以启动 Wi-Fi 并进入相机相册。"
    case .scanning:
      return "正在连接相机，请保持相机处于连接状态。"
    case .none, .offline:
      return "已保存相机，可以点击进入相机相册开始连接。"
    }
  }
}

enum NativeHomePairingPreparationLayoutPolicy {
  static let usesCompactRows = true
  static let rowMinimumHeight: CGFloat = 70
  static let showsLongInstructionBody = false
  static let showsInlineDisclaimerText = false
  static let hidesSystemNavigationBar = true
  static let usesInlineBluetoothAction = true
}

enum NativeHomeHeaderLayoutPolicy {
  static let showsProEntry = false
}

enum NativeHomePairedCameraCardLayoutPolicy {
  static let centersPrimaryGalleryAction = true
  static let primaryGalleryActionMinimumWidth: CGFloat = 158
  static let cardMinimumHeight: CGFloat = 168
  static let anchorsStatusPanelBelowCameraIdentity = true
  static let statusPanelTopSpacingAfterIdentity: CGFloat = 8
  static let showsDecorativeProfileHeader = false
  static let showsStatusPanelFrame = false
}

enum NativeHomeCameraSearchActionPolicy {
  static let symbolName = "arrow.clockwise"
  static let accessibilityLabel = "刷新搜索附近相机"
}

enum NativeHomePassiveConnectionResetPolicy {
  static func shouldResetOnViewWillAppear(
    isRootHome: Bool,
    isEnteringGalleryFromRememberedCamera: Bool
  ) -> Bool {
    isRootHome && !isEnteringGalleryFromRememberedCamera
  }
}

enum NativeConnectFlowResultLogPolicy {
  static func message(
    state: IOSCameraConnectFlowState,
    peripheralID: UUID
  ) -> String {
    switch state {
    case .galleryReady(let session):
      return "[BEGIN_USER_GALLERY_FLOW_RESULT] state=galleryReady cameraID=\(session.cameraID) ptpSessionID=\(session.ptpSessionID) peripheralID=\(peripheralID)"
    default:
      return "[BEGIN_USER_GALLERY_FLOW_RESULT] state=\(String(describing: state)) peripheralID=\(peripheralID)"
    }
  }
}

enum NativeHomeConnectionPresentation: Equatable {
  case normal
  case systemBluetoothCleanup
  case pairingConfirmation
}

enum NativeHomeConnectionPresentationPolicy {
  static func resolve(
    requiresSystemBluetoothPairingCleanup: Bool,
    isPairingConfirmationBlockingRememberedGalleryEntry: Bool
  ) -> NativeHomeConnectionPresentation {
    if requiresSystemBluetoothPairingCleanup {
      return .systemBluetoothCleanup
    }
    if isPairingConfirmationBlockingRememberedGalleryEntry {
      return .pairingConfirmation
    }
    return .normal
  }
}

enum NativeWiredImportEntryPolicy {
  static let noDeviceTitle = "需要有线连接"
  static let noDeviceMessage = "请先用数据线连接相机，并在相机上开启 USB 传输或读卡模式。"

  static func canOpenImport(deviceCount: Int) -> Bool {
    deviceCount > 0
  }
}

extension Notification.Name {
  static let nativeDownloadStateDidChange = Notification.Name("nativeDownloadStateDidChange")
}

enum NativeLuxuryTheme {
  static let background = UIColor(red: 0.945, green: 0.933, blue: 0.906, alpha: 1)
  static let pageTopBackground = UIColor(red: 0.980, green: 0.973, blue: 0.953, alpha: 1)
  static let cardBackground = UIColor(red: 1.0, green: 0.992, blue: 0.973, alpha: 1)
  static let ink = UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1)
  static let secondaryInk = UIColor(red: 0.439, green: 0.416, blue: 0.376, alpha: 1)
  static let hairline = UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 0.10)
  static let accent = UIColor(red: 0.624, green: 0.478, blue: 0.271, alpha: 1)
  static let accentSoft = UIColor(red: 0.937, green: 0.886, blue: 0.792, alpha: 1)
  static let mutedFill = UIColor.white.withAlphaComponent(0.72)
  static let warmFill = UIColor(red: 1.0, green: 0.992, blue: 0.973, alpha: 0.88)

  static func stylePrimaryButton(_ button: UIButton) {
    let title = button.configuration?.title ?? button.title(for: .normal)
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.title = title
    config.baseBackgroundColor = ink
    config.baseForegroundColor = cardBackground
    config.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
    config.attributedTitle = AttributedString(title ?? "", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
    ]))
    button.configuration = config
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.14
    button.layer.shadowRadius = 18
    button.layer.shadowOffset = CGSize(width: 0, height: 10)
  }

  static func styleSecondaryButton(_ button: UIButton) {
    let title = button.configuration?.title ?? button.title(for: .normal)
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.title = title
    config.baseForegroundColor = ink
    config.baseBackgroundColor = mutedFill
    config.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
    config.attributedTitle = AttributedString(title ?? "", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
    ]))
    button.configuration = config
    button.layer.cornerRadius = 22
    button.layer.borderWidth = 1
    button.layer.borderColor = UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 0.13).cgColor
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.04
    button.layer.shadowRadius = 12
    button.layer.shadowOffset = CGSize(width: 0, height: 6)
  }

  static func styleCompactPillButton(_ button: UIButton, accentColor: UIColor = ink) {
    let title = button.configuration?.title ?? button.title(for: .normal)
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.title = title
    config.baseForegroundColor = ink
    config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.58)
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    config.attributedTitle = AttributedString(title ?? "", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    button.configuration = config
    button.layer.cornerRadius = 18
    button.layer.borderWidth = 1
    button.layer.borderColor = accentColor.withAlphaComponent(0.24).cgColor
    button.layer.shadowOpacity = 0
  }

  static func applyCardStyle(_ view: UIView, radius: CGFloat = 28) {
    view.backgroundColor = cardBackground
    view.layer.cornerRadius = radius
    view.layer.borderWidth = 1
    view.layer.borderColor = hairline.cgColor
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOpacity = 0.075
    view.layer.shadowRadius = 28
    view.layer.shadowOffset = CGSize(width: 0, height: 18)
  }

  static func applyFloatingPillStyle(_ view: UIView) {
    view.backgroundColor = warmFill
    view.layer.cornerRadius = 28
    view.layer.borderWidth = 1
    view.layer.borderColor = hairline.cgColor
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOpacity = 0.075
    view.layer.shadowRadius = 24
    view.layer.shadowOffset = CGSize(width: 0, height: 14)
  }

  static func setIcon(_ systemName: String, on button: UIButton) {
    button.configuration?.image = UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    button.configuration?.imagePadding = 8
    button.configuration?.imagePlacement = .leading
  }

  static func applyNavigationAppearance(to navigationController: UINavigationController?) {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = background
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [
      .foregroundColor: ink,
      .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
    ]
    navigationController?.navigationBar.standardAppearance = appearance
    navigationController?.navigationBar.scrollEdgeAppearance = appearance
    navigationController?.navigationBar.compactAppearance = appearance
    navigationController?.navigationBar.tintColor = ink
    navigationController?.navigationBar.overrideUserInterfaceStyle = .light
  }

  static func styleSegmentedControl(_ control: UISegmentedControl) {
    control.selectedSegmentTintColor = ink
    control.backgroundColor = mutedFill
    control.setTitleTextAttributes([
      .foregroundColor: secondaryInk,
      .font: UIFont.systemFont(ofSize: 12, weight: .semibold)
    ], for: .normal)
    control.setTitleTextAttributes([
      .foregroundColor: cardBackground,
      .font: UIFont.systemFont(ofSize: 12, weight: .semibold)
    ], for: .selected)
  }

  static func makeBrandLabel(_ text: String = "CAMTRANSFER", size: CGFloat = 10) -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = text
    label.font = .systemFont(ofSize: size, weight: .heavy)
    label.textColor = accent
    label.letterSpacing = size * 0.22
    return label
  }

  static func makeTitleLabel(_ text: String, size: CGFloat = 30) -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = text
    label.numberOfLines = 0
    label.textColor = ink
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = 0.96
    label.attributedText = NSAttributedString(string: text, attributes: [
      .font: UIFont.systemFont(ofSize: size, weight: .heavy),
      .kern: 0,
      .foregroundColor: ink,
      .paragraphStyle: paragraph
    ])
    return label
  }

  static func makeCopyLabel(_ text: String, alignment: NSTextAlignment = .natural) -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = text
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.textColor = secondaryInk
    label.numberOfLines = 0
    label.textAlignment = alignment
    return label
  }

  static func makeDivider() -> UIView {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = hairline
    view.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return view
  }
}

private extension UILabel {
  var letterSpacing: CGFloat {
    get { 0 }
    set {
      guard let text else { return }
      attributedText = NSAttributedString(
        string: text,
        attributes: [
          .kern: newValue,
          .font: font as Any,
          .foregroundColor: textColor as Any
        ]
      )
    }
  }
}

final class NativeChipBarControl: UIControl {
  struct Item: Equatable {
    let id: String
    let title: String
  }

  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private(set) var items: [Item] = []
  private var buttons: [UIButton] = []
  private(set) var selectedID: String?
  private(set) var selectedIDs: Set<String> = []
  private var heightConstraint: NSLayoutConstraint?

  var onSelected: ((String) -> Void)?
  var onSelectionChanged: ((Set<String>) -> Void)?
  var allowsMultipleSelection = false {
    didSet {
      if !allowsMultipleSelection, let selectedID {
        selectedIDs = [selectedID]
      }
      refreshButtonStates()
    }
  }

  var useCompactStyle: Bool = false {
    didSet {
      heightConstraint?.constant = useCompactStyle ? 28 : 38
      stack.spacing = useCompactStyle ? 6 : 8
      refreshButtonStates()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.backgroundColor = .clear
    scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    addSubview(scrollView)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.spacing = 7
    stack.alignment = .center
    scrollView.addSubview(stack)

    let height = heightAnchor.constraint(equalToConstant: 38)
    heightConstraint = height
    stack.spacing = 8
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      height,

      stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
      stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
    ])
  }

  func configure(items: [Item], selectedID: String) {
    self.items = items
    self.selectedID = selectedID
    self.selectedIDs = [selectedID]
    rebuild()
  }

  func configure(items: [Item], selectedIDs: Set<String>) {
    self.items = items
    self.selectedIDs = selectedIDs.filter { id in items.contains(where: { $0.id == id }) }
    self.selectedID = self.selectedIDs.first
    rebuild()
  }

  func setSelected(_ id: String) {
    guard items.contains(where: { $0.id == id }) else { return }
    selectedID = id
    selectedIDs = [id]
    refreshButtonStates()
  }

  func setSelectedIDs(_ ids: Set<String>) {
    let validIDs = ids.filter { id in items.contains(where: { $0.id == id }) }
    selectedIDs = validIDs
    selectedID = validIDs.first
    refreshButtonStates()
  }

  func refreshTitle(forID id: String, title: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index] = Item(id: id, title: title)
    selectedID = id
    selectedIDs = [id]
    refreshButtonStates()
  }

  private func rebuild() {
    buttons.forEach { $0.removeFromSuperview() }
    stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    buttons = items.map { item in
      let button = UIButton(type: .system)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.configuration = UIButton.Configuration.filled()
      button.configuration?.cornerStyle = .capsule
      button.layer.borderWidth = 1
      button.layer.shadowColor = UIColor.black.cgColor
      button.layer.shadowOffset = CGSize(width: 0, height: 4)
      button.layer.shadowRadius = 10
      button.addAction(UIAction { [weak self] _ in
        guard let self else { return }
        if self.allowsMultipleSelection {
          if self.selectedIDs.contains(item.id) {
            guard self.selectedIDs.count > 1 else { return }
            self.selectedIDs.remove(item.id)
          } else {
            self.selectedIDs.insert(item.id)
          }
          self.selectedID = self.selectedIDs.first
          self.refreshButtonStates(animated: true)
          self.onSelectionChanged?(self.selectedIDs)
          return
        }
        self.selectedID = item.id
        self.selectedIDs = [item.id]
        self.refreshButtonStates(animated: true)
        self.onSelected?(item.id)
      }, for: .touchUpInside)
      button.addTarget(self, action: #selector(buttonPressed(_:)), for: .touchDown)
      button.addTarget(self, action: #selector(buttonReleased(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
      stack.addArrangedSubview(button)
      return button
    }
    refreshButtonStates()
  }

  @objc private func buttonPressed(_ sender: UIButton) {
    UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
      sender.transform = CGAffineTransform(scaleX: 0.93, y: 0.93)
    }
  }

  @objc private func buttonReleased(_ sender: UIButton) {
    UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4) {
      sender.transform = .identity
    }
  }

  private func refreshButtonStates(animated: Bool = false) {
    let fontSize: CGFloat = useCompactStyle ? 11 : 12.5
    let insets = useCompactStyle
      ? NSDirectionalEdgeInsets(top: 6, leading: 13, bottom: 6, trailing: 13)
      : NSDirectionalEdgeInsets(top: 9, leading: 17, bottom: 9, trailing: 17)
    for (index, button) in buttons.enumerated() {
      let item = items[index]
      let isActive = selectedIDs.contains(item.id)
      var config = button.configuration
      config?.contentInsets = insets
      let titleAttributes = AttributeContainer([
        .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
        .kern: 0.4,
        .foregroundColor: isActive ? NativeLuxuryTheme.cardBackground : NativeLuxuryTheme.ink
      ])
      config?.attributedTitle = AttributedString(item.title, attributes: titleAttributes)
      let applyChanges = {
        if isActive {
          config?.baseBackgroundColor = NativeLuxuryTheme.ink
          config?.baseForegroundColor = NativeLuxuryTheme.cardBackground
          button.layer.borderWidth = 1.4
          button.layer.borderColor = NativeLuxuryTheme.accent.withAlphaComponent(0.7).cgColor
          button.layer.shadowOpacity = 0.22
          button.layer.shadowRadius = 14
          button.layer.shadowOffset = CGSize(width: 0, height: 6)
        } else {
          config?.baseBackgroundColor = UIColor.white
          config?.baseForegroundColor = NativeLuxuryTheme.ink
          button.layer.borderWidth = 1
          button.layer.borderColor = UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 0.08).cgColor
          button.layer.shadowOpacity = 0.05
          button.layer.shadowRadius = 8
          button.layer.shadowOffset = CGSize(width: 0, height: 3)
        }
        button.configuration = config
      }
      if animated {
        UIView.transition(with: button, duration: 0.24, options: [.transitionCrossDissolve, .allowUserInteraction]) {
          applyChanges()
        }
      } else {
        applyChanges()
      }
    }
  }
}



final class NativeConnectViewController: UIViewController {
  private let scrollView: UIScrollView = {
    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    return scrollView
  }()

  private let contentStack: UIStackView = {
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 12
    return stack
  }()

  private let brandLabel = NativeLuxuryTheme.makeBrandLabel(NativeHomeAndroidParityCopy.brandTitle)
  private let modeLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = NativeHomeAndroidParityCopy.idleModeLabel
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.textAlignment = .right
    return label
  }()
  private let screenTitleLabel = NativeLuxuryTheme.makeTitleLabel(NativeHomeAndroidParityCopy.screenTitle, size: 32)

  private let pairingPreparationStack: UIStackView = {
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 8
    return stack
  }()

  private let startPairingButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle(NativeHomeAndroidParityCopy.startPairingTitle, for: .normal)
    NativeLuxuryTheme.stylePrimaryButton(button)
    NativeLuxuryTheme.setIcon("magnifyingglass", on: button)
    return button
  }()

  private let confirmPairingButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("手机确认配对完成", for: .normal)
    NativeLuxuryTheme.stylePrimaryButton(button)
    NativeLuxuryTheme.setIcon("checkmark", on: button)
    button.isHidden = true
    return button
  }()

  private let wiredImportButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle(NativeHomeAndroidParityCopy.wiredAccessLabel, for: .normal)
    NativeLuxuryTheme.styleSecondaryButton(button)
    NativeLuxuryTheme.setIcon("cable.connector", on: button)
    return button
  }()

  private let proEntryButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.title = "Pro"
    config.baseForegroundColor = UIColor(red: 0.24, green: 0.17, blue: 0.07, alpha: 1)
    config.baseBackgroundColor = UIColor(red: 0.96, green: 0.88, blue: 0.68, alpha: 1)
    config.image = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
    config.imagePadding = 5
    config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
    config.attributedTitle = AttributedString("Pro", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .heavy)
    ]))
    button.configuration = config
    button.accessibilityLabel = "打开 CamTransfer Pro"
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.10
    button.layer.shadowRadius = 12
    button.layer.shadowOffset = CGSize(width: 0, height: 6)
    return button
  }()

  private let spinner: UIActivityIndicatorView = {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    spinner.color = NativeLuxuryTheme.secondaryInk
    return spinner
  }()

  private let statusBadgeLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = ""
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.numberOfLines = 0
    label.textAlignment = .center
    label.isHidden = true
    return label
  }()

  private let copyLogButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.configuration = .tinted()
    button.configuration?.title = "复制日志"
    button.configuration?.cornerStyle = .medium
    button.isHidden = true
    return button
  }()

  private let shareLogButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle(NativeHomeAndroidParityCopy.diagnosticActionLabel, for: .normal)
    NativeLuxuryTheme.styleCompactPillButton(button)
    NativeLuxuryTheme.setIcon("doc.text.magnifyingglass", on: button)
    button.isHidden = false
    return button
  }()

  private let disclaimerButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle(NativeHomeAndroidParityCopy.disclaimerLabel, for: .normal)
    NativeLuxuryTheme.styleCompactPillButton(button)
    NativeLuxuryTheme.setIcon("info.circle", on: button)
    return button
  }()

  private let logView: UITextView = {
    let view = UITextView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isEditable = false
    view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    view.backgroundColor = .secondarySystemBackground
    view.layer.cornerRadius = 14
    view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    view.isHidden = true
    return view
  }()

  private let discoveredCameraStack: UIStackView = {
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 10
    stack.isHidden = true
    return stack
  }()

  private let pairedCameraStack: UIStackView = {
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 10
    stack.isHidden = true
    return stack
  }()

  private let cameraSessionRuntime: CameraSessionRuntime
  private let wiredImportProbeService = WiredCameraImportService()
  private var autoDownloadRule = CameraAutoDownloadRuleStore.load()
  private var isAutoDownloadPending = false
  private var autoDownloadCatalogObserverID: UUID?
  private var cameras: [IOSCameraDiscoveredCamera] = []
  private var wiredImportDevices: [WiredCameraImportDevice] = []
  private weak var scanController: NativeScanViewController?
  private var connectingOverlay: NativeConnectingOverlay?
  private var hasStartedInitialCameraSearch = false
  private var hasAttemptedStartupDownloadSessionResume = false
  private var hasShownStartupDownloadRecoveryPrompt = false
  private var hasRunDebugRememberedAutoConnect = false
  private var hasShownDebugStubGallery = false
  private var isEnteringGalleryFromRememberedCamera = false
  private var isDisconnectingActiveRememberedCamera = false
  private var isPresentingPairingConfirmationPrompt = false
  private var isPresentingSystemBluetoothCleanupPrompt = false
  private var isPresentingFreshPairingCleanupPrompt = false
  private var hasConfirmedSystemBluetoothCleanupForFreshPairing = false
  private var latestServiceStatus = ""
  private var latestServiceIsBusy = false
  private var galleryEntryTask: Task<Void, Never>?

  init(runtime: CameraSessionRuntime) {
    self.cameraSessionRuntime = runtime
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .light
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    print("CamTransferNative NativeConnectViewController viewDidLoad")
    cameraSessionRuntime.onPresentationDestinationReady = { [weak self] destination in
      self?.routeRuntimePresentationDestination(destination)
    }
    cameraSessionRuntime.onConnectionSnapshotChanged = { [weak self] snapshot in
      guard let self else { return }
      self.cameras = snapshot.discoveredCameras
      self.latestServiceStatus = snapshot.status
      self.latestServiceIsBusy = snapshot.isBusy
      self.statusBadgeLabel.text = snapshot.status
      self.statusBadgeLabel.isHidden = snapshot.status.isEmpty
      self.refreshPairingConfirmationButton(for: snapshot.status, isBusy: snapshot.isBusy)
      self.updateRememberedCameraCard()
      self.updateInlineDiscoveredCameras()
      self.presentPhonePairingConfirmationPromptIfNeeded(status: snapshot.status, isBusy: snapshot.isBusy)
      self.presentSystemBluetoothPairingCleanupPromptIfNeeded(status: snapshot.status, isBusy: snapshot.isBusy)
      self.scanController?.update(status: snapshot.status, isBusy: snapshot.isBusy)
      self.scanController?.update(cameras: snapshot.discoveredCameras)
      self.connectingOverlay?.update(status: snapshot.status)
      if snapshot.isBusy {
        self.spinner.startAnimating()
      } else {
        self.spinner.stopAnimating()
      }
    }
    cameraSessionRuntime.onConnectionLogAppended = { [weak self] message in
      guard let self else { return }
      guard NativeLogTextViewPolicy.shouldRenderLiveText(
        applicationState: UIApplication.shared.applicationState,
        hasWindow: self.view.window != nil
      ) else { return }
      self.logView.text = NativeLogTextViewPolicy.appending(message, to: self.logView.text)
      let bottom = NSRange(location: max(self.logView.text.count - 1, 0), length: 1)
      self.logView.scrollRangeToVisible(bottom)
    }
    wiredImportProbeService.delegate = self
    setupUI()
    _ = cameraSessionRuntime.restoreRememberedCameraRecords()
    updateRememberedCameraCard()
    refreshWiredImportButton()
    wiredImportProbeService.start()
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
      Task {
        await CamTransferProStore.shared.refreshPurchasedEntitlements()
      }
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    cancelAutoDownloadCatalogObserver()
    galleryEntryTask?.cancel()
    wiredImportProbeService.stop()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    if NativeHomePairingPreparationLayoutPolicy.hidesSystemNavigationBar {
      navigationController?.setNavigationBarHidden(true, animated: animated)
    }
    _ = cameraSessionRuntime.restoreRememberedCameraRecords()
    updateRememberedCameraCard()
    let isRootHome = navigationController?.viewControllers.first === self
      && navigationController?.viewControllers.count == 1
    if NativeHomePassiveConnectionResetPolicy.shouldResetOnViewWillAppear(
      isRootHome: isRootHome,
      isEnteringGalleryFromRememberedCamera: isEnteringGalleryFromRememberedCamera
    ) {
      // We've returned to the home screen; clear stale BLE/PTP flags so the
      // next "Connect" tap is guaranteed to actually start a new attempt.
      cancelConnectFlow(reason: "home-view-will-appear-passive-reset")
      hideConnectingOverlay()
      isEnteringGalleryFromRememberedCamera = false
    } else if isRootHome && isEnteringGalleryFromRememberedCamera {
      CameraVendorFileLogger.log("[HOME_PASSIVE_RESET_SKIPPED] active remembered gallery flow")
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if NativeHomePairingPreparationLayoutPolicy.hidesSystemNavigationBar {
      navigationController?.setNavigationBarHidden(false, animated: animated)
    }
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .darkContent
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !presentStartupSystemBluetoothCleanupBlockIfNeeded() else { return }
    guard !showDebugStubDownloadsIfRequested() else { return }
    guard !showDebugStubGalleryIfRequested() else { return }
    guard !startDebugRememberedAutoConnectIfRequested() else { return }
    guard !offerPendingDownloadRecoveryIfNeeded() else { return }
    updateRememberedCameraCard()
    startInitialCameraSearchIfNeeded()
    beginPairingProbeIfNeeded()
  }

  // MARK: - Pairing Probe

  private var pairingProbeTask: Task<Void, Never>?

  private func beginPairingProbeIfNeeded() {
    guard let record = cameraSessionRuntime.rememberedCameraRecords.first else { return }
    guard !cameraSessionRuntime.isConnectionWorkerActive else { return }
    guard pairingProbeTask == nil else { return }

    CameraVendorFileLogger.log("[PAIRING_PROBE_UI_BEGIN] peripheralID=\(record.peripheralID)")

    pairingProbeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await self.cameraSessionRuntime.probePairing(peripheralID: record.peripheralID)
      self.pairingProbeTask = nil

      CameraVendorFileLogger.log("[PAIRING_PROBE_UI_RESULT] result=\(result)")

      switch result {
      case .online:
        // Camera is reachable and pairing is valid — BLE pre-connected.
        self.updateRememberedCameraCard()
      case .pairingInvalid(let reason):
        // Pairing has been invalidated on the camera side.
        CameraVendorFileLogger.log("[PAIRING_PROBE_INVALID] reason=\(reason) — clearing pairing record")
        self.cameraSessionRuntime.forgetRememberedCamera(peripheralID: record.peripheralID)
        self.updateRememberedCameraCard()
      case .offline:
        // Camera not in range — no action needed, card remains as-is.
        self.updateRememberedCameraCard()
      case .bluetoothOff:
        // Bluetooth is off — no action, system will prompt if needed.
        break
      }
    }
  }

  private func requestRememberedGalleryResume(peripheralID: UUID, reason: String) {
    guard let record = cameraSessionRuntime.rememberedCameraRecords.first(where: { $0.peripheralID == peripheralID }) else {
      CameraVendorFileLogger.log(
        "[REMEMBERED_GALLERY_FLOW_RESUME_SKIPPED] reason=\(reason) peripheralID=\(peripheralID) missing-record"
      )
      return
    }
    CameraVendorFileLogger.log(
      "[REMEMBERED_GALLERY_FLOW_RESUME] reason=\(reason) peripheralID=\(peripheralID)"
    )
    if currentTopGalleryController() == nil, navigationController?.topViewController !== self {
      navigationController?.popToViewController(self, animated: false)
    }
    hideConnectingOverlay()
    isEnteringGalleryFromRememberedCamera = false
    connectRememberedCamera(record)
  }

  @discardableResult
  private func presentStartupSystemBluetoothCleanupBlockIfNeeded() -> Bool {
    guard cameraSessionRuntime.publishSystemBluetoothCleanupBlockIfNeeded() else {
      return false
    }
    logView.text = ""
    isEnteringGalleryFromRememberedCamera = false
    hideConnectingOverlay()
    updateRememberedCameraCard()
    presentSystemBluetoothPairingCleanupPromptIfNeeded(
      status: CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus,
      isBusy: false
    )
    return true
  }

  private func showDebugStubDownloadsIfRequested() -> Bool {
    #if DEBUG
    guard !hasShownDebugStubGallery else { return false }
    guard NativeCameraDebugLaunchPolicy.shouldShowStubDownloads(
      arguments: ProcessInfo.processInfo.arguments
    ) else { return false }
    hasShownDebugStubGallery = true
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "DSCF0001.JPG", formatLabel: "JPG", captureDate: "2026:06:23 10:00:00", byteSizeText: "4 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "DSCF0002.HEIC", formatLabel: "HEIF", captureDate: "2026:06:23 10:01:00", byteSizeText: "5 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "DSCF0003.RAF", formatLabel: "RAW", captureDate: "2026:06:23 10:02:00", byteSizeText: "32 MB"),
    ]
    let states: [Int: CameraVendorDownloadState] = [
      1: .saved,
      2: .downloading,
      3: .queued,
    ]
    let controller = NativeDownloadListViewController(
      runtime: cameraSessionRuntime,
      itemsProvider: { items },
      stateProvider: { handle in states[handle] ?? .idle },
      progressProvider: { handle in handle == 2 ? "1/3" : nil },
      isTransferActiveProvider: { false },
      onTerminateDownload: {},
      onClearDownloadCache: { _ in }
    )
    navigationController?.pushViewController(controller, animated: false)
    return true
    #else
    return false
    #endif
  }

  private func showDebugStubGalleryIfRequested() -> Bool {
    #if DEBUG
    guard !hasShownDebugStubGallery else { return false }
    guard NativeCameraDebugLaunchPolicy.shouldShowStubGallery(
      arguments: ProcessInfo.processInfo.arguments
    ) else { return false }
    hasShownDebugStubGallery = true
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "STUB",
      preferredWifiNetwork: nil
    )
      let controller = NativeGalleryViewController(summary: summary, runtime: cameraSessionRuntime)
    navigationController?.pushViewController(controller, animated: false)
    return true
    #else
    return false
    #endif
  }

  private func startDebugRememberedAutoConnectIfRequested() -> Bool {
    #if DEBUG
    guard !hasRunDebugRememberedAutoConnect else { return false }
    guard NativeCameraDebugLaunchPolicy.shouldAutoConnectRememberedCamera(
      arguments: ProcessInfo.processInfo.arguments
    ) else { return false }

    hasRunDebugRememberedAutoConnect = true
    guard let record = cameraSessionRuntime.rememberedCameraRecords.first else { return false }
    connectRememberedCamera(record)
    return true
    #else
    return false
    #endif
  }

  private func setupUI() {
    view.backgroundColor = NativeLuxuryTheme.background
    navigationItem.title = ""
    navigationItem.rightBarButtonItem = nil

    proEntryButton.isHidden = !NativeHomeHeaderLayoutPolicy.showsProEntry
    let headerActionViews: [UIView] = NativeHomeHeaderLayoutPolicy.showsProEntry
      ? [modeLabel, proEntryButton]
      : [modeLabel]
    let headerActionsRow = UIStackView(arrangedSubviews: headerActionViews)
    headerActionsRow.translatesAutoresizingMaskIntoConstraints = false
    headerActionsRow.axis = .horizontal
    headerActionsRow.alignment = .center
    headerActionsRow.spacing = 8

    let headerTopRow = UIStackView(arrangedSubviews: [brandLabel, headerActionsRow])
    headerTopRow.translatesAutoresizingMaskIntoConstraints = false
    headerTopRow.axis = .horizontal
    headerTopRow.alignment = .center
    headerTopRow.distribution = .equalSpacing

    let headerStack = UIStackView(arrangedSubviews: [headerTopRow, screenTitleLabel])
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    headerStack.axis = .vertical
    headerStack.spacing = 6

    buildPairingPreparationCards()

    let statusStack = UIStackView(arrangedSubviews: [spinner, statusBadgeLabel])
    statusStack.translatesAutoresizingMaskIntoConstraints = false
    statusStack.axis = .horizontal
    statusStack.spacing = 8
    statusStack.alignment = .center
    statusStack.distribution = .equalCentering

    let utilitySection = makeHomeSection(
      title: NativeHomeAndroidParityCopy.utilitySectionTitle,
      arrangedSubviews: [wiredImportButton]
    )
    let auxiliarySection = makeHomeSection(
      title: NativeHomeAndroidParityCopy.auxiliarySectionTitle,
      arrangedSubviews: NativeHomePairingPreparationLayoutPolicy.showsInlineDisclaimerText
        ? [shareLogButton, disclaimerButton, NativeLuxuryTheme.makeCopyLabel(NativeHomeAndroidParityCopy.disclaimerText)]
        : [makeHorizontalActionRow([shareLogButton, disclaimerButton])]
    )

    view.addSubview(scrollView)
    scrollView.addSubview(contentStack)
    contentStack.addArrangedSubview(headerStack)
    contentStack.addArrangedSubview(pairingPreparationStack)
    contentStack.addArrangedSubview(pairedCameraStack)
    contentStack.addArrangedSubview(discoveredCameraStack)
    contentStack.addArrangedSubview(startPairingButton)
    contentStack.addArrangedSubview(confirmPairingButton)
    contentStack.addArrangedSubview(statusStack)
    contentStack.addArrangedSubview(utilitySection)
    contentStack.addArrangedSubview(auxiliarySection)
    contentStack.addArrangedSubview(logView)

    confirmPairingButton.addTarget(self, action: #selector(confirmPairingTapped), for: .touchUpInside)
    startPairingButton.addTarget(self, action: #selector(refreshSearchTapped), for: .touchUpInside)
    wiredImportButton.addTarget(self, action: #selector(wiredImportTapped), for: .touchUpInside)
    proEntryButton.addTarget(self, action: #selector(proEntryTapped), for: .touchUpInside)
    copyLogButton.addTarget(self, action: #selector(copyLogsTapped), for: .touchUpInside)
    shareLogButton.addTarget(self, action: #selector(shareLogsTapped), for: .touchUpInside)
    disclaimerButton.addTarget(self, action: #selector(disclaimerTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
      contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 22),
      contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -22),
      contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),

      statusBadgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusStack.leadingAnchor),
      statusBadgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusStack.trailingAnchor),
    ])
  }

  private func buildPairingPreparationCards() {
    pairingPreparationStack.arrangedSubviews.forEach { view in
      pairingPreparationStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    pairingPreparationStack.addArrangedSubview(NativePairingPreparationCard(
      number: "1",
      label: "相机准备",
      title: "进入配对注册界面",
      body: "在相机上打开下面这个菜单，停在配对注册界面后，再回到 App 开始配对。",
      footnote: NativeHomeAndroidParityCopy.cameraMenuPath,
      accentColor: NativeLuxuryTheme.accent
    ))
    pairingPreparationStack.addArrangedSubview(NativePairingPreparationCard(
      number: "2",
      label: "手机准备",
      title: "删除本地蓝牙配对",
      body: "如果这台相机以前配过，请到 iPhone 本地蓝牙设置里找到 X-T / FUJIFILM 相机记录，先删除本地蓝牙配对，再回到这里。",
      footnote: "设置 -> 蓝牙 -> 相机名称 -> 忽略此设备/删除本地蓝牙配对",
      accentColor: UIColor(red: 0.176, green: 0.490, blue: 0.275, alpha: 1),
      actionTitle: "打开本地蓝牙设置",
      onAction: { [weak self] in
        self?.openBluetoothSettings()
      }
    ))
  }

  private func makeHomeSection(title: String, arrangedSubviews: [UIView]) -> UIStackView {
    let titleLabel = NativeLuxuryTheme.makeBrandLabel(title, size: 10)
    titleLabel.textColor = NativeLuxuryTheme.secondaryInk
    let stack = UIStackView(arrangedSubviews: [titleLabel] + arrangedSubviews)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 10
    stack.setCustomSpacing(8, after: titleLabel)
    return stack
  }

  private func makeHorizontalActionRow(_ views: [UIView]) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .fill
    stack.distribution = .fillEqually
    stack.spacing = 8
    return stack
  }

  @objc private func refreshSearchTapped() {
    guard presentFreshPairingBluetoothCleanupPromptIfNeeded() else { return }
    startFreshPairingSearch()
  }

  private func startFreshPairingSearch() {
    cameraSessionRuntime.clearConnectionLogs()
    prepareFreshPairingSearchPresentation()
    cameraSessionRuntime.requestCameraDiscovery()
  }

  private func prepareFreshPairingSearchPresentation() {
    logView.text = ""
    confirmPairingButton.isHidden = true
    hasStartedInitialCameraSearch = true
    latestServiceStatus = "搜索中"
    latestServiceIsBusy = true
    updateRememberedCameraCard()
    updateInlineDiscoveredCameras()
  }

  @objc private func disclaimerTapped() {
    presentNotice(
      title: NativeHomeAndroidParityCopy.disclaimerLabel,
      message: NativeHomeAndroidParityCopy.disclaimerText
    )
  }

  private func openBluetoothSettings() {
    let candidates = [
      "App-Prefs:root=Bluetooth",
      "App-Prefs:Bluetooth",
      UIApplication.openSettingsURLString,
    ]
    func openNext(_ index: Int) {
      guard index < candidates.count else { return }
      guard let url = URL(string: candidates[index]) else {
        openNext(index + 1)
        return
      }
      UIApplication.shared.open(url, options: [:]) { success in
        if !success {
          openNext(index + 1)
        }
      }
    }
    openNext(0)
  }

  @discardableResult
  private func presentFreshPairingBluetoothCleanupPromptIfNeeded() -> Bool {
    if NativeHomeConnectionPresentationPolicy.resolve(
      requiresSystemBluetoothPairingCleanup: cameraSessionRuntime.requiresSystemBluetoothPairingCleanup,
      isPairingConfirmationBlockingRememberedGalleryEntry: false
    ) == .systemBluetoothCleanup {
      hideConnectingOverlay()
      presentSystemBluetoothPairingCleanupPromptIfNeeded(
        status: CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus,
        isBusy: false
      )
      return false
    }
    return true
  }

  private func presentBluetoothCleanupConfirmationPrompt(
    title: String,
    message: String,
    openBluetoothTitle: String,
    confirmTitle: String,
    checkboxTitle: String,
    onDismiss: @escaping () -> Void,
    onConfirm: @escaping () -> Void
  ) {
    let presenter = scanController?.navigationController ?? self
    guard view.window != nil, presenter.view.window != nil else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        self?.presentBluetoothCleanupConfirmationPrompt(
          title: title,
          message: message,
          openBluetoothTitle: openBluetoothTitle,
          confirmTitle: confirmTitle,
          checkboxTitle: checkboxTitle,
          onDismiss: onDismiss,
          onConfirm: onConfirm
        )
      }
      return
    }
    if presenter.presentedViewController is NativeBluetoothCleanupConfirmationViewController {
      return
    }
    let controller = NativeBluetoothCleanupConfirmationViewController(
      title: title,
      message: message,
      openBluetoothTitle: openBluetoothTitle,
      confirmTitle: confirmTitle,
      checkboxTitle: checkboxTitle,
      openBluetoothAction: { [weak self] in
        self?.openBluetoothSettings()
      },
      confirmAction: onConfirm,
      cancelAction: onDismiss
    )
    presenter.present(controller, animated: true)
  }

  private func confirmDeletedBluetoothAndStartFreshPairing() {
    isPresentingFreshPairingCleanupPrompt = false
    isPresentingSystemBluetoothCleanupPrompt = false
    hasConfirmedSystemBluetoothCleanupForFreshPairing = true
    cameraSessionRuntime.repairSystemBluetoothCleanupAndStartFreshDiscovery()
    prepareFreshPairingSearchPresentation()
  }

  @objc private func wiredImportTapped() {
    guard NativeWiredImportEntryPolicy.canOpenImport(deviceCount: wiredImportDevices.count) else {
      presentNotice(
        title: NativeWiredImportEntryPolicy.noDeviceTitle,
        message: NativeWiredImportEntryPolicy.noDeviceMessage
      )
      return
    }

    let controller = WiredCameraImportViewController()
    navigationController?.pushViewController(controller, animated: true)
  }

  private func refreshWiredImportButton() {
    let hasWiredCamera = NativeWiredImportEntryPolicy.canOpenImport(deviceCount: wiredImportDevices.count)
    let title = hasWiredCamera ? "有线接入 · 已连接" : NativeHomeAndroidParityCopy.wiredAccessLabel
    var config = wiredImportButton.configuration ?? UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.baseForegroundColor = NativeLuxuryTheme.ink
    config.baseBackgroundColor = hasWiredCamera ? NativeLuxuryTheme.warmFill : NativeLuxuryTheme.mutedFill
    config.image = UIImage(systemName: "cable.connector", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    config.imagePadding = 6
    config.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
    config.attributedTitle = AttributedString(title, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
    ]))
    wiredImportButton.configuration = config
    wiredImportButton.alpha = hasWiredCamera ? 1 : 0.62
    wiredImportButton.accessibilityHint = hasWiredCamera
      ? "打开有线相机照片导入"
      : NativeWiredImportEntryPolicy.noDeviceMessage
  }

  private func presentScanController() {
    if scanController != nil { return }
    let controller = NativeScanViewController(
      initialCameras: cameras,
      onSelect: { [weak self] camera in
        guard let self else { return }
        guard self.presentFreshPairingBluetoothCleanupPromptIfNeeded() else { return }
        self.scanController?.markConnecting(to: camera)
        self.beginPairing(with: camera)
      },
      onCancel: { [weak self] in
        self?.scanController?.dismiss(animated: true)
      }
    )
    let nav = UINavigationController(rootViewController: controller)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.large(), .medium()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28
    }
    nav.overrideUserInterfaceStyle = .light
    NativeLuxuryTheme.applyNavigationAppearance(to: nav)
    scanController = controller
    present(nav, animated: true)
  }

  private func startInitialCameraSearchIfNeeded() {
    guard !presentStartupSystemBluetoothCleanupBlockIfNeeded() else { return }
    guard !hasStartedInitialCameraSearch else { return }
    let hasRememberedCamera = !cameraSessionRuntime.rememberedCameraRecords.isEmpty
    guard NativeCameraSearchStartupPolicy.shouldStartScanningOnLaunch(
      hasRememberedCamera: hasRememberedCamera
    ) else { return }

    hasStartedInitialCameraSearch = true
    cameraSessionRuntime.requestCameraDiscovery()
    if !NativeCameraSearchStartupPolicy.shouldHideRememberedCameraWhileScanning(
      hasRememberedCamera: hasRememberedCamera
    ) {
      updateRememberedCameraCard()
    }
  }

  @discardableResult
  private func resumePendingDownloadSessionIfNeeded(now: Date = Date()) -> Bool {
    guard !hasAttemptedStartupDownloadSessionResume else {
      return cameraSessionRuntime.hasPendingRecovery
    }
    hasAttemptedStartupDownloadSessionResume = true
    cameraSessionRuntime.send(.restorePersistedDownload)
    return cameraSessionRuntime.hasPendingRecovery
  }

  @discardableResult
  private func offerPendingDownloadRecoveryIfNeeded() -> Bool {
    if cameraSessionRuntime.hasPendingRecovery {
      return true
    }
    guard cameraSessionRuntime.hasPersistedDownloadRecovery,
          !hasShownStartupDownloadRecoveryPrompt else {
      return false
    }

    hasShownStartupDownloadRecoveryPrompt = true
    let alert = UIAlertController(
      title: "发现未完成下载",
      message: "上次有一批照片没有完成下载。是否现在继续？",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "稍后", style: .cancel))
    alert.addAction(UIAlertAction(title: "继续下载", style: .default) { [weak self] _ in
      guard let self else { return }
      _ = self.resumePendingDownloadSessionIfNeeded()
    })
    present(alert, animated: true)
    return true
  }

  private func updateInlineDiscoveredCameras() {
    discoveredCameraStack.arrangedSubviews.forEach { view in
      discoveredCameraStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    guard NativeHomeConnectionPresentationPolicy.resolve(
      requiresSystemBluetoothPairingCleanup: cameraSessionRuntime.requiresSystemBluetoothPairingCleanup,
      isPairingConfirmationBlockingRememberedGalleryEntry: isPairingConfirmationBlockingRememberedGalleryEntry
    ) == .normal else {
      discoveredCameraStack.isHidden = true
      return
    }

    let unpairedCameras = cameras
      .filter { !cameraSessionRuntime.isRememberedCamera($0) }
      .prefix(NativeCameraSearchStartupPolicy.inlineDiscoveredCameraLimit)

    guard NativeCameraSearchStartupPolicy.shouldShowInlineDiscoveredCameraList(
      discoveredCameraCount: unpairedCameras.count
    ) else {
      discoveredCameraStack.isHidden = true
      return
    }

    discoveredCameraStack.isHidden = false
    for camera in unpairedCameras {
      let card = NativeScanCameraCard(
        camera: camera,
        isConnecting: false
      ) { [weak self] in
        self?.beginPairing(with: camera)
      }
      discoveredCameraStack.addArrangedSubview(card)
    }
  }

  private func beginPairing(with camera: IOSCameraDiscoveredCamera) {
    guard presentFreshPairingBluetoothCleanupPromptIfNeeded() else { return }
    cameraSessionRuntime.startPairingConnection(camera: camera) { [weak self] result in
      guard let self, case let .failure(error) = result else { return }
      self.handleConnectFlowFailure(
        title: "无法开始配对",
        error: error,
        hidesOverlay: false,
        resetsRememberedFlow: false
      )
    }
  }

  private func connectRememberedCamera(_ record: IOSCameraRememberedCameraRecord) {
    // Cancel any in-progress probe — user is explicitly connecting now.
    pairingProbeTask?.cancel()
    pairingProbeTask = nil
    cameraSessionRuntime.cancelPairingProbe(reason: "user-initiated-connect")

    isDisconnectingActiveRememberedCamera = false
    if cameraSessionRuntime.publishSystemBluetoothCleanupBlockIfNeeded() {
      logView.text = ""
      isEnteringGalleryFromRememberedCamera = false
      hideConnectingOverlay()
      presentSystemBluetoothPairingCleanupPromptIfNeeded(
        status: CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus,
        isBusy: false
      )
      updateRememberedCameraCard()
      return
    }
    if isPairingConfirmationBlockingRememberedGalleryEntry {
      isEnteringGalleryFromRememberedCamera = false
      hideConnectingOverlay()
      updateRememberedCameraCard()
      return
    }
    cameraSessionRuntime.clearConnectionLogs()
    CameraVendorFileLogger.log(
      "[REMEMBERED_GALLERY_FLOW_START] device=\(record.identity.displayName) peripheralID=\(record.peripheralID)"
    )
    logView.text = ""
    isEnteringGalleryFromRememberedCamera = true
    showConnectingOverlay(deviceName: record.identity.displayName)
    cameraSessionRuntime.startRememberedGalleryConnection(record: record) { [weak self] state in
      guard let self else { return }
      CameraVendorFileLogger.log(
        NativeConnectFlowResultLogPolicy.message(
          state: state,
          peripheralID: record.peripheralID
        )
      )
      switch state {
      case .galleryReady:
        break
      case .failed(let issue):
        self.handleConnectFlowFailure(
          title: "进入相机相册失败",
          error: issue,
          hidesOverlay: true,
          resetsRememberedFlow: true
        )
      default:
        self.hideConnectingOverlay()
        self.isEnteringGalleryFromRememberedCamera = false
      }
    }
    updateRememberedCameraCard()
  }

  private func showConnectingOverlay(deviceName: String) {
    if let existing = connectingOverlay {
      existing.configure(deviceName: deviceName)
      return
    }
    let overlay = NativeConnectingOverlay()
    overlay.configure(deviceName: deviceName)
    overlay.onCancel = { [weak self] in
      guard let self else { return }
      if !self.cameraSessionRuntime.cancelRecoveredDownloadFromConnectionOverlay() {
        self.cancelConnectFlow(reason: "connecting-overlay-user-cancel")
      }
      self.hideConnectingOverlay()
      self.isEnteringGalleryFromRememberedCamera = false
    }
    connectingOverlay = overlay
    overlay.reveal(in: view)
  }

  private func hideConnectingOverlay() {
    connectingOverlay?.hide { [weak self] in
      self?.connectingOverlay = nil
    }
  }

  private func cancelConnectFlow(reason: String) {
    CameraVendorFileLogger.log(
      "[HOME_CONNECT_FLOW_COMMAND] reason=\(reason) workerActive=\(cameraSessionRuntime.isConnectionWorkerActive) " +
      "rememberedEntry=\(isEnteringGalleryFromRememberedCamera)"
    )
    cancelAutoDownloadCatalogObserver()
    pairingProbeTask?.cancel()
    pairingProbeTask = nil
    cameraSessionRuntime.cancelPairingProbe(reason: reason)
    cameraSessionRuntime.cancelConnectionWorker(reason: reason)
  }

  private func forgetRememberedCamera(_ record: IOSCameraRememberedCameraRecord) {
    let alert = UIAlertController(
      title: "删除已配对相机？",
      message: "CamTransfer 只能删除 App 本地记录，不能直接移除 iPhone 本地蓝牙配对。\n\n如果要彻底重新配对，还需要到 iPhone 设置 > 蓝牙里忽略“\(record.identity.displayName)”对应设备。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "只删本地记录", style: .destructive) { [weak self] _ in
      guard let self else { return }
      self.completeForgetRememberedCamera(record)
    })
    alert.addAction(UIAlertAction(title: "删除并查看蓝牙步骤", style: .default) { [weak self] _ in
      guard let self else { return }
      self.completeForgetRememberedCamera(record)
      self.presentSystemBluetoothForgetNotice(for: record.identity.displayName)
    })
    present(alert, animated: true)
  }

  private func completeForgetRememberedCamera(_ record: IOSCameraRememberedCameraRecord) {
    cancelConnectFlow(reason: "forget-remembered-camera")
    galleryEntryTask?.cancel()
    galleryEntryTask = nil
    cameraSessionRuntime.forgetRememberedCamera(peripheralID: record.peripheralID)
    hasConfirmedSystemBluetoothCleanupForFreshPairing = false
    cameras = []
    scanController?.update(cameras: [])
    updateRememberedCameraCard()
    if NativeCameraSearchStartupPolicy.shouldRestartScanningAfterRememberedCameraDeletion {
      cameraSessionRuntime.requestCameraDiscovery()
    }
  }

  private func presentSystemBluetoothForgetNotice(for deviceName: String) {
    UIPasteboard.general.string = deviceName
    let alert = UIAlertController(
      title: "删除本地蓝牙配对",
      message: "已复制设备名“\(deviceName)”。\n\n请到：设置 > 蓝牙 > 找到对应设备 > 忽略此设备，删除本地蓝牙配对。\n\n处理完再回 CamTransfer 重新配对。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "知道了", style: .default))
    present(alert, animated: true)
  }

  @objc private func confirmPairingTapped() {
    cameraSessionRuntime.confirmPairingConnection { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        let finishPairing: () -> Void = {
          self.updateRememberedCameraCard()
          self.statusBadgeLabel.text = "配对完成，点击进入相机相册"
          self.statusBadgeLabel.isHidden = false
        }
        self.dismissPairingUIAfterSuccess(event: .didCompletePairing) {
          finishPairing()
        }
      case .failure(let error):
        self.handleConnectFlowFailure(
          title: "确认配对失败",
          error: error,
          hidesOverlay: false,
          resetsRememberedFlow: false
        )
      }
    }
  }

  @objc private func proEntryTapped() {
    presentCamTransferPaywall()
  }

  private func presentPhonePairingConfirmationPromptIfNeeded(status: String, isBusy: Bool) {
    guard NativePairingConfirmationPresentationPolicy.shouldPresentPhoneConfirmationPrompt(
      status: status,
      isBusy: isBusy
    ) else { return }
    guard !isPresentingPairingConfirmationPrompt else { return }

    isPresentingPairingConfirmationPrompt = true
    let presentPrompt: () -> Void = { [weak self] in
      guard let self else { return }
      let alert = UIAlertController(
        title: "确认配对",
        message: "相机已显示配对成功后，点“确认”返回结果给相机。",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "稍后", style: .cancel) { [weak self] _ in
        self?.isPresentingPairingConfirmationPrompt = false
      })
      alert.addAction(UIAlertAction(title: "确认", style: .default) { [weak self] _ in
        guard let self else { return }
        self.isPresentingPairingConfirmationPrompt = false
        self.confirmPairingTapped()
      })
      self.present(alert, animated: true)
    }

    if let scan = scanController {
      scan.dismiss(animated: true) { [weak self] in
        self?.scanController = nil
        presentPrompt()
      }
    } else {
      presentPrompt()
    }
  }

  private func dismissPairingUIAfterSuccess(
    event: NativePairingSuccessCleanupPolicy.Event,
    completion: (() -> Void)? = nil
  ) {
    guard NativePairingSuccessCleanupPolicy.shouldDismissPairingUI(event: event) else {
      completion?()
      return
    }

    confirmPairingButton.isHidden = true
    isPresentingPairingConfirmationPrompt = false
    isPresentingSystemBluetoothCleanupPrompt = false
    hasConfirmedSystemBluetoothCleanupForFreshPairing = false

    let dismissPromptThenComplete: () -> Void = { [weak self] in
      guard let self else {
        completion?()
        return
      }
      if let alert = self.presentedViewController as? UIAlertController,
         NativePairingSuccessCleanupPolicy.isPairingConfirmationAlert(title: alert.title) {
        alert.dismiss(animated: true, completion: completion)
      } else {
        completion?()
      }
    }

    if let scan = scanController {
      scan.dismiss(animated: true) { [weak self] in
        self?.scanController = nil
        dismissPromptThenComplete()
      }
    } else {
      dismissPromptThenComplete()
    }
  }

  private func finishRememberedGalleryEntryIfPossible() {
    guard let payload = cameraSessionRuntime.galleryPresentationPayload else {
      handleConnectFlowFailure(
        title: "进入相机相册失败",
        error: CameraSessionRuntimeGalleryActivationError.missingGalleryNavigation,
        hidesOverlay: true,
        resetsRememberedFlow: true
      )
      return
    }

    latestServiceStatus = "相机照片读取完成"
    latestServiceIsBusy = false
    statusBadgeLabel.text = latestServiceStatus
    spinner.stopAnimating()
    isEnteringGalleryFromRememberedCamera = false

    let pushGallery: () -> Void = { [weak self] in
      guard let self else { return }
      let rememberedRecord = self.cameraSessionRuntime.rememberedCameraRecords.first(where: {
        $0.peripheralID == payload.rememberedPeripheralID
      })
      let controller = NativeGalleryViewController(
        summary: payload.summary,
        rememberedPeripheralID: rememberedRecord?.peripheralID,
        runtime: self.cameraSessionRuntime
      )
      if self.replaceVisibleGalleryControllerIfNeeded(
        controller,
        rememberedPeripheralID: rememberedRecord?.peripheralID
      ) {
        return
      }
      self.navigationController?.pushViewController(controller, animated: true)
    }

    if NativeGalleryEntryNavigationPolicy.shouldPushGalleryBeforeDismissingPairingUI {
      pushGallery()
      if NativeGalleryEntryNavigationPolicy.shouldHideConnectingOverlayAfterGalleryPush {
        hideConnectingOverlay()
      }
      dismissPairingUIAfterSuccess(event: .didCompleteHandshake)
    } else if connectingOverlay != nil {
      hideConnectingOverlay()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
        self?.dismissPairingUIAfterSuccess(event: .didCompleteHandshake) {
          pushGallery()
        }
      }
    } else {
      dismissPairingUIAfterSuccess(event: .didCompleteHandshake) {
        pushGallery()
      }
    }
  }

  private func routeRuntimePresentationDestination(
    _ destination: CameraSessionRuntimePresentationDestination
  ) {
    switch destination {
    case .gallery(_):
      if isAutoDownloadPending {
        isAutoDownloadPending = false
        startAutoDownload()
      } else {
        finishRememberedGalleryEntryIfPossible()
      }
    case .recoveryDownloadCenter(let payload):
      finishRecoveredDownloadEntryIfPossible(payload: payload)
    }
  }

  private func startAutoDownload() {
    guard cameraSessionRuntime.galleryPresentationPayload != nil else {
      CameraVendorFileLogger.log("[AUTO_DOWNLOAD] no gallery payload, aborting auto-download")
      finishAutoDownloadWithoutNavigation(status: "自动下载失败：连接异常")
      return
    }
    let catalog = cameraSessionRuntime.presentation.catalog
    CameraVendorFileLogger.log(
      "[AUTO_DOWNLOAD] checking rule=\(autoDownloadRule.summaryText) " +
      "catalogState=\(catalog.state) items=\(catalog.items.count)"
    )

    // If catalog isn't ready yet, wait for it to become ready
    guard case .ready = catalog.state, !catalog.items.isEmpty else {
      CameraVendorFileLogger.log("[AUTO_DOWNLOAD] catalog not ready, waiting for catalog...")
      waitForCatalogThenAutoDownload()
      return
    }

    let items = catalog.items
    let savedHandles = cameraSessionRuntime.savedDownloadHandles()

    // For HEIF format rule, we need the HEIF handle set (from subtractBaseline).
    // Use the catalog's full handle set minus the baseline (ALL directory = non-HEIF).
    // The initial catalog was loaded via D604=2 which returns ALL+HEIF (~2427).
    // We need to identify which handles are HEIF-only.
    // For now, if format requires HEIF, fetch the baseline and subtract.
    let needsHeifHandles = [.heif, .jpgAndHeif].contains(autoDownloadRule.format)

    if needsHeifHandles {
      // Async fetch the baseline to compute HEIF handles
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          let baselineSnapshot = try await self.cameraSessionRuntime.fetchBaselineCatalog()
          let baselineSet = Set(baselineSnapshot.orderedHandles.map { Int($0) })
          let heifHandles = Set(items.map(\.handle)).subtracting(baselineSet)
          CameraVendorFileLogger.log("[AUTO_DOWNLOAD] heifHandles=\(heifHandles.count) baseline=\(baselineSet.count)")
          self.executeAutoDownload(items: items, savedHandles: savedHandles, heifHandles: heifHandles)
        } catch {
          CameraVendorFileLogger.log("[AUTO_DOWNLOAD] baseline fetch failed: \(error.localizedDescription)")
          self.finishAutoDownloadWithoutNavigation(status: "自动下载失败：无法获取格式信息")
        }
      }
    } else {
      executeAutoDownload(items: items, savedHandles: savedHandles, heifHandles: [])
    }
  }

  private func executeAutoDownload(
    items: [CameraVendorGalleryItem],
    savedHandles: Set<Int>,
    heifHandles: Set<Int>
  ) {
    let matchedHandles = CameraAutoDownloadRuleFilter.matchingHandles(
      items: items,
      rule: autoDownloadRule,
      savedHandles: savedHandles,
      heifHandles: heifHandles
    )

    CameraVendorFileLogger.log(
      "[AUTO_DOWNLOAD] rule=\(autoDownloadRule.summaryText) " +
      "totalItems=\(items.count) matched=\(matchedHandles.count)"
    )

    guard !matchedHandles.isEmpty else {
      CameraVendorFileLogger.log("[AUTO_DOWNLOAD] no matching photos for rule")
      finishAutoDownloadWithoutNavigation(status: "没有匹配的新照片")
      let alert = UIAlertController(
        title: "没有匹配的新照片",
        message: "当前规则「\(autoDownloadRule.summaryText)」没有匹配到需要下载的照片。",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "好", style: .default))
      present(alert, animated: true)
      return
    }

    cameraSessionRuntime.send(
      .startDownload(handles: matchedHandles, mode: autoDownloadRule.downloadMode.transferMode)
    )

    latestServiceStatus = "自动下载 \(matchedHandles.count) 张"
    statusBadgeLabel.text = latestServiceStatus
    spinner.stopAnimating()
    isEnteringGalleryFromRememberedCamera = false

    let pushDownloadCenter: () -> Void = { [weak self] in
      guard let self else { return }
      let controller = NativeDownloadListViewController(
        runtime: self.cameraSessionRuntime,
        itemsProvider: { [weak runtime = self.cameraSessionRuntime] in
          guard let runtime else { return [] }
          return runtime.presentation.catalog.items.filter { runtime.downloadState(for: $0.handle) != .idle }
        },
        stateProvider: { [weak runtime = self.cameraSessionRuntime] handle in
          runtime?.downloadState(for: handle) ?? .idle
        },
        progressProvider: { [weak runtime = self.cameraSessionRuntime] handle in
          runtime?.downloadProgressText(for: handle)
        },
        isTransferActiveProvider: { [weak runtime = self.cameraSessionRuntime] in
          runtime?.canCancelDownload == true
        },
        onTerminateDownload: { [weak self] in
          self?.cameraSessionRuntime.send(.cancelDownloadByUser)
        },
        onClearDownloadCache: { [weak self] item in
          self?.cameraSessionRuntime.send(.clearSavedDownloadHistory(handle: UInt32(item.handle)))
        }
      )
      controller.onMovedFromParent = { [weak self] in
        guard let self else { return }
        self.cameraSessionRuntime.onDownloadThumbnailGenerated = nil
        if self.autoDownloadRule.disconnectAfterDownload {
          self.cameraSessionRuntime.send(.disconnectCamera(reason: "auto-download-complete-disconnect"))
        }
        self.updateRememberedCameraCard()
      }
      // Wire thumbnail generation: when a file finishes downloading, its thumbnail
      // is generated from the temp file and displayed immediately in the download center
      self.cameraSessionRuntime.onDownloadThumbnailGenerated = { [weak controller] handle, image in
        guard let controller else { return }
        controller.setDownloadThumbnail(handle: Int(handle), image: image)
      }
      self.navigationController?.pushViewController(controller, animated: true)
    }

    hideConnectingOverlay()
    dismissPairingUIAfterSuccess(event: .didCompleteHandshake) {
      pushDownloadCenter()
    }
  }

  /// Auto-download determined there is nothing to download (or failed to start).
  /// Stay on the connect page — do NOT push gallery or download center.
  private func finishAutoDownloadWithoutNavigation(status: String) {
    cancelAutoDownloadCatalogObserver()
    latestServiceStatus = status
    statusBadgeLabel.text = status
    spinner.stopAnimating()
    isEnteringGalleryFromRememberedCamera = false
    hideConnectingOverlay()
    updateRememberedCameraCard()
  }

  /// Wait for catalog to become ready, then execute auto-download.
  /// Registers a presentation observer and fires startAutoDownload() once
  /// the catalog state transitions to .ready with items.
  private func waitForCatalogThenAutoDownload() {
    cancelAutoDownloadCatalogObserver()
    autoDownloadCatalogObserverID = cameraSessionRuntime.observe { [weak self] presentation in
      guard let self else { return }
      switch presentation.catalog.state {
      case .ready:
        guard !presentation.catalog.items.isEmpty else { return }
        self.cancelAutoDownloadCatalogObserver()
        self.startAutoDownload()
      case .failed, .transportLost, .unsupported:
        CameraVendorFileLogger.log("[AUTO_DOWNLOAD] catalog failed while waiting, aborting")
        self.finishAutoDownloadWithoutNavigation(status: "自动下载失败：相册加载失败")
      case .loading, .unavailable:
        break
      }
    }
  }

  private func cancelAutoDownloadCatalogObserver() {
    if let id = autoDownloadCatalogObserverID {
      cameraSessionRuntime.removeObserver(id)
      autoDownloadCatalogObserverID = nil
    }
  }

  private func finishRecoveredDownloadEntryIfPossible(
    payload: CameraSessionRuntimeGalleryPresentationPayload
  ) {
    latestServiceStatus = "正在恢复下载"
    latestServiceIsBusy = false
    statusBadgeLabel.text = latestServiceStatus
    spinner.stopAnimating()
    isEnteringGalleryFromRememberedCamera = false

    let pushDownloadCenter: () -> Void = { [weak self] in
      guard let self,
            !(self.navigationController?.topViewController is NativeDownloadListViewController) else {
        return
      }
      let controller = NativeDownloadListViewController(
        runtime: self.cameraSessionRuntime,
        itemsProvider: { [weak runtime = self.cameraSessionRuntime] in
          guard let runtime else { return [] }
          return runtime.presentation.catalog.items.filter { runtime.downloadState(for: $0.handle) != .idle }
        },
        stateProvider: { [weak runtime = self.cameraSessionRuntime] handle in
          runtime?.downloadState(for: handle) ?? .idle
        },
        progressProvider: { [weak runtime = self.cameraSessionRuntime] handle in
          runtime?.downloadProgressText(for: handle)
        },
        isTransferActiveProvider: { [weak runtime = self.cameraSessionRuntime] in
          runtime?.canCancelDownload == true
        },
        onTerminateDownload: { [weak runtime = self.cameraSessionRuntime] in
          runtime?.send(.cancelDownloadByUser)
        },
        onClearDownloadCache: { [weak runtime = self.cameraSessionRuntime] item in
          runtime?.send(.clearSavedDownloadHistory(handle: UInt32(item.handle)))
        }
      )
      self.navigationController?.pushViewController(controller, animated: true)
    }

    hideConnectingOverlay()
    dismissPairingUIAfterSuccess(event: .didCompleteHandshake) {
      pushDownloadCenter()
    }
  }

  private func handleConnectFlowFailure(
    title: String,
    error: Error,
    hidesOverlay: Bool,
    resetsRememberedFlow: Bool
  ) {
    let message = error.localizedDescription
    latestServiceStatus = message
    latestServiceIsBusy = false
    statusBadgeLabel.text = message
    statusBadgeLabel.isHidden = false
    spinner.stopAnimating()
    if hidesOverlay {
      hideConnectingOverlay()
    } else {
      connectingOverlay?.update(status: message)
    }
    scanController?.update(status: message, isBusy: false)
    if resetsRememberedFlow {
      isEnteringGalleryFromRememberedCamera = false
    }
    updateRememberedCameraCard()
    presentNotice(title: title, message: message)
  }

  private func presentSystemBluetoothPairingCleanupPromptIfNeeded(status: String, isBusy: Bool) {
    guard status == CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus, !isBusy else { return }
    guard !isPresentingSystemBluetoothCleanupPrompt else { return }

    isPresentingSystemBluetoothCleanupPrompt = true
    hideConnectingOverlay()
    let presentPrompt: () -> Void = { [weak self] in
      guard let self else { return }
      self.presentBluetoothCleanupConfirmationPrompt(
        title: "需要删除本地蓝牙配对",
        message: "iPhone 本地蓝牙里还保留这台相机的旧配对。请到：设置 > 蓝牙 > 找到相机 > 忽略此设备，删除本地蓝牙配对，然后回到 CamTransfer 重新配对。",
        openBluetoothTitle: NativeFreshPairingSystemBluetoothCleanupPrompt.openBluetoothTitle,
        confirmTitle: NativeFreshPairingSystemBluetoothCleanupPrompt.confirmTitle,
        checkboxTitle: NativeFreshPairingSystemBluetoothCleanupPrompt.checkboxTitle,
        onDismiss: { [weak self] in
          self?.isPresentingSystemBluetoothCleanupPrompt = false
        },
        onConfirm: { [weak self] in
          self?.completeSystemBluetoothCleanupForRepair()
        }
      )
    }

    if let scan = scanController {
      scan.dismiss(animated: true) { [weak self] in
        self?.scanController = nil
        presentPrompt()
      }
    } else {
      presentPrompt()
    }
  }

  private func completeSystemBluetoothCleanupForRepair() {
    confirmDeletedBluetoothAndStartFreshPairing()
  }

  @objc private func copyLogsTapped() {
    UIPasteboard.general.string = CamTransferDiagnosticLogRedactor.redacted(cameraSessionRuntime.connectionLogText)
    presentNotice(title: "已复制", message: "连接日志已经复制到剪贴板")
  }

  @objc private func shareLogsTapped() {
    do {
      let exportURL = try CamTransferDiagnosticLogExporter.makeExportFile(
        sourceLogURLs: [cameraSessionRuntime.connectionLogFileURL, CameraVendorFileLogger.logFileURL].compactMap { $0 }
      )
      let activity = UIActivityViewController(
        activityItems: [exportURL],
        applicationActivities: nil
      )
      present(activity, animated: true)
    } catch {
      presentNotice(title: "导出失败", message: error.localizedDescription)
    }
  }

  private func presentNotice(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "知道了", style: .default))
    let presenter = navigationController?.visibleViewController ?? self
    presenter.present(alert, animated: true)
  }

  private func refreshPairingConfirmationButton(for status: String, isBusy: Bool) {
    confirmPairingButton.isHidden = status != CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus
    confirmPairingButton.isEnabled = !isBusy
  }

  private func updateRememberedCameraCard() {
    switch NativeHomeConnectionPresentationPolicy.resolve(
      requiresSystemBluetoothPairingCleanup: cameraSessionRuntime.requiresSystemBluetoothPairingCleanup,
      isPairingConfirmationBlockingRememberedGalleryEntry: isPairingConfirmationBlockingRememberedGalleryEntry
    ) {
    case .systemBluetoothCleanup:
      showSystemBluetoothCleanupBlockedHome()
      return
    case .pairingConfirmation:
      hideRememberedGalleryEntryDuringPairingConfirmation()
      return
    case .normal:
      break
    }

    let records = cameraSessionRuntime.rememberedCameraRecords
    modeLabel.text = NativeHomeAndroidParityCopy.modeLabel(
      hasRememberedCamera: !records.isEmpty,
      isBusy: latestServiceIsBusy,
      status: latestServiceStatus
    )
    if records.isEmpty {
      hidePairedCard()
    } else {
      showPairedCards(records: records)
    }
  }

  private var isPairingConfirmationBlockingRememberedGalleryEntry: Bool {
    isPresentingPairingConfirmationPrompt
      || latestServiceStatus == CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus
  }

  private func hideRememberedGalleryEntryDuringPairingConfirmation() {
    pairedCameraStack.arrangedSubviews.forEach { view in
      pairedCameraStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    discoveredCameraStack.arrangedSubviews.forEach { view in
      discoveredCameraStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    pairedCameraStack.isHidden = true
    pairingPreparationStack.isHidden = true
    discoveredCameraStack.isHidden = true
    startPairingButton.isHidden = true
    modeLabel.text = "正在确认蓝牙配对"
    statusBadgeLabel.text = CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus
    statusBadgeLabel.isHidden = false
    spinner.stopAnimating()
  }

  private func showSystemBluetoothCleanupBlockedHome() {
    pairedCameraStack.arrangedSubviews.forEach { view in
      pairedCameraStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    discoveredCameraStack.arrangedSubviews.forEach { view in
      discoveredCameraStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    pairedCameraStack.isHidden = true
    pairingPreparationStack.isHidden = true
    discoveredCameraStack.isHidden = true
    startPairingButton.setTitle("删除旧蓝牙后重新配对", for: .normal)
    startPairingButton.isHidden = false
    confirmPairingButton.isHidden = true
    modeLabel.text = "蓝牙配对已失效"
    statusBadgeLabel.text = CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus
    statusBadgeLabel.isHidden = false
    spinner.stopAnimating()
  }

  private func showPairedCards(records: [IOSCameraRememberedCameraRecord]) {
    pairedCameraStack.arrangedSubviews.forEach { view in
      pairedCameraStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    pairedCameraStack.isHidden = false
    pairingPreparationStack.isHidden = true
    startPairingButton.isHidden = true
    for record in records {
      let isActiveSession = cameraSessionRuntime.activeCameraIdentity?.peripheralID == record.peripheralID
      let presence = NativeHomeRememberedCameraPresencePolicy.presence(
        rememberedPeripheralID: record.peripheralID,
        discoveredCameraIDs: cameras.map(\.id),
        status: latestServiceStatus,
        isBusy: latestServiceIsBusy,
        hasActiveRememberedCameraSession: isActiveSession
      )
      let card = NativePairedCameraCard(
        record: record,
        presence: presence,
        primaryActionTitle: NativeHomeCameraCardCopyPolicy.pairedActionTitle,
        showsDisconnectAction: isActiveSession && !isDisconnectingActiveRememberedCamera,
        quickDownloadSummary: autoDownloadRule.isEnabled ? autoDownloadRule.summaryText : "首次需设置参数",
        onQuickDownload: { [weak self] in
          self?.quickDownloadTapped(record: record)
        },
        onQuickDownloadSettings: { [weak self] in
          self?.autoDownloadSettingsTapped()
        },
        onConnect: { [weak self] in
          guard let self else { return }
          if isActiveSession, let payload = self.cameraSessionRuntime.galleryPresentationPayload {
            // Session still alive — push Gallery instantly without reconnecting
            let controller = NativeGalleryViewController(
              summary: payload.summary,
              rememberedPeripheralID: record.peripheralID,
              runtime: self.cameraSessionRuntime
            )
            self.navigationController?.pushViewController(controller, animated: true)
          } else {
            self.connectRememberedCamera(record)
          }
        },
        onDisconnect: { [weak self] in
          self?.disconnectActiveRememberedCamera(record)
        },
        onForget: { [weak self] in
          self?.forgetRememberedCamera(record)
        }
      )
      pairedCameraStack.addArrangedSubview(card)
    }

    confirmPairingButton.isHidden = true
  }

  private func quickDownloadTapped(record: IOSCameraRememberedCameraRecord) {
    switch NativeHomeQuickDownloadEntryPolicy.action(ruleIsEnabled: autoDownloadRule.isEnabled) {
    case .configure:
      let controller = NativeAutoDownloadSettingsViewController(
        rule: autoDownloadRule,
        saveButtonTitle: "开始下载",
        forcesEnabledOnSave: true
      ) { [weak self] updatedRule in
        guard let self else { return }
        self.autoDownloadRule = updatedRule
        CameraAutoDownloadRuleStore.save(updatedRule)
        self.updateRememberedCameraCard()
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.beginQuickDownload(record: record)
        }
      }
      navigationController?.pushViewController(controller, animated: true)
    case .start:
      beginQuickDownload(record: record)
    }
  }

  /// If session is already active for this camera, execute auto-download
  /// immediately without reconnecting. Otherwise start a new connection.
  private func beginQuickDownload(record: IOSCameraRememberedCameraRecord) {
    let isActiveSession = cameraSessionRuntime.activeCameraIdentity?.peripheralID == record.peripheralID
    if isActiveSession, cameraSessionRuntime.galleryPresentationPayload != nil {
      // Session still alive — run auto-download directly
      startAutoDownload()
    } else {
      isAutoDownloadPending = true
      connectRememberedCamera(record)
    }
  }

  @objc private func autoDownloadSettingsTapped() {
    let controller = NativeAutoDownloadSettingsViewController(
      rule: autoDownloadRule
    ) { [weak self] updatedRule in
      guard let self else { return }
      self.autoDownloadRule = updatedRule
      CameraAutoDownloadRuleStore.save(updatedRule)
      self.updateRememberedCameraCard()
    }
    navigationController?.pushViewController(controller, animated: true)
  }

  private func rememberedCameraRecord(for peripheralID: UUID) -> IOSCameraRememberedCameraRecord? {
    cameraSessionRuntime.rememberedCameraRecords.first(where: { $0.peripheralID == peripheralID })
  }

  private func currentTopGalleryController() -> NativeGalleryViewController? {
    navigationController?.topViewController as? NativeGalleryViewController
  }

  @discardableResult
  private func replaceVisibleGalleryControllerIfNeeded(
    _ controller: NativeGalleryViewController,
    rememberedPeripheralID: UUID?
  ) -> Bool {
    guard let navigationController,
          let currentGallery = currentTopGalleryController(),
          currentGallery.activeRememberedPeripheralID == rememberedPeripheralID else {
      return false
    }
    var viewControllers = navigationController.viewControllers
    guard !viewControllers.isEmpty else { return false }
    viewControllers.removeLast()
    viewControllers.append(controller)
    navigationController.setViewControllers(viewControllers, animated: false)
    return true
  }

  private func disconnectActiveRememberedCamera(_ record: IOSCameraRememberedCameraRecord) {
    guard !isDisconnectingActiveRememberedCamera else {
      return
    }
    guard cameraSessionRuntime.activeCameraIdentity?.peripheralID == record.peripheralID else {
      return
    }
    isDisconnectingActiveRememberedCamera = true
    cancelConnectFlow(reason: "home-disconnect-active-camera-session")
    galleryEntryTask?.cancel()
    galleryEntryTask = nil
    hideConnectingOverlay()
    isEnteringGalleryFromRememberedCamera = false
    cameraSessionRuntime.send(.disconnectCamera(reason: "home-disconnect-active-camera-session"))
    updateRememberedCameraCard()
  }

  private func hidePairedCard() {
    pairedCameraStack.arrangedSubviews.forEach { view in
      pairedCameraStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    pairedCameraStack.isHidden = true
    pairingPreparationStack.isHidden = false
    startPairingButton.setTitle(NativeHomeAndroidParityCopy.startPairingTitle, for: .normal)
    startPairingButton.isHidden = false

    confirmPairingButton.isHidden = true
  }

  private func badgeText(for deviceName: String) -> String {
    let upper = deviceName.uppercased()
    return String(upper.filter { $0.isLetter }.prefix(2))
  }
}

extension NativeConnectViewController: WiredCameraImportServiceDelegate {
  func wiredCameraImportServiceDidUpdateAuthorization(_ service: WiredCameraImportService, isAuthorized: Bool) {
    CameraVendorMainThread.run { [weak self] in
      self?.refreshWiredImportButton()
    }
  }

  func wiredCameraImportServiceDidUpdateDevices(
    _ service: WiredCameraImportService,
    devices: [WiredCameraImportDevice]
  ) {
    CameraVendorMainThread.run { [weak self] in
      self?.wiredImportDevices = devices
      self?.refreshWiredImportButton()
    }
  }

  func wiredCameraImportServiceDidStartLoadingItems(_ service: WiredCameraImportService) {}

  func wiredCameraImportService(
    _ service: WiredCameraImportService,
    didUpdateItems items: [WiredCameraImportItem]
  ) {}

  func wiredCameraImportService(
    _ service: WiredCameraImportService,
    didUpdateThumbnailFor itemID: String,
    thumbnail: UIImage
  ) {}

  func wiredCameraImportService(_ service: WiredCameraImportService, didFailWith message: String) {
    CameraVendorMainThread.run { [weak self] in
      self?.wiredImportDevices = []
      self?.refreshWiredImportButton()
    }
  }
}

final class NativeWifiPromptOverlay: UIView {
  var onOpenSettings: (() -> Void)?
  var onRetry: (() -> Void)?
  private var passphrase: String?

  private let backdrop: UIVisualEffectView = {
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let dimView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = NativeLuxuryTheme.background.withAlphaComponent(0.55)
    return view
  }()

  private let card: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    NativeLuxuryTheme.applyCardStyle(view, radius: 32)
    return view
  }()

  private let brandLabel = NativeLuxuryTheme.makeBrandLabel("CAMERA WI-FI", size: 9)

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "需要连接相机 Wi-Fi"
    label.font = .systemFont(ofSize: 24, weight: .heavy)
    label.textColor = NativeLuxuryTheme.ink
    label.textAlignment = .center
    label.numberOfLines = 2
    return label
  }()

  private let wifiArt: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.cornerRadius = 36
    view.backgroundColor = UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1)
    view.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    view.layer.borderWidth = 1
    let icon = UIImageView(image: UIImage(systemName: "wifi", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)))
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.tintColor = NativeLuxuryTheme.accent
    view.addSubview(icon)
    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    return view
  }()

  private let ssidChip: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .heavy)
    label.textColor = NativeLuxuryTheme.ink
    label.textAlignment = .center
    label.backgroundColor = UIColor.white.withAlphaComponent(0.9)
    label.layer.cornerRadius = 10
    label.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    label.layer.borderWidth = 1
    label.clipsToBounds = true
    return label
  }()

  private let copyLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.numberOfLines = 0
    label.textAlignment = .center
    label.text = "在「设置 › Wi‑Fi」里选上面这个网络，回到 CamTransfer 会自动继续。"
    return label
  }()

  private let passwordButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.tinted()
    config.cornerStyle = .capsule
    config.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    config.imagePadding = 6
    config.baseForegroundColor = NativeLuxuryTheme.ink
    config.attributedTitle = AttributedString("复制 Wi-Fi 密码", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
    ]))
    button.configuration = config
    button.isHidden = true
    return button
  }()

  private let openSettingsButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("去连接 Wi-Fi", for: .normal)
    NativeLuxuryTheme.stylePrimaryButton(button)
    NativeLuxuryTheme.setIcon("arrow.up.right", on: button)
    return button
  }()

  private let retryButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.plain()
    config.attributedTitle = AttributedString("我已连接，重试", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
      .foregroundColor: NativeLuxuryTheme.secondaryInk
    ]))
    button.configuration = config
    return button
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(ssidHint: String?, passphrase: String? = nil) {
    if let ssid = ssidHint, !ssid.isEmpty {
      ssidChip.text = "  \(ssid)  "
      ssidChip.isHidden = false
    } else {
      ssidChip.text = "  连接相机的 CAMERA-XXXX 网络  "
      ssidChip.isHidden = false
    }
    let trimmedPassword = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.passphrase = trimmedPassword?.isEmpty == false ? trimmedPassword : nil
    if let passphrase = self.passphrase {
      passwordButton.isHidden = false
      passwordButton.configuration?.attributedTitle = AttributedString("复制密码 \(passphrase)", attributes: AttributeContainer([
        .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
      ]))
    } else {
      passwordButton.isHidden = true
    }
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    isUserInteractionEnabled = true
    addSubview(backdrop)
    addSubview(dimView)
    addSubview(card)
    card.addSubview(brandLabel)
    card.addSubview(titleLabel)
    card.addSubview(wifiArt)
    card.addSubview(ssidChip)
    card.addSubview(copyLabel)
    card.addSubview(passwordButton)
    card.addSubview(openSettingsButton)
    card.addSubview(retryButton)

    openSettingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
    passwordButton.addTarget(self, action: #selector(copyPasswordTapped), for: .touchUpInside)
    retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      backdrop.topAnchor.constraint(equalTo: topAnchor),
      backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
      backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

      dimView.topAnchor.constraint(equalTo: topAnchor),
      dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
      dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dimView.bottomAnchor.constraint(equalTo: bottomAnchor),

      card.centerYAnchor.constraint(equalTo: centerYAnchor),
      card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
      card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),

      brandLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
      brandLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),

      titleLabel.topAnchor.constraint(equalTo: brandLabel.bottomAnchor, constant: 10),
      titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
      titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

      wifiArt.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 22),
      wifiArt.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      wifiArt.widthAnchor.constraint(equalToConstant: 88),
      wifiArt.heightAnchor.constraint(equalToConstant: 72),

      ssidChip.topAnchor.constraint(equalTo: wifiArt.bottomAnchor, constant: 14),
      ssidChip.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      ssidChip.heightAnchor.constraint(equalToConstant: 26),

      copyLabel.topAnchor.constraint(equalTo: ssidChip.bottomAnchor, constant: 14),
      copyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
      copyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

      passwordButton.topAnchor.constraint(equalTo: copyLabel.bottomAnchor, constant: 14),
      passwordButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      passwordButton.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 22),
      passwordButton.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -22),

      openSettingsButton.topAnchor.constraint(equalTo: passwordButton.bottomAnchor, constant: 14),
      openSettingsButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
      openSettingsButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),

      retryButton.topAnchor.constraint(equalTo: openSettingsButton.bottomAnchor, constant: 6),
      retryButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      retryButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
    ])
  }

  func reveal(in container: UIView) {
    container.addSubview(self)
    NSLayoutConstraint.activate([
      topAnchor.constraint(equalTo: container.topAnchor),
      leadingAnchor.constraint(equalTo: container.leadingAnchor),
      trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    alpha = 0
    card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
    UIView.animate(withDuration: 0.26, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.4, animations: {
      self.alpha = 1
      self.card.transform = .identity
    })
  }

  func hide(completion: (() -> Void)? = nil) {
    UIView.animate(withDuration: 0.18, animations: {
      self.alpha = 0
      self.card.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
    }, completion: { _ in
      self.removeFromSuperview()
      completion?()
    })
  }

  @objc private func settingsTapped() {
    onOpenSettings?()
  }

  @objc private func copyPasswordTapped() {
    guard let passphrase else { return }
    UIPasteboard.general.string = passphrase
    passwordButton.configuration?.attributedTitle = AttributedString("密码已复制", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
    ]))
   }

  @objc private func retryTapped() {
    onRetry?()
  }
}

final class NativeGradientChromeView: UIView {
  enum Direction {
    case topToBottom
    case bottomToTop
  }

  private let gradientLayer = CAGradientLayer()
  private let direction: Direction

  init(direction: Direction) {
    self.direction = direction
    super.init(frame: .zero)
    isUserInteractionEnabled = true
    backgroundColor = .clear
    let strong = UIColor.black.withAlphaComponent(0.62).cgColor
    let mid = UIColor.black.withAlphaComponent(0.32).cgColor
    let clear = UIColor.black.withAlphaComponent(0.0).cgColor
    switch direction {
    case .topToBottom:
      gradientLayer.colors = [strong, mid, clear]
      gradientLayer.locations = [0.0, 0.55, 1.0]
    case .bottomToTop:
      gradientLayer.colors = [clear, mid, strong]
      gradientLayer.locations = [0.0, 0.45, 1.0]
    }
    layer.addSublayer(gradientLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradientLayer.frame = bounds
    bringChromeChildrenForward()
  }

  private func bringChromeChildrenForward() {
    for sub in subviews where sub.layer != gradientLayer {
      bringSubviewToFront(sub)
    }
  }
}

final class NativeDateRangePickerController: UIViewController {
  private let onCancel: () -> Void
  private let onConfirm: (Date, Date) -> Void
  private let initialFrom: Date
  private let initialTo: Date

  private let brand = NativeLuxuryTheme.makeBrandLabel("CAPTURE DATE", size: 9)
  private let titleLabel = NativeLuxuryTheme.makeTitleLabel("筛选拍摄日期", size: 24)

  private let fromHeader: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "开始"
    label.font = .systemFont(ofSize: 11, weight: .heavy)
    label.textColor = NativeLuxuryTheme.accent
    label.letterSpacing = 1.4
    return label
  }()

  private let toHeader: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "结束"
    label.font = .systemFont(ofSize: 11, weight: .heavy)
    label.textColor = NativeLuxuryTheme.accent
    label.letterSpacing = 1.4
    return label
  }()

  private let fromPicker: UIDatePicker = {
    let picker = UIDatePicker()
    picker.translatesAutoresizingMaskIntoConstraints = false
    picker.datePickerMode = .date
    picker.preferredDatePickerStyle = .compact
    picker.maximumDate = Date()
    picker.tintColor = NativeLuxuryTheme.ink
    return picker
  }()

  private let toPicker: UIDatePicker = {
    let picker = UIDatePicker()
    picker.translatesAutoresizingMaskIntoConstraints = false
    picker.datePickerMode = .date
    picker.preferredDatePickerStyle = .compact
    picker.maximumDate = Date()
    picker.tintColor = NativeLuxuryTheme.ink
    return picker
  }()

  private let confirmButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("应用筛选", for: .normal)
    NativeLuxuryTheme.stylePrimaryButton(button)
    NativeLuxuryTheme.setIcon("line.3.horizontal.decrease.circle", on: button)
    return button
  }()

  private let cancelButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.plain()
    config.attributedTitle = AttributedString("取消", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
      .foregroundColor: NativeLuxuryTheme.secondaryInk
    ]))
    button.configuration = config
    return button
  }()

  init(
    initialFrom: Date,
    initialTo: Date,
    onCancel: @escaping () -> Void,
    onConfirm: @escaping (Date, Date) -> Void
  ) {
    self.initialFrom = initialFrom
    self.initialTo = initialTo
    self.onCancel = onCancel
    self.onConfirm = onConfirm
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = NativeLuxuryTheme.background

    fromPicker.date = initialFrom
    toPicker.date = initialTo

    let headerStack = UIStackView(arrangedSubviews: [brand, titleLabel])
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    headerStack.axis = .vertical
    headerStack.spacing = 6

    let fromCard = makeFieldCard(headerLabel: fromHeader, picker: fromPicker)
    let toCard = makeFieldCard(headerLabel: toHeader, picker: toPicker)

    let fieldsStack = UIStackView(arrangedSubviews: [fromCard, toCard])
    fieldsStack.translatesAutoresizingMaskIntoConstraints = false
    fieldsStack.axis = .vertical
    fieldsStack.spacing = 12

    view.addSubview(headerStack)
    view.addSubview(fieldsStack)
    view.addSubview(confirmButton)
    view.addSubview(cancelButton)

    confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
      headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
      headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),

      fieldsStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 22),
      fieldsStack.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
      fieldsStack.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),

      confirmButton.topAnchor.constraint(equalTo: fieldsStack.bottomAnchor, constant: 24),
      confirmButton.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
      confirmButton.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),

      cancelButton.topAnchor.constraint(equalTo: confirmButton.bottomAnchor, constant: 6),
      cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
    ])
  }

  private func makeFieldCard(headerLabel: UILabel, picker: UIDatePicker) -> UIView {
    let card = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    NativeLuxuryTheme.applyCardStyle(card, radius: 22)
    card.addSubview(headerLabel)
    card.addSubview(picker)
    NSLayoutConstraint.activate([
      headerLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
      headerLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),

      picker.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
      picker.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
      picker.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
      picker.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
    ])
    return card
  }

  @objc private func confirmTapped() {
    onConfirm(fromPicker.date, toPicker.date)
  }

  @objc private func cancelTapped() {
    onCancel()
  }
}

final class NativeConnectingOverlay: UIView {
  var onCancel: (() -> Void)?

  private let backdrop: UIVisualEffectView = {
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let dimView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = NativeLuxuryTheme.background.withAlphaComponent(0.55)
    return view
  }()

  private let card: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    NativeLuxuryTheme.applyCardStyle(view, radius: 32)
    return view
  }()

  private let brandLabel = NativeLuxuryTheme.makeBrandLabel("CONNECTING", size: 9)

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 2
    label.textAlignment = .center
    label.text = "正在连接相机"
    label.font = .systemFont(ofSize: 24, weight: .heavy)
    label.textColor = NativeLuxuryTheme.ink
    return label
  }()

  private let loaderRing: NativeLoaderRingView = {
    let view = NativeLoaderRingView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let stepBadge: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "当前步骤"
    label.font = .systemFont(ofSize: 11, weight: .heavy)
    label.textColor = NativeLuxuryTheme.accent
    label.letterSpacing = 1.6
    label.textAlignment = .center
    return label
  }()

  private let statusLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "正在准备..."
    label.font = .systemFont(ofSize: 16, weight: .semibold)
    label.textColor = NativeLuxuryTheme.ink
    label.numberOfLines = 0
    label.textAlignment = .center
    return label
  }()

  private let helperLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "保持相机靠近 iPhone，画面会自动跳转。"
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.numberOfLines = 0
    label.textAlignment = .center
    return label
  }()

  private let cancelButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.plain()
    config.attributedTitle = AttributedString("取消", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
      .foregroundColor: NativeLuxuryTheme.secondaryInk
    ]))
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
    button.configuration = config
    return button
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    isUserInteractionEnabled = true
    addSubview(backdrop)
    addSubview(dimView)
    addSubview(card)
    card.addSubview(brandLabel)
    card.addSubview(titleLabel)
    card.addSubview(loaderRing)
    card.addSubview(stepBadge)
    card.addSubview(statusLabel)
    card.addSubview(helperLabel)
    card.addSubview(cancelButton)

    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      backdrop.topAnchor.constraint(equalTo: topAnchor),
      backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
      backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

      dimView.topAnchor.constraint(equalTo: topAnchor),
      dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
      dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dimView.bottomAnchor.constraint(equalTo: bottomAnchor),

      card.centerYAnchor.constraint(equalTo: centerYAnchor),
      card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
      card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),

      brandLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
      brandLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),

      titleLabel.topAnchor.constraint(equalTo: brandLabel.bottomAnchor, constant: 10),
      titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
      titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

      loaderRing.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
      loaderRing.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      loaderRing.widthAnchor.constraint(equalToConstant: 86),
      loaderRing.heightAnchor.constraint(equalToConstant: 86),

      stepBadge.topAnchor.constraint(equalTo: loaderRing.bottomAnchor, constant: 22),
      stepBadge.centerXAnchor.constraint(equalTo: card.centerXAnchor),

      statusLabel.topAnchor.constraint(equalTo: stepBadge.bottomAnchor, constant: 6),
      statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
      statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

      helperLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
      helperLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
      helperLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

      cancelButton.topAnchor.constraint(equalTo: helperLabel.bottomAnchor, constant: 18),
      cancelButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      cancelButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
    ])
  }

  func configure(deviceName: String) {
    titleLabel.text = "正在连接\n\(deviceName)"
    loaderRing.startAnimating()
  }

  func update(status: String) {
    let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
    let display = NativeGalleryLoadingPhrase.humanize(trimmed)
    let final = display.isEmpty ? trimmed : display
    if !final.isEmpty {
      UIView.transition(with: statusLabel, duration: 0.18, options: [.transitionCrossDissolve]) {
        self.statusLabel.text = final
      }
    }
  }

  func showError(_ message: String) {
    loaderRing.stopAnimating(error: true)
    stepBadge.text = "出错了"
    stepBadge.textColor = UIColor.systemRed
    statusLabel.text = message
    statusLabel.textColor = .label
    helperLabel.text = "请检查相机和手机距离，重新连接试试。"
  }

  func reveal(in container: UIView) {
    container.addSubview(self)
    NSLayoutConstraint.activate([
      topAnchor.constraint(equalTo: container.topAnchor),
      leadingAnchor.constraint(equalTo: container.leadingAnchor),
      trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    alpha = 0
    card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
    UIView.animate(withDuration: 0.26, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.4, animations: {
      self.alpha = 1
      self.card.transform = .identity
    })
  }

  func hide(completion: (() -> Void)? = nil) {
    UIView.animate(withDuration: 0.18, animations: {
      self.alpha = 0
      self.card.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
    }, completion: { _ in
      self.removeFromSuperview()
      completion?()
    })
  }

  @objc private func cancelTapped() {
    onCancel?()
  }
}

final class NativeLoaderRingView: UIView {
  private let trackLayer = CAShapeLayer()
  private let progressLayer = CAShapeLayer()
  private var isErrorState = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = NativeLuxuryTheme.cardBackground
    layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    layer.borderWidth = 1
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.06
    layer.shadowRadius = 16
    layer.shadowOffset = CGSize(width: 0, height: 8)

    trackLayer.fillColor = UIColor.clear.cgColor
    trackLayer.strokeColor = UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 0.10).cgColor
    trackLayer.lineWidth = 3
    trackLayer.lineCap = .round
    layer.addSublayer(trackLayer)

    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.strokeColor = NativeLuxuryTheme.accent.cgColor
    progressLayer.lineWidth = 3
    progressLayer.lineCap = .round
    progressLayer.strokeStart = 0
    progressLayer.strokeEnd = 0.28
    layer.addSublayer(progressLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.width / 2
    let inset: CGFloat = 16
    let radius = (bounds.width - inset * 2) / 2
    let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
    trackLayer.path = path
    progressLayer.path = path
  }

  func startAnimating() {
    isErrorState = false
    progressLayer.strokeColor = NativeLuxuryTheme.accent.cgColor
    progressLayer.removeAllAnimations()
    let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
    rotation.fromValue = 0
    rotation.toValue = 2 * Double.pi
    rotation.duration = 1.2
    rotation.repeatCount = .infinity
    layer.add(rotation, forKey: "spin")
  }

  func stopAnimating(error: Bool = false) {
    isErrorState = error
    layer.removeAllAnimations()
    if error {
      progressLayer.strokeColor = UIColor.systemRed.cgColor
      progressLayer.strokeEnd = 1
    }
  }
}
