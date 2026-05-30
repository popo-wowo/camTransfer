import UIKit
import Photos
import ImageIO

enum NativeLogTextViewPolicy {
  static let maxDisplayedCharacters = 20_000

  static func appending(_ message: String, to existingText: String) -> String {
    let combined = existingText.isEmpty ? message : "\(existingText)\n\(message)"
    guard combined.count > maxDisplayedCharacters else {
      return combined
    }
    return "...\n" + String(combined.suffix(maxDisplayedCharacters))
  }

  static func shouldRenderLiveText(applicationState: UIApplication.State, hasWindow: Bool) -> Bool {
    applicationState == .active && hasWindow
  }
}

enum NativeGalleryGridLayoutPolicy {
  static func columnCount(forCollectionWidth width: CGFloat) -> Int {
    width >= 700 ? 4 : 3
  }

  static func itemSide(
    forCollectionWidth width: CGFloat,
    horizontalInset: CGFloat,
    interItemSpacing: CGFloat,
    columns: Int? = nil
  ) -> CGFloat {
    let columnCount = CGFloat(columns ?? self.columnCount(forCollectionWidth: width))
    let availableWidth = width - (horizontalInset * 2) - (interItemSpacing * (columnCount - 1))
    return floor(availableWidth / columnCount)
  }
}

enum NativeGalleryDateFilter: Equatable {
  case all
  case today
  case specificDay(Date)
  case range(from: Date, to: Date)
}

enum NativeGalleryFormatFilter: Equatable {
  case all
  case jpg
  case heif
  case raw
  case video
}

struct NativeGalleryFilterState: Equatable {
  var date: NativeGalleryDateFilter = .all
  var format: NativeGalleryFormatFilter = .all
}

enum NativeGalleryFilterPolicy {
  static func filteredItems(
    _ items: [CameraVendorGalleryItem],
    state: NativeGalleryFilterState,
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [CameraVendorGalleryItem] {
    items.filter { item in
      matchesFormat(item, format: state.format) &&
      matchesDate(item, date: state.date, now: now, calendar: calendar)
    }
  }

  private static func matchesFormat(_ item: CameraVendorGalleryItem, format: NativeGalleryFormatFilter) -> Bool {
    switch format {
    case .all:
      return true
    case .jpg:
      return item.formatLabel == "JPG"
    case .heif:
      return item.formatLabel == "HEIF"
    case .raw:
      return item.formatLabel == "RAW"
    case .video:
      return item.formatLabel == "Video"
    }
  }

  private static func matchesDate(
    _ item: CameraVendorGalleryItem,
    date: NativeGalleryDateFilter,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    guard date != .all else { return true }
    guard let captureDate = parsedCaptureDate(item.captureDate) else { return false }
    switch date {
    case .all:
      return true
    case .today:
      return calendar.isDate(captureDate, inSameDayAs: now)
    case .specificDay(let day):
      return calendar.isDate(captureDate, inSameDayAs: day)
    case .range(let from, let to):
      let startOfFrom = calendar.startOfDay(for: from)
      let startOfDayAfterTo = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
      return captureDate >= startOfFrom && captureDate < startOfDayAfterTo
    }
  }

  private static func parsedCaptureDate(_ text: String) -> Date? {
    let formats = [
      "yyyy:MM:dd HH:mm:ss",
      "yyyyMMdd'T'HHmmss",
      "yyyyMMdd'T'HHmmss.SSS",
    ]
    for format in formats {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = format
      if let date = formatter.date(from: text) {
        return date
      }
    }
    return nil
  }

}

enum CameraVendorDownloadHistoryStore {
  private static let storageKey = "camtransfer.downloadHistory.v1"

  static func savedHandles(for cameraID: String) -> Set<Int> {
    let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Int]] ?? [:]
    return Set(dict[cameraID] ?? [])
  }

  static func markSaved(handle: Int, for cameraID: String) {
    var dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Int]] ?? [:]
    var existing = Set(dict[cameraID] ?? [])
    existing.insert(handle)
    dict[cameraID] = Array(existing).sorted()
    UserDefaults.standard.set(dict, forKey: storageKey)
  }

  static func clear(for cameraID: String) {
    var dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Int]] ?? [:]
    dict.removeValue(forKey: cameraID)
    UserDefaults.standard.set(dict, forKey: storageKey)
  }
}

enum NativeGalleryLoadingPhrase {
  /// Map raw diagnostic strings into a short human-readable sentence
  /// shown under the spinner. Returns empty string if the message is
  /// not worth surfacing (e.g. very low-level packet logs).
  static func humanize(_ message: String) -> String {
    let lower = message.lowercased()
    if lower.contains("openSession".lowercased()) || lower.contains("session") && lower.contains("open") {
      return "正在打开 PTP 会话"
    }
    if lower.contains("getstorageids") || lower.contains("storage") {
      return "正在读取相机存储信息"
    }
    if lower.contains("getobjecthandles") || lower.contains("d621") || lower.contains("listing") || lower.contains("getobjectinfo") {
      return "正在获取照片列表"
    }
    if lower.contains("hidden handle") || lower.contains("heif") || lower.contains("raw") {
      return "正在补全 HEIF / RAW 照片"
    }
    if lower.contains("缩略图") || lower.contains("thumbnail") {
      return "正在加载缩略图"
    }
    if lower.contains("ble") || lower.contains("蓝牙") {
      return "正在通过蓝牙激活相机传输"
    }
    if lower.contains("wi-fi") || lower.contains("wifi") {
      return "正在等待相机 Wi-Fi"
    }
    if lower.contains("握手") || lower.contains("handshake") {
      return "正在与相机建立连接"
    }
    if lower.contains("加载失败") || lower.contains("failed") {
      return ""
    }
    return ""
  }
}

enum NativeGalleryDownloadSelectionPolicy {
  static func canSelect(downloadState: CameraVendorDownloadState) -> Bool {
    switch downloadState {
    case .idle, .failed:
      return true
    case .queued, .downloading, .saved:
      return false
    }
  }
}

enum NativeGalleryNavigationPolicy {
  static func canLeaveGallery(isDownloading: Bool) -> Bool {
    !isDownloading
  }

  static func canDismissPreview(isDownloading: Bool) -> Bool {
    canLeaveGallery(isDownloading: isDownloading)
  }
}

enum NativeHomeRememberedCameraPresence: Equatable {
  case none
  case online
  case scanning
  case offline
}

enum NativeHomeRememberedCameraPresencePolicy {
  static func presence(
    rememberedPeripheralID: UUID?,
    discoveredCameraIDs: [UUID],
    status: String,
    isBusy: Bool
  ) -> NativeHomeRememberedCameraPresence {
    guard let rememberedPeripheralID else {
      return .none
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

enum NativeHomeCameraSearchActionPolicy {
  static let symbolName = "arrow.clockwise"
  static let accessibilityLabel = "刷新搜索附近相机"
}

extension Notification.Name {
  static let nativeDownloadStateDidChange = Notification.Name("nativeDownloadStateDidChange")
}

enum NativeLuxuryTheme {
  static let background = UIColor(red: 0.973, green: 0.969, blue: 0.957, alpha: 1)
  static let cardBackground = UIColor.white
  static let ink = UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1)
  static let secondaryInk = UIColor(red: 0.43, green: 0.42, blue: 0.39, alpha: 1)
  static let hairline = UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 0.10)
  static let accent = UIColor(red: 0.62, green: 0.51, blue: 0.34, alpha: 1)
  static let mutedFill = UIColor.white.withAlphaComponent(0.72)
  static let warmFill = UIColor(red: 1.0, green: 0.992, blue: 0.980, alpha: 0.88)

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
      .kern: -size * 0.05,
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
  private var heightConstraint: NSLayoutConstraint?

  var onSelected: ((String) -> Void)?

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
    rebuild()
  }

  func setSelected(_ id: String) {
    guard items.contains(where: { $0.id == id }) else { return }
    selectedID = id
    refreshButtonStates()
  }

  func refreshTitle(forID id: String, title: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index] = Item(id: id, title: title)
    selectedID = id
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
        self.selectedID = item.id
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
      let isActive = item.id == selectedID
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
  private let brandLabel = NativeLuxuryTheme.makeBrandLabel("CAMTRANSFER")
  private let titleLabel = NativeLuxuryTheme.makeTitleLabel("Camera roll,\nrefined.", size: 32)
  private let subtitleLabel = NativeLuxuryTheme.makeCopyLabel(
    "从相机中取回 JPG、HEIF、RAW 与视频。轻量、安静、可靠。"
  )

  private let footerCopyLabel = NativeLuxuryTheme.makeCopyLabel(
    "打开相机传图模式后连接。",
    alignment: .center
  )

  private let confirmPairingButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("相机已显示配对成功", for: .normal)
    NativeLuxuryTheme.stylePrimaryButton(button)
    NativeLuxuryTheme.setIcon("checkmark", on: button)
    button.isHidden = true
    return button
  }()

  private let wiredImportButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("有线导入 Beta", for: .normal)
    NativeLuxuryTheme.styleSecondaryButton(button)
    NativeLuxuryTheme.setIcon("cable.connector", on: button)
    return button
  }()

  private let refreshSearchButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.baseBackgroundColor = NativeLuxuryTheme.ink
    config.baseForegroundColor = NativeLuxuryTheme.cardBackground
    config.image = UIImage(
      systemName: NativeHomeCameraSearchActionPolicy.symbolName,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    )
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    button.configuration = config
    button.tintColor = NativeLuxuryTheme.cardBackground
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.22
    button.layer.shadowRadius = 18
    button.layer.shadowOffset = CGSize(width: 0, height: 10)
    button.accessibilityLabel = NativeHomeCameraSearchActionPolicy.accessibilityLabel
    return button
  }()

  private let pairedCameraCard: UIControl = {
    let control = UIControl()
    control.translatesAutoresizingMaskIntoConstraints = false
    NativeLuxuryTheme.applyCardStyle(control, radius: 28)
    control.isHidden = true
    return control
  }()

  private let pairedCameraBrandLabel = NativeLuxuryTheme.makeBrandLabel("PAIRED CAMERA", size: 9)
  private let pairedCameraTitleLabel = NativeLuxuryTheme.makeTitleLabel("DEVICE-A", size: 32)
  private let pairedCameraSubtitleLabel = NativeLuxuryTheme.makeCopyLabel("")
  private let pairedCameraDivider = NativeLuxuryTheme.makeDivider()


  private let pairedCameraBadgeLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "XT"
    label.textAlignment = .center
    label.font = .systemFont(ofSize: 14, weight: .heavy)
    label.textColor = NativeLuxuryTheme.ink
    label.layer.cornerRadius = 27
    label.layer.borderWidth = 1
    label.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    label.clipsToBounds = true
    return label
  }()

  private let connectPairedCameraButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("连接这台相机", for: .normal)
    NativeLuxuryTheme.stylePrimaryButton(button)
    NativeLuxuryTheme.setIcon("bolt.fill", on: button)
    return button
  }()

  private let forgetPairedCameraButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("删除", for: .normal)
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.title = "删除"
    config.baseBackgroundColor = UIColor.systemRed.withAlphaComponent(0.92)
    config.baseForegroundColor = .white
    config.image = UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    config.imagePadding = 6
    config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    config.attributedTitle = AttributedString("删除", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
    ]))
    button.configuration = config
    button.isHidden = true
    button.alpha = 0
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
    button.configuration = .tinted()
    button.configuration?.title = "分享日志"
    button.configuration?.cornerStyle = .medium
    button.isHidden = true
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

  private var pairedCameraCardHeightConstraint: NSLayoutConstraint?
  private var actionStackTopVisible: NSLayoutConstraint?
  private var actionStackTopHidden: NSLayoutConstraint?

  private let service = CameraVendorBluetoothService()
  private let galleryService: CameraVendorGalleryService = CameraVendorRealtimeGalleryService()
  private var cameras: [CameraVendorDiscoveredCamera] = []
  private weak var scanController: NativeScanViewController?
  private var connectingOverlay: NativeConnectingOverlay?
  private var didStartHomeScan = false
  private var latestServiceStatus = ""
  private var latestServiceIsBusy = false

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .light
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    print("CamTransferNative NativeConnectViewController viewDidLoad")
    service.delegate = self
    service.restoreLastPairedCameraIfAvailable()
    setupUI()
    updateRememberedCameraCard()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    service.delegate = self
    if navigationController?.viewControllers.first === self,
       navigationController?.viewControllers.count == 1 {
      // We've returned to the home screen; clear stale BLE/PTP flags so the
      // next "Connect" tap is guaranteed to actually start a new attempt.
      service.resetForNewConnectionAttempt()
      hideConnectingOverlay()
      connectPairedCameraButton.isEnabled = true
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startHomeScanIfNeeded()
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .darkContent
  }

  private func setupUI() {
    view.backgroundColor = NativeLuxuryTheme.background
    navigationItem.title = "CamTransfer"

    let headerStack = UIStackView(arrangedSubviews: [brandLabel, titleLabel, subtitleLabel])
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    headerStack.axis = .vertical
    headerStack.spacing = 8
    headerStack.setCustomSpacing(7, after: brandLabel)
    headerStack.setCustomSpacing(10, after: titleLabel)

    let actionStack = UIStackView(arrangedSubviews: [
      wiredImportButton,
      confirmPairingButton
    ])
    actionStack.translatesAutoresizingMaskIntoConstraints = false
    actionStack.axis = .vertical
    actionStack.spacing = 12
    actionStack.alignment = .fill

    view.addSubview(headerStack)
    view.addSubview(forgetPairedCameraButton)
    view.addSubview(pairedCameraCard)
    view.addSubview(actionStack)
    view.addSubview(footerCopyLabel)
    view.addSubview(statusBadgeLabel)
    view.addSubview(spinner)
    view.addSubview(refreshSearchButton)

    connectPairedCameraButton.addTarget(self, action: #selector(connectRememberedCameraTapped), for: .touchUpInside)
    forgetPairedCameraButton.addTarget(self, action: #selector(forgetRememberedCameraTapped), for: .touchUpInside)
    confirmPairingButton.addTarget(self, action: #selector(confirmPairingTapped), for: .touchUpInside)
    wiredImportButton.addTarget(self, action: #selector(wiredImportTapped), for: .touchUpInside)
    copyLogButton.addTarget(self, action: #selector(copyLogsTapped), for: .touchUpInside)
    shareLogButton.addTarget(self, action: #selector(shareLogsTapped), for: .touchUpInside)
    refreshSearchButton.addTarget(self, action: #selector(refreshSearchTapped), for: .touchUpInside)
    refreshSearchButton.addTarget(self, action: #selector(handleFabPress(_:)), for: .touchDown)
    refreshSearchButton.addTarget(self, action: #selector(handleFabRelease(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])

    let revealDeleteSwipe = UISwipeGestureRecognizer(target: self, action: #selector(revealPairedCameraDeleteAction))
    revealDeleteSwipe.direction = .left
    pairedCameraCard.addGestureRecognizer(revealDeleteSwipe)
    let hideDeleteSwipe = UISwipeGestureRecognizer(target: self, action: #selector(hidePairedCameraDeleteAction))
    hideDeleteSwipe.direction = .right
    pairedCameraCard.addGestureRecognizer(hideDeleteSwipe)

    pairedCameraCard.addSubview(pairedCameraBrandLabel)
    pairedCameraCard.addSubview(pairedCameraTitleLabel)
    pairedCameraCard.addSubview(pairedCameraSubtitleLabel)
    pairedCameraCard.addSubview(pairedCameraBadgeLabel)
    pairedCameraCard.addSubview(pairedCameraDivider)
    pairedCameraCard.addSubview(connectPairedCameraButton)

    let cardHeight = pairedCameraCard.heightAnchor.constraint(equalToConstant: 0)
    cardHeight.priority = UILayoutPriority(999)
    pairedCameraCardHeightConstraint = cardHeight

    let actionTopVisible = actionStack.topAnchor.constraint(equalTo: pairedCameraCard.bottomAnchor, constant: 16)
    let actionTopHidden = actionStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 24)
    actionStackTopVisible = actionTopVisible
    actionStackTopHidden = actionTopHidden

    NSLayoutConstraint.activate([
      headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
      headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
      headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),

      pairedCameraCard.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 22),
      pairedCameraCard.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
      pairedCameraCard.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),

      pairedCameraBrandLabel.topAnchor.constraint(equalTo: pairedCameraCard.topAnchor, constant: 20),
      pairedCameraBrandLabel.leadingAnchor.constraint(equalTo: pairedCameraCard.leadingAnchor, constant: 20),
      pairedCameraBrandLabel.trailingAnchor.constraint(lessThanOrEqualTo: pairedCameraBadgeLabel.leadingAnchor, constant: -12),

      pairedCameraTitleLabel.topAnchor.constraint(equalTo: pairedCameraBrandLabel.bottomAnchor, constant: 6),
      pairedCameraTitleLabel.leadingAnchor.constraint(equalTo: pairedCameraBrandLabel.leadingAnchor),
      pairedCameraTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pairedCameraBadgeLabel.leadingAnchor, constant: -12),

      pairedCameraSubtitleLabel.topAnchor.constraint(equalTo: pairedCameraTitleLabel.bottomAnchor, constant: 4),
      pairedCameraSubtitleLabel.leadingAnchor.constraint(equalTo: pairedCameraTitleLabel.leadingAnchor),
      pairedCameraSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pairedCameraBadgeLabel.leadingAnchor, constant: -12),

      pairedCameraBadgeLabel.topAnchor.constraint(equalTo: pairedCameraCard.topAnchor, constant: 20),
      pairedCameraBadgeLabel.trailingAnchor.constraint(equalTo: pairedCameraCard.trailingAnchor, constant: -20),
      pairedCameraBadgeLabel.widthAnchor.constraint(equalToConstant: 54),
      pairedCameraBadgeLabel.heightAnchor.constraint(equalToConstant: 54),

      pairedCameraDivider.topAnchor.constraint(equalTo: pairedCameraSubtitleLabel.bottomAnchor, constant: 18),
      pairedCameraDivider.leadingAnchor.constraint(equalTo: pairedCameraCard.leadingAnchor, constant: 20),
      pairedCameraDivider.trailingAnchor.constraint(equalTo: pairedCameraCard.trailingAnchor, constant: -20),

      connectPairedCameraButton.topAnchor.constraint(equalTo: pairedCameraDivider.bottomAnchor, constant: 16),
      connectPairedCameraButton.leadingAnchor.constraint(equalTo: pairedCameraCard.leadingAnchor, constant: 20),
      connectPairedCameraButton.trailingAnchor.constraint(equalTo: pairedCameraCard.trailingAnchor, constant: -20),
      connectPairedCameraButton.bottomAnchor.constraint(equalTo: pairedCameraCard.bottomAnchor, constant: -18),

      forgetPairedCameraButton.centerYAnchor.constraint(equalTo: pairedCameraCard.centerYAnchor),
      forgetPairedCameraButton.trailingAnchor.constraint(equalTo: pairedCameraCard.trailingAnchor, constant: -12),
      forgetPairedCameraButton.widthAnchor.constraint(equalToConstant: 84),

      actionStack.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
      actionStack.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),

      footerCopyLabel.topAnchor.constraint(equalTo: actionStack.bottomAnchor, constant: 14),
      footerCopyLabel.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
      footerCopyLabel.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),

      statusBadgeLabel.topAnchor.constraint(equalTo: footerCopyLabel.bottomAnchor, constant: 12),
      statusBadgeLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      statusBadgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: headerStack.leadingAnchor),
      statusBadgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerStack.trailingAnchor),

      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.topAnchor.constraint(equalTo: statusBadgeLabel.bottomAnchor, constant: 8),

      refreshSearchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
      refreshSearchButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      refreshSearchButton.widthAnchor.constraint(equalToConstant: 60),
      refreshSearchButton.heightAnchor.constraint(equalToConstant: 60),
    ])
  }

  @objc private func handleFabPress(_ sender: UIButton) {
    UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
      sender.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
      sender.layer.shadowOpacity = 0.32
    }
  }

  @objc private func handleFabRelease(_ sender: UIButton) {
    UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4) {
      sender.transform = .identity
      sender.layer.shadowOpacity = 0.22
    }
  }

  @objc private func refreshSearchTapped() {
    service.clearLogs()
    logView.text = ""
    confirmPairingButton.isHidden = true
    presentScanController()
    service.startScan()
  }

  private func startHomeScanIfNeeded() {
    guard !didStartHomeScan else { return }
    didStartHomeScan = true
    service.restoreLastPairedCameraIfAvailable()
    updateRememberedCameraCard()
    if service.rememberedCameraSummary == nil {
      presentScanController()
    }
    service.startScan()
  }

  @objc private func wiredImportTapped() {
    let controller = WiredCameraImportViewController()
    navigationController?.pushViewController(controller, animated: true)
  }

  private func presentScanController() {
    if scanController != nil { return }
    let controller = NativeScanViewController(
      initialCameras: cameras,
      onSelect: { [weak self] camera in
        guard let self else { return }
        self.scanController?.markConnecting(to: camera)
        self.service.connect(to: camera.id)
      },
      onCancel: { [weak self] in
        self?.scanController?.dismiss(animated: true)
      },
      onDirectTransfer: { [weak self] in
        guard let self else { return }
        self.scanController?.dismiss(animated: true) {
          self.manualConnectTapped()
        }
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

  @objc private func connectRememberedCameraTapped() {
    guard let summary = service.rememberedCameraSummary else {
      presentNotice(title: "还没有已配对相机", message: "请刷新搜索附近相机后完成配对")
      return
    }

    service.clearLogs()
    logView.text = ""
    connectPairedCameraButton.isEnabled = false
    showConnectingOverlay(deviceName: summary.deviceName)

    service.resetForNewConnectionAttempt()
    service.approveNextRememberedCameraConnection()
    let started = service.connectLastPairedCameraIfAvailable()
    if !started {
      hideConnectingOverlay()
      connectPairedCameraButton.isEnabled = true
      presentNotice(title: "还没有已配对相机", message: "请刷新搜索附近相机后完成配对")
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
      self.service.resetForNewConnectionAttempt()
      self.hideConnectingOverlay()
      self.connectPairedCameraButton.isEnabled = true
    }
    connectingOverlay = overlay
    overlay.reveal(in: view)
  }

  private func hideConnectingOverlay() {
    connectingOverlay?.hide { [weak self] in
      self?.connectingOverlay = nil
    }
  }

  @objc private func forgetRememberedCameraTapped() {
    let alert = UIAlertController(
      title: "删除已配对相机？",
      message: "只会删除 CamTransfer 本地记录。若相机和 iPhone 系统仍保留蓝牙配对，重新连接时可能会自动识别。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
      guard let self else { return }
      self.service.forgetLastPairedCamera()
      self.cameras = []
      self.scanController?.update(cameras: [])
      self.updateRememberedCameraCard()
    })
    present(alert, animated: true)
  }

  @objc private func revealPairedCameraDeleteAction() {
    guard service.rememberedCameraSummary != nil else { return }
    forgetPairedCameraButton.isHidden = false
    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
      self.pairedCameraCard.transform = CGAffineTransform(translationX: -108, y: 0)
      self.forgetPairedCameraButton.alpha = 1
    }
  }

  @objc private func hidePairedCameraDeleteAction() {
    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
      self.pairedCameraCard.transform = .identity
      self.forgetPairedCameraButton.alpha = 0
    } completion: { _ in
      self.forgetPairedCameraButton.isHidden = true
    }
  }

  private func resetPairedCameraDeleteAction() {
    pairedCameraCard.transform = .identity
    forgetPairedCameraButton.alpha = 0
    forgetPairedCameraButton.isHidden = true
  }

  @objc private func confirmPairingTapped() {
    service.confirmCameraPairingSucceeded()
  }

  @objc private func manualConnectTapped() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "Camera",
      serialNumber: "manual"
    )
    if let configurable = galleryService as? CameraVendorGalleryConfigurable {
      configurable.configureForDirectPTP()
    }
    let controller = NativeGalleryViewController(summary: summary, galleryService: galleryService)
    navigationController?.pushViewController(controller, animated: true)
  }

  @objc private func copyLogsTapped() {
    UIPasteboard.general.string = service.currentLogText
    presentNotice(title: "已复制", message: "连接日志已经复制到剪贴板")
  }

  @objc private func shareLogsTapped() {
    let activity = UIActivityViewController(
      activityItems: [service.logFileURL],
      applicationActivities: nil
    )
    present(activity, animated: true)
  }

  private func presentNotice(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "知道了", style: .default))
    present(alert, animated: true)
  }

  private func refreshPairingConfirmationButton(for status: String, isBusy: Bool) {
    confirmPairingButton.isHidden = status != "请先在相机上确认配对成功"
    confirmPairingButton.isEnabled = !isBusy
  }

  private func updateRememberedCameraCard() {
    if let summary = service.rememberedCameraSummary {
      showPairedCard(summary: summary, presence: rememberedCameraPresence())
    } else {
      hidePairedCard()
    }
  }

  private func rememberedCameraPresence() -> NativeHomeRememberedCameraPresence {
    NativeHomeRememberedCameraPresencePolicy.presence(
      rememberedPeripheralID: service.rememberedCameraID,
      discoveredCameraIDs: cameras.map(\.id),
      status: latestServiceStatus,
      isBusy: latestServiceIsBusy
    )
  }

  private func showPairedCard(
    summary: CameraVendorConnectionSummary,
    presence: NativeHomeRememberedCameraPresence
  ) {
    pairedCameraCard.isHidden = false
    pairedCameraCardHeightConstraint?.isActive = false
    actionStackTopHidden?.isActive = false
    actionStackTopVisible?.isActive = true
    connectPairedCameraButton.isHidden = false
    connectPairedCameraButton.isEnabled = true
    pairedCameraTitleLabel.attributedText = NSAttributedString(
      string: summary.deviceName,
      attributes: [
        .font: UIFont.systemFont(ofSize: 32, weight: .heavy),
        .kern: -1.6,
        .foregroundColor: NativeLuxuryTheme.ink
      ]
    )
    switch presence {
    case .online:
      pairedCameraSubtitleLabel.text = "\(summary.subtitle) · 在线"
      connectPairedCameraButton.setTitle("连接这台相机", for: .normal)
    case .scanning:
      pairedCameraSubtitleLabel.text = "\(summary.subtitle) · 正在搜索"
      connectPairedCameraButton.setTitle("连接这台相机", for: .normal)
    case .offline:
      pairedCameraSubtitleLabel.text = "\(summary.subtitle) · 未在线"
      connectPairedCameraButton.setTitle("重新搜索并连接", for: .normal)
    case .none:
      pairedCameraSubtitleLabel.text = summary.subtitle
      connectPairedCameraButton.setTitle("连接这台相机", for: .normal)
    }
    pairedCameraBadgeLabel.text = badgeText(for: summary.deviceName)
    resetPairedCameraDeleteAction()

    confirmPairingButton.isHidden = true
    footerCopyLabel.text = presence == .online
      ? "相机已在线，可以连接。"
      : "正在扫描相机；可点右下角刷新重新搜索。"
  }

  private func hidePairedCard() {
    pairedCameraCard.isHidden = true
    actionStackTopVisible?.isActive = false
    pairedCameraCardHeightConstraint?.isActive = true
    actionStackTopHidden?.isActive = true
    resetPairedCameraDeleteAction()

    confirmPairingButton.isHidden = true
    footerCopyLabel.text = "正在搜索附近相机；可点右下角刷新重试。"
  }

  private func badgeText(for deviceName: String) -> String {
    let upper = deviceName.uppercased()
    return String(upper.filter { $0.isLetter }.prefix(2))
  }
}

extension NativeConnectViewController: CameraVendorBluetoothServiceDelegate {
  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didUpdateStatus status: String,
    isBusy: Bool
  ) {
    CameraVendorMainThread.run { [weak self] in
      guard let self else { return }
      let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
      latestServiceStatus = trimmed
      latestServiceIsBusy = isBusy
      statusBadgeLabel.text = trimmed
      statusBadgeLabel.isHidden = trimmed.isEmpty
      connectPairedCameraButton.isEnabled = !isBusy
      refreshPairingConfirmationButton(for: status, isBusy: isBusy)
      updateRememberedCameraCard()
      if isBusy {
        spinner.startAnimating()
      } else {
        spinner.stopAnimating()
      }
      self.scanController?.update(status: trimmed, isBusy: isBusy)
      self.connectingOverlay?.update(status: trimmed)
    }
  }

  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didUpdateDiscoveredCameras cameras: [CameraVendorDiscoveredCamera]
  ) {
    CameraVendorMainThread.run { [weak self] in
      guard let self else { return }
      self.cameras = cameras
      self.updateRememberedCameraCard()
      self.scanController?.update(cameras: cameras)
    }
  }

  func cameraVendorBluetoothService(_ service: CameraVendorBluetoothService, didAppendLog message: String) {
    CameraVendorMainThread.run { [weak self] in
      guard let self else { return }
      guard NativeLogTextViewPolicy.shouldRenderLiveText(
        applicationState: UIApplication.shared.applicationState,
        hasWindow: view.window != nil
      ) else { return }

      logView.text = NativeLogTextViewPolicy.appending(message, to: logView.text)
      let bottom = NSRange(location: max(logView.text.count - 1, 0), length: 1)
      logView.scrollRangeToVisible(bottom)
    }
  }

  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didCompleteHandshake summary: CameraVendorConnectionSummary
  ) {
    CameraVendorMainThread.run { [weak self] in
      guard let self else { return }
      if let configurable = galleryService as? CameraVendorGalleryConfigurable {
        configurable.configure(connectionSummary: summary)
      }
      let pushGallery: () -> Void = {
        let controller = NativeGalleryViewController(summary: summary, galleryService: self.galleryService)
        self.navigationController?.pushViewController(controller, animated: true)
      }
      if let scan = self.scanController {
        scan.dismiss(animated: true) {
          pushGallery()
        }
        self.scanController = nil
      } else if self.connectingOverlay != nil {
        self.hideConnectingOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
          pushGallery()
        }
      } else {
        pushGallery()
      }
    }
  }

  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didCompletePairing summary: CameraVendorConnectionSummary
  ) {
    CameraVendorMainThread.run { [weak self] in
      guard let self else { return }
      if CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing {
        // 自动传输模式下跳过"准备传输"页，等 didCompleteHandshake 直接进图库
        return
      }
      let presentReady: () -> Void = {
        let controller = NativeTransferReadyViewController(
          summary: summary,
          service: service,
          galleryService: self.galleryService
        )
        self.navigationController?.pushViewController(controller, animated: true)
      }
      if let scan = self.scanController {
        scan.dismiss(animated: true) {
          presentReady()
        }
        self.scanController = nil
      } else {
        presentReady()
      }
    }
  }
}

final class NativeWifiPromptOverlay: UIView {
  var onOpenSettings: (() -> Void)?
  var onRetry: (() -> Void)?

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

  func configure(ssidHint: String?) {
    if let ssid = ssidHint, !ssid.isEmpty {
      ssidChip.text = "  \(ssid)  "
      ssidChip.isHidden = false
    } else {
      ssidChip.text = "  连接相机的 CAMERA-XXXX 网络  "
      ssidChip.isHidden = false
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
    card.addSubview(openSettingsButton)
    card.addSubview(retryButton)

    openSettingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
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

      openSettingsButton.topAnchor.constraint(equalTo: copyLabel.bottomAnchor, constant: 18),
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

final class NativeScanViewController: UIViewController {
  private let onSelect: (CameraVendorDiscoveredCamera) -> Void
  private let onCancel: () -> Void
  private let onDirectTransfer: () -> Void

  private var cameras: [CameraVendorDiscoveredCamera]
  private var connectingCameraID: UUID?

  private let brandLabel = NativeLuxuryTheme.makeBrandLabel("CAMTRANSFER", size: 10)
  private let titleLabel = NativeLuxuryTheme.makeTitleLabel("Pair\na camera.", size: 30)
  private let copyLabel = NativeLuxuryTheme.makeCopyLabel("把相机调到 Bluetooth 配对模式，下面会出现可用的相机。")

  private let statusBanner: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = NativeLuxuryTheme.warmFill
    view.layer.cornerRadius = 18
    view.layer.borderWidth = 1
    view.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    view.isHidden = true
    return view
  }()

  private let statusBannerLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.textColor = NativeLuxuryTheme.ink
    label.numberOfLines = 0
    return label
  }()

  private let statusBannerSpinner: UIActivityIndicatorView = {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = NativeLuxuryTheme.accent
    spinner.hidesWhenStopped = true
    return spinner
  }()

  private let scanIndicator: UIActivityIndicatorView = {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = NativeLuxuryTheme.accent
    spinner.hidesWhenStopped = false
    return spinner
  }()

  private let emptyLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "正在搜索附近的 相机…"
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.numberOfLines = 0
    label.textAlignment = .center
    return label
  }()

  private let cameraStack: UIStackView = {
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 12
    return stack
  }()

  private let directTransferButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("已连接相机 Wi-Fi，直接传图", for: .normal)
    var config = UIButton.Configuration.plain()
    config.attributedTitle = AttributedString("已连接相机 Wi-Fi，直接传图", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NativeLuxuryTheme.secondaryInk,
      .underlineStyle: NSUnderlineStyle.single.rawValue
    ]))
    button.configuration = config
    return button
  }()

  init(
    initialCameras: [CameraVendorDiscoveredCamera],
    onSelect: @escaping (CameraVendorDiscoveredCamera) -> Void,
    onCancel: @escaping () -> Void,
    onDirectTransfer: @escaping () -> Void
  ) {
    self.cameras = initialCameras
    self.onSelect = onSelect
    self.onCancel = onCancel
    self.onDirectTransfer = onDirectTransfer
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .light
    view.backgroundColor = NativeLuxuryTheme.background
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    title = "连接新设备"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "xmark"),
      style: .plain,
      target: self,
      action: #selector(cancelTapped)
    )
    navigationItem.leftBarButtonItem?.tintColor = NativeLuxuryTheme.ink

    let header = UIStackView(arrangedSubviews: [brandLabel, titleLabel, copyLabel])
    header.translatesAutoresizingMaskIntoConstraints = false
    header.axis = .vertical
    header.spacing = 6
    header.setCustomSpacing(8, after: titleLabel)

    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false

    let content = UIView()
    content.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(scrollView)
    scrollView.addSubview(content)

    content.addSubview(header)
    content.addSubview(statusBanner)
    statusBanner.addSubview(statusBannerSpinner)
    statusBanner.addSubview(statusBannerLabel)
    content.addSubview(scanIndicator)
    content.addSubview(cameraStack)
    content.addSubview(emptyLabel)
    content.addSubview(directTransferButton)

    directTransferButton.addTarget(self, action: #selector(directTransferTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

      content.topAnchor.constraint(equalTo: scrollView.topAnchor),
      content.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
      content.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
      content.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

      header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
      header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),

      statusBanner.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
      statusBanner.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      statusBanner.trailingAnchor.constraint(equalTo: header.trailingAnchor),

      statusBannerSpinner.leadingAnchor.constraint(equalTo: statusBanner.leadingAnchor, constant: 14),
      statusBannerSpinner.centerYAnchor.constraint(equalTo: statusBanner.centerYAnchor),
      statusBannerSpinner.widthAnchor.constraint(equalToConstant: 18),
      statusBannerSpinner.heightAnchor.constraint(equalToConstant: 18),

      statusBannerLabel.leadingAnchor.constraint(equalTo: statusBannerSpinner.trailingAnchor, constant: 10),
      statusBannerLabel.trailingAnchor.constraint(equalTo: statusBanner.trailingAnchor, constant: -14),
      statusBannerLabel.topAnchor.constraint(equalTo: statusBanner.topAnchor, constant: 12),
      statusBannerLabel.bottomAnchor.constraint(equalTo: statusBanner.bottomAnchor, constant: -12),

      scanIndicator.topAnchor.constraint(equalTo: statusBanner.bottomAnchor, constant: 18),
      scanIndicator.centerXAnchor.constraint(equalTo: content.centerXAnchor),

      cameraStack.topAnchor.constraint(equalTo: scanIndicator.bottomAnchor, constant: 14),
      cameraStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      cameraStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),

      emptyLabel.topAnchor.constraint(equalTo: cameraStack.bottomAnchor, constant: 8),
      emptyLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      emptyLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),

      directTransferButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 24),
      directTransferButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      directTransferButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
    ])

    scanIndicator.startAnimating()
    rebuildCameraCards()
  }

  func update(cameras: [CameraVendorDiscoveredCamera]) {
    self.cameras = cameras
    rebuildCameraCards()
  }

  func update(status: String, isBusy: Bool) {
    if status.isEmpty {
      statusBanner.isHidden = true
      statusBannerSpinner.stopAnimating()
      return
    }
    statusBanner.isHidden = false
    statusBannerLabel.text = status
    if isBusy {
      statusBannerSpinner.startAnimating()
    } else {
      statusBannerSpinner.stopAnimating()
    }
  }

  func markConnecting(to camera: CameraVendorDiscoveredCamera) {
    connectingCameraID = camera.id
    rebuildCameraCards()
  }

  @objc private func cancelTapped() {
    onCancel()
  }

  @objc private func directTransferTapped() {
    onDirectTransfer()
  }

  private func rebuildCameraCards() {
    cameraStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if cameras.isEmpty {
      emptyLabel.text = "正在搜索附近的 相机…\n请确保相机蓝牙开启并处于配对模式。"
      emptyLabel.isHidden = false
      return
    }
    emptyLabel.isHidden = true
    for camera in cameras {
      let card = NativeScanCameraCard(
        camera: camera,
        isConnecting: connectingCameraID == camera.id
      ) { [weak self] in
        guard let self else { return }
        guard self.connectingCameraID == nil else { return }
        self.onSelect(camera)
      }
      cameraStack.addArrangedSubview(card)
    }
  }
}

private final class NativeScanCameraCard: UIControl {
  private let camera: CameraVendorDiscoveredCamera
  private let isConnecting: Bool
  private let onTap: () -> Void

  init(camera: CameraVendorDiscoveredCamera, isConnecting: Bool, onTap: @escaping () -> Void) {
    self.camera = camera
    self.isConnecting = isConnecting
    self.onTap = onTap
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    NativeLuxuryTheme.applyCardStyle(self, radius: 22)
    setupSubviews()
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupSubviews() {
    let badge = UILabel()
    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.text = badgeText(for: camera.name)
    badge.textAlignment = .center
    badge.font = .systemFont(ofSize: 13, weight: .heavy)
    badge.textColor = NativeLuxuryTheme.ink
    badge.layer.cornerRadius = 23
    badge.layer.borderWidth = 1
    badge.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    badge.clipsToBounds = true

    let nameLabel = UILabel()
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.text = camera.name
    nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    nameLabel.textColor = NativeLuxuryTheme.ink

    let detailLabel = UILabel()
    detailLabel.translatesAutoresizingMaskIntoConstraints = false
    detailLabel.text = "信号 \(camera.rssi) dB · \(camera.id.uuidString.prefix(8))"
    detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
    detailLabel.textColor = NativeLuxuryTheme.secondaryInk

    let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.tintColor = NativeLuxuryTheme.secondaryInk

    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = NativeLuxuryTheme.accent
    spinner.hidesWhenStopped = true

    addSubview(badge)
    addSubview(nameLabel)
    addSubview(detailLabel)
    addSubview(chevron)
    addSubview(spinner)

    if isConnecting {
      spinner.startAnimating()
      chevron.isHidden = true
      alpha = 0.92
      isUserInteractionEnabled = false
    }

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 76),

      badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      badge.centerYAnchor.constraint(equalTo: centerYAnchor),
      badge.widthAnchor.constraint(equalToConstant: 46),
      badge.heightAnchor.constraint(equalToConstant: 46),

      nameLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 14),
      nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -10),

      detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
      detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -10),
      detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),

      chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      chevron.centerYAnchor.constraint(equalTo: centerYAnchor),

      spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.16) {
        self.alpha = self.isHighlighted ? 0.78 : 1
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
      }
    }
  }

  @objc private func handleTap() {
    onTap()
  }

  private func badgeText(for deviceName: String) -> String {
    let upper = deviceName.uppercased()
    return String(upper.filter { $0.isLetter }.prefix(2))
  }
}

private final class NativeTransferReadyViewController: UIViewController {
  private let summary: CameraVendorConnectionSummary
  private let service: CameraVendorBluetoothService
  private let galleryService: CameraVendorGalleryService

  private let summaryLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 28, weight: .heavy)
    label.textColor = NativeLuxuryTheme.ink
    label.numberOfLines = 0
    return label
  }()

  private let statusLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 16, weight: .semibold)
    label.textColor = .systemBlue
    label.numberOfLines = 0
    label.text = "相机已连接，点“传输照片”进入查看和下载。"
    return label
  }()

  private let transferButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.configuration = .filled()
    button.configuration?.title = "传输照片"
    button.configuration?.cornerStyle = .large
    button.configuration?.baseBackgroundColor = .systemBlue
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
    return view
  }()

  init(
    summary: CameraVendorConnectionSummary,
    service: CameraVendorBluetoothService,
    galleryService: CameraVendorGalleryService
  ) {
    self.summary = summary
    self.service = service
    self.galleryService = galleryService
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    logView.text = service.currentLogText
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    service.delegate = self
  }

  private func setupUI() {
    view.backgroundColor = .systemBackground
    navigationItem.title = "准备传输"
    summaryLabel.text = "\(summary.navigationTitle)\n\(summary.subtitle)"

    let infoStack = UIStackView(arrangedSubviews: [summaryLabel, statusLabel, transferButton])
    infoStack.translatesAutoresizingMaskIntoConstraints = false
    infoStack.axis = .vertical
    infoStack.spacing = 14

    let logTitle = UILabel()
    logTitle.translatesAutoresizingMaskIntoConstraints = false
    logTitle.text = "运行日志"
    logTitle.font = .systemFont(ofSize: 14, weight: .semibold)

    view.addSubview(infoStack)
    view.addSubview(logTitle)
    view.addSubview(logView)

    transferButton.addTarget(self, action: #selector(transferTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      infoStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
      infoStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      infoStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

      logTitle.topAnchor.constraint(equalTo: infoStack.bottomAnchor, constant: 18),
      logTitle.leadingAnchor.constraint(equalTo: infoStack.leadingAnchor),
      logTitle.trailingAnchor.constraint(equalTo: infoStack.trailingAnchor),

      logView.topAnchor.constraint(equalTo: logTitle.bottomAnchor, constant: 8),
      logView.leadingAnchor.constraint(equalTo: infoStack.leadingAnchor),
      logView.trailingAnchor.constraint(equalTo: infoStack.trailingAnchor),
      logView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])
  }

  @objc private func transferTapped() {
    service.startPhotoTransfer()
  }
}

extension NativeTransferReadyViewController: CameraVendorBluetoothServiceDelegate {
  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didUpdateStatus status: String,
    isBusy: Bool
  ) {
    CameraVendorMainThread.run { [weak self] in
      self?.statusLabel.text = status
      self?.transferButton.isEnabled = !isBusy
    }
  }

  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didUpdateDiscoveredCameras cameras: [CameraVendorDiscoveredCamera]
  ) {
  }

  func cameraVendorBluetoothService(_ service: CameraVendorBluetoothService, didAppendLog message: String) {
    CameraVendorMainThread.run { [weak self] in
      guard let self else { return }
      guard NativeLogTextViewPolicy.shouldRenderLiveText(
        applicationState: UIApplication.shared.applicationState,
        hasWindow: view.window != nil
      ) else { return }

      logView.text = NativeLogTextViewPolicy.appending(message, to: logView.text)
      let bottom = NSRange(location: max(logView.text.count - 1, 0), length: 1)
      logView.scrollRangeToVisible(bottom)
    }
  }

  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didCompletePairing summary: CameraVendorConnectionSummary
  ) {
  }

  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didCompleteHandshake summary: CameraVendorConnectionSummary
  ) {
    CameraVendorMainThread.run { [weak self] in
      guard let self else { return }
      if let configurable = galleryService as? CameraVendorGalleryConfigurable {
        configurable.configure(connectionSummary: summary)
      }
      let controller = NativeGalleryViewController(summary: summary, galleryService: galleryService)
      navigationController?.pushViewController(controller, animated: true)
    }
  }
}

private final class NativeGalleryViewController: UIViewController {
  private let summary: CameraVendorConnectionSummary
  private let galleryService: CameraVendorGalleryService
  private var galleryState = CameraVendorGalleryState()
  private var allGalleryItems: [CameraVendorGalleryItem] = []
  private var filterState = NativeGalleryFilterState()
  private var isDownloading = false
  private var shouldRetryWhenAppBecomesActive = false
  private var networkStatusTimer: Timer?
  private var manualWifiBaselineIP: String?
  private var wifiPromptOverlay: NativeWifiPromptOverlay?
  private var downloadListButtonItem: UIBarButtonItem?
  private var selectAllButtonItem: UIBarButtonItem?
  private var previousInteractivePopGestureEnabled: Bool?

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

  private let reloadButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("刷新", for: .normal)
    NativeLuxuryTheme.styleSecondaryButton(button)
    NativeLuxuryTheme.setIcon("arrow.clockwise", on: button)
    button.isHidden = true
    return button
  }()

  private let dateChips = NativeChipBarControl()
  private let formatChips = NativeChipBarControl()
  private let downloadSizeChips = NativeChipBarControl()
  private var currentColumnCount: Int = {
    let stored = UserDefaults.standard.integer(forKey: "camtransfer.galleryColumnCount")
    if (2...5).contains(stored) { return stored }
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
    view.isHidden = true
    return view
  }()

  private let bottomDownloadLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.textColor = NativeLuxuryTheme.ink
    return label
  }()

  private let bottomDownloadButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.title = "下载原图"
    config.baseBackgroundColor = NativeLuxuryTheme.ink
    config.baseForegroundColor = NativeLuxuryTheme.cardBackground
    config.image = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
    config.imagePadding = 6
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
    config.attributedTitle = AttributedString("下载原图", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    button.configuration = config
    return button
  }()

  private let reservedReceiveProbeButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("HEIF/RAW探测", for: .normal)
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
    return collectionView
  }()

  init(summary: CameraVendorConnectionSummary, galleryService: CameraVendorGalleryService) {
    self.summary = summary
    self.galleryService = galleryService
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
    print("CamTransferGallery NativeGalleryViewController viewDidLoad")
    setupUI()
    configureDiagnostics()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    if CameraVendorGalleryLoadPolicy.shouldLoadAutomaticallyOnEntry {
      loadGallery()
    } else {
      manualWifiBaselineIP = CameraVendorNetworkUtils.wifiIPv4Address()
      copyLabel.text = "等待连接相机 Wi-Fi…"
      let currentIP = CameraVendorNetworkUtils.wifiIPv4Address()
      if !CameraVendorGalleryLoadPolicy.shouldAllowManualReload(currentWifiIP: currentIP) {
        DispatchQueue.main.async { [weak self] in
          self?.showWifiPromptOverlay()
        }
      }
      updateManualReloadAvailability()
      startNetworkStatusTimer()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    networkStatusTimer?.invalidate()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    previousInteractivePopGestureEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
    updateNavigationLock()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if let previousInteractivePopGestureEnabled {
      navigationController?.interactivePopGestureRecognizer?.isEnabled = previousInteractivePopGestureEnabled
    }
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .darkContent
  }

  private func setupUI() {
    view.backgroundColor = NativeLuxuryTheme.background
    navigationItem.title = summary.navigationTitle
    brandLabel.text = "\(summary.deviceName.uppercased()) GALLERY"
    brandLabel.letterSpacing = 2.2
    copyLabel.text = "准备加载图库"
    titleLabel.isHidden = true
    // Right bar order from edge inwards: tray (download list), select-all.
    let downloadListButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "tray.full"),
      style: .plain,
      target: self,
      action: #selector(downloadListTapped)
    )
    let selectAllButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "checkmark.circle"),
      style: .plain,
      target: self,
      action: #selector(selectAllTapped)
    )
    self.downloadListButtonItem = downloadListButtonItem
    self.selectAllButtonItem = selectAllButtonItem
    navigationItem.rightBarButtonItems = [downloadListButtonItem, selectAllButtonItem]
    navigationItem.rightBarButtonItems?.forEach { $0.tintColor = NativeLuxuryTheme.ink }

    let copyRow = UIStackView(arrangedSubviews: [loadingSpinner, copyLabel])
    copyRow.translatesAutoresizingMaskIntoConstraints = false
    copyRow.axis = .horizontal
    copyRow.alignment = .center
    copyRow.spacing = 8

    let headerStack = UIStackView(arrangedSubviews: [brandLabel, copyRow])
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    headerStack.axis = .vertical
    headerStack.spacing = 6
    view.addSubview(headerStack)

    view.addSubview(statusLabel)
    view.addSubview(diagnosticsView)

    dateChips.configure(items: [
      .init(id: "all", title: "全部"),
      .init(id: "today", title: "今天"),
      .init(id: "pickDate", title: "选择日期"),
    ], selectedID: "all")
    formatChips.configure(items: [
      .init(id: "all", title: "全部"),
      .init(id: "jpg", title: "JPG"),
      .init(id: "heif", title: "HEIF"),
      .init(id: "raw", title: "RAW"),
      .init(id: "video", title: "视频"),
    ], selectedID: "all")
    let initialDownloadSize = CameraVendorTransferActivationResizePolicy.preferCompressedDownloads ? "compressed" : "original"
    downloadSizeChips.configure(items: [
      .init(id: "original", title: "原图"),
      .init(id: "compressed", title: "压缩 ~3M"),
    ], selectedID: initialDownloadSize)
    dateChips.onSelected = { [weak self] _ in self?.chipFilterChanged() }
    formatChips.onSelected = { [weak self] _ in self?.chipFilterChanged() }
    downloadSizeChips.onSelected = { [weak self] selected in
      guard let self else { return }
      let preferCompressed = selected == "compressed"
      let wasCompressed = CameraVendorTransferActivationResizePolicy.preferCompressedDownloads
      CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = preferCompressed
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      if preferCompressed != wasCompressed {
        self.showToast(preferCompressed ? "已切换到压缩 ~ 3M（下次连接生效）" : "已切换到原图（下次连接生效）")
      }
    }

    let filterStack = UIStackView(arrangedSubviews: [dateChips, formatChips, downloadSizeChips])
    filterStack.translatesAutoresizingMaskIntoConstraints = false
    filterStack.axis = .vertical
    filterStack.spacing = 8

    view.addSubview(filterStack)
    view.addSubview(collectionView)
    view.addSubview(bottomDownloadBar)
    view.addSubview(toastLabel)
    bottomDownloadBar.addSubview(bottomDownloadLabel)
    bottomDownloadBar.addSubview(bottomDownloadButton)

    reservedReceiveProbeButton.addTarget(self, action: #selector(reservedReceiveProbeTapped), for: .touchUpInside)
    bottomDownloadButton.addTarget(self, action: #selector(downloadSelectedTapped), for: .touchUpInside)

    collectionView.dataSource = self
    collectionView.delegate = self

    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleGalleryPinch(_:)))
    collectionView.addGestureRecognizer(pinch)

    NSLayoutConstraint.activate([
      headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
      headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),

      statusLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4),
      statusLabel.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),

      diagnosticsView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 0),
      diagnosticsView.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
      diagnosticsView.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),
      diagnosticsView.heightAnchor.constraint(equalToConstant: 0),

      filterStack.topAnchor.constraint(equalTo: diagnosticsView.bottomAnchor, constant: 10),
      filterStack.leadingAnchor.constraint(equalTo: headerStack.leadingAnchor),
      filterStack.trailingAnchor.constraint(equalTo: headerStack.trailingAnchor),

      collectionView.topAnchor.constraint(equalTo: filterStack.bottomAnchor, constant: 8),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      bottomDownloadBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
      bottomDownloadBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
      bottomDownloadBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
      bottomDownloadBar.heightAnchor.constraint(equalToConstant: 56),

      bottomDownloadLabel.leadingAnchor.constraint(equalTo: bottomDownloadBar.leadingAnchor, constant: 18),
      bottomDownloadLabel.centerYAnchor.constraint(equalTo: bottomDownloadBar.centerYAnchor),

      bottomDownloadButton.trailingAnchor.constraint(equalTo: bottomDownloadBar.trailingAnchor, constant: -10),
      bottomDownloadButton.centerYAnchor.constraint(equalTo: bottomDownloadBar.centerYAnchor),
      bottomDownloadButton.leadingAnchor.constraint(greaterThanOrEqualTo: bottomDownloadLabel.trailingAnchor, constant: 12),

      toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      toastLabel.bottomAnchor.constraint(equalTo: bottomDownloadBar.topAnchor, constant: -12),
      toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
      toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
      toastLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
    ])

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

  private func showPinchHintIfNeeded() {
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
    let target = max(2, min(5, currentColumnCount + delta))
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

  @objc private func chipFilterChanged() {
    switch dateChips.selectedID {
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

    applyCurrentFilters(shouldLoadThumbnails: true)
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
        let normalizedFrom = min(from, to)
        let normalizedTo = max(from, to)
        if Calendar.current.isDate(normalizedFrom, inSameDayAs: normalizedTo) {
          self.filterState.date = .specificDay(normalizedFrom)
          self.dateChips.refreshTitle(forID: "pickDate", title: self.dateChipTitle(for: normalizedFrom))
        } else {
          self.filterState.date = .range(from: normalizedFrom, to: normalizedTo)
          self.dateChips.refreshTitle(forID: "pickDate", title: self.dateRangeChipTitle(from: normalizedFrom, to: normalizedTo))
        }
        self.applyCurrentFilters(shouldLoadThumbnails: true)
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
    guard let reporting = galleryService as? CameraVendorGalleryDiagnosticReporting else {
      diagnosticsView.text = "当前图库服务没有提供实时诊断。"
      return
    }

    reporting.diagnosticHandler = { [weak self] message in
      DispatchQueue.main.async {
        self?.appendDiagnostic(message)
      }
    }
  }

  private func appendDiagnostic(_ message: String) {
    print("CamTransferGallery UI \(message)")
    if galleryState.isLoading {
      let humanized = NativeGalleryLoadingPhrase.humanize(message)
      if !humanized.isEmpty {
        copyLabel.text = humanized
        copyLabel.textColor = NativeLuxuryTheme.secondaryInk
      }
    }
    guard NativeLogTextViewPolicy.shouldRenderLiveText(
      applicationState: UIApplication.shared.applicationState,
      hasWindow: view.window != nil
    ) else {
      return
    }

    diagnosticsView.text = NativeLogTextViewPolicy.appending(message, to: diagnosticsView.text)
    let bottom = NSRange(location: max(diagnosticsView.text.count - 1, 0), length: 1)
    diagnosticsView.scrollRangeToVisible(bottom)
  }

  private func startNetworkStatusTimer() {
    networkStatusTimer?.invalidate()
    networkStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      self?.updateManualReloadAvailability()
    }
    updateManualReloadAvailability()
  }

  private func updateManualReloadAvailability() {
    let currentIP = CameraVendorNetworkUtils.wifiIPv4Address()
    let isReady = CameraVendorGalleryLoadPolicy.shouldAllowManualReload(currentWifiIP: currentIP)
    reloadButton.isEnabled = isReady && !galleryState.isLoading && !isDownloading
    reloadButton.configuration?.title = isReady ? "刷新" : "等待相机 Wi-Fi"
    if galleryState.items.isEmpty {
      copyLabel.text = isReady
        ? "已连接相机 Wi-Fi，正在准备读取照片。"
        : "等待连接相机 Wi-Fi…"
    }
    if isReady {
      hideWifiPromptOverlay()
    }
    if CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
      currentWifiIP: currentIP,
      baselineWifiIP: manualWifiBaselineIP,
      itemCount: galleryState.items.count,
      isLoading: galleryState.isLoading
    ) {
      appendDiagnostic("已检测到相机 Wi-Fi，自动加载图库。")
      loadGallery()
    }
  }

  @objc private func reloadTapped() {
    guard CameraVendorGalleryLoadPolicy.shouldAllowManualReload(currentWifiIP: CameraVendorNetworkUtils.wifiIPv4Address()) else {
      updateManualReloadAvailability()
      presentNotice(title: "等待相机 Wi-Fi", message: "请先在系统设置中连接相机 Wi-Fi，回到 CamTransfer 后会自动继续。")
      return
    }
    loadGallery()
  }

  @objc private func appDidBecomeActive() {
    updateManualReloadAvailability()
    guard CameraVendorGalleryLoadPolicy.shouldRetryAutomaticallyWhenAppBecomesActive else {
      appendDiagnostic("已回到 CamTransfer。请确认相机 Wi-Fi 已连接，然后手动点“刷新”。")
      return
    }
    let currentIP = CameraVendorNetworkUtils.wifiIPv4Address()
    if CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
      currentWifiIP: currentIP,
      baselineWifiIP: manualWifiBaselineIP,
      itemCount: galleryState.items.count,
      isLoading: galleryState.isLoading
    ) {
      appendDiagnostic("回到 CamTransfer 且已连接相机 Wi-Fi，自动加载图库。")
      loadGallery()
      return
    }
    guard CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
      itemCount: galleryState.items.count,
      isLoading: galleryState.isLoading,
      errorMessage: shouldRetryWhenAppBecomesActive ? galleryState.errorMessage : nil,
      currentWifiIP: currentIP,
      baselineWifiIP: manualWifiBaselineIP
    ) else {
      return
    }
    appendDiagnostic("检测到你回到了 CamTransfer，自动重试连接相机图库。")
    loadGallery()
  }

  @objc private func selectAllTapped() {
    guard NativeGalleryNavigationPolicy.canLeaveGallery(isDownloading: isDownloading) else {
      showToast("正在下载，请先保持在当前页面")
      return
    }
    let selectableHandles = Set(galleryState.downloadableHandles(from: galleryState.items.map(\.handle)))
    if galleryState.selectedHandles == selectableHandles, !selectableHandles.isEmpty {
      galleryState.clearSelection()
    } else {
      galleryState.setSelection(handles: selectableHandles)
    }

    refreshStatusText()
    collectionView.reloadData()
  }

  @objc private func downloadSelectedTapped() {
    let selectedItems = galleryState.items.filter { galleryState.selectedHandles.contains($0.handle) }
    let unsupportedItems = selectedItems.filter { !CameraVendorGalleryDownloadPolicy.canDownloadOriginal($0) }
    let handles = selectedItems
      .filter { CameraVendorGalleryDownloadPolicy.canDownloadOriginal($0) }
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
    startDownload(for: handles)
  }

  @objc private func downloadListTapped() {
    guard NativeGalleryNavigationPolicy.canLeaveGallery(isDownloading: isDownloading) else {
      showToast("正在下载，请先保持在当前页面")
      return
    }
    let controller = NativeDownloadListViewController(
      itemsProvider: { [weak self] in
        self?.downloadListItems() ?? []
      },
      stateProvider: { [weak self] handle in
        self?.galleryState.downloadState(for: handle) ?? .idle
      },
      progressProvider: { [weak self] handle in
        self?.galleryState.downloadProgressText(for: handle)
      }
    )
    navigationController?.pushViewController(controller, animated: true)
  }

  @objc private func reservedReceiveProbeTapped() {
    guard CameraVendorGalleryLoadPolicy.shouldAllowManualReload(currentWifiIP: CameraVendorNetworkUtils.wifiIPv4Address()) else {
      appendDiagnostic("当前还不是相机 Wi-Fi，暂不启动 HEIF/RAW 探测。")
      return
    }
    guard let diagnosticService = galleryService as? CameraVendorReservedReceiveDiagnosticService else {
      appendDiagnostic("当前服务不支持 Reserved Receive 诊断。")
      return
    }

    reservedReceiveProbeButton.isEnabled = false
    appendDiagnostic("开始独立 HEIF/RAW Reserved Receive 探测...")
    Task { @MainActor in
      defer {
        reservedReceiveProbeButton.isEnabled = !isDownloading
      }
      do {
        let result = try await diagnosticService.probeReservedReceive()
        appendDiagnostic("HEIF/RAW 探测成功: \(result.summary)")
        presentNotice(title: "探测成功", message: result.summary)
      } catch {
        appendDiagnostic("HEIF/RAW 探测失败: \(error.localizedDescription)")
        presentNotice(title: "探测失败", message: error.localizedDescription)
      }
    }
  }

  private func loadGallery() {
    networkStatusTimer?.invalidate()
    guard CameraVendorGalleryLoadPolicy.shouldStartLoad(isLoading: galleryState.isLoading) else {
      appendDiagnostic("已有图库加载任务在进行，忽略本次重复请求。")
      return
    }

    galleryState.isLoading = true
    galleryState.errorMessage = nil
    shouldRetryWhenAppBecomesActive = false
    refreshStatusText()
    diagnosticsView.text = ""

    Task { @MainActor in
      do {
        let items = try await galleryService.fetchGallery()
        allGalleryItems = items
        restoreSavedDownloadStates()
        applyCurrentFilters(shouldLoadThumbnails: false)
        galleryState.isLoading = false
        shouldRetryWhenAppBecomesActive = false
        networkStatusTimer?.invalidate()
        refreshStatusText()
        collectionView.reloadData()

        loadVisibleThumbnails()
        if !galleryState.items.isEmpty {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showPinchHintIfNeeded()
          }
        }
      } catch {
        galleryState.isLoading = false
        startNetworkStatusTimer()
        updateManualReloadAvailability()
        galleryState.errorMessage = error.localizedDescription
        shouldRetryWhenAppBecomesActive = CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
          itemCount: galleryState.items.count,
          isLoading: false,
          errorMessage: galleryState.errorMessage,
          currentWifiIP: CameraVendorNetworkUtils.wifiIPv4Address(),
          baselineWifiIP: manualWifiBaselineIP
        )
        refreshStatusText()
        appendDiagnostic("加载失败: \(error.localizedDescription)")
        if let nsError = error as NSError?,
           nsError.domain == "CameraVendorRealtimeGalleryService",
           nsError.code == 2 {
          presentManualWifiNotice(message: error.localizedDescription)
        }
      }
    }
  }

  @MainActor
  private func loadThumbnail(for handle: Int) async {
    do {
      appendDiagnostic("开始加载缩略图 handle=\(handle)")
      let data = try await galleryService.fetchThumbnail(for: handle)
      appendDiagnostic("缩略图加载成功 handle=\(handle) bytes=\(data.count)")
      galleryState.updateThumbnail(handle: handle, data: data)
      if let allIndex = allGalleryItems.firstIndex(where: { $0.handle == handle }) {
        allGalleryItems[allIndex].thumbnailData = data
      }
      if let item = galleryState.items.first(where: { $0.handle == handle }),
         let indexPath = indexPath(for: item) {
        collectionView.reloadItems(at: [indexPath])
      }
    } catch {
      // Keep list usable even if some thumbnails fail.
      appendDiagnostic("缩略图加载失败 handle=\(handle): \(error.localizedDescription)")
    }
  }

  @MainActor
  private func loadThumbnailsSequentially(for handles: [Int]) async {
    for handle in handles {
      await loadThumbnail(for: handle)
    }
  }

  private func startDownload(for handles: [Int]) {
    let handlesToDownload = galleryState.downloadableHandles(from: handles)
    let skippedSavedCount = handles.count - handlesToDownload.count
    guard !handlesToDownload.isEmpty else {
      showToast("已下载过，无需重复下载")
      return
    }
    galleryState.enqueueDownloads(for: handlesToDownload)
    refreshStatusText()
    if skippedSavedCount > 0 {
      showToast("已跳过 \(skippedSavedCount) 张，\(handlesToDownload.count) 张加入下载列表")
    } else {
      showToast("\(handlesToDownload.count) 张已加入下载列表")
    }
    collectionView.reloadData()
    notifyDownloadStateChanged()
    guard !isDownloading else {
      return
    }
    isDownloading = true
    updateNavigationLock()

    Task { @MainActor in
      var successCount = 0
      var startedCount = 0
      while let handle = galleryState.nextQueuedDownloadHandle() {
        startedCount += 1
        do {
          let totalCount = max(startedCount + galleryState.queuedDownloadHandles().count - 1, 1)
          galleryState.markDownloadStarted(handle: handle, position: startedCount, total: totalCount)
          refreshStatusText()
          collectionView.reloadData()
          notifyDownloadStateChanged()

          let item = allGalleryItems.first(where: { $0.handle == handle })
          if item.map(CameraVendorGalleryDownloadPolicy.mediaType(for:)) == .video {
            let downloadedFile = try await galleryService.downloadOriginalFile(for: handle)
            try await CameraVendorPhotoLibrarySaver.save(file: downloadedFile)
          } else {
            let data = try await galleryService.downloadOriginal(for: handle)
            let filename = item?.filename ?? "CamTransfer.jpg"
            try await CameraVendorPhotoLibrarySaver.save(data: data, filename: filename)
          }
          galleryState.markDownloadFinished(handle: handle)
          CameraVendorDownloadHistoryStore.markSaved(handle: handle, for: cameraHistoryKey)
          successCount += 1
        } catch {
          galleryState.markDownloadFailed(handle: handle, message: error.localizedDescription)
        }
        refreshStatusText()
        collectionView.reloadData()
        notifyDownloadStateChanged()
      }

      isDownloading = false
      updateNavigationLock()
      if successCount > 0 {
        showToast("已保存 \(successCount) 张到系统相册")
      }
    }
  }

  /// One worker loop. Pulls handles off the shared queue and downloads them
  /// over its dedicated PTP channel. Worker 2 retires itself on the first
  /// failure and the failed handle is re-queued so worker 1 picks it up;
  /// worker 1 NEVER retires until the queue is empty so the batch is
  /// guaranteed to complete (or fail per item) just like the sequential
  /// path used to.
  @MainActor
  fileprivate func runSafeDownloadLoop(
    worker: CameraVendorParallelDownloadAsyncFetcher,
    label: String,
    isWorker2: Bool,
    counter: SafeParallelDownloadCounter,
    worker2Status: SafeParallelDownloadWorker2Status
  ) async {
    while true {
      if isWorker2 {
        if await worker2Status.isRetired { return }
      }
      guard let handle = galleryState.nextQueuedDownloadHandle() else { return }

      let position = await counter.bumpStarted()
      galleryState.markDownloadStarted(handle: handle, position: position, total: max(position, position))
      refreshStatusText()
      collectionView.reloadData()
      notifyDownloadStateChanged()

      let item = allGalleryItems.first(where: { $0.handle == handle })
      let isVideo = item.map(CameraVendorGalleryDownloadPolicy.mediaType(for:)) == .video
      let filename = item?.filename ?? "CamTransfer.jpg"

      do {
        if isVideo {
          let file = try await worker.downloadOriginalFile(for: handle)
          try await CameraVendorPhotoLibrarySaver.save(file: file)
        } else {
          let data = try await worker.downloadOriginal(for: handle)
          try await CameraVendorPhotoLibrarySaver.save(data: data, filename: filename)
        }
        galleryState.markDownloadFinished(handle: handle)
        CameraVendorDownloadHistoryStore.markSaved(handle: handle, for: cameraHistoryKey)
        await counter.bumpSuccess()
      } catch {
        if isWorker2 {
          // Safety net: worker 2 had a problem. Put the handle back into
          // the queue for worker 1, retire worker 2, and never touch this
          // handle again from worker 2.
          appendDiagnostic("[\(label)] 下载失败 handle=\(handle)，回退到主通道：\(error.localizedDescription)")
          galleryState.enqueueDownloads(for: [handle])
          await worker2Status.retire()
          refreshStatusText()
          collectionView.reloadData()
          notifyDownloadStateChanged()
          return
        }
        galleryState.markDownloadFailed(handle: handle, message: error.localizedDescription)
      }
      refreshStatusText()
      collectionView.reloadData()
      notifyDownloadStateChanged()
    }
  }
}

fileprivate enum CameraVendorParallelDownloadAsyncFetcher {
  case primary(CameraVendorGalleryService)
  case secondary(CameraVendorParallelDownloadWorker)

  func downloadOriginal(for handle: Int) async throws -> Data {
    switch self {
    case .primary(let service): return try await service.downloadOriginal(for: handle)
    case .secondary(let worker): return try await worker.downloadOriginal(for: handle)
    }
  }

  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile {
    switch self {
    case .primary(let service): return try await service.downloadOriginalFile(for: handle)
    case .secondary(let worker): return try await worker.downloadOriginalFile(for: handle)
    }
  }
}

fileprivate actor SafeParallelDownloadCounter {
  private(set) var startedCount = 0
  private(set) var successCount = 0
  func bumpStarted() -> Int { startedCount += 1; return startedCount }
  func bumpSuccess() { successCount += 1 }
}

fileprivate actor SafeParallelDownloadWorker2Status {
  private(set) var isRetired = false
  func retire() { isRetired = true }
}

extension NativeGalleryViewController {
  private func showDownloadListForCurrentTasks() {
    let controller = NativeDownloadListViewController(
      itemsProvider: { [weak self] in
        self?.downloadListItems() ?? []
      },
      stateProvider: { [weak self] handle in
        self?.galleryState.downloadState(for: handle) ?? .idle
      },
      progressProvider: { [weak self] handle in
        self?.galleryState.downloadProgressText(for: handle)
      }
    )
    navigationController?.pushViewController(controller, animated: true)
  }

  private var cameraHistoryKey: String {
    let serial = summary.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    return serial.isEmpty ? summary.deviceName : serial
  }

  private func restoreSavedDownloadStates() {
    let saved = CameraVendorDownloadHistoryStore.savedHandles(for: cameraHistoryKey)
    guard !saved.isEmpty else { return }
    for item in allGalleryItems {
      if saved.contains(item.handle) {
        galleryState.markDownloadFinished(handle: item.handle)
      }
    }
  }

  private func downloadListItems() -> [CameraVendorGalleryItem] {
    let activeItems = allGalleryItems.filter { item in
      switch galleryState.downloadState(for: item.handle) {
      case .idle: return false
      case .queued, .downloading, .saved, .failed: return true
      }
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
    return activeItems.sorted { lhs, rhs in
      let lp = priority(galleryState.downloadState(for: lhs.handle))
      let rp = priority(galleryState.downloadState(for: rhs.handle))
      if lp != rp { return lp < rp }
      return lhs.handle < rhs.handle
    }
  }

  private func notifyDownloadStateChanged() {
    NotificationCenter.default.post(name: .nativeDownloadStateDidChange, object: nil)
  }

  private func refreshStatusText() {
    updateNavigationLock()
    if galleryState.isLoading {
      if (copyLabel.text ?? "").isEmpty || copyLabel.text == "准备加载图库" {
        copyLabel.text = "正在加载图库…"
      }
      copyLabel.textColor = NativeLuxuryTheme.secondaryInk
      loadingSpinner.startAnimating()
      refreshBottomDownloadBar()
      return
    }

    loadingSpinner.stopAnimating()

    if let errorMessage = galleryState.errorMessage {
      copyLabel.text = "加载失败：\(errorMessage)"
      copyLabel.textColor = NativeLuxuryTheme.secondaryInk
      refreshBottomDownloadBar()
      return
    }

    let total = allGalleryItems.count
    let visible = galleryState.items.count
    let selected = galleryState.selectedHandles.count
    let filterApplied = !(filterState.date == .all && filterState.format == .all)
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
    refreshBottomDownloadBar()
  }

  private func refreshBottomDownloadBar() {
    let selectedCount = galleryState.selectedHandles.count
    bottomDownloadBar.isHidden = selectedCount == 0
    bottomDownloadLabel.text = "已选 \(selectedCount) 张"
    bottomDownloadButton.isEnabled = selectedCount > 0 && !isDownloading
  }

  private func updateNavigationLock() {
    let canLeave = NativeGalleryNavigationPolicy.canLeaveGallery(isDownloading: isDownloading)
    navigationItem.hidesBackButton = !canLeave
    navigationController?.interactivePopGestureRecognizer?.isEnabled = canLeave
    isModalInPresentation = !canLeave
    downloadListButtonItem?.isEnabled = canLeave
    selectAllButtonItem?.isEnabled = canLeave
    if !canLeave {
      reservedReceiveProbeButton.isEnabled = false
    }
  }

  private func applyCurrentFilters(shouldLoadThumbnails: Bool) {
    let filteredItems = NativeGalleryFilterPolicy.filteredItems(
      allGalleryItems,
      state: filterState
    )
    galleryState.replaceItems(filteredItems)
    refreshStatusText()
    collectionView.reloadData()
    if shouldLoadThumbnails {
      loadVisibleThumbnails()
    }
  }

  private func loadVisibleThumbnails() {
    let handles = galleryState.items
      .filter { $0.thumbnailData == nil }
      .map(\.handle)
    if CameraVendorThumbnailLoadPolicy.shouldLoadSequentially {
      Task { @MainActor in
        await loadThumbnailsSequentially(for: handles)
      }
    } else {
      for handle in handles {
        Task { @MainActor in
          await loadThumbnail(for: handle)
        }
      }
    }
  }

  private func toggleSelection(for item: CameraVendorGalleryItem) {
    galleryState.toggleSelection(handle: item.handle)
    refreshStatusText()
    if let indexPath = indexPath(for: item) {
      collectionView.reloadItems(at: [indexPath])
    }
  }

  private func indexPath(for item: CameraVendorGalleryItem) -> IndexPath? {
    guard let index = galleryState.items.firstIndex(where: { $0.handle == item.handle }) else {
      return nil
    }
    return IndexPath(item: index, section: 0)
  }

  private func presentPreview(startingAt index: Int) {
    let controller = NativePhotoPreviewViewController(
      items: galleryState.items,
      initialIndex: index,
      galleryService: galleryService,
      isSelected: { [weak self] handle in
        self?.galleryState.selectedHandles.contains(handle) ?? false
      },
      downloadStateProvider: { [weak self] handle in
        self?.galleryState.downloadState(for: handle) ?? .idle
      },
      onSelectionToggle: { [weak self] item in
        guard let self,
              NativeGalleryDownloadSelectionPolicy.canSelect(
                downloadState: self.galleryState.downloadState(for: item.handle)
              ) else { return }
        self.toggleSelection(for: item)
      },
      onDownload: { [weak self] item in
        self?.startDownload(for: [item.handle])
      },
      isTransferLocked: { [weak self] in
        self?.isDownloading ?? false
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
    overlay.configure(ssidHint: summary.wifiCandidates.first)
    overlay.onOpenSettings = { [weak self] in
      guard let self else { return }
      self.openSystemWifiSettings()
    }
    overlay.onRetry = { [weak self] in
      guard let self else { return }
      let currentIP = CameraVendorNetworkUtils.wifiIPv4Address()
      if CameraVendorGalleryLoadPolicy.shouldAllowManualReload(currentWifiIP: currentIP) {
        self.hideWifiPromptOverlay()
        self.loadGallery()
      } else {
        self.appendDiagnostic("仍未检测到相机 Wi-Fi，请在系统设置确认连接的是 CAMERA 网络。")
      }
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
  static func decoded(from data: Data) -> UIImage? {
    guard let raw = decodeRaw(data: data) else { return nil }
    return cropBlackBars(raw) ?? raw
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
  private let itemsProvider: () -> [CameraVendorGalleryItem]
  private let stateProvider: (Int) -> CameraVendorDownloadState
  private let progressProvider: (Int) -> String?

  private let brandLabel = NativeLuxuryTheme.makeBrandLabel("DOWNLOADS", size: 10)
  private let titleLabel = NativeLuxuryTheme.makeTitleLabel("下载中心", size: 30)
  private let copyLabel = NativeLuxuryTheme.makeCopyLabel("缩略图网格。哪张下载，哪张显示状态。")

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
    layout.minimumInteritemSpacing = 6
    layout.minimumLineSpacing = 6
    layout.sectionInset = UIEdgeInsets(top: 4, left: 18, bottom: 16, right: 18)
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
    title.text = "还没有下载任务"
    title.font = .systemFont(ofSize: 16, weight: .semibold)
    title.textColor = NativeLuxuryTheme.ink
    title.textAlignment = .center

    let copy = UILabel()
    copy.translatesAutoresizingMaskIntoConstraints = false
    copy.text = "在图库里点击照片右上的下载，或多选后点底部 “下载原图”，任务会出现在这里。"
    copy.font = .systemFont(ofSize: 13, weight: .regular)
    copy.textColor = NativeLuxuryTheme.secondaryInk
    copy.numberOfLines = 0
    copy.textAlignment = .center

    let stack = UIStackView(arrangedSubviews: [icon, title, copy])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 12
    stack.alignment = .center
    stack.isHidden = true
    return stack
  }()

  init(
    itemsProvider: @escaping () -> [CameraVendorGalleryItem],
    stateProvider: @escaping (Int) -> CameraVendorDownloadState,
    progressProvider: @escaping (Int) -> String?
  ) {
    self.itemsProvider = itemsProvider
    self.stateProvider = stateProvider
    self.progressProvider = progressProvider
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
    title = "下载中心"
    view.backgroundColor = NativeLuxuryTheme.background

    let header = UIStackView(arrangedSubviews: [brandLabel, titleLabel, copyLabel])
    header.translatesAutoresizingMaskIntoConstraints = false
    header.axis = .vertical
    header.spacing = 6
    header.setCustomSpacing(8, after: titleLabel)

    view.addSubview(header)
    view.addSubview(collectionView)
    view.addSubview(emptyContainer)
    view.addSubview(footerLabel)
    collectionView.dataSource = self
    collectionView.delegate = self
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
      header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),

      collectionView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8),

      emptyContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyContainer.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor, constant: -20),
      emptyContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
      emptyContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

      footerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      footerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      footerLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
    ])
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(downloadStateDidChange),
      name: .nativeDownloadStateDidChange,
      object: nil
    )
    refreshFooter()
    refreshEmptyState()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    collectionView.reloadData()
    refreshFooter()
    refreshEmptyState()
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .darkContent
  }

  @objc private func downloadStateDidChange() {
    collectionView.reloadData()
    refreshFooter()
    refreshEmptyState()
  }

  private func refreshEmptyState() {
    let isEmpty = itemsProvider().isEmpty
    emptyContainer.isHidden = !isEmpty
    collectionView.isHidden = isEmpty
    footerLabel.isHidden = isEmpty
  }

  private func refreshFooter() {
    let items = itemsProvider()
    let total = items.count
    var saved = 0
    var downloading: CameraVendorGalleryItem?
    var queued = 0
    for item in items {
      switch stateProvider(item.handle) {
      case .saved: saved += 1
      case .downloading: downloading = item
      case .queued: queued += 1
      case .idle, .failed: break
      }
    }
    if let active = downloading {
      let progress = progressProvider(active.handle).map { " · \($0)" } ?? ""
      footerLabel.text = "\(active.formatLabel) · \(active.byteSizeText)\(progress)"
    } else if queued > 0 {
      footerLabel.text = "\(queued) 张排队中 · 已保存 \(saved)/\(total)"
    } else if total == 0 {
      footerLabel.text = "暂无下载任务"
    } else {
      footerLabel.text = "已保存 \(saved)/\(total)"
    }
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
    cell.configure(
      item: item,
      isSelected: false,
      downloadState: stateProvider(item.handle),
      showsSelection: false,
      dimsUndownloaded: true
    )
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let side = NativeGalleryGridLayoutPolicy.itemSide(
      forCollectionWidth: collectionView.bounds.width,
      horizontalInset: 18,
      interItemSpacing: 6,
      columns: 4
    )
    return CGSize(width: side, height: side)
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: true)
  }
}

extension NativeGalleryViewController: UICollectionViewDataSource {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    galleryState.items.count
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
    let item = galleryState.items[indexPath.item]
    let downloadState = galleryState.downloadState(for: item.handle)
    cell.configure(
      item: item,
      isSelected: galleryState.selectedHandles.contains(item.handle),
      downloadState: downloadState
    )
    cell.onSelectionTapped = { [weak self] in
      guard NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: downloadState) else { return }
      self?.toggleSelection(for: item)
    }
    return cell
  }
}

extension NativeGalleryViewController: UICollectionViewDelegateFlowLayout {
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    presentPreview(startingAt: indexPath.item)
  }

  private var horizontalInsetForCurrentLayout: CGFloat {
    currentColumnCount >= 5 ? 8 : 12
  }

  private var spacingForCurrentLayout: CGFloat {
    currentColumnCount >= 5 ? 4 : 6
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
    return UIEdgeInsets(top: 6, left: inset, bottom: 24, right: inset)
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
}

private final class NativeGalleryGridCell: UICollectionViewCell {
  static let reuseIdentifier = "NativeGalleryGridCell"

  var onSelectionTapped: (() -> Void)?

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
    label.font = .systemFont(ofSize: 6.5, weight: .heavy)
    label.textColor = NativeLuxuryTheme.ink
    label.textAlignment = .center
    label.backgroundColor = UIColor.white.withAlphaComponent(0.82)
    label.layer.cornerRadius = 5
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
    selectionButton.isEnabled = true
    downloadActivityIndicator.stopAnimating()
  }

  func configure(
    item: CameraVendorGalleryItem,
    isSelected: Bool,
    downloadState: CameraVendorDownloadState,
    showsSelection: Bool = true,
    dimsUndownloaded: Bool = false
  ) {
    titleLabel.text = nil
    detailLabel.text = nil
    formatBadgeLabel.text = formatBadgeText(for: item)
    if let data = item.thumbnailData, let image = CameraVendorGalleryThumbnailRenderer.decoded(from: data) {
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
    labelContainer.contentView.addSubview(titleLabel)
    labelContainer.contentView.addSubview(detailLabel)
    labelContainer.isHidden = true
    selectionButton.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)

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

      formatBadgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
      formatBadgeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
      formatBadgeLabel.heightAnchor.constraint(equalToConstant: 11),
      formatBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),

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
    case .idle, .failed:
      imageView.alpha = dimsUndownloaded ? 0.58 : 1
      statusBadgeLabel.isHidden = true
      downloadActivityIndicator.stopAnimating()
    case .queued:
      imageView.alpha = 0.86
      statusBadgeLabel.text = " 排队 "
      statusBadgeLabel.backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.78)
      statusBadgeLabel.textColor = NativeLuxuryTheme.cardBackground
      statusBadgeLabel.isHidden = false
      downloadActivityIndicator.stopAnimating()
    case .downloading:
      imageView.alpha = 0.86
      statusBadgeLabel.isHidden = true
      downloadActivityIndicator.startAnimating()
    case .saved:
      imageView.alpha = 1
      statusBadgeLabel.text = " 已保存 "
      statusBadgeLabel.backgroundColor = UIColor.white.withAlphaComponent(0.92)
      statusBadgeLabel.textColor = NativeLuxuryTheme.ink
      statusBadgeLabel.isHidden = false
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

  private func formatBadgeText(for item: CameraVendorGalleryItem) -> String {
    let raw = item.formatLabel == "Video" ? "MOV" : item.formatLabel.uppercased()
    return " \(raw) "
  }

  @objc private func selectionTapped() {
    onSelectionTapped?()
  }
}

private final class NativePhotoPreviewViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
  private let items: [CameraVendorGalleryItem]
  private let galleryService: CameraVendorGalleryService
  private let isSelected: (Int) -> Bool
  private let downloadStateProvider: (Int) -> CameraVendorDownloadState
  private let onSelectionToggle: (CameraVendorGalleryItem) -> Void
  private let onDownload: (CameraVendorGalleryItem) -> Void
  private let isTransferLocked: () -> Bool
  private let onTransferLockedDismissAttempt: () -> Void
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
    galleryService: CameraVendorGalleryService,
    isSelected: @escaping (Int) -> Bool,
    downloadStateProvider: @escaping (Int) -> CameraVendorDownloadState,
    onSelectionToggle: @escaping (CameraVendorGalleryItem) -> Void,
    onDownload: @escaping (CameraVendorGalleryItem) -> Void,
    isTransferLocked: @escaping () -> Bool,
    onTransferLockedDismissAttempt: @escaping () -> Void
  ) {
    self.items = items
    self.currentIndex = min(max(initialIndex, 0), max(items.count - 1, 0))
    self.galleryService = galleryService
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
    bottomBar.addSubview(downloadButton)

    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
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
      topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),

      closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
      closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),
      closeButton.widthAnchor.constraint(equalToConstant: 36),
      closeButton.heightAnchor.constraint(equalToConstant: 36),

      titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -2),

      subtitleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      subtitleLabel.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),

      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bottomBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -68),

      selectionButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 22),
      selectionButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 14),
      selectionButton.widthAnchor.constraint(equalToConstant: 44),
      selectionButton.heightAnchor.constraint(equalToConstant: 44),

      downloadButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -22),
      downloadButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
    ])
  }

  private func makePage(for index: Int) -> NativePhotoPreviewPageController {
    let item = items[index]
    return NativePhotoPreviewPageController(
      item: item,
      index: index,
      galleryService: galleryService,
      canDismiss: { [weak self] in
        guard let self else { return true }
        return NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: self.isTransferLocked())
      },
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
    subtitleLabel.text = "\(currentIndex + 1) / \(items.count) · \(item.formatLabel) · \(item.byteSizeText)"
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
      title = "已下载"; enabled = false
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

  @objc private func downloadTapped() {
    guard items.indices.contains(currentIndex) else { return }
    let item = items[currentIndex]
    guard CameraVendorGalleryDownloadPolicy.canDownloadOriginal(item),
          NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: downloadStateProvider(item.handle)) else {
      return
    }
    onDownload(item)
    refreshChromeForCurrentItem()
  }

  @objc private func downloadStateChanged() {
    refreshChromeForCurrentItem()
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
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool
  ) {
    guard completed,
          let page = pageController.viewControllers?.first as? NativePhotoPreviewPageController else { return }
    currentIndex = page.index
    refreshChromeForCurrentItem()
  }
}

private final class NativePhotoPreviewPageController: UIViewController, UIScrollViewDelegate {
  let index: Int
  let item: CameraVendorGalleryItem
  private let galleryService: CameraVendorGalleryService
  private let canDismiss: () -> Bool
  private let onDismissDrag: (CGFloat) -> Void
  private let onDismissBlocked: () -> Void
  private let onDismissCommit: () -> Void
  private let onDismissCancel: () -> Void
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

  init(
    item: CameraVendorGalleryItem,
    index: Int,
    galleryService: CameraVendorGalleryService,
    canDismiss: @escaping () -> Bool,
    onDismissDrag: @escaping (CGFloat) -> Void,
    onDismissBlocked: @escaping () -> Void,
    onDismissCommit: @escaping () -> Void,
    onDismissCancel: @escaping () -> Void
  ) {
    self.item = item
    self.index = index
    self.galleryService = galleryService
    self.canDismiss = canDismiss
    self.onDismissDrag = onDismissDrag
    self.onDismissBlocked = onDismissBlocked
    self.onDismissCommit = onDismissCommit
    self.onDismissCancel = onDismissCancel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit { loadTask?.cancel() }

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

    loadImage()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    centerImage()
  }

  private func loadImage() {
    if let data = item.thumbnailData,
       let image = CameraVendorGalleryThumbnailRenderer.decoded(from: data) {
      apply(image: image)
    } else {
      spinner.startAnimating()
    }
    guard loadTask == nil else { return }
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let data = try await galleryService.fetchThumbnail(for: item.handle)
        if Task.isCancelled { return }
        let image = CameraVendorGalleryThumbnailRenderer.decoded(from: data)
        await MainActor.run {
          self.spinner.stopAnimating()
          if let image { self.apply(image: image) }
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

  private func apply(image: UIImage) {
    imageView.image = image
    placeholderView.isHidden = true
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

private enum CameraVendorPhotoLibrarySaver {
  static func save(file: CameraVendorDownloadedFile) async throws {
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

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges({
        switch file.mediaType {
        case .photo:
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = file.filename
          request.addResource(with: .photo, fileURL: file.fileURL, options: options)
        case .video:
          _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file.fileURL)
        }
      }) { success, error in
        try? FileManager.default.removeItem(at: file.fileURL)
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          continuation.resume()
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
