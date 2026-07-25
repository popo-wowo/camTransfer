import UIKit
import Photos
import ImageIO
import CoreLocation


final class NativeGalleryHighDefinitionPreviewModeController {
  private(set) var isActive = false
  private(set) var pendingHandles: [Int] = []
  private var orderedHandles: [Int] = []

  var hasPendingPreviews: Bool {
    !pendingHandles.isEmpty
  }

  func begin(
    orderedHandles: [Int],
    currentHandle: Int,
    alreadyLoadedHandles: Set<Int>
  ) {
    self.orderedHandles = distinct(orderedHandles)
    isActive = true
    setPending(queue(from: currentHandle, alreadyLoadedHandles: alreadyLoadedHandles))
  }

  func promoteCurrentHandle(
    _ currentHandle: Int,
    alreadyLoadedHandles: Set<Int>
  ) {
    guard isActive else { return }
    let promoted = [currentHandle] + pendingHandles.filter { $0 != currentHandle }
    let missing = queue(from: currentHandle, alreadyLoadedHandles: alreadyLoadedHandles)
      .filter { !promoted.contains($0) }
    setPending((promoted + missing).filter { !alreadyLoadedHandles.contains($0) })
  }

  func markLoaded(_ handle: Int) {
    setPending(pendingHandles.filter { $0 != handle })
  }

  func stop() {
    isActive = false
    orderedHandles = []
    setPending([])
  }

  private func queue(from currentHandle: Int, alreadyLoadedHandles: Set<Int>) -> [Int] {
    guard let currentIndex = orderedHandles.firstIndex(of: currentHandle) else {
      return alreadyLoadedHandles.contains(currentHandle) ? [] : [currentHandle]
    }
    let forward = orderedHandles[currentIndex...]
    let backward = orderedHandles[..<currentIndex]
    return (Array(forward) + Array(backward)).filter { !alreadyLoadedHandles.contains($0) }
  }

  private func setPending(_ handles: [Int]) {
    pendingHandles = distinct(handles)
  }

  private func distinct(_ handles: [Int]) -> [Int] {
    var seen: Set<Int> = []
    var result: [Int] = []
    for handle in handles where !seen.contains(handle) {
      seen.insert(handle)
      result.append(handle)
    }
    return result
  }
}

struct NativeGalleryCachedPreview {
  let data: Data
  let objectOrientation: Int?
}

final class NativeGalleryHighDefinitionPreviewCache {
  private let maxMemoryImages: Int
  private let directory: URL
  private var memory: [Int: Data] = [:]
  private var memoryOrder: [Int] = []
  private var loaded: Set<Int> = []
  private var objectOrientations: [Int: Int] = [:]

  init(
    maxMemoryImages: Int = 30,
    directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("hd-preview-cache", isDirectory: true)
  ) {
    self.maxMemoryImages = max(1, maxMemoryImages)
    self.directory = directory
  }

  var loadedHandles: Set<Int> {
    loaded
  }

  func memoryData(for handle: Int) -> Data? {
    guard let data = memory[handle] else { return nil }
    touch(handle)
    return data
  }

  func store(_ data: Data, for handle: Int, objectOrientation: Int? = nil) {
    loaded.insert(handle)
    objectOrientations[handle] = objectOrientation
    cacheInMemory(data, for: handle)
    writeToDisk(data, for: handle)
  }

  func restoreLoadedData(for handle: Int) -> Data? {
    guard loaded.contains(handle) else { return nil }
    if let data = memoryData(for: handle) {
      return data
    }
    guard let data = try? Data(contentsOf: fileURL(for: handle)) else {
      return nil
    }
    cacheInMemory(data, for: handle)
    return data
  }

  func restoreLoadedPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    guard let data = restoreLoadedData(for: handle) else { return nil }
    return NativeGalleryCachedPreview(
      data: data,
      objectOrientation: objectOrientations[handle]
    )
  }

  func reset() {
    memory.removeAll()
    memoryOrder.removeAll()
    loaded.removeAll()
    objectOrientations.removeAll()
    try? FileManager.default.removeItem(at: directory)
  }

  private func cacheInMemory(_ data: Data, for handle: Int) {
    memory[handle] = data
    touch(handle)
    while memoryOrder.count > maxMemoryImages {
      let evicted = memoryOrder.removeFirst()
      memory.removeValue(forKey: evicted)
    }
  }

  private func touch(_ handle: Int) {
    memoryOrder.removeAll { $0 == handle }
    memoryOrder.append(handle)
  }

  private func writeToDisk(_ data: Data, for handle: Int) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: fileURL(for: handle), options: .atomic)
  }

  private func fileURL(for handle: Int) -> URL {
    directory.appendingPathComponent("\(handle).bin", isDirectory: false)
  }
}


private enum NativeGalleryDownloadRunDisposition {
  case finished
  case terminatedByUser
  case interruptedRecoverable
}


private enum NativeGalleryHeaderIcon {
  case back
  case share
  case downloads
}


private final class NativeTopHeaderFrameView: UIView {
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

private final class NativeGalleryHeaderIconButton: UIButton {
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
  static let pairedActionTitle = "进入相机相册"
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
    case .gallery:
      finishRememberedGalleryEntryIfPossible()
    case .recoveryDownloadCenter(let payload):
      finishRecoveredDownloadEntryIfPossible(payload: payload)
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
        onConnect: { [weak self] in
          guard let self else { return }
          self.connectRememberedCamera(record)
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


@MainActor
private final class NativeGalleryViewController: UIViewController, UIGestureRecognizerDelegate {
  private let summary: CameraVendorConnectionSummary
  private let rememberedPeripheralID: UUID?
  private let runtime: CameraSessionRuntime
  private var catalogPresentation = CameraGalleryPresentation.unavailable
  private var selectedHandles: Set<Int> = []
  private var gallerySections: [NativeGalleryDaySection] = []
  private var filterState = NativeGalleryFilterState()
  private var currentPreferCompressedDownloads: Bool
  private var visibleThumbnailRefreshTask: Task<Void, Never>?
  private var thumbnailRehydrateTasks: [Int: Task<Void, Never>] = [:]
  private let thumbnailImageCache = NSCache<NSNumber, UIImage>()
  private var runtimePresentationObserverID: UUID?
  private var previousIdleTimerDisabled: Bool?
  private var wifiPromptOverlay: NativeWifiPromptOverlay?
  private var selectAllButtonItem: UIBarButtonItem?
  private var isShowingExitConfirmation = false
  private var isExitingAfterConfirmation = false
  private var previousInteractivePopGestureEnabled: Bool?
  private weak var previousInteractivePopGestureDelegate: UIGestureRecognizerDelegate?
  private var previousNavigationBarHidden: Bool?
  private var dragSelectionMode: NativeGalleryDragSelectionMode?
  private var dragSelectionStartHandle: Int?
  private var dragSelectionLastEndHandle: Int?
  private lazy var dragSelectionGesture: UIPanGestureRecognizer = {
    let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleGalleryDragSelection(_:)))
    gesture.maximumNumberOfTouches = 1
    gesture.cancelsTouchesInView = false
    gesture.delegate = self
    return gesture
  }()

  private let galleryBackButton = NativeGalleryHeaderIconButton(icon: .back, accessibilityLabel: "返回")
  private let galleryShareButton = NativeGalleryHeaderIconButton(icon: .share, accessibilityLabel: "现场分享")
  private let galleryDownloadListButton = NativeGalleryHeaderIconButton(icon: .downloads, accessibilityLabel: "下载中心")
  private let galleryHeaderTitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = NativeGalleryChromeCopy.title
    label.font = .systemFont(ofSize: 13, weight: .black)
    label.textColor = NativeLuxuryTheme.ink
    label.textAlignment = .center
    return label
  }()

  private let brandLabel = NativeLuxuryTheme.makeBrandLabel("DEVICE-A GALLERY", size: 10)
  private let titleLabel = NativeLuxuryTheme.makeTitleLabel("图库", size: 30)
  private let copyLabel = NativeLuxuryTheme.makeCopyLabel("准备加载图库")
  private let loadingSpinner: UIActivityIndicatorView = {
    let view = UIActivityIndicatorView(style: .medium)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.color = NativeLuxuryTheme.accent
    view.hidesWhenStopped = true
    return view
  }()

  private let statusLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.text = ""
    label.numberOfLines = 0
    label.isHidden = true
    return label
  }()

  private let diagnosticsView: UITextView = {
    let view = UITextView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isEditable = false
    view.isHidden = true
    view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    view.backgroundColor = .secondarySystemBackground
    view.layer.cornerRadius = 12
    view.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    return view
  }()

  private let dateChips = NativeChipBarControl()
  private let formatChips = NativeChipBarControl()
  private let sortChips = NativeChipBarControl()
  private let filterHeaderView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = NativeLuxuryTheme.warmFill
    view.layer.cornerRadius = 24
    view.layer.borderWidth = 1
    view.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOpacity = 0.05
    view.layer.shadowRadius = 8
    view.layer.shadowOffset = CGSize(width: 0, height: 2)
    return view
  }()
  private let filterTitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = NativeGalleryChromeCopy.filterTitle
    label.font = .systemFont(ofSize: 13, weight: .black)
    label.textColor = NativeLuxuryTheme.ink
    return label
  }()
  private let filterSummaryLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = NativeGalleryChromeCopy.defaultFilterSummary
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }()
  private let filterChevronLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "⌄"
    label.font = .systemFont(ofSize: 16, weight: .black)
    label.textColor = NativeLuxuryTheme.ink
    label.textAlignment = .center
    return label
  }()
  private let filterContentStack: UIStackView = {
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 8
    stack.isHidden = true
    return stack
  }()
  private var isFilterPanelExpanded = false
  private var currentColumnCount: Int = {
    let stored = UserDefaults.standard.integer(forKey: "camtransfer.galleryColumnCount")
    if (NativeGalleryGridLayoutPolicy.minColumnCount...NativeGalleryGridLayoutPolicy.maxColumnCount).contains(stored) {
      return stored
    }
    return 3
  }()
  private let pinchHintBubble: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.86)
    view.layer.cornerRadius = 16
    view.alpha = 0
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOpacity = 0.18
    view.layer.shadowRadius = 14
    view.layer.shadowOffset = CGSize(width: 0, height: 8)
    return view
  }()
  private let pinchHintBubbleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "双指捏合调整每行张数"
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = NativeLuxuryTheme.cardBackground
    return label
  }()
  private var hasTriggeredPinchOnce = false
  private var hasShownPinchHint = false
  private var pinchHintTrailingConstraint: NSLayoutConstraint?

  private let bottomDownloadBar: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    NativeLuxuryTheme.applyFloatingPillStyle(view)
    view.isHidden = false
    return view
  }()

  private let bottomDownloadLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = NativeLuxuryTheme.ink
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.78
    return label
  }()

  private let bottomSelectAllButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.configuration = .plain()
    button.configuration?.image = UIImage(
      systemName: "checkmark.circle",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    )
    button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    button.tintColor = NativeLuxuryTheme.ink
    button.accessibilityLabel = "全选"
    return button
  }()

  private let bottomCompressionSwitch = NativeTransferSizeSwitchControl()

  private let bottomDownloadButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.title = "下载"
    config.baseBackgroundColor = NativeLuxuryTheme.ink
    config.baseForegroundColor = NativeLuxuryTheme.cardBackground
    config.image = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
    config.imagePadding = 6
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
    config.attributedTitle = AttributedString("下载", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    button.configuration = config
    return button
  }()

  private let reservedReceiveProbeButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("HEIF Count Sweep", for: .normal)
    NativeLuxuryTheme.styleSecondaryButton(button)
    NativeLuxuryTheme.setIcon("sparkle.magnifyingglass", on: button)
    button.isHidden = true
    return button
  }()

  private let toastLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.alpha = 0
    label.textAlignment = .center
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.textColor = NativeLuxuryTheme.cardBackground
    label.backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.88)
    label.layer.cornerRadius = 18
    label.clipsToBounds = true
    label.numberOfLines = 2
    return label
  }()

  private let collectionView: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 8
    layout.minimumLineSpacing = 12
    layout.sectionInset = UIEdgeInsets(top: 8, left: 12, bottom: 24, right: 12)
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.backgroundColor = .clear
    collectionView.register(NativeGalleryGridCell.self, forCellWithReuseIdentifier: NativeGalleryGridCell.reuseIdentifier)
    collectionView.register(
      NativeGallerySectionHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: NativeGallerySectionHeaderView.reuseIdentifier
    )
    return collectionView
  }()

  init(
    summary: CameraVendorConnectionSummary,
    rememberedPeripheralID: UUID? = nil,
    runtime: CameraSessionRuntime
  ) {
    self.summary = summary
    self.rememberedPeripheralID = rememberedPeripheralID
    self.runtime = runtime
    self.currentPreferCompressedDownloads = summary.preferCompressedDownloads
    super.init(nibName: nil, bundle: nil)
  }

  private var currentTransferDownloadMode: CameraVendorTransferDownloadMode {
    currentPreferCompressedDownloads ? .compressed : .original
  }

  private var selectionProjectionState: CameraVendorGalleryState {
    var state = CameraVendorGalleryState(items: catalogPresentation.items)
    state.setSelection(handles: selectedHandles)
    return state
  }

  private var hasVerifiedConnectionHandoff: Bool {
    !summary.wifiConfigurations.isEmpty
  }

  var activeRememberedPeripheralID: UUID? {
    rememberedPeripheralID
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .light
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    print("CamTransferGallery NativeGalleryViewController viewDidLoad")
    setupUI()
    configureDiagnostics()
    runtimePresentationObserverID = runtime.observe { [weak self] presentation in
      guard let self else { return }
      self.applyCatalogPresentation(presentation.catalog)
      NotificationCenter.default.post(name: .nativeDownloadStateDidChange, object: nil)
    }
    runtime.observeIncrementalCatalogUpdates { [weak self] catalog, handles in
      guard let self else { return }
      self.catalogPresentation = catalog
      // Decode new thumbnail data to UIImage cache for changed handles
      var rehydrateRequests: [(handle: Int, data: Data)] = []
      for handle in handles {
        guard let item = catalog.items.first(where: { $0.handle == handle }),
              let data = item.thumbnailData,
              self.thumbnailImageCache.object(forKey: NSNumber(value: handle)) == nil else {
          continue
        }
        rehydrateRequests.append((handle: handle, data: data))
      }
      if !rehydrateRequests.isEmpty {
        self.rehydrateCachedThumbnailImages(rehydrateRequests)
      } else {
        self.refreshVisibleCells(forHandles: handles)
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    let observerID = runtimePresentationObserverID
    let runtime = runtime
    let visibleThumbnailRefreshTask = visibleThumbnailRefreshTask
    let thumbnailRehydrateTasks = thumbnailRehydrateTasks
    Task { @MainActor in
      visibleThumbnailRefreshTask?.cancel()
      thumbnailRehydrateTasks.values.forEach { $0.cancel() }
      if let observerID {
        runtime.removeObserver(observerID)
      }
      runtime.send(.galleryPresentationDetached)
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    applyTopChromeNavigationState(animated: animated)
    protectGalleryExitNavigation()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    updateNavigationLock()
    updateIdleTimerProtection()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    restoreGalleryExitNavigation()
    if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
      restoreTopChromeNavigationState(animated: animated)
    }
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .darkContent
  }

  private func setupUI() {
    view.backgroundColor = NativeLuxuryTheme.background
    navigationItem.title = ""
    navigationItem.hidesBackButton = true
    copyLabel.text = "准备加载图库"
    titleLabel.isHidden = true
    self.selectAllButtonItem = nil

    let copyRow = UIStackView(arrangedSubviews: [loadingSpinner, copyLabel])
    copyRow.translatesAutoresizingMaskIntoConstraints = false
    copyRow.axis = .horizontal
    copyRow.alignment = .center
    copyRow.spacing = 8

    let headerBar = UIView()
    headerBar.translatesAutoresizingMaskIntoConstraints = false
    let headerStack = UIStackView(arrangedSubviews: [headerBar])
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    headerStack.axis = .vertical
    headerStack.spacing = NativeGalleryTopChromePolicy.statusSpacing
    let headerFrame = NativeTopHeaderFrameView()
    headerBar.addSubview(galleryBackButton)
    headerBar.addSubview(galleryHeaderTitleLabel)
    headerBar.addSubview(galleryShareButton)
    headerBar.addSubview(galleryDownloadListButton)
    headerFrame.addSubview(headerStack)
    view.addSubview(headerFrame)
    view.addSubview(copyRow)

    view.addSubview(statusLabel)
    view.addSubview(diagnosticsView)

    dateChips.configure(items: [
      .init(id: "all", title: "全部"),
      .init(id: "today", title: "今天"),
      .init(id: "pickDate", title: "选择日期"),
    ], selectedID: "all")
    formatChips.allowsMultipleSelection = false
    formatChips.configure(items: [
      .init(id: "all", title: "全部格式"),
      .init(id: "jpg", title: "JPG"),
      .init(id: "heif", title: "HEIF"),
      .init(id: "raw", title: "RAW"),
      .init(id: "video", title: "视频"),
    ], selectedIDs: ["all"])
    sortChips.configure(items: [
      .init(id: "newest", title: NativeGalleryChromeCopy.sortOptionTitles[0]),
      .init(id: "oldest", title: NativeGalleryChromeCopy.sortOptionTitles[1]),
      .init(id: "notDownloaded", title: NativeGalleryChromeCopy.sortOptionTitles[2]),
    ], selectedID: "newest")
    dateChips.onSelected = { [weak self] _ in self?.chipFilterChanged() }
    sortChips.onSelected = { [weak self] _ in self?.chipFilterChanged() }
    formatChips.onSelected = { [weak self] _ in self?.chipFilterChanged() }

    filterContentStack.addArrangedSubview(dateChips)
    filterContentStack.addArrangedSubview(formatChips)
    filterContentStack.addArrangedSubview(sortChips)
    filterHeaderView.addSubview(filterTitleLabel)
    filterHeaderView.addSubview(filterSummaryLabel)
    filterHeaderView.addSubview(filterChevronLabel)
    let filterStack = UIStackView(arrangedSubviews: [filterHeaderView, filterContentStack])
    filterStack.translatesAutoresizingMaskIntoConstraints = false
    filterStack.axis = .vertical
    filterStack.spacing = 8

    view.addSubview(filterStack)
    view.addSubview(collectionView)
    view.addSubview(bottomDownloadBar)
    view.addSubview(toastLabel)
    bottomDownloadBar.addSubview(bottomSelectAllButton)
    bottomDownloadBar.addSubview(bottomDownloadLabel)
    bottomDownloadBar.addSubview(bottomCompressionSwitch)
    bottomDownloadBar.addSubview(bottomDownloadButton)

    galleryBackButton.addTarget(self, action: #selector(exitGalleryTapped), for: .touchUpInside)
    galleryShareButton.addTarget(self, action: #selector(localProofingTapped), for: .touchUpInside)
    galleryDownloadListButton.addTarget(self, action: #selector(downloadListTapped), for: .touchUpInside)
    filterHeaderView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleFilterPanel)))
    reservedReceiveProbeButton.addTarget(self, action: #selector(reservedReceiveProbeTapped), for: .touchUpInside)
    bottomSelectAllButton.addTarget(self, action: #selector(selectAllTapped), for: .touchUpInside)
    bottomCompressionSwitch.addTarget(self, action: #selector(bottomTransferSizeChanged), for: .valueChanged)
    bottomCompressionSwitch.accessibilityLabel = "下载尺寸"
    bottomCompressionSwitch.isOn = NativeTransferSizeSettingPolicy.switchIsOn(
      preferCompressedDownloads: currentPreferCompressedDownloads
    )
    bottomDownloadButton.addTarget(self, action: #selector(downloadSelectedTapped), for: .touchUpInside)

    collectionView.dataSource = self
    collectionView.delegate = self

    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleGalleryPinch(_:)))
    collectionView.addGestureRecognizer(pinch)
    collectionView.addGestureRecognizer(dragSelectionGesture)

    NSLayoutConstraint.activate([
      headerFrame.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: NativeGalleryTopChromePolicy.topInset),
      headerFrame.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: NativeGalleryTopChromePolicy.horizontalInset),
      headerFrame.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -NativeGalleryTopChromePolicy.horizontalInset),

      headerStack.topAnchor.constraint(equalTo: headerFrame.topAnchor),
      headerStack.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      headerStack.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),
      headerStack.bottomAnchor.constraint(equalTo: headerFrame.bottomAnchor, constant: -NativeGalleryTopChromePolicy.bottomInset),

      headerBar.heightAnchor.constraint(equalToConstant: NativeGalleryTopChromePolicy.actionRowHeight),
      galleryBackButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
      galleryBackButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      galleryHeaderTitleLabel.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
      galleryHeaderTitleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      galleryHeaderTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: galleryBackButton.trailingAnchor, constant: NativeGalleryTopChromePolicy.actionSpacing),
      galleryShareButton.trailingAnchor.constraint(equalTo: galleryDownloadListButton.leadingAnchor, constant: -NativeGalleryTopChromePolicy.actionSpacing),
      galleryShareButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      galleryDownloadListButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
      galleryDownloadListButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      galleryHeaderTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: galleryShareButton.leadingAnchor, constant: -NativeGalleryTopChromePolicy.actionSpacing),

      copyRow.topAnchor.constraint(equalTo: headerFrame.bottomAnchor, constant: 8),
      copyRow.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor, constant: 2),
      copyRow.trailingAnchor.constraint(lessThanOrEqualTo: headerFrame.trailingAnchor, constant: -2),

      statusLabel.topAnchor.constraint(equalTo: copyRow.bottomAnchor, constant: 0),
      statusLabel.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),

      diagnosticsView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 0),
      diagnosticsView.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      diagnosticsView.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),
      diagnosticsView.heightAnchor.constraint(equalToConstant: 0),

      filterStack.topAnchor.constraint(
        equalTo: diagnosticsView.bottomAnchor,
        constant: NativeGalleryAndroidParityLayoutPolicy.filterTopSpacing
      ),
      filterStack.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      filterStack.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),

      filterHeaderView.heightAnchor.constraint(equalToConstant: NativeGalleryAndroidParityLayoutPolicy.filterHeaderHeight),
      filterTitleLabel.leadingAnchor.constraint(equalTo: filterHeaderView.leadingAnchor, constant: 42),
      filterTitleLabel.centerYAnchor.constraint(equalTo: filterHeaderView.centerYAnchor),
      filterSummaryLabel.leadingAnchor.constraint(equalTo: filterTitleLabel.trailingAnchor, constant: 10),
      filterSummaryLabel.trailingAnchor.constraint(equalTo: filterChevronLabel.leadingAnchor, constant: -8),
      filterSummaryLabel.centerYAnchor.constraint(equalTo: filterHeaderView.centerYAnchor),
      filterChevronLabel.trailingAnchor.constraint(equalTo: filterHeaderView.trailingAnchor, constant: -14),
      filterChevronLabel.centerYAnchor.constraint(equalTo: filterHeaderView.centerYAnchor),
      filterChevronLabel.widthAnchor.constraint(equalToConstant: 18),

      collectionView.topAnchor.constraint(
        equalTo: filterStack.bottomAnchor,
        constant: NativeGalleryAndroidParityLayoutPolicy.filterToGridSpacing
      ),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      bottomDownloadBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
      bottomDownloadBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
      bottomDownloadBar.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor,
        constant: -NativeGalleryAndroidParityLayoutPolicy.bottomBarBottomInset
      ),
      bottomDownloadBar.heightAnchor.constraint(
        equalToConstant: NativeGalleryAndroidParityLayoutPolicy.bottomBarHeight
      ),

      bottomSelectAllButton.leadingAnchor.constraint(equalTo: bottomDownloadBar.leadingAnchor, constant: 12),
      bottomSelectAllButton.centerYAnchor.constraint(equalTo: bottomDownloadBar.centerYAnchor),
      bottomSelectAllButton.widthAnchor.constraint(equalToConstant: 34),
      bottomSelectAllButton.heightAnchor.constraint(equalToConstant: 34),

      bottomDownloadLabel.leadingAnchor.constraint(equalTo: bottomSelectAllButton.trailingAnchor, constant: 8),
      bottomDownloadLabel.centerYAnchor.constraint(equalTo: bottomDownloadBar.centerYAnchor),

      bottomDownloadButton.trailingAnchor.constraint(equalTo: bottomDownloadBar.trailingAnchor, constant: -10),
      bottomDownloadButton.centerYAnchor.constraint(equalTo: bottomDownloadBar.centerYAnchor),
      bottomDownloadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),

      bottomCompressionSwitch.trailingAnchor.constraint(equalTo: bottomDownloadButton.leadingAnchor, constant: -8),
      bottomCompressionSwitch.centerYAnchor.constraint(equalTo: bottomDownloadBar.centerYAnchor),
      bottomCompressionSwitch.leadingAnchor.constraint(greaterThanOrEqualTo: bottomDownloadLabel.trailingAnchor, constant: 8),

      toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      toastLabel.bottomAnchor.constraint(equalTo: bottomDownloadBar.topAnchor, constant: -12),
      toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
      toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
      toastLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
    ])

    if NativeGalleryAndroidParityLayoutPolicy.shouldShowPinchHintBubble {
      view.addSubview(pinchHintBubble)
      pinchHintBubble.addSubview(pinchHintBubbleLabel)
      let trailing = pinchHintBubble.leadingAnchor.constraint(equalTo: view.trailingAnchor)
      pinchHintTrailingConstraint = trailing
      NSLayoutConstraint.activate([
        pinchHintBubble.topAnchor.constraint(equalTo: filterStack.bottomAnchor, constant: 12),
        trailing,
        pinchHintBubble.heightAnchor.constraint(equalToConstant: 32),

        pinchHintBubbleLabel.leadingAnchor.constraint(equalTo: pinchHintBubble.leadingAnchor, constant: 14),
        pinchHintBubbleLabel.trailingAnchor.constraint(equalTo: pinchHintBubble.trailingAnchor, constant: -14),
        pinchHintBubbleLabel.centerYAnchor.constraint(equalTo: pinchHintBubble.centerYAnchor),
      ])
    }
  }

  private var hasActiveCameraCommunication: Bool {
    runtime.presentation.phase != .idle
  }

  private func updateIdleTimerProtection() {
    let shouldDisable = NativeGalleryPresentationLifecyclePolicy.shouldDisableIdleTimer(
      isLoading: catalogPresentation.isLoading,
      isDownloading: runtime.isDownloading,
      hasActiveCameraCommunication: hasActiveCameraCommunication
    )
    if shouldDisable {
      if previousIdleTimerDisabled == nil {
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
      }
      UIApplication.shared.isIdleTimerDisabled = true
    } else {
      restoreIdleTimerIfNeeded()
    }
  }

  private func restoreIdleTimerIfNeeded() {
    guard let previousIdleTimerDisabled else { return }
    UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    self.previousIdleTimerDisabled = nil
  }

  private func protectGalleryExitNavigation() {
    guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
    if previousInteractivePopGestureEnabled == nil {
      previousInteractivePopGestureEnabled = gesture.isEnabled
      previousInteractivePopGestureDelegate = gesture.delegate
    }
    gesture.isEnabled = false
  }

  private func restoreGalleryExitNavigation() {
    guard let gesture = navigationController?.interactivePopGestureRecognizer,
          let wasEnabled = previousInteractivePopGestureEnabled else { return }
    gesture.isEnabled = wasEnabled
    gesture.delegate = previousInteractivePopGestureDelegate
    previousInteractivePopGestureEnabled = nil
    previousInteractivePopGestureDelegate = nil
  }

  private func applyTopChromeNavigationState(animated: Bool) {
    guard NativeGalleryTopChromePolicy.shouldHideSystemNavigationBar,
          let navigationController else {
      return
    }
    if previousNavigationBarHidden == nil {
      previousNavigationBarHidden = navigationController.isNavigationBarHidden
    }
    navigationController.setNavigationBarHidden(true, animated: animated)
  }

  private func restoreTopChromeNavigationState(animated: Bool) {
    guard NativeGalleryTopChromePolicy.shouldHideSystemNavigationBar,
          let navigationController,
          let wasHidden = previousNavigationBarHidden else {
      return
    }
    navigationController.setNavigationBarHidden(wasHidden, animated: animated)
    previousNavigationBarHidden = nil
  }

  @objc private func exitGalleryTapped() {
    if NativeGalleryInteractionPriorityPolicy.shouldCancelThumbnailQueueBeforeExitTap {
      prioritizeGalleryInteraction()
    }
    guard NativeGalleryExitPolicy.shouldConfirmBeforeLeaving(
      hasActiveCameraCommunication: hasActiveCameraCommunication
    ) else {
      leaveGallery()
      return
    }
    presentExitConfirmation()
  }

  private func presentExitConfirmation() {
    guard !isShowingExitConfirmation else { return }
    isShowingExitConfirmation = true
    let alert = UIAlertController(
      title: NativeGalleryExitCopy.title,
      message: NativeGalleryExitCopy.message,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: NativeGalleryExitCopy.cancelTitle, style: .cancel) { [weak self] _ in
      self?.isShowingExitConfirmation = false
    })
    alert.addAction(UIAlertAction(title: NativeGalleryExitCopy.confirmTitle, style: .destructive) { [weak self] _ in
      guard let self else { return }
      self.isShowingExitConfirmation = false
      self.confirmGalleryExit()
    })
    present(alert, animated: true)
  }

  private func confirmGalleryExit() {
    if NativeGalleryExitPolicy.shouldTerminateCameraCommunication(
      hasActiveCameraCommunication: hasActiveCameraCommunication,
      userConfirmedExit: true
    ) {
      runtime.send(.disconnectCamera(reason: "user-confirmed-gallery-exit"))
    }
    leaveGallery()
  }

  private func leaveGallery() {
    isExitingAfterConfirmation = true
    if let navigationController {
      navigationController.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  private func showPinchHintIfNeeded() {
    guard NativeGalleryAndroidParityLayoutPolicy.shouldShowPinchHintBubble else { return }
    guard !hasShownPinchHint, !hasTriggeredPinchOnce else { return }
    hasShownPinchHint = true
    view.layoutIfNeeded()
    let bubbleWidth = pinchHintBubble.systemLayoutSizeFitting(
      UIView.layoutFittingCompressedSize
    ).width
    pinchHintTrailingConstraint?.constant = -bubbleWidth - 16
    UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4, options: [.curveEaseOut]) {
      self.pinchHintBubble.alpha = 1
      self.view.layoutIfNeeded()
    }
    runColumnDemoAnimation()
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
      self?.hidePinchHint()
    }
  }

  /// Briefly nudge the column count up & back to silently demonstrate the
  /// pinch gesture. Only runs when the hint is being shown for the first
  /// time so we never disturb users who already know the gesture.
  private func runColumnDemoAnimation() {
    let original = currentColumnCount
    let demoTarget = original < 5 ? original + 1 : original - 1
    UIView.animate(withDuration: 0.35, delay: 0.55, options: [.curveEaseInOut], animations: {
      self.currentColumnCount = demoTarget
      self.collectionView.collectionViewLayout.invalidateLayout()
      self.collectionView.layoutIfNeeded()
    }, completion: { _ in
      UIView.animate(withDuration: 0.35, delay: 0.45, options: [.curveEaseInOut], animations: {
        self.currentColumnCount = original
        self.collectionView.collectionViewLayout.invalidateLayout()
        self.collectionView.layoutIfNeeded()
      })
    })
  }

  private func hidePinchHint() {
    guard pinchHintBubble.alpha > 0 else { return }
    pinchHintTrailingConstraint?.constant = 0
    UIView.animate(withDuration: 0.36, delay: 0, options: [.curveEaseIn]) {
      self.pinchHintBubble.alpha = 0
      self.view.layoutIfNeeded()
    }
  }

  @objc private func handleGalleryPinch(_ pinch: UIPinchGestureRecognizer) {
    guard pinch.state == .changed else { return }
    let scale = pinch.scale
    if scale > 1.45 {
      changeColumnCount(by: -1)
      pinch.scale = 1.0
    } else if scale < 0.7 {
      changeColumnCount(by: 1)
      pinch.scale = 1.0
    }
  }

  private func changeColumnCount(by delta: Int) {
    let target = NativeGalleryGridLayoutPolicy.clampedColumnCount(currentColumnCount + delta)
    guard target != currentColumnCount else { return }
    currentColumnCount = target
    UserDefaults.standard.set(target, forKey: "camtransfer.galleryColumnCount")
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if !hasTriggeredPinchOnce {
      hasTriggeredPinchOnce = true
      hidePinchHint()
    }
    UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseInOut]) {
      self.collectionView.collectionViewLayout.invalidateLayout()
      self.collectionView.layoutIfNeeded()
    }
  }

  @objc private func handleGalleryDragSelection(_ gesture: UIPanGestureRecognizer) {
    let location = gesture.location(in: collectionView)
    switch gesture.state {
    case .began:
      guard let indexPath = collectionView.indexPathForItem(at: location),
            let item = galleryItem(at: indexPath),
            NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: runtime.downloadState(for: item.handle)) else {
        dragSelectionMode = nil
        dragSelectionStartHandle = nil
        dragSelectionLastEndHandle = nil
        return
      }
      prioritizeGalleryInteraction()
      dragSelectionMode = nil
      dragSelectionStartHandle = item.handle
      dragSelectionLastEndHandle = nil
    case .changed:
      guard let startHandle = dragSelectionStartHandle else { return }
      if dragSelectionMode == nil {
        let translation = gesture.translation(in: collectionView)
        guard NativeGalleryDragSelectionPolicy.shouldStartDragSelection(
          deltaX: translation.x,
          deltaY: translation.y,
          touchSlop: 10,
          selectionActive: !selectedHandles.isEmpty
        ) else {
          return
        }
        let endHandle = collectionView.indexPathForItem(at: location).flatMap { galleryItem(at: $0)?.handle }
        let canSelectEndHandle = endHandle
          .map { NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: runtime.downloadState(for: $0)) } ?? false
        guard NativeGalleryDragSelectionPolicy.shouldCommitDragSelection(
          startHandle: startHandle,
          endHandle: endHandle,
          canSelectEndHandle: canSelectEndHandle
        ) else {
          return
        }
        dragSelectionMode = NativeGalleryDragSelectionPolicy.mode(
          startHandle: startHandle,
          selectedHandles: selectedHandles
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
      }
      let scrollDelta = NativeGalleryDragSelectionPolicy.autoScrollDelta(
        pointerY: location.y,
        viewportStart: collectionView.contentOffset.y,
        viewportEnd: collectionView.contentOffset.y + collectionView.bounds.height,
        edgeSize: 72,
        maxDelta: 34
      )
      if scrollDelta != 0 {
        let maxOffsetY = max(
          -collectionView.adjustedContentInset.top,
          collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        )
        let targetOffsetY = min(
          max(collectionView.contentOffset.y + scrollDelta, -collectionView.adjustedContentInset.top),
          maxOffsetY
        )
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: targetOffsetY), animated: false)
      }
      guard let indexPath = collectionView.indexPathForItem(at: location) else { return }
      applyDragSelection(at: indexPath)
    case .ended, .cancelled, .failed:
      dragSelectionMode = nil
      dragSelectionStartHandle = nil
      dragSelectionLastEndHandle = nil
      scheduleVisibleThumbnailRefresh(
        after: NativeGalleryInteractionPriorityPolicy.thumbnailResumeDelayAfterSelectionSeconds
      )
    default:
      break
    }
  }

  private func applyDragSelection(at indexPath: IndexPath) {
    guard let mode = dragSelectionMode,
          let startHandle = dragSelectionStartHandle,
          let item = galleryItem(at: indexPath),
          dragSelectionLastEndHandle != item.handle,
          NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: runtime.downloadState(for: item.handle)) else {
      return
    }
    dragSelectionLastEndHandle = item.handle
    let selectableHandles = Set(runtime.downloadableHandles(from: catalogPresentation.items.map(\.handle)))
    let updated = NativeGalleryDragSelectionPolicy.updatedRangeSelection(
      selectedHandles: selectedHandles,
      orderedHandles: catalogPresentation.items.map(\.handle),
      startHandle: startHandle,
      endHandle: item.handle,
      selectableHandles: selectableHandles,
      mode: mode
    )
    guard updated != selectedHandles else { return }
    let previousSelection = selectedHandles
    selectedHandles = updated
    refreshStatusText()
    refreshVisibleSelectionStates(
      forHandles: NativeGalleryUIInvalidationPolicy.changedHandles(
        before: previousSelection,
        after: updated
      )
    )
    refreshVisibleSectionHeaders()
  }

  private func galleryItem(at indexPath: IndexPath) -> CameraVendorGalleryItem? {
    guard gallerySections.indices.contains(indexPath.section),
          gallerySections[indexPath.section].items.indices.contains(indexPath.item) else { return nil }
    return gallerySections[indexPath.section].items[indexPath.item]
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === dragSelectionGesture else { return true }
    let location = dragSelectionGesture.location(in: collectionView)
    guard collectionView.indexPathForItem(at: location) != nil else { return false }
    let velocity = dragSelectionGesture.velocity(in: collectionView)
    return NativeGalleryDragSelectionPolicy.shouldStartDragSelection(
      deltaX: velocity.x,
      deltaY: velocity.y,
      touchSlop: 10
    )
  }

  @objc private func chipFilterChanged() {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    let previousDate = filterState.date
    let previousFormat = filterState.format
    switch dateChips.selectedID {
    case "all": filterState.date = .all
    case "today": filterState.date = .today
    case "pickDate":
      presentDatePicker()
      return
    default: filterState.date = .all
    }

    switch formatChips.selectedID {
    case "jpg": filterState.format = .jpg
    case "heif": filterState.format = .heif
    case "raw": filterState.format = .raw
    case "video": filterState.format = .video
    default: filterState.format = .all
    }

    appendDiagnostic(
      "[OBS] GALLERY_FILTER_UI_APPLIED " +
      "date=\(dateChips.selectedID ?? "nil") " +
      "format=\(formatChips.selectedID ?? "all") " +
      "sort=\(sortChips.selectedID ?? "nil")"
    )

    switch sortChips.selectedID {
    case "oldest":
      filterState.sort = .oldest
    case "notDownloaded":
      filterState.sort = .notDownloaded
    default:
      filterState.sort = .newest
    }

    if previousDate != filterState.date || previousFormat != filterState.format {
      submitGalleryIntent()
    } else {
      submitGalleryIntent()
    }
    refreshFilterSummary()
  }

  private func submitGalleryIntent() {
    prioritizeGalleryInteraction()
    appendDiagnostic(
      "[OBS] GALLERY_CATALOG_INTENT_SUBMITTED " +
      "date=\(dateChips.selectedID ?? "all") format=\(formatChips.selectedID ?? "all")"
    )
    runtime.submitGalleryIntent(filterState.catalogIntent)
  }

  @objc private func toggleFilterPanel() {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    isFilterPanelExpanded.toggle()
    filterContentStack.isHidden = !isFilterPanelExpanded
    filterChevronLabel.text = isFilterPanelExpanded ? "⌃" : "⌄"
    UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut]) {
      self.view.layoutIfNeeded()
    }
  }

  @objc private func localProofingTapped() {
    presentNotice(title: "现场分享", message: "iOS 现场分享服务还没有接入，下一步会按 Android localproofing 模块移植本地分享和二维码。")
  }

  private func presentDatePicker() {
    let now = Date()
    var initialFrom = Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now
    var initialTo = now
    if case let .range(from, to) = filterState.date {
      initialFrom = from
      initialTo = to
    } else if case let .specificDay(day) = filterState.date {
      initialFrom = day
      initialTo = day
    }
    let picker = NativeDateRangePickerController(
      initialFrom: initialFrom,
      initialTo: initialTo,
      onCancel: { [weak self] in
        self?.dismiss(animated: true)
        self?.dateChips.setSelected(self?.dateFilterChipID() ?? "all")
      },
      onConfirm: { [weak self] from, to in
        guard let self else { return }
        self.dismiss(animated: true)
        guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: self.runtime.isDownloading) else {
          return
        }
        let normalizedFrom = min(from, to)
        let normalizedTo = max(from, to)
        if Calendar.current.isDate(normalizedFrom, inSameDayAs: normalizedTo) {
          self.filterState.date = .specificDay(normalizedFrom)
          self.dateChips.refreshTitle(forID: "pickDate", title: self.dateChipTitle(for: normalizedFrom))
        } else {
          self.filterState.date = .range(from: normalizedFrom, to: normalizedTo)
          self.dateChips.refreshTitle(forID: "pickDate", title: self.dateRangeChipTitle(from: normalizedFrom, to: normalizedTo))
        }
        self.submitGalleryIntent()
      }
    )
    picker.modalPresentationStyle = .pageSheet
    if let sheet = picker.sheetPresentationController {
      sheet.detents = [.medium()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28
    }
    picker.overrideUserInterfaceStyle = .light
    present(picker, animated: true)
  }

  private func dateFilterChipID() -> String {
    switch filterState.date {
    case .all: return "all"
    case .today: return "today"
    case .specificDay, .range: return "pickDate"
    }
  }

  private func dateChipTitle(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日"
    return formatter.string(from: date)
  }

  private func dateRangeChipTitle(from: Date, to: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日"
    return "\(formatter.string(from: from)) – \(formatter.string(from: to))"
  }

  private func configureDiagnostics() {
    diagnosticsView.text = "相机通信由 Session Runtime 统一管理。"
  }

  private func appendDiagnostic(_ message: String, writesToFile: Bool = true) {
    print("CamTransferGallery UI \(message)")
    if writesToFile && NativeGalleryDownloadDiagnosticLogPolicy.shouldWriteToFile(message) {
      CameraVendorFileLogger.log("UI: \(message)")
    }
    if catalogPresentation.isLoading {
      let humanized = NativeGalleryLoadingPhrase.humanize(message)
      if !humanized.isEmpty {
        copyLabel.text = humanized
        copyLabel.textColor = NativeLuxuryTheme.secondaryInk
      }
    }
    guard NativeLogTextViewPolicy.shouldRenderLiveText(
      applicationState: UIApplication.shared.applicationState,
      hasWindow: view.window != nil,
      visibleHeight: diagnosticsView.bounds.height
    ) else {
      return
    }

    diagnosticsView.text = NativeLogTextViewPolicy.appending(message, to: diagnosticsView.text)
    let bottom = NSRange(location: max(diagnosticsView.text.count - 1, 0), length: 1)
    diagnosticsView.scrollRangeToVisible(bottom)
  }

  @objc private func appDidBecomeActive() {
    appendDiagnostic(
      "[GALLERY_APP_DID_BECOME_ACTIVE] state=\(applicationStateDescription) " +
      "isDownloading=\(runtime.isDownloading) hasActiveCameraCommunication=\(hasActiveCameraCommunication)"
    )
    updateIdleTimerProtection()
    appendDiagnostic("已回到 CamTransfer；生命周期由 Runtime/Home 统一处理。")
    scheduleVisibleThumbnailRefresh(after: 0.25)
  }

  @objc private func appDidEnterBackground() {
    appendDiagnostic(
      "[GALLERY_APP_DID_ENTER_BACKGROUND] state=\(applicationStateDescription) " +
      "isDownloading=\(runtime.isDownloading) hasActiveCameraCommunication=\(hasActiveCameraCommunication)"
    )
    pauseVisibleThumbnailLoadingForBackground()
  }

  private var applicationStateDescription: String {
    switch UIApplication.shared.applicationState {
    case .active:
      return "active"
    case .inactive:
      return "inactive"
    case .background:
      return "background"
    @unknown default:
      return "unknown"
    }
  }

  private var isCurrentForegroundGalleryOwner: Bool {
    guard !isExitingAfterConfirmation else { return false }
    guard view.window != nil else { return false }
    return NativeGalleryDownloadModePresentationPolicy.shouldKeepForegroundGallerySession(
      surface: currentSessionPresentationSurface
    )
  }

  private var currentSessionPresentationSurface: NativeGallerySessionPresentationSurface {
    guard let navigationController else { return .other }
    if navigationController.topViewController === self {
      return .gallery
    }
    if navigationController.topViewController is NativeDownloadListViewController,
       navigationController.viewControllers.contains(where: { $0 === self }) {
      return .downloadCenter
    }
    return .other
  }

  @objc private func selectAllTapped() {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    let selectableHandles = Set(runtime.downloadableHandles(from: catalogPresentation.items.map(\.handle)))
    let previousSelection = selectedHandles
    if selectedHandles == selectableHandles, !selectableHandles.isEmpty {
      selectedHandles.removeAll()
    } else {
      selectedHandles = selectableHandles
    }

    let changedHandles = NativeGalleryUIInvalidationPolicy.changedHandles(
      before: previousSelection,
      after: selectedHandles
    )
    refreshStatusText()
    refreshVisibleCells(forHandles: changedHandles)
    refreshVisibleSectionHeaders()
  }

  @objc private func downloadSelectedTapped() {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      showDownloadListForCurrentTasks()
      return
    }
    let selectedItems = catalogPresentation.items.filter { selectedHandles.contains($0.handle) }
    let unsupportedItems = selectedItems.filter { !CameraVendorGalleryDownloadPolicy.canDownloadOriginal($0) }
    let downloadableItems = selectedItems.filter { CameraVendorGalleryDownloadPolicy.canDownloadOriginal($0) }
    let handles = downloadableItems
      .map(\.handle)
      .sorted()
    guard !handles.isEmpty else {
      let message = unsupportedItems.isEmpty
        ? "先勾选要下载的照片"
        : "当前只支持下载照片原图，视频暂不支持下载"
      presentNotice(title: unsupportedItems.isEmpty ? "还没选择" : "暂不支持", message: message)
      return
    }
    if !unsupportedItems.isEmpty {
      appendDiagnostic("已跳过 \(unsupportedItems.count) 个暂不支持的视频下载。")
    }
    openDownloadCenter(for: handles)
  }

  @objc private func downloadListTapped() {
    let controller = NativeDownloadListViewController(
      runtime: runtime,
      itemsProvider: { [weak self] in
        self?.downloadListItems() ?? []
      },
      stateProvider: { [weak self] handle in
        self?.runtime.downloadState(for: handle) ?? .idle
      },
      progressProvider: { [weak self] handle in
        self?.runtime.downloadProgressText(for: handle)
      },
      isTransferActiveProvider: { [weak self] in
        self?.runtime.canCancelDownload == true
      },
      onTerminateDownload: { [weak self] in
        self?.requestTerminateDownloadForDownloadCenterExit(reason: "download-center-back")
      },
      onClearDownloadCache: { [weak self] item in
        self?.clearDownloadCache(for: item)
      }
    )
    navigationController?.pushViewController(controller, animated: true)
  }

  @objc private func bottomTransferSizeChanged() {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      bottomCompressionSwitch.isOn = NativeTransferSizeSettingPolicy.switchIsOn(
        preferCompressedDownloads: currentPreferCompressedDownloads
      )
      return
    }
    let nextPreference = NativeTransferSizeSettingPolicy.preferCompressedDownloads(forSwitchIsOn: bottomCompressionSwitch.isOn)
    currentPreferCompressedDownloads = nextPreference
    CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = nextPreference
    bottomCompressionSwitch.isOn = NativeTransferSizeSettingPolicy.switchIsOn(
      preferCompressedDownloads: currentPreferCompressedDownloads
    )
    let nextMode = nextPreference ? "压缩" : "原图"
    appendDiagnostic("本次下载模式已切换为 \(nextMode)，并保存为下次默认。")
    showToast("本次下载使用\(nextMode)")
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  @objc private func clearAllDownloadCacheTapped() {
    let clearedCount = runtime.savedDownloadHandles().count
    runtime.send(.clearAllSavedDownloadHistory)
    refreshStatusText()
    collectionView.reloadData()
    notifyDownloadStateChanged()
    appendDiagnostic("[缓存] 已清理全部下载缓存 count=\(clearedCount)")
    showToast(clearedCount > 0 ? "已清理 \(clearedCount) 张缓存，可重新下载" : "没有可清理的下载缓存")
  }


  @objc private func reservedReceiveProbeTapped() {
    appendDiagnostic("[HEIF实验] 启动 XApp Count Sweep 实验...")
    runtime.runCountSweepExperiment()
  }

  private func applyCatalogPresentation(_ presentation: CameraGalleryPresentation) {
    let previousItems = catalogPresentation.items
    catalogPresentation = presentation
    selectedHandles.formIntersection(presentation.items.map(\.handle))
    let handlesNeedingReDecode = NativeGalleryOrientationRefreshPolicy.handlesNeedingThumbnailReDecode(
      existingItems: previousItems,
      resolvedItems: presentation.items
    )
    invalidateThumbnailDecodes(forHandles: handlesNeedingReDecode)
    refreshGallerySections()
    refreshStatusText()
    collectionView.reloadData()

    if case .ready = presentation.state {
      loadVisibleThumbnails()
      if !presentation.items.isEmpty {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
          self?.showPinchHintIfNeeded()
        }
      }
    }
  }

  private func invalidateThumbnailDecodes(forHandles handles: Set<Int>) {
    for handle in handles {
      thumbnailRehydrateTasks.removeValue(forKey: handle)?.cancel()
      thumbnailImageCache.removeObject(forKey: NSNumber(value: handle))
      CameraVendorFileLogger.log("[ORIENTATION_THUMBNAIL] invalidated handle=\(handle) reason=late-object-info")
    }
  }

  private func requestTerminateDownloadForDownloadCenterExit(reason: String) {
    guard runtime.canCancelDownload else { return }
    runtime.send(.cancelDownloadByUser)
    appendDiagnostic("[下载] 用户终止下载；相机连接保持可用 reason=\(reason)")
    showToast("已终止当前下载")
  }

  private func openDownloadCenter(for handles: [Int]) {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      showDownloadListForCurrentTasks()
      return
    }
    let handlesToDownload = runtime.downloadableHandles(from: handles)
    guard !handlesToDownload.isEmpty else {
      showToast("已下载过，无需重复下载")
      return
    }
    let itemsToDownload = catalogPresentation.items.filter { handlesToDownload.contains($0.handle) }
    let previousSelection = selectedHandles
    selectedHandles = NativeGalleryPostDownloadSelectionPolicy.selectionAfterStartingDownload(
      selectedHandles: selectedHandles
    )
    runtime.send(.startDownload(handles: handlesToDownload.map(UInt32.init), mode: currentTransferDownloadMode))
    guard runtime.isDownloading else {
      showToast("下载未启动，请重新进入相册后重试")
      return
    }
    let changedSelectionHandles = NativeGalleryUIInvalidationPolicy.changedHandles(
      before: previousSelection,
      after: selectedHandles
    )
    refreshVisibleCells(forHandles: Set(handlesToDownload).union(changedSelectionHandles))
    refreshVisibleSectionHeaders()
    notifyDownloadStateChanged()
    showToast("\(handlesToDownload.count) 张已加入下载列表")
    let controller = NativeDownloadListViewController(
      runtime: runtime,
      itemsProvider: { itemsToDownload },
      stateProvider: { [weak self] handle in
        self?.runtime.downloadState(for: handle) ?? .idle
      },
      progressProvider: { [weak self] handle in
        self?.runtime.downloadProgressText(for: handle)
      },
      isTransferActiveProvider: { [weak self] in
        self?.runtime.canCancelDownload == true
      },
      onTerminateDownload: { [weak self] in
        self?.requestTerminateDownloadForDownloadCenterExit(reason: "download-center-back")
      },
      onClearDownloadCache: { [weak self] item in
        self?.clearDownloadCache(for: item)
      }
    )
    navigationController?.pushViewController(controller, animated: true)
  }
}
extension NativeGalleryViewController {
  private func showDownloadListForCurrentTasks() {
    guard !(navigationController?.topViewController is NativeDownloadListViewController) else {
      return
    }
    let controller = NativeDownloadListViewController(
      runtime: runtime,
      itemsProvider: { [weak self] in
        self?.downloadListItems() ?? []
      },
      stateProvider: { [weak self] handle in
        self?.runtime.downloadState(for: handle) ?? .idle
      },
      progressProvider: { [weak self] handle in
        self?.runtime.downloadProgressText(for: handle)
      },
      isTransferActiveProvider: { [weak self] in
        self?.runtime.canCancelDownload == true
      },
      onTerminateDownload: { [weak self] in
        self?.requestTerminateDownloadForDownloadCenterExit(reason: "download-center-back")
      },
      onClearDownloadCache: { [weak self] item in
        self?.clearDownloadCache(for: item)
      }
    )
    navigationController?.pushViewController(controller, animated: true)
  }

  private func downloadListItems() -> [CameraVendorGalleryItem] {
    let historyItems = runtime.downloadHistoryItems()
    let historyHandles = Set(historyItems.map(\.handle))
    let activeItems = catalogPresentation.items.filter { item in
      switch runtime.downloadState(for: item.handle) {
      case .idle: return false
      case .queued, .downloading, .saved, .failed: return true
      }
    }
    let activeHandles = Set(activeItems.map(\.handle))
    let mergedItems = activeItems + historyItems.filter { !activeHandles.contains($0.handle) }
    func displayState(for handle: Int) -> CameraVendorDownloadState {
      let state = runtime.downloadState(for: handle)
      if state == .idle, historyHandles.contains(handle) {
        return .saved
      }
      return state
    }
    func priority(_ state: CameraVendorDownloadState) -> Int {
      switch state {
      case .saved: return 0
      case .downloading: return 1
      case .queued: return 2
      case .failed: return 3
      case .idle: return 4
      }
    }
    return mergedItems.sorted { lhs, rhs in
      let lp = priority(displayState(for: lhs.handle))
      let rp = priority(displayState(for: rhs.handle))
      if lp != rp { return lp < rp }
      return lhs.handle < rhs.handle
    }
  }

  private func clearDownloadCache(for item: CameraVendorGalleryItem) {
    runtime.send(.clearSavedDownloadHistory(handle: UInt32(item.handle)))
    refreshStatusText()
    refreshVisibleCells(forHandles: [item.handle])
    refreshVisibleSectionHeaders()
    notifyDownloadStateChanged()
    appendDiagnostic("已清理下载缓存 handle=\(item.handle)，可重新下载")
    showToast("已清理缓存，可重新下载")
  }

  private func notifyDownloadStateChanged() {
    NotificationCenter.default.post(name: .nativeDownloadStateDidChange, object: nil)
  }

  private func refreshStatusText() {
    updateNavigationLock()
    if catalogPresentation.isLoading {
      if (copyLabel.text ?? "").isEmpty || copyLabel.text == "准备加载图库" {
        copyLabel.text = "正在加载图库…"
      }
      copyLabel.textColor = NativeLuxuryTheme.secondaryInk
      loadingSpinner.startAnimating()
      refreshFilterSummary()
      refreshBottomDownloadBar()
      return
    }

    loadingSpinner.stopAnimating()

    if let errorMessage = catalogPresentation.errorMessage {
      copyLabel.text = "加载失败：\(errorMessage)"
      copyLabel.textColor = NativeLuxuryTheme.secondaryInk
      refreshFilterSummary()
      refreshBottomDownloadBar()
      return
    }

    let total = catalogPresentation.items.count
    let visible = catalogPresentation.items.count
    let selected = selectedHandles.count
    let filterApplied = filterState.date != .all || !filterState.isAllFormats
    let countText: String
    if total == 0 {
      countText = "暂无照片"
    } else if filterApplied {
      countText = "\(visible) / \(total) 张"
    } else {
      countText = "\(total) 张照片"
    }
    copyLabel.text = "\(countText) · 已选 \(selected)"
    copyLabel.textColor = NativeLuxuryTheme.secondaryInk
    refreshFilterSummary()
    refreshBottomDownloadBar()
  }

  private func refreshFilterSummary() {
    let dateText: String
    switch filterState.date {
    case .all:
      dateText = "全部日期"
    case .today:
      dateText = "今天"
    case .specificDay:
      dateText = "指定日期"
    case .range:
      dateText = "日期范围"
    }
    let formatText: String
    switch filterState.format {
    case .all: formatText = "全部格式"
    case .jpg: formatText = "JPG"
    case .heif: formatText = "HEIF"
    case .raw: formatText = "RAW"
    case .video: formatText = "视频"
    }
    let sortText: String
    switch filterState.sort {
    case .newest:
      sortText = "最新优先"
    case .oldest:
      sortText = "最早优先"
    case .notDownloaded:
      sortText = "未下载优先"
    }
    filterSummaryLabel.text = "\(dateText) · \(formatText) · \(sortText)"
  }

  private func refreshBottomDownloadBar() {
    let summary = NativeGallerySelectionSummaryPolicy.summary(
      items: catalogPresentation.items,
      state: selectionProjectionState
    )
    bottomDownloadBar.isHidden = false
    bottomDownloadLabel.text = summary.text
    bottomDownloadButton.isEnabled = NativeGalleryDownloadBarPolicy.canStartDownload(
      selectedCount: summary.selectedCount,
      isDownloading: runtime.isDownloading
    )
    bottomSelectAllButton.isEnabled = NativeGalleryDownloadBarPolicy.canToggleSelectAll(
      totalSelectableCount: summary.totalSelectableCount,
      isDownloading: runtime.isDownloading
    )
    bottomCompressionSwitch.isEnabled = !runtime.isDownloading
  }

  private func updateNavigationLock() {
    let canLeave = NativeGalleryNavigationPolicy.canLeaveGallery(isDownloading: runtime.isDownloading)
    galleryBackButton.isEnabled = true
    isModalInPresentation = !canLeave
    galleryDownloadListButton.isEnabled = true
    let selectableCount = NativeGallerySelectionSummaryPolicy.summary(
      items: catalogPresentation.items,
      state: selectionProjectionState
    )
      .totalSelectableCount
    selectAllButtonItem?.isEnabled = NativeGalleryDownloadBarPolicy.canToggleSelectAll(
      totalSelectableCount: selectableCount,
      isDownloading: runtime.isDownloading
    )
    if !canLeave {
      reservedReceiveProbeButton.isEnabled = false
    }
  }

  private func galleryEntryViewState(for handle: Int) -> CameraGalleryEntryViewState? {
    catalogPresentation.entries.first { $0.summary.handle == handle }
  }

  private func refreshGallerySections() {
    gallerySections = NativeGallerySectionPolicy.sections(from: catalogPresentation.items)
  }

  private func loadVisibleThumbnails() {
    collectionView.layoutIfNeeded()
    let orderedHandles = catalogPresentation.items.map(\.handle)
    let visibleHandles = collectionView.indexPathsForVisibleItems
      .compactMap { galleryItem(at: $0)?.handle }
    let requestedHandles = NativeGalleryThumbnailRequestWindowPolicy.handlesToRequest(
      orderedHandles: orderedHandles,
      visibleHandles: visibleHandles.isEmpty ? Array(orderedHandles.prefix(currentColumnCount * 3)) : visibleHandles,
      columnCount: currentColumnCount
    )
    let itemsByHandle = Dictionary(uniqueKeysWithValues: catalogPresentation.items.map { ($0.handle, $0) })
    var handles: [Int] = []
    var rehydrateRequests: [(handle: Int, data: Data)] = []
    for handle in requestedHandles {
      guard let item = itemsByHandle[handle] else { continue }
      switch NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: item.thumbnailData,
        cachedImage: thumbnailImageCache.object(forKey: NSNumber(value: handle)),
        hasFailedThumbnailRequest: false
      ) {
      case .none:
        continue
      case .decodeCachedData:
        if let data = item.thumbnailData {
          rehydrateRequests.append((handle: handle, data: data))
        }
      case .fetchFromCamera:
        handles.append(handle)
      }
    }
    rehydrateCachedThumbnailImages(rehydrateRequests)
    guard !handles.isEmpty else { return }
    guard NativeGalleryThumbnailLoadingPolicy.shouldStartCatalogWork(
      runtimeCanAcceptCatalogCommands: runtime.canAcceptCatalogCommands,
      isDownloading: runtime.isDownloading
    ) else {
      appendDiagnostic("Runtime 当前不接受缩略图命令，跳过本轮缩略图加载")
      return
    }
    runtime.requestVisibleGalleryThumbnails(handles: handles)
  }

  private func rehydrateCachedThumbnailImages(_ requests: [(handle: Int, data: Data)]) {
    for request in requests where thumbnailRehydrateTasks[request.handle] == nil {
      let handle = request.handle
      let data = request.data
      thumbnailRehydrateTasks[handle] = Task { [weak self] in
        let orientation = await MainActor.run {
          self?.catalogPresentation.items.first(where: { $0.handle == handle })?.orientation
        }
        let decodedImage = await NativeGalleryThumbnailDecodePipeline.decodedImage(
          from: data,
          objectOrientation: orientation
        )
        await MainActor.run { [weak self] in
          guard let self else { return }
          self.thumbnailRehydrateTasks.removeValue(forKey: handle)
          guard !Task.isCancelled, let decodedImage else { return }
          self.thumbnailImageCache.setObject(decodedImage, forKey: NSNumber(value: handle))
          self.refreshVisibleCells(forHandles: [handle])
        }
      }
    }
  }

  private func cancelThumbnailRehydrateTasks() {
    thumbnailRehydrateTasks.values.forEach { $0.cancel() }
    thumbnailRehydrateTasks.removeAll()
  }

  private func prioritizeGalleryInteraction() {
    guard NativeGallerySelectionRefreshPolicy.shouldPauseThumbnailLoadingDuringSelectionGesture else { return }
    visibleThumbnailRefreshTask?.cancel()
    visibleThumbnailRefreshTask = nil
  }

  private func pauseVisibleThumbnailLoadingForBackground() {
    guard NativeGalleryPresentationLifecyclePolicy.shouldPauseThumbnailRequests(
      applicationState: UIApplication.shared.applicationState,
      hasActiveCameraCommunication: hasActiveCameraCommunication
    ) else {
      return
    }
    visibleThumbnailRefreshTask?.cancel()
    visibleThumbnailRefreshTask = nil
    appendDiagnostic("[后台] 已暂停缩略图请求，保留相机连接")
  }

  private func scheduleVisibleThumbnailRefresh(after delay: TimeInterval = 0.15) {
    guard NativeGalleryThumbnailLoadingPolicy.shouldStartCatalogWork(
      runtimeCanAcceptCatalogCommands: runtime.canAcceptCatalogCommands,
      isDownloading: runtime.isDownloading
    ) else {
      return
    }
    guard visibleThumbnailRefreshTask == nil else { return }
    visibleThumbnailRefreshTask = Task { @MainActor in
      let nanoseconds = UInt64(delay * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      visibleThumbnailRefreshTask = nil
      loadVisibleThumbnails()
    }
  }

  private func toggleSelection(for item: CameraVendorGalleryItem) {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    prioritizeGalleryInteraction()
    let previousSelection = selectedHandles
    if selectedHandles.contains(item.handle) {
      selectedHandles.remove(item.handle)
    } else {
      selectedHandles.insert(item.handle)
    }
    refreshStatusText()
    refreshVisibleSelectionStates(
      forHandles: NativeGalleryUIInvalidationPolicy.changedHandles(
        before: previousSelection,
        after: selectedHandles
      )
    )
    refreshVisibleSectionHeaders()
    scheduleVisibleThumbnailRefresh(
      after: NativeGalleryInteractionPriorityPolicy.thumbnailResumeDelayAfterSelectionSeconds
    )
  }

  private func toggleSelection(forSectionAt sectionIndex: Int) {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    guard gallerySections.indices.contains(sectionIndex) else { return }
    let handles = runtime.downloadableHandles(from: gallerySections[sectionIndex].items.map(\.handle))
    let selectableHandles = Set(handles)
    guard !selectableHandles.isEmpty else { return }
    prioritizeGalleryInteraction()
    let previousSelection = selectedHandles
    var selection = selectedHandles
    if selectableHandles.isSubset(of: selection) {
      selection.subtract(selectableHandles)
    } else {
      selection.formUnion(selectableHandles)
    }
    selectedHandles = selection
    refreshStatusText()
    refreshVisibleSelectionStates(
      forHandles: NativeGalleryUIInvalidationPolicy.changedHandles(
        before: previousSelection,
        after: selectedHandles
      )
    )
    refreshVisibleSectionHeaders()
    scheduleVisibleThumbnailRefresh(
      after: NativeGalleryInteractionPriorityPolicy.thumbnailResumeDelayAfterSelectionSeconds
    )
  }

  private func indexPath(for item: CameraVendorGalleryItem) -> IndexPath? {
    indexPath(forHandle: item.handle)
  }

  private func indexPath(forHandle handle: Int) -> IndexPath? {
    for (sectionIndex, section) in gallerySections.enumerated() {
      if let itemIndex = section.items.firstIndex(where: { $0.handle == handle }) {
        return IndexPath(item: itemIndex, section: sectionIndex)
      }
    }
    return nil
  }

  private func configureGalleryCell(_ cell: NativeGalleryGridCell, at indexPath: IndexPath) {
    guard let item = galleryItem(at: indexPath) else { return }
    let downloadState = runtime.downloadState(for: item.handle)
    cell.configure(
      item: item,
      viewState: galleryEntryViewState(for: item.handle),
      isSelected: selectedHandles.contains(item.handle),
      downloadState: downloadState,
      thumbnailImage: thumbnailImageCache.object(forKey: NSNumber(value: item.handle))
    )
    cell.onSelectionTapped = { [weak self, weak cell] in
      guard let self,
            let cell,
            let indexPath = self.collectionView.indexPath(for: cell),
            let currentItem = self.galleryItem(at: indexPath) else {
        return
      }
      let currentState = self.runtime.downloadState(for: currentItem.handle)
      guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: self.runtime.isDownloading) else {
        return
      }
      guard NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: currentState) else { return }
      self.toggleSelection(for: currentItem)
    }
    cell.onClearCacheTapped = { [weak self, weak cell] in
      guard let self,
            let cell,
            let indexPath = self.collectionView.indexPath(for: cell),
            let currentItem = self.galleryItem(at: indexPath) else {
        return
      }
      guard self.runtime.downloadState(for: currentItem.handle) == .saved else { return }
      self.clearDownloadCache(for: currentItem)
    }
  }

  private func configureGalleryHeader(_ header: NativeGallerySectionHeaderView, at indexPath: IndexPath) {
    guard gallerySections.indices.contains(indexPath.section) else { return }
    let section = gallerySections[indexPath.section]
    let selectableHandles = Set(runtime.downloadableHandles(from: section.items.map(\.handle)))
    let allSelected = !selectableHandles.isEmpty && selectableHandles.isSubset(of: selectedHandles)
    header.configure(title: section.title, selectionTitle: allSelected ? "取消" : "全选")
    header.onSelectionTapped = { [weak self] in
      self?.toggleSelection(forSectionAt: indexPath.section)
    }
  }

  private func refreshVisibleCells(forHandles handles: Set<Int>) {
    guard !handles.isEmpty else { return }
    UIView.performWithoutAnimation {
      for indexPath in collectionView.indexPathsForVisibleItems {
        guard let item = galleryItem(at: indexPath),
              handles.contains(item.handle),
              let cell = collectionView.cellForItem(at: indexPath) as? NativeGalleryGridCell else {
          continue
        }
        configureGalleryCell(cell, at: indexPath)
      }
    }
  }

  private func refreshVisibleSelectionStates(forHandles handles: Set<Int>) {
    guard !handles.isEmpty else { return }
    guard !NativeGallerySelectionRefreshPolicy.shouldReconfigureImageDuringSelectionChange else {
      refreshVisibleCells(forHandles: handles)
      return
    }
    UIView.performWithoutAnimation {
      for indexPath in collectionView.indexPathsForVisibleItems {
        guard let item = galleryItem(at: indexPath),
              handles.contains(item.handle),
              let cell = collectionView.cellForItem(at: indexPath) as? NativeGalleryGridCell else {
          continue
        }
        cell.updateSelectionOnly(
          isSelected: selectedHandles.contains(item.handle),
          downloadState: runtime.downloadState(for: item.handle)
        )
      }
    }
  }

  private func refreshVisibleSectionHeaders() {
    UIView.performWithoutAnimation {
      let indexPaths = collectionView.indexPathsForVisibleSupplementaryElements(
        ofKind: UICollectionView.elementKindSectionHeader
      )
      for indexPath in indexPaths {
        guard let header = collectionView.supplementaryView(
          forElementKind: UICollectionView.elementKindSectionHeader,
          at: indexPath
        ) as? NativeGallerySectionHeaderView else {
          continue
        }
        configureGalleryHeader(header, at: indexPath)
      }
    }
  }

  private func presentPreview(startingAt index: Int) {
    guard NativeGalleryNavigationPolicy.canOpenPreview(isDownloading: runtime.isDownloading) else {
      showToast("正在下载，请先保持在照片筛选页面")
      return
    }
    let controller = NativePhotoPreviewViewController(
      items: catalogPresentation.items,
      initialIndex: index,
      runtime: runtime,
      shouldLoadPreviewThumbnail: { [weak self] in
        NativeGalleryPriorityDownloadPolicy.shouldLoadPreviewThumbnail(
          isDownloading: self?.runtime.isDownloading == true
        )
      },
      cachedThumbnailImageProvider: { [weak self] handle in
        self?.thumbnailImageCache.object(forKey: NSNumber(value: handle))
      },
      displayStateProvider: { [weak self] handle in
        self?.galleryEntryViewState(for: handle)
      },
      isSelected: { [weak self] handle in
        self?.selectedHandles.contains(handle) ?? false
      },
      downloadStateProvider: { [weak self] handle in
        self?.runtime.downloadState(for: handle) ?? .idle
      },
      onSelectionToggle: { [weak self] item in
        guard let self,
              NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: self.runtime.isDownloading),
              NativeGalleryDownloadSelectionPolicy.canSelect(
                downloadState: self.runtime.downloadState(for: item.handle)
              ) else { return }
        self.toggleSelection(for: item)
      },
      onDownload: { [weak self] item in
        guard let self else { return }
        if NativeGalleryPreviewDownloadPolicy.shouldDismissAfterStartingDownload {
          self.navigationController?.popViewController(animated: false)
        }
        self.openDownloadCenter(for: [item.handle])
      },
      isTransferLocked: { [weak self] in
        self?.runtime.isDownloading ?? false
      },
      onTransferLockedDismissAttempt: { [weak self] in
        self?.showToast("正在下载，请先保持在当前页面")
      }
    )
    navigationController?.pushViewController(controller, animated: true)
  }

  private func presentNotice(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "知道了", style: .default))
    present(alert, animated: true)
  }

  private func showToast(_ message: String) {
    toastLabel.text = "  \(message)  "
    view.bringSubviewToFront(toastLabel)
    UIView.animate(withDuration: 0.18) {
      self.toastLabel.alpha = 1
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
      guard let self else { return }
      UIView.animate(withDuration: 0.22) {
        self.toastLabel.alpha = 0
      }
    }
  }

  private func presentManualWifiNotice(message: String) {
    showWifiPromptOverlay()
  }

  func showWifiPromptOverlay() {
    if wifiPromptOverlay != nil { return }
    let overlay = NativeWifiPromptOverlay()
    let preferredWifi = summary.wifiConfigurations.first
    overlay.configure(ssidHint: preferredWifi?.ssid ?? summary.wifiCandidates.first, passphrase: preferredWifi?.passphrase)
    overlay.onOpenSettings = { [weak self] in
      guard let self else { return }
      self.openSystemWifiSettings()
    }
    overlay.onRetry = { [weak self] in
      guard let self else { return }
      self.appendDiagnostic("相册页面不重新启动连接协议，请返回连接页重新进入相册。")
      self.presentNotice(title: "请重新进入相册", message: "相册启动只允许由连接流程完成，不能在页面层重试。")
    }
    wifiPromptOverlay = overlay
    overlay.reveal(in: view)
  }

  func hideWifiPromptOverlay() {
    wifiPromptOverlay?.hide { [weak self] in
      self?.wifiPromptOverlay = nil
    }
  }

  private func openSystemWifiSettings() {
    let candidates = [
      "App-Prefs:root=WIFI",
      "App-Prefs:WIFI",
      "App-Prefs:Wi-Fi",
      "prefs:root=WIFI",
      "App-Prefs:",
    ]
    var index = 0
    func tryNext() {
      if index >= candidates.count {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url, options: [:], completionHandler: { _ in
            self.showToast("无法直接跳转，请点 ‹返回› 进入 Wi-Fi 选项")
          })
        }
        return
      }
      let next = candidates[index]
      index += 1
      guard let url = URL(string: next) else { tryNext(); return }
      UIApplication.shared.open(url, options: [:]) { success in
        if !success {
          tryNext()
        }
      }
    }
    tryNext()
  }
}

enum CameraVendorGalleryThumbnailRenderer {
  /// Decode a raw PTP-thumbnail data blob into a UIImage that is safe to
  /// display directly in a UIImageView using `.scaleAspectFill` without any
  /// extra letterboxing. We also detect & trim CameraVendor's baked-in black bars
  /// (cameras often hard-encode 4:3 thumbnails for 3:2 photos by adding
  /// black strips top & bottom; native UIImage(data:) preserves them).
  static func decoded(from data: Data, objectOrientation: Int? = nil) -> UIImage? {
    guard let raw = decodeRaw(data: data) else { return nil }
    let cropped = cropBlackBars(raw) ?? raw
    if cropped.imageOrientation != .up {
      return NativePhotoPreviewImageRenderer.rendered(image: cropped, manualRotationDegrees: 0)
    }
    let degrees = NativePhotoPreviewRotationPolicy.autoRotationDegrees(
      objectOrientation: objectOrientation,
      decodedWidth: Int(cropped.size.width),
      decodedHeight: Int(cropped.size.height),
      imageData: data
    )
    return NativePhotoPreviewImageRenderer.rendered(image: cropped, manualRotationDegrees: degrees)
  }

  private static func decodeRaw(data: Data) -> UIImage? {
    if let image = UIImage(data: data) { return image }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: cg)
  }

  /// Detect leading / trailing rows that are essentially solid black and
  /// crop them out. Designed for CameraVendor's camera-side thumbnails where 3:2
  /// photos arrive as 4:3 with black strips above and below.
  private static func cropBlackBars(_ image: UIImage) -> UIImage? {
    guard let cg = image.cgImage else { return nil }
    let width = cg.width
    let height = cg.height
    guard width > 4, height > 4 else { return nil }

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

    let darkThreshold: UInt8 = 16
    func rowIsDark(_ y: Int) -> Bool {
      let rowStart = y * bytesPerRow
      var sampleCount = 0
      var darkCount = 0
      for x in stride(from: 0, to: width, by: max(1, width / 24)) {
        let i = rowStart + x * bytesPerPixel
        let r = pixels[i]
        let g = pixels[i + 1]
        let b = pixels[i + 2]
        sampleCount += 1
        if r <= darkThreshold && g <= darkThreshold && b <= darkThreshold {
          darkCount += 1
        }
      }
      return darkCount >= max(1, sampleCount - 1)
    }

    var top = 0
    while top < height && rowIsDark(top) { top += 1 }
    var bottom = height - 1
    while bottom > top && rowIsDark(bottom) { bottom -= 1 }
    let trimmedHeight = bottom - top + 1
    let trimAmount = height - trimmedHeight
    // Only crop if the bars are notable (>3% of original height) and we
    // didn't trim away too much (the photo isn't actually a black photo).
    guard trimAmount > Int(Double(height) * 0.03), trimmedHeight > height / 2 else {
      return nil
    }
    let cropRect = CGRect(x: 0, y: top, width: width, height: trimmedHeight)
    guard let cropped = cg.cropping(to: cropRect) else { return nil }
    return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
  }
}

private final class NativeDownloadListViewController: UIViewController {
  private let runtime: CameraSessionRuntime
  private let itemsProvider: () -> [CameraVendorGalleryItem]
  private let stateProvider: (Int) -> CameraVendorDownloadState
  private let progressProvider: (Int) -> String?
  private let isTransferActiveProvider: () -> Bool
  private let onTerminateDownload: () -> Void
  private let onClearDownloadCache: (CameraVendorGalleryItem) -> Void
  private var previousNavigationBarHidden: Bool?
  private var runtimePresentationObserverID: UUID?
  private var hasObservedActiveTransfer = false
  private let thumbnailImageCache = NSCache<NSNumber, UIImage>()
  private var thumbnailRehydrateTasks: [Int: Task<Void, Never>] = [:]

  private let backButton = NativeGalleryHeaderIconButton(icon: .back, accessibilityLabel: "返回")
  private let headerTitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = NativeDownloadCenterChrome.title
    label.font = .systemFont(ofSize: 13, weight: .black)
    label.textColor = NativeLuxuryTheme.ink
    label.textAlignment = .center
    return label
  }()
  private let clearRecordsButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.baseForegroundColor = NativeLuxuryTheme.ink
    config.baseBackgroundColor = NativeLuxuryTheme.warmFill
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    config.attributedTitle = AttributedString(NativeDownloadCenterChrome.clearRecordsTitle, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .black)
    ]))
    button.configuration = config
    button.layer.borderWidth = 1
    button.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    button.layer.cornerRadius = 17
    button.accessibilityLabel = NativeDownloadCenterChrome.clearRecordsTitle
    return button
  }()
  private let headerSpinner: UIActivityIndicatorView = {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = NativeLuxuryTheme.accent
    spinner.hidesWhenStopped = true
    return spinner
  }()
  private let summaryLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.numberOfLines = 1
    return label
  }()

  private let footerLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.textAlignment = .center
    label.numberOfLines = 1
    return label
  }()

  private let collectionView: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = NativeDownloadCenterChrome.gridHorizontalSpacing
    layout.minimumLineSpacing = NativeDownloadCenterChrome.gridVerticalSpacing
    layout.sectionInset = NativeDownloadCenterChrome.gridInsets
    let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
    view.register(NativeGalleryGridCell.self, forCellWithReuseIdentifier: NativeGalleryGridCell.reuseIdentifier)
    return view
  }()

  private let emptyContainer: UIStackView = {
    let icon = UIImageView(image: UIImage(systemName: "tray", withConfiguration: UIImage.SymbolConfiguration(pointSize: 36, weight: .light)))
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.tintColor = NativeLuxuryTheme.secondaryInk.withAlphaComponent(0.5)
    icon.contentMode = .scaleAspectFit

    let title = UILabel()
    title.translatesAutoresizingMaskIntoConstraints = false
	    title.text = NativeDownloadCenterChrome.emptyTitle
    title.font = .systemFont(ofSize: 16, weight: .semibold)
    title.textColor = NativeLuxuryTheme.ink
    title.textAlignment = .center

    let copy = UILabel()
    copy.translatesAutoresizingMaskIntoConstraints = false
	    copy.text = ""
    copy.font = .systemFont(ofSize: 13, weight: .regular)
    copy.textColor = NativeLuxuryTheme.secondaryInk
    copy.numberOfLines = 0
    copy.textAlignment = .center

	    let stack = UIStackView(arrangedSubviews: [icon, title])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 12
    stack.alignment = .center
    stack.isHidden = true
    return stack
  }()

  init(
    runtime: CameraSessionRuntime,
    itemsProvider: @escaping () -> [CameraVendorGalleryItem],
    stateProvider: @escaping (Int) -> CameraVendorDownloadState,
    progressProvider: @escaping (Int) -> String?,
    isTransferActiveProvider: @escaping () -> Bool,
    onTerminateDownload: @escaping () -> Void,
    onClearDownloadCache: @escaping (CameraVendorGalleryItem) -> Void
  ) {
    self.runtime = runtime
    self.itemsProvider = itemsProvider
    self.stateProvider = stateProvider
    self.progressProvider = progressProvider
    self.isTransferActiveProvider = isTransferActiveProvider
    self.onTerminateDownload = onTerminateDownload
    self.onClearDownloadCache = onClearDownloadCache
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
    title = ""
    navigationItem.hidesBackButton = true
    view.backgroundColor = NativeLuxuryTheme.background

    let headerBar = UIView()
    headerBar.translatesAutoresizingMaskIntoConstraints = false
    headerBar.addSubview(backButton)
    headerBar.addSubview(headerTitleLabel)
    headerBar.addSubview(clearRecordsButton)
    let summaryRow = UIStackView(arrangedSubviews: [headerSpinner, summaryLabel])
    summaryRow.translatesAutoresizingMaskIntoConstraints = false
    summaryRow.axis = .horizontal
    summaryRow.spacing = 8
    summaryRow.alignment = .center
    let header = UIStackView(arrangedSubviews: [headerBar, summaryRow])
    header.translatesAutoresizingMaskIntoConstraints = false
    header.axis = .vertical
    header.spacing = NativeGalleryTopChromePolicy.statusSpacing
    let headerFrame = NativeTopHeaderFrameView()
    headerFrame.addSubview(header)

    view.addSubview(headerFrame)
    view.addSubview(collectionView)
    view.addSubview(emptyContainer)
    collectionView.dataSource = self
    collectionView.delegate = self
    backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
    clearRecordsButton.addTarget(self, action: #selector(clearRecordsTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      headerFrame.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: NativeGalleryTopChromePolicy.topInset),
      headerFrame.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: NativeGalleryTopChromePolicy.horizontalInset),
      headerFrame.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -NativeGalleryTopChromePolicy.horizontalInset),

      header.topAnchor.constraint(equalTo: headerFrame.topAnchor),
      header.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),
      header.bottomAnchor.constraint(equalTo: headerFrame.bottomAnchor, constant: -NativeGalleryTopChromePolicy.bottomInset),

      headerBar.heightAnchor.constraint(equalToConstant: NativeGalleryTopChromePolicy.actionRowHeight),
      backButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
      backButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      headerTitleLabel.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
      headerTitleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      headerTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: NativeGalleryTopChromePolicy.actionSpacing),
      clearRecordsButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
      clearRecordsButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      clearRecordsButton.heightAnchor.constraint(equalToConstant: 34),
      headerTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearRecordsButton.leadingAnchor, constant: -NativeGalleryTopChromePolicy.actionSpacing),

      collectionView.topAnchor.constraint(equalTo: headerFrame.bottomAnchor, constant: 12),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      emptyContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyContainer.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor, constant: -20),
      emptyContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
      emptyContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
    ])
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(downloadStateDidChange),
      name: .nativeDownloadStateDidChange,
      object: nil
    )
    hasObservedActiveTransfer = isTransferActiveProvider()
    runtimePresentationObserverID = runtime.observe { [weak self] _ in
      self?.downloadStateDidChange()
    }
    refreshSummary()
    refreshEmptyState()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    cancelThumbnailRehydrateTasks()
    if let runtimePresentationObserverID {
      let runtime = runtime
      Task { @MainActor in
        runtime.removeObserver(runtimePresentationObserverID)
      }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    applyTopChromeNavigationState(animated: animated)
    collectionView.reloadData()
    refreshSummary()
    refreshEmptyState()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
      restoreTopChromeNavigationState(animated: animated)
    }
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .darkContent
  }

  private func applyTopChromeNavigationState(animated: Bool) {
    guard NativeGalleryTopChromePolicy.shouldHideSystemNavigationBar,
          let navigationController else {
      return
    }
    if previousNavigationBarHidden == nil {
      previousNavigationBarHidden = navigationController.isNavigationBarHidden
    }
    navigationController.setNavigationBarHidden(true, animated: animated)
  }

  private func restoreTopChromeNavigationState(animated: Bool) {
    guard NativeGalleryTopChromePolicy.shouldHideSystemNavigationBar,
          let navigationController,
          let wasHidden = previousNavigationBarHidden else {
      return
    }
    navigationController.setNavigationBarHidden(wasHidden, animated: animated)
    previousNavigationBarHidden = nil
  }

  @objc private func backTapped() {
    guard isTransferActiveProvider() else {
      navigationController?.popViewController(animated: true)
      return
    }
    let alert = UIAlertController(
      title: NativeDownloadCenterChrome.terminateAlertTitle,
      message: NativeDownloadCenterChrome.terminateAlertMessage,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: NativeDownloadCenterChrome.terminateAlertCancelTitle, style: .cancel))
    alert.addAction(UIAlertAction(title: NativeDownloadCenterChrome.terminateAlertConfirmTitle, style: .destructive) { [weak self] _ in
      self?.hasObservedActiveTransfer = false
      self?.onTerminateDownload()
      self?.navigationController?.popViewController(animated: true)
    })
    present(alert, animated: true)
  }

  @objc private func clearRecordsTapped() {
    guard clearRecordsButton.isEnabled else { return }
    itemsProvider().forEach(onClearDownloadCache)
    collectionView.reloadData()
    refreshSummary()
    refreshEmptyState()
  }

  @objc private func downloadStateDidChange() {
    let isTransferActive = isTransferActiveProvider()
    if isTransferActive {
      hasObservedActiveTransfer = true
    }
    collectionView.reloadData()
    refreshSummary()
    refreshEmptyState()
    guard hasObservedActiveTransfer,
          !isTransferActive,
          navigationController?.topViewController === self else { return }
    hasObservedActiveTransfer = false
    navigationController?.popViewController(animated: true)
  }

  private func refreshEmptyState() {
    let isEmpty = itemsProvider().isEmpty
    emptyContainer.isHidden = !isEmpty
    collectionView.isHidden = isEmpty
  }

  private func refreshSummary() {
    let items = itemsProvider()
    let total = items.count
    var saved = 0
    var active = 0
    for item in items {
      switch stateProvider(item.handle) {
      case .saved: saved += 1
      case .downloading, .queued: active += 1
      case .idle, .failed: break
      }
    }
    summaryLabel.text = NativeDownloadCenterChrome.summary(
      totalCount: total,
      doneCount: saved,
      activeCount: active
    )
    if active > 0 {
      headerSpinner.startAnimating()
    } else {
      headerSpinner.stopAnimating()
    }
    let isTransferActive = isTransferActiveProvider()
    clearRecordsButton.isHidden = isTransferActive
    clearRecordsButton.isEnabled = total > 0 && !isTransferActive
    clearRecordsButton.alpha = clearRecordsButton.isEnabled ? 1 : 0.48
    backButton.isEnabled = true
    backButton.alpha = 1
  }

  private func configure(_ cell: NativeGalleryGridCell, with item: CameraVendorGalleryItem) {
    cell.configure(
      item: item,
      isSelected: false,
      downloadState: stateProvider(item.handle),
      thumbnailImage: thumbnailImageCache.object(forKey: NSNumber(value: item.handle)),
      showsSelection: false,
      dimsUndownloaded: true
    )
    rehydrateCachedThumbnailIfNeeded(for: item)
  }

  private func rehydrateCachedThumbnailIfNeeded(for item: CameraVendorGalleryItem) {
    switch NativeDownloadCenterThumbnailPolicy.action(
      thumbnailData: item.thumbnailData,
      cachedImage: thumbnailImageCache.object(forKey: NSNumber(value: item.handle))
    ) {
    case .none, .fetchFromCamera:
      return
    case .decodeCachedData:
      guard thumbnailRehydrateTasks[item.handle] == nil,
            let data = item.thumbnailData else { return }
      let handle = item.handle
      let orientation = item.orientation
      thumbnailRehydrateTasks[handle] = Task { [weak self] in
        let decodedImage = await NativeGalleryThumbnailDecodePipeline.decodedImage(
          from: data,
          objectOrientation: orientation
        )
        await MainActor.run { [weak self] in
          guard let self else { return }
          self.thumbnailRehydrateTasks.removeValue(forKey: handle)
          guard !Task.isCancelled, let decodedImage else { return }
          self.thumbnailImageCache.setObject(decodedImage, forKey: NSNumber(value: handle))
          self.refreshVisibleCell(forHandle: handle)
        }
      }
    }
  }

  private func refreshVisibleCell(forHandle handle: Int) {
    UIView.performWithoutAnimation {
      for indexPath in collectionView.indexPathsForVisibleItems {
        let items = itemsProvider()
        guard items.indices.contains(indexPath.item),
              items[indexPath.item].handle == handle,
              let cell = collectionView.cellForItem(at: indexPath) as? NativeGalleryGridCell else {
          continue
        }
        configure(cell, with: items[indexPath.item])
      }
    }
  }

  private func cancelThumbnailRehydrateTasks() {
    thumbnailRehydrateTasks.values.forEach { $0.cancel() }
    thumbnailRehydrateTasks.removeAll()
  }
}

extension NativeDownloadListViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    itemsProvider().count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    guard let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: NativeGalleryGridCell.reuseIdentifier,
      for: indexPath
    ) as? NativeGalleryGridCell else {
      return UICollectionViewCell()
    }
    let item = itemsProvider()[indexPath.item]
    configure(cell, with: item)
    cell.onClearCacheTapped = { [weak self, weak collectionView, weak cell] in
      guard let self,
            let cell,
            let indexPath = collectionView?.indexPath(for: cell) else {
        return
      }
      let items = self.itemsProvider()
      guard items.indices.contains(indexPath.item) else { return }
      let currentItem = items[indexPath.item]
      guard self.stateProvider(currentItem.handle) == .saved else { return }
      self.onClearDownloadCache(currentItem)
    }
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let side = NativeGalleryGridLayoutPolicy.itemSide(
      forCollectionWidth: collectionView.bounds.width,
      horizontalInset: NativeDownloadCenterChrome.gridInsets.left,
      interItemSpacing: NativeDownloadCenterChrome.gridHorizontalSpacing,
      columns: NativeDownloadCenterChrome.gridColumnCount
    )
    return CGSize(width: side, height: side)
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: true)
  }
}

extension NativeGalleryViewController: UICollectionViewDataSource {
  func numberOfSections(in collectionView: UICollectionView) -> Int {
    gallerySections.isEmpty ? 1 : gallerySections.count
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    guard gallerySections.indices.contains(section) else { return 0 }
    return gallerySections[section].items.count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    guard let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: NativeGalleryGridCell.reuseIdentifier,
      for: indexPath
    ) as? NativeGalleryGridCell else {
      return UICollectionViewCell()
    }
    configureGalleryCell(cell, at: indexPath)
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    viewForSupplementaryElementOfKind kind: String,
    at indexPath: IndexPath
  ) -> UICollectionReusableView {
    guard kind == UICollectionView.elementKindSectionHeader,
          let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: NativeGallerySectionHeaderView.reuseIdentifier,
            for: indexPath
          ) as? NativeGallerySectionHeaderView,
          gallerySections.indices.contains(indexPath.section) else {
      return UICollectionReusableView()
    }
    configureGalleryHeader(header, at: indexPath)
    return header
  }
}

extension NativeGalleryViewController: UICollectionViewDelegateFlowLayout {
  func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    scheduleVisibleThumbnailRefresh()
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard let item = galleryItem(at: indexPath),
          let flatIndex = catalogPresentation.items.firstIndex(where: { $0.handle == item.handle }) else {
      return
    }
    presentPreview(startingAt: flatIndex)
  }

  private var horizontalInsetForCurrentLayout: CGFloat {
    12
  }

  private var spacingForCurrentLayout: CGFloat {
    NativeGalleryGridLayoutPolicy.androidGridSpacing
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let side = NativeGalleryGridLayoutPolicy.itemSide(
      forCollectionWidth: collectionView.bounds.width,
      horizontalInset: horizontalInsetForCurrentLayout,
      interItemSpacing: spacingForCurrentLayout,
      columns: currentColumnCount
    )
    return CGSize(width: side, height: side)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    insetForSectionAt section: Int
  ) -> UIEdgeInsets {
    let inset = horizontalInsetForCurrentLayout
    let bottom: CGFloat = section == max(gallerySections.count - 1, 0) ? 96 : 4
    return UIEdgeInsets(top: 0, left: inset, bottom: bottom, right: inset)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    referenceSizeForHeaderInSection section: Int
  ) -> CGSize {
    guard gallerySections.indices.contains(section) else { return .zero }
    return CGSize(width: collectionView.bounds.width, height: 44)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    minimumInteritemSpacingForSectionAt section: Int
  ) -> CGFloat {
    spacingForCurrentLayout
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    minimumLineSpacingForSectionAt section: Int
  ) -> CGFloat {
    spacingForCurrentLayout
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      scheduleVisibleThumbnailRefresh(after: 0.05)
    }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    scheduleVisibleThumbnailRefresh(after: 0.05)
  }
}

private final class NativeGallerySectionHeaderView: UICollectionReusableView {
  static let reuseIdentifier = "NativeGallerySectionHeaderView"

  var onSelectionTapped: (() -> Void)?

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 15, weight: .black)
    label.textColor = NativeLuxuryTheme.ink
    label.numberOfLines = 1
    return label
  }()

  private let selectionButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.baseBackgroundColor = NativeLuxuryTheme.mutedFill
    config.baseForegroundColor = NativeLuxuryTheme.ink
    config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
    button.configuration = config
    return button
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = NativeLuxuryTheme.background
    addSubview(titleLabel)
    addSubview(selectionButton)
    selectionButton.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectionButton.leadingAnchor, constant: -8),

      selectionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      selectionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      selectionButton.heightAnchor.constraint(equalToConstant: 28),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onSelectionTapped = nil
  }

  func configure(title: String, selectionTitle: String) {
    titleLabel.text = title
    selectionButton.configuration?.attributedTitle = AttributedString(selectionTitle, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
  }

  @objc private func selectionTapped() {
    onSelectionTapped?()
  }
}

private final class NativeGalleryGridCell: UICollectionViewCell {
  static let reuseIdentifier = "NativeGalleryGridCell"

  var onSelectionTapped: (() -> Void)?
  var onClearCacheTapped: (() -> Void)?

  private let imageView: UIImageView = {
    let view = UIImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    view.tintColor = .tertiaryLabel
    return view
  }()

  private let selectionButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = NativeLuxuryTheme.cardBackground
    button.backgroundColor = UIColor.white.withAlphaComponent(0.7)
    button.layer.cornerRadius = 13
    button.accessibilityLabel = "选择照片"
    return button
  }()

  private let downloadActivityIndicator: UIActivityIndicatorView = {
    let view = UIActivityIndicatorView(style: .medium)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.hidesWhenStopped = true
    view.color = .white
    view.backgroundColor = UIColor.black.withAlphaComponent(0.42)
    view.layer.cornerRadius = 18
    return view
  }()

  private let labelContainer: UIVisualEffectView = {
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .white
    label.lineBreakMode = .byTruncatingMiddle
    return label
  }()

  private let detailLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 10, weight: .medium)
    label.textColor = UIColor.white.withAlphaComponent(0.86)
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private let formatBadgeLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 8.5, weight: .heavy)
    label.textColor = NativeLuxuryTheme.ink
    label.textAlignment = .center
    label.backgroundColor = UIColor.white.withAlphaComponent(0.92)
    label.layer.cornerRadius = 7
    label.clipsToBounds = true
    return label
  }()

  private let statusBadgeLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 7.5, weight: .heavy)
    label.textColor = NativeLuxuryTheme.cardBackground
    label.textAlignment = .center
    label.backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.78)
    label.layer.cornerRadius = 6
    label.clipsToBounds = true
    label.isHidden = true
    return label
  }()

  private let clearCacheButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var configuration = UIButton.Configuration.filled()
    configuration.attributedTitle = AttributedString("清缓存", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 10, weight: .heavy)
    ]))
    configuration.baseForegroundColor = NativeLuxuryTheme.ink
    configuration.baseBackgroundColor = UIColor.white.withAlphaComponent(0.92)
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7)
    button.configuration = configuration
    button.layer.cornerRadius = 10
    button.clipsToBounds = true
    button.isHidden = true
    button.accessibilityLabel = "清理下载缓存"
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

  override func prepareForReuse() {
    super.prepareForReuse()
    imageView.image = nil
    imageView.alpha = 1
    titleLabel.text = nil
    detailLabel.text = nil
    formatBadgeLabel.text = nil
    statusBadgeLabel.text = nil
    statusBadgeLabel.isHidden = true
    onSelectionTapped = nil
    onClearCacheTapped = nil
    selectionButton.isEnabled = true
    clearCacheButton.isHidden = true
    downloadActivityIndicator.stopAnimating()
  }

  func configure(
    item: CameraVendorGalleryItem,
    viewState: CameraGalleryEntryViewState? = nil,
    isSelected: Bool,
    downloadState: CameraVendorDownloadState,
    thumbnailImage: UIImage? = nil,
    showsSelection: Bool = true,
    dimsUndownloaded: Bool = false
  ) {
    titleLabel.text = nil
    detailLabel.text = nil
    formatBadgeLabel.text = NativeGalleryFormatDisplayPolicy.badgeText(for: item, viewState: viewState)
    formatBadgeLabel.isHidden = formatBadgeLabel.text == nil
    let decodedFallbackImage = NativeGalleryCellThumbnailDecodePolicy.shouldDecodeDataDuringCellConfigure
      ? item.thumbnailData.flatMap { CameraVendorGalleryThumbnailRenderer.decoded(from: $0, objectOrientation: item.orientation) }
      : nil
    if let image = thumbnailImage ?? decodedFallbackImage {
      imageView.contentMode = .scaleAspectFill
      imageView.image = image
      imageView.tintColor = NativeLuxuryTheme.cardBackground
    } else {
      imageView.image = UIImage(systemName: "photo")
      imageView.tintColor = NativeLuxuryTheme.secondaryInk.withAlphaComponent(0.4)
      imageView.contentMode = .center
    }
    updateDownloadAppearance(downloadState, dimsUndownloaded: dimsUndownloaded)
    updateSelection(isSelected, downloadState: downloadState, showsSelection: showsSelection)
  }

  func updateSelectionOnly(
    isSelected: Bool,
    downloadState: CameraVendorDownloadState,
    showsSelection: Bool = true
  ) {
    updateSelection(isSelected, downloadState: downloadState, showsSelection: showsSelection)
  }

  private func setup() {
    contentView.backgroundColor = UIColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 1)
    contentView.layer.cornerRadius = 18
    contentView.clipsToBounds = true
    contentView.addSubview(imageView)
    contentView.addSubview(labelContainer)
    contentView.addSubview(selectionButton)
    contentView.addSubview(downloadActivityIndicator)
    contentView.addSubview(formatBadgeLabel)
    contentView.addSubview(statusBadgeLabel)
    contentView.addSubview(clearCacheButton)
    labelContainer.contentView.addSubview(titleLabel)
    labelContainer.contentView.addSubview(detailLabel)
    labelContainer.isHidden = true
    selectionButton.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)
    clearCacheButton.addTarget(self, action: #selector(clearCacheTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      selectionButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
      selectionButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 7),
      selectionButton.widthAnchor.constraint(equalToConstant: 26),
      selectionButton.heightAnchor.constraint(equalToConstant: 26),

      downloadActivityIndicator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
      downloadActivityIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
      downloadActivityIndicator.widthAnchor.constraint(equalToConstant: 28),
      downloadActivityIndicator.heightAnchor.constraint(equalToConstant: 28),

      statusBadgeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
      statusBadgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
      statusBadgeLabel.heightAnchor.constraint(equalToConstant: 13),
      statusBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),

      clearCacheButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
      clearCacheButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
      clearCacheButton.heightAnchor.constraint(equalToConstant: 22),
      clearCacheButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 50),

      formatBadgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
      formatBadgeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
      formatBadgeLabel.heightAnchor.constraint(equalToConstant: 15),
      formatBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),

      labelContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      labelContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      labelContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      titleLabel.topAnchor.constraint(equalTo: labelContainer.contentView.topAnchor, constant: 6),
      titleLabel.leadingAnchor.constraint(equalTo: labelContainer.contentView.leadingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: labelContainer.contentView.trailingAnchor, constant: -8),

      detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      detailLabel.bottomAnchor.constraint(equalTo: labelContainer.contentView.bottomAnchor, constant: -6),
    ])
  }

  private func updateSelection(_ isSelected: Bool, downloadState: CameraVendorDownloadState, showsSelection: Bool) {
    let canSelect = canSelectForDownload(downloadState)
    // Hide the selection circle entirely for photos that already have a
    // download status (saved / queued / downloading). Those cells already
    // show a status badge, so a redundant empty circle just adds noise.
    selectionButton.isHidden = !showsSelection || !canSelect
    guard !selectionButton.isHidden else { return }
    selectionButton.isEnabled = true
    if isSelected {
      let symbol = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .heavy))
      selectionButton.setImage(symbol, for: .normal)
      selectionButton.tintColor = NativeLuxuryTheme.cardBackground
      selectionButton.backgroundColor = NativeLuxuryTheme.ink
    } else {
      selectionButton.setImage(nil, for: .normal)
      selectionButton.backgroundColor = UIColor.white.withAlphaComponent(0.7)
    }
    selectionButton.layer.borderColor = NativeLuxuryTheme.cardBackground.withAlphaComponent(0.6).cgColor
    selectionButton.layer.borderWidth = isSelected ? 0 : 1.5
    selectionButton.alpha = 1
  }

  private func updateDownloadAppearance(_ state: CameraVendorDownloadState, dimsUndownloaded: Bool) {
    switch state {
    case .idle:
      imageView.alpha = dimsUndownloaded ? 0.58 : 1
      statusBadgeLabel.isHidden = true
      clearCacheButton.isHidden = true
      downloadActivityIndicator.stopAnimating()
    case .failed:
      imageView.alpha = 0.86
      statusBadgeLabel.text = " 失败 "
      statusBadgeLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.86)
      statusBadgeLabel.textColor = NativeLuxuryTheme.cardBackground
      statusBadgeLabel.isHidden = false
      clearCacheButton.isHidden = true
      downloadActivityIndicator.stopAnimating()
    case .queued:
      imageView.alpha = 0.86
      statusBadgeLabel.text = " 排队 "
      statusBadgeLabel.backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.78)
      statusBadgeLabel.textColor = NativeLuxuryTheme.cardBackground
      statusBadgeLabel.isHidden = false
      clearCacheButton.isHidden = true
      downloadActivityIndicator.stopAnimating()
    case .downloading:
      imageView.alpha = 0.86
      statusBadgeLabel.text = " 下载中 "
      statusBadgeLabel.backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.78)
      statusBadgeLabel.textColor = NativeLuxuryTheme.cardBackground
      statusBadgeLabel.isHidden = false
      clearCacheButton.isHidden = true
      downloadActivityIndicator.stopAnimating()
    case .saved:
      imageView.alpha = 1
      statusBadgeLabel.text = " 已保存 "
      statusBadgeLabel.backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.78)
      statusBadgeLabel.textColor = NativeLuxuryTheme.cardBackground
      statusBadgeLabel.isHidden = false
      clearCacheButton.isHidden = true
      downloadActivityIndicator.stopAnimating()
    }
  }

  private func canSelectForDownload(_ state: CameraVendorDownloadState) -> Bool {
    switch state {
    case .idle, .failed:
      return true
    case .queued, .downloading, .saved:
      return false
    }
  }

  private func stateText(for state: CameraVendorDownloadState) -> String {
    switch state {
    case .idle:
      return "未下载"
    case .queued:
      return "下载列表中"
    case .downloading:
      return "下载中"
    case .saved:
      return "已保存"
    case .failed:
      return "失败"
    }
  }

  @objc private func selectionTapped() {
    onSelectionTapped?()
  }

  @objc private func clearCacheTapped() {
    onClearCacheTapped?()
  }
}

private final class NativePhotoPreviewViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
  private let items: [CameraVendorGalleryItem]
  private let runtime: CameraSessionRuntime
  private let shouldLoadPreviewThumbnail: () -> Bool
  private let cachedThumbnailImageProvider: (Int) -> UIImage?
  private let displayStateProvider: (Int) -> CameraGalleryEntryViewState?
  private let isSelected: (Int) -> Bool
  private let downloadStateProvider: (Int) -> CameraVendorDownloadState
  private let onSelectionToggle: (CameraVendorGalleryItem) -> Void
  private let onDownload: (CameraVendorGalleryItem) -> Void
  private let isTransferLocked: () -> Bool
  private let onTransferLockedDismissAttempt: () -> Void
  private let previewImageCache = NativeGalleryHighDefinitionPreviewCache()
  private var currentIndex: Int
  private var pageController: UIPageViewController!
  private var controlsHidden = false

  private let topBar: NativeGradientChromeView = {
    let view = NativeGradientChromeView(direction: .topToBottom)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 15, weight: .semibold)
    label.textColor = .white
    label.textAlignment = .center
    return label
  }()

  private let subtitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = UIColor.white.withAlphaComponent(0.7)
    label.textAlignment = .center
    return label
  }()

  private let closeButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
    button.accessibilityLabel = "关闭"
    return button
  }()

  private let rotateButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.setImage(UIImage(systemName: "rotate.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
    button.accessibilityLabel = "向右旋转"
    return button
  }()

  private let rotateLeftButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.setImage(UIImage(systemName: "rotate.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
    button.accessibilityLabel = "向左旋转"
    return button
  }()

  private let bottomBar: NativeGradientChromeView = {
    let view = NativeGradientChromeView(direction: .bottomToTop)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let selectionButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.accessibilityLabel = "选择当前照片"
    return button
  }()

  private let downloadButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.title = "下载原图"
    config.image = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
    config.imagePadding = 6
    config.cornerStyle = .capsule
    config.baseBackgroundColor = .white
    config.baseForegroundColor = NativeLuxuryTheme.ink
    config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
    config.attributedTitle = AttributedString("下载原图", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .bold)
    ]))
    button.configuration = config
    return button
  }()

  init(
    items: [CameraVendorGalleryItem],
    initialIndex: Int,
    runtime: CameraSessionRuntime,
    shouldLoadPreviewThumbnail: @escaping () -> Bool,
    cachedThumbnailImageProvider: @escaping (Int) -> UIImage?,
    displayStateProvider: @escaping (Int) -> CameraGalleryEntryViewState?,
    isSelected: @escaping (Int) -> Bool,
    downloadStateProvider: @escaping (Int) -> CameraVendorDownloadState,
    onSelectionToggle: @escaping (CameraVendorGalleryItem) -> Void,
    onDownload: @escaping (CameraVendorGalleryItem) -> Void,
    isTransferLocked: @escaping () -> Bool,
    onTransferLockedDismissAttempt: @escaping () -> Void
  ) {
    self.items = items
    self.currentIndex = min(max(initialIndex, 0), max(items.count - 1, 0))
    self.runtime = runtime
    self.shouldLoadPreviewThumbnail = shouldLoadPreviewThumbnail
    self.cachedThumbnailImageProvider = cachedThumbnailImageProvider
    self.displayStateProvider = displayStateProvider
    self.isSelected = isSelected
    self.downloadStateProvider = downloadStateProvider
    self.onSelectionToggle = onSelectionToggle
    self.onDownload = onDownload
    self.isTransferLocked = isTransferLocked
    self.onTransferLockedDismissAttempt = onTransferLockedDismissAttempt
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    setupUI()
    refreshChromeForCurrentItem()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(downloadStateChanged),
      name: .nativeDownloadStateDidChange,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: animated)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    navigationController?.setNavigationBarHidden(false, animated: animated)
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .lightContent
  }

  override var prefersStatusBarHidden: Bool {
    controlsHidden
  }

  override var prefersHomeIndicatorAutoHidden: Bool {
    controlsHidden
  }

  private func setupUI() {
    view.backgroundColor = .black

    pageController = UIPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: .horizontal,
      options: [UIPageViewController.OptionsKey.interPageSpacing: 24]
    )
    pageController.dataSource = self
    pageController.delegate = self
    addChild(pageController)
    view.addSubview(pageController.view)
    pageController.view.translatesAutoresizingMaskIntoConstraints = false
    pageController.didMove(toParent: self)

    if items.indices.contains(currentIndex) {
      let initialPage = makePage(for: currentIndex)
      pageController.setViewControllers([initialPage], direction: .forward, animated: false)
    }

    view.addSubview(topBar)
    topBar.addSubview(closeButton)
    topBar.addSubview(titleLabel)
    topBar.addSubview(subtitleLabel)

    view.addSubview(bottomBar)
    bottomBar.addSubview(selectionButton)
    bottomBar.addSubview(rotateLeftButton)
    bottomBar.addSubview(rotateButton)
    bottomBar.addSubview(downloadButton)

    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    rotateLeftButton.addTarget(self, action: #selector(rotateLeftTapped), for: .touchUpInside)
    rotateButton.addTarget(self, action: #selector(rotateTapped), for: .touchUpInside)
    selectionButton.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)
    downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)

    let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
    tap.cancelsTouchesInView = false
    pageController.view.addGestureRecognizer(tap)

    NSLayoutConstraint.activate([
      pageController.view.topAnchor.constraint(equalTo: view.topAnchor),
      pageController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pageController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pageController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      topBar.topAnchor.constraint(equalTo: view.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),

      closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
      closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),
      closeButton.widthAnchor.constraint(equalToConstant: 36),
      closeButton.heightAnchor.constraint(equalToConstant: 36),

      titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -16),
      titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -2),

      subtitleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 10),
      subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -16),
      subtitleLabel.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),

      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bottomBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -68),

      selectionButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 22),
      selectionButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 14),
      selectionButton.widthAnchor.constraint(equalToConstant: 44),
      selectionButton.heightAnchor.constraint(equalToConstant: 44),

      rotateLeftButton.leadingAnchor.constraint(equalTo: selectionButton.trailingAnchor, constant: 12),
      rotateLeftButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
      rotateLeftButton.widthAnchor.constraint(equalToConstant: 40),
      rotateLeftButton.heightAnchor.constraint(equalToConstant: 40),

      rotateButton.leadingAnchor.constraint(equalTo: rotateLeftButton.trailingAnchor, constant: 8),
      rotateButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
      rotateButton.widthAnchor.constraint(equalToConstant: 40),
      rotateButton.heightAnchor.constraint(equalToConstant: 40),

      downloadButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -18),
      downloadButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
      downloadButton.leadingAnchor.constraint(greaterThanOrEqualTo: rotateButton.trailingAnchor, constant: 12),
    ])
  }

  private func makePage(for index: Int) -> NativePhotoPreviewPageController {
    let item = items[index]
    return NativePhotoPreviewPageController(
      item: item,
      index: index,
      runtime: runtime,
      cachedThumbnailImage: cachedThumbnailImageProvider(item.handle),
      canDismiss: { [weak self] in
        guard let self else { return true }
        return NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: self.isTransferLocked())
      },
      shouldLoadPreviewThumbnail: shouldLoadPreviewThumbnail,
      onDismissDrag: { [weak self] progress in
        self?.applyDismissDragProgress(progress)
      },
      onDismissBlocked: { [weak self] in
        self?.onTransferLockedDismissAttempt()
      },
      onDismissCommit: { [weak self] in
        self?.dismissPreview()
      },
      onDismissCancel: { [weak self] in
        self?.applyDismissDragProgress(0)
      },
      previewImageDataProvider: { [weak self] handle in
        self?.previewImageCache.restoreLoadedPreview(for: handle)
      },
      onPreviewImageDataLoaded: { [weak self] handle, data, orientation in
        self?.previewImageCache.store(data, for: handle, objectOrientation: orientation)
      }
    )
  }

  private func applyDismissDragProgress(_ progress: CGFloat) {
    let clamped = max(0, min(1, progress))
    view.backgroundColor = UIColor.black.withAlphaComponent(1 - clamped * 0.65)
    topBar.alpha = 1 - clamped
    bottomBar.alpha = 1 - clamped
  }

  private func refreshChromeForCurrentItem() {
    guard items.indices.contains(currentIndex) else { return }
    let item = items[currentIndex]
    titleLabel.text = item.filename
    subtitleLabel.text = NativeGalleryFormatDisplayPolicy.previewSubtitle(
      index: currentIndex,
      total: items.count,
      item: item,
      viewState: displayStateProvider(item.handle)
    )
    let state = downloadStateProvider(item.handle)
    configureDownloadButton(for: item, state: state)
    updateSelectionButton(for: item)
    updateCloseButton()
  }

  private func configureDownloadButton(for item: CameraVendorGalleryItem, state: CameraVendorDownloadState) {
    guard CameraVendorGalleryDownloadPolicy.canDownloadOriginal(item) else {
      downloadButton.configuration?.attributedTitle = AttributedString("暂不支持", attributes: AttributeContainer([
        .font: UIFont.systemFont(ofSize: 13, weight: .bold)
      ]))
      downloadButton.isEnabled = false
      downloadButton.alpha = 0.55
      return
    }
    let title: String
    let enabled: Bool
    switch state {
    case .idle:
      title = "下载原图"; enabled = true
    case .queued:
      title = "下载列表中"; enabled = false
    case .downloading:
      title = "下载中…"; enabled = false
    case .saved:
      title = "已保存"; enabled = false
    case .failed:
      title = "重试下载"; enabled = true
    }
    downloadButton.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .bold)
    ]))
    downloadButton.isEnabled = enabled
    downloadButton.alpha = enabled ? 1 : 0.62
  }

  private func updateSelectionButton(for item: CameraVendorGalleryItem) {
    let canSelect = NativeGalleryDownloadSelectionPolicy.canSelect(
      downloadState: downloadStateProvider(item.handle)
    )
    let symbol = isSelected(item.handle) ? "checkmark.circle.fill" : "circle"
    let configuration = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
    selectionButton.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
    selectionButton.isEnabled = canSelect
    selectionButton.alpha = canSelect ? 1 : 0.45
  }

  private func updateCloseButton() {
    let canDismiss = NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: isTransferLocked())
    closeButton.isEnabled = canDismiss
    closeButton.alpha = canDismiss ? 1 : 0.35
  }

  @objc private func toggleControls() {
    controlsHidden.toggle()
    UIView.animate(withDuration: 0.22) {
      self.topBar.alpha = self.controlsHidden ? 0 : 1
      self.bottomBar.alpha = self.controlsHidden ? 0 : 1
      self.setNeedsStatusBarAppearanceUpdate()
      self.setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
  }

  private func dismissPreview() {
    guard NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: isTransferLocked()) else {
      onTransferLockedDismissAttempt()
      return
    }
    if let nav = navigationController, nav.viewControllers.first !== self {
      nav.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  @objc private func closeTapped() {
    dismissPreview()
  }

  @objc private func selectionTapped() {
    guard items.indices.contains(currentIndex) else { return }
    let item = items[currentIndex]
    onSelectionToggle(item)
    updateSelectionButton(for: item)
  }

  @objc private func rotateLeftTapped() {
    guard let page = pageController.viewControllers?.first as? NativePhotoPreviewPageController else { return }
    page.rotateCounterClockwise()
  }

  @objc private func rotateTapped() {
    guard let page = pageController.viewControllers?.first as? NativePhotoPreviewPageController else { return }
    page.rotateClockwise()
  }

  @objc private func downloadTapped() {
    guard items.indices.contains(currentIndex) else { return }
    let item = items[currentIndex]
    guard CameraVendorGalleryDownloadPolicy.canDownloadOriginal(item),
          NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: downloadStateProvider(item.handle)) else {
      return
    }
    cancelPreviewThumbnailLoads()
    onDownload(item)
    refreshChromeForCurrentItem()
  }

  @objc private func downloadStateChanged() {
    refreshChromeForCurrentItem()
  }

  private func cancelPreviewThumbnailLoads() {
    for controller in pageController.viewControllers ?? [] {
      (controller as? NativePhotoPreviewPageController)?.cancelThumbnailLoadForPriorityDownload()
    }
  }

  // MARK: - UIPageViewControllerDataSource

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerBefore viewController: UIViewController
  ) -> UIViewController? {
    guard let page = viewController as? NativePhotoPreviewPageController else { return nil }
    let prev = page.index - 1
    guard items.indices.contains(prev) else { return nil }
    return makePage(for: prev)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerAfter viewController: UIViewController
  ) -> UIViewController? {
    guard let page = viewController as? NativePhotoPreviewPageController else { return nil }
    let next = page.index + 1
    guard items.indices.contains(next) else { return nil }
    return makePage(for: next)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    willTransitionTo pendingViewControllers: [UIViewController]
  ) {
    guard let page = pendingViewControllers.first as? NativePhotoPreviewPageController else { return }
    currentIndex = page.index
    refreshChromeForCurrentItem()
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool
  ) {
    guard let page = pageController.viewControllers?.first as? NativePhotoPreviewPageController else { return }
    currentIndex = page.index
    refreshChromeForCurrentItem()
  }
}

private final class NativePhotoPreviewPageController: UIViewController, UIScrollViewDelegate {
  let index: Int
  let item: CameraVendorGalleryItem
  private let runtime: CameraSessionRuntime
  private let cachedThumbnailImage: UIImage?
  private let canDismiss: () -> Bool
  private let shouldLoadPreviewThumbnail: () -> Bool
  private let onDismissDrag: (CGFloat) -> Void
  private let onDismissBlocked: () -> Void
  private let onDismissCommit: () -> Void
  private let onDismissCancel: () -> Void
  private let previewImageDataProvider: (Int) -> NativeGalleryCachedPreview?
  private let onPreviewImageDataLoaded: (Int, Data, Int?) -> Void
  private var loadTask: Task<Void, Never>?

  private let scrollView: UIScrollView = {
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 4
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.bouncesZoom = true
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.alwaysBounceVertical = false
    scroll.alwaysBounceHorizontal = false
    return scroll
  }()

  private let imageView: UIImageView = {
    let view = UIImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentMode = .scaleAspectFit
    view.isUserInteractionEnabled = true
    view.clipsToBounds = true
    return view
  }()

  private let placeholderView: UIImageView = {
    let view = UIImageView(image: UIImage(systemName: "photo"))
    view.translatesAutoresizingMaskIntoConstraints = false
    view.tintColor = UIColor.white.withAlphaComponent(0.18)
    view.contentMode = .center
    return view
  }()

  private let spinner: UIActivityIndicatorView = {
    let spinner = UIActivityIndicatorView(style: .large)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = .white
    spinner.hidesWhenStopped = true
    return spinner
  }()

  private var imageWidthConstraint: NSLayoutConstraint?
  private var imageHeightConstraint: NSLayoutConstraint?
  private var dismissStartTransform: CGAffineTransform = .identity
  private var sourceImage: UIImage?
  private var sourceImageData: Data?
  private var appliedObjectOrientation: Int?
  private var runtimePresentationObserverID: UUID?
  private var manualRotationDegrees = 0

  init(
    item: CameraVendorGalleryItem,
    index: Int,
    runtime: CameraSessionRuntime,
    cachedThumbnailImage: UIImage?,
    canDismiss: @escaping () -> Bool,
    shouldLoadPreviewThumbnail: @escaping () -> Bool,
    onDismissDrag: @escaping (CGFloat) -> Void,
    onDismissBlocked: @escaping () -> Void,
    onDismissCommit: @escaping () -> Void,
    onDismissCancel: @escaping () -> Void,
    previewImageDataProvider: @escaping (Int) -> NativeGalleryCachedPreview?,
    onPreviewImageDataLoaded: @escaping (Int, Data, Int?) -> Void
  ) {
    self.item = item
    self.index = index
    self.runtime = runtime
    self.cachedThumbnailImage = cachedThumbnailImage
    self.canDismiss = canDismiss
    self.shouldLoadPreviewThumbnail = shouldLoadPreviewThumbnail
    self.onDismissDrag = onDismissDrag
    self.onDismissBlocked = onDismissBlocked
    self.onDismissCommit = onDismissCommit
    self.onDismissCancel = onDismissCancel
    self.previewImageDataProvider = previewImageDataProvider
    self.onPreviewImageDataLoaded = onPreviewImageDataLoaded
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    loadTask?.cancel()
    if let runtimePresentationObserverID {
      Task { @MainActor [runtime] in
        runtime.removeObserver(runtimePresentationObserverID)
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.addSubview(placeholderView)
    view.addSubview(scrollView)
    view.addSubview(spinner)
    scrollView.addSubview(imageView)
    scrollView.delegate = self

    let widthC = imageView.widthAnchor.constraint(equalToConstant: 0)
    let heightC = imageView.heightAnchor.constraint(equalToConstant: 0)
    imageWidthConstraint = widthC
    imageHeightConstraint = heightC

    NSLayoutConstraint.activate([
      placeholderView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      placeholderView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      placeholderView.widthAnchor.constraint(equalToConstant: 80),
      placeholderView.heightAnchor.constraint(equalToConstant: 80),

      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      widthC,
      heightC,

      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    pan.delegate = self
    scrollView.addGestureRecognizer(pan)

    runtimePresentationObserverID = runtime.observe { [weak self] presentation in
      self?.applyLateObjectOrientation(from: presentation.catalog)
    }

    loadImage()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    if let image = imageView.image, sourceImage != nil {
      layout(image: image)
    } else {
      centerImage()
    }
  }

  private func loadImage() {
    if let data = item.thumbnailData,
       let image = CameraVendorGalleryThumbnailRenderer.decoded(from: data, objectOrientation: item.orientation) {
      setSourceImage(image, imageData: data, objectOrientation: item.orientation)
    } else if let image = NativePhotoPreviewInitialImagePolicy.initialImage(
      item: item,
      cachedThumbnailImage: cachedThumbnailImage
    ) {
      setSourceImage(image)
    } else {
      spinner.startAnimating()
    }
    if let cachedPreview = previewImageDataProvider(item.handle),
       let image = CameraVendorGalleryThumbnailRenderer.decoded(
        from: cachedPreview.data,
        objectOrientation: cachedPreview.objectOrientation ?? item.orientation
       ) {
      setSourceImage(
        image,
        imageData: cachedPreview.data,
        objectOrientation: cachedPreview.objectOrientation ?? item.orientation
      )
      spinner.stopAnimating()
      return
    }
    guard loadTask == nil else { return }
    guard shouldLoadPreviewThumbnail() else {
      spinner.stopAnimating()
      return
    }
    loadTask = Task { [weak self] in
      guard let self else { return }
      guard self.shouldLoadPreviewThumbnail() else {
        await MainActor.run {
          self.spinner.stopAnimating()
          self.loadTask = nil
        }
        return
      }
      do {
        var hasLoadedPreviewImage = false
        if let cachedPreview = self.previewImageDataProvider(self.item.handle),
           let image = CameraVendorGalleryThumbnailRenderer.decoded(
            from: cachedPreview.data,
            objectOrientation: cachedPreview.objectOrientation ?? self.item.orientation
           ) {
          hasLoadedPreviewImage = true
          await MainActor.run {
            self.setSourceImage(
              image,
              imageData: cachedPreview.data,
              objectOrientation: cachedPreview.objectOrientation ?? self.item.orientation
            )
          }
        }
        if NativePhotoPreviewImageSourcePolicy.shouldFetchPreviewImage(
          item: item,
          hasPreviewImage: false,
          hasLoadedPreviewData: hasLoadedPreviewImage
        ) {
          let preview = try await runtime.requestPreviewImageWithInfo(for: item.handle)
          if Task.isCancelled { return }
          let data = preview.data
          let previewOrientation = preview.item?.orientation ?? item.orientation
          let image = CameraVendorGalleryThumbnailRenderer.decoded(
            from: data,
            objectOrientation: previewOrientation
          )
          if let image {
            hasLoadedPreviewImage = true
            onPreviewImageDataLoaded(item.handle, data, previewOrientation)
            await MainActor.run {
              self.setSourceImage(image, imageData: data, objectOrientation: previewOrientation)
            }
          }
        }
        await MainActor.run {
          self.spinner.stopAnimating()
          self.loadTask = nil
        }
      } catch {
        await MainActor.run {
          self.spinner.stopAnimating()
          self.loadTask = nil
        }
      }
    }
  }

  func cancelThumbnailLoadForPriorityDownload() {
    loadTask?.cancel()
    loadTask = nil
    spinner.stopAnimating()
  }

  func rotateClockwise() {
    guard sourceImage != nil else { return }
    manualRotationDegrees = NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(manualRotationDegrees)
    renderSourceImage()
  }

  func rotateCounterClockwise() {
    guard sourceImage != nil else { return }
    manualRotationDegrees = NativePhotoPreviewRotationPolicy.previousManualRotationDegrees(manualRotationDegrees)
    renderSourceImage()
  }

  private func setSourceImage(
    _ image: UIImage,
    imageData: Data? = nil,
    objectOrientation: Int? = nil
  ) {
    sourceImage = image
    if let imageData {
      sourceImageData = imageData
      appliedObjectOrientation = objectOrientation
    }
    renderSourceImage()
  }

  private func applyLateObjectOrientation(from presentation: CameraGalleryPresentation) {
    guard let updatedItem = presentation.items.first(where: {
      $0.handle == item.handle
    }),
      let data = sourceImageData,
      NativePhotoPreviewOrientationRefreshPolicy.shouldRerender(
        previousObjectOrientation: appliedObjectOrientation,
        updatedObjectOrientation: updatedItem.orientation,
        hasLoadedImageData: true
      ),
      let image = CameraVendorGalleryThumbnailRenderer.decoded(
        from: data,
        objectOrientation: updatedItem.orientation
      ) else {
      return
    }
    setSourceImage(image, imageData: data, objectOrientation: updatedItem.orientation)
    CameraVendorFileLogger.log(
      "[ORIENTATION_PREVIEW] rerendered handle=\(item.handle) orientation=\(updatedItem.orientation!) reason=late-object-info"
    )
  }

  private func renderSourceImage() {
    guard let sourceImage else { return }
    let image = NativePhotoPreviewImageRenderer.rendered(
      image: sourceImage,
      manualRotationDegrees: manualRotationDegrees
    )
    imageView.image = image
    placeholderView.isHidden = true
    layout(image: image)
  }

  private func layout(image: UIImage) {
    let bounds = view.bounds.size
    guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }
    let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
    let displaySize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    imageWidthConstraint?.constant = displaySize.width
    imageHeightConstraint?.constant = displaySize.height
    scrollView.zoomScale = 1
    scrollView.layoutIfNeeded()
    centerImage()
  }

  private func centerImage() {
    let scrollSize = scrollView.bounds.size
    let contentSize = scrollView.contentSize
    let horizontalInset = max(0, (scrollSize.width - contentSize.width) / 2)
    let verticalInset = max(0, (scrollSize.height - contentSize.height) / 2)
    scrollView.contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: verticalInset, right: horizontalInset)
  }

  @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    if scrollView.zoomScale > scrollView.minimumZoomScale {
      scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
    } else {
      let location = gesture.location(in: imageView)
      let zoom: CGFloat = 2.5
      let width = scrollView.bounds.width / zoom
      let height = scrollView.bounds.height / zoom
      let rect = CGRect(x: location.x - width / 2, y: location.y - height / 2, width: width, height: height)
      scrollView.zoom(to: rect, animated: true)
    }
  }

  @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
    guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
    guard canDismiss() else {
      if gesture.state == .began {
        onDismissBlocked()
      }
      onDismissCancel()
      return
    }
    let translation = gesture.translation(in: view)
    switch gesture.state {
    case .began:
      dismissStartTransform = imageView.transform
    case .changed:
      let progress = max(0, translation.y) / max(view.bounds.height, 1)
      let scale = max(0.6, 1 - progress * 0.4)
      imageView.transform = CGAffineTransform(translationX: translation.x, y: translation.y).scaledBy(x: scale, y: scale)
      onDismissDrag(progress)
    case .ended, .cancelled:
      let progress = max(0, translation.y) / max(view.bounds.height, 1)
      let velocity = gesture.velocity(in: view).y
      if progress > 0.18 || velocity > 900 {
        UIView.animate(withDuration: 0.22, animations: {
          self.imageView.transform = CGAffineTransform(translationX: translation.x, y: self.view.bounds.height).scaledBy(x: 0.5, y: 0.5)
          self.imageView.alpha = 0
          self.onDismissDrag(1)
        }, completion: { _ in self.onDismissCommit() })
      } else {
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4, animations: {
          self.imageView.transform = self.dismissStartTransform
          self.onDismissDrag(0)
        })
        onDismissCancel()
      }
    default:
      break
    }
  }

  // MARK: - UIScrollViewDelegate

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    imageView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerImage()
  }
}

extension NativePhotoPreviewPageController: UIGestureRecognizerDelegate {
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
    let velocity = pan.velocity(in: view)
    if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 { return false }
    return abs(velocity.y) > abs(velocity.x) * 1.2
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }
}

enum CameraVendorPhotoLibrarySaver {
  static func save(
    file: CameraVendorDownloadedFile,
    commitGate: CameraSessionRuntimeTransferCommitGate,
    onPhotoLibraryCommit: @escaping @MainActor () -> Void
  ) async throws {
    guard commitGate.allowsPhotoLibraryCommit else {
      throw CancellationError()
    }
    let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    let status: PHAuthorizationStatus
    if current == .notDetermined {
      status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    } else {
      status = current
    }

    guard status == .authorized || status == .limited else {
      throw NSError(
        domain: "CameraVendorPhotoLibrarySaver",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "没有相册写入权限"]
      )
    }

    guard commitGate.allowsPhotoLibraryCommit else {
      throw CancellationError()
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges({
        guard commitGate.beginPhotoLibraryCommit() else { return }
        switch file.mediaType {
        case .photo, .raw:
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = file.filename
          if CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
            filename: file.filename,
            mediaType: file.mediaType
          ), let data = try? Data(contentsOf: file.fileURL) {
            request.addResource(
              with: .photo,
              data: CameraVendorImageDataNormalizer.imageData(from: data),
              options: options
            )
          } else {
            request.addResource(with: .photo, fileURL: file.fileURL, options: options)
          }
        case .video:
          _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file.fileURL)
        }
      }) { success, error in
        try? FileManager.default.removeItem(at: file.fileURL)
        guard commitGate.didBeginPhotoLibraryCommit else {
          continuation.resume(throwing: CancellationError())
          return
        }
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          Task { @MainActor in
            onPhotoLibraryCommit()
            continuation.resume()
          }
        } else {
          continuation.resume(
            throwing: NSError(
              domain: "CameraVendorPhotoLibrarySaver",
              code: 2,
              userInfo: [NSLocalizedDescriptionKey: "保存文件失败"]
            )
          )
        }
      }
    }
  }

  static func save(data: Data, filename: String) async throws {
    let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    let status: PHAuthorizationStatus
    if current == .notDetermined {
      status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    } else {
      status = current
    }

    guard status == .authorized || status == .limited else {
      throw NSError(
        domain: "CameraVendorPhotoLibrarySaver",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "没有相册写入权限"]
      )
    }

    // Skip the disk round-trip: write data directly into the photo asset
    // via `addResource(with:data:)` instead of temp-file → asset import.
    // For a 30 MB JPG this saves ~150-300 ms of synchronous I/O per save.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = filename
        request.addResource(with: .photo, data: data, options: options)
      }) { success, error in
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          continuation.resume()
        } else {
          continuation.resume(
            throwing: NSError(
              domain: "CameraVendorPhotoLibrarySaver",
              code: 2,
              userInfo: [NSLocalizedDescriptionKey: "保存照片失败"]
            )
          )
        }
      }
    }
  }
}
