import Foundation
import UIKit
import CoreBluetooth

enum NativeCameraSearchStartupPolicy {
  static let shouldShowManualAddCameraButton = false
  static let inlineDiscoveredCameraLimit = 3
  static let shouldRestartScanningAfterRememberedCameraDeletion = true

  static func shouldStartScanningOnLaunch(hasRememberedCamera: Bool) -> Bool {
    hasRememberedCamera
  }

  static func shouldHideRememberedCameraWhileScanning(hasRememberedCamera _: Bool) -> Bool {
    false
  }

  static func shouldShowInlineDiscoveredCameraList(discoveredCameraCount: Int) -> Bool {
    discoveredCameraCount > 0
  }
}

enum NativeCameraDebugLaunchPolicy {
  static let autoConnectRememberedArgument = "--camtransfer-autoconnect-remembered"
  static let showStubGalleryArgument = "--camtransfer-show-stub-gallery"
  static let showStubDownloadsArgument = "--camtransfer-show-stub-downloads"

  static func shouldAutoConnectRememberedCamera(arguments: [String]) -> Bool {
    arguments.contains(autoConnectRememberedArgument)
  }

  static func shouldShowStubGallery(arguments: [String]) -> Bool {
    arguments.contains(showStubGalleryArgument)
  }

  static func shouldShowStubDownloads(arguments: [String]) -> Bool {
    arguments.contains(showStubDownloadsArgument)
  }
}

enum NativePairingConfirmationPresentationPolicy {
  static func shouldPresentPhoneConfirmationPrompt(status: String, isBusy: Bool) -> Bool {
    status.trimmingCharacters(in: .whitespacesAndNewlines)
      == CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus && !isBusy
  }
}

enum NativeFreshPairingSystemBluetoothCleanupPrompt {
  static let title = "先删除本地蓝牙配对"
  static let message = "重新配对前，请先删除本地蓝牙配对：打开 iPhone 设置 > 蓝牙，找到这台相机并点“忽略此设备”。未删除的本地蓝牙配对会让相机继续信任之前的注册信息，后面的 Wi-Fi/PTP 传图链路可能失败。"
  static let openBluetoothTitle = "打开本地蓝牙设置"
  static let confirmTitle = "确认已删除，重新配对"
  static let checkboxTitle = "我已在 iPhone 蓝牙里忽略/删除这台相机"

  static func shouldRequireBeforeFreshPairing() -> Bool {
    false
  }
}

final class NativeBluetoothCleanupConfirmationViewController: UIViewController {
  private let promptTitle: String
  private let promptMessage: String
  private let openBluetoothTitle: String
  private let confirmTitle: String
  private let checkboxTitle: String
  private let openBluetoothAction: () -> Void
  private let confirmAction: () -> Void
  private let cancelAction: () -> Void
  private var isChecked = false

  let checkboxButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = NativeLuxuryTheme.ink
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
  }()

  private let confirmButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.layer.cornerRadius = 14
    button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    button.configuration = configuration
    return button
  }()

  init(
    title: String,
    message: String,
    openBluetoothTitle: String,
    confirmTitle: String,
    checkboxTitle: String,
    openBluetoothAction: @escaping () -> Void,
    confirmAction: @escaping () -> Void,
    cancelAction: @escaping () -> Void
  ) {
    self.promptTitle = title
    self.promptMessage = message
    self.openBluetoothTitle = openBluetoothTitle
    self.confirmTitle = confirmTitle
    self.checkboxTitle = checkboxTitle
    self.openBluetoothAction = openBluetoothAction
    self.confirmAction = confirmAction
    self.cancelAction = cancelAction
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.35)

    let card = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = .white
    card.layer.cornerRadius = 24
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = 0.18
    card.layer.shadowRadius = 28
    card.layer.shadowOffset = CGSize(width: 0, height: 16)

    let titleLabel = UILabel()
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.text = promptTitle
    titleLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
    titleLabel.textColor = NativeLuxuryTheme.ink
    titleLabel.numberOfLines = 0

    let messageLabel = UILabel()
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    messageLabel.text = promptMessage
    messageLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
    messageLabel.textColor = NativeLuxuryTheme.secondaryInk
    messageLabel.numberOfLines = 0

    let openButton = UIButton(type: .system)
    openButton.translatesAutoresizingMaskIntoConstraints = false
    openButton.setTitle(openBluetoothTitle, for: .normal)
    openButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    openButton.layer.cornerRadius = 14
    openButton.layer.borderWidth = 1
    openButton.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    openButton.setTitleColor(NativeLuxuryTheme.ink, for: .normal)
    var openConfiguration = UIButton.Configuration.plain()
    openConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
    openButton.configuration = openConfiguration
    openButton.addTarget(self, action: #selector(openBluetoothTapped), for: .touchUpInside)

    let checkboxLabel = UILabel()
    checkboxLabel.translatesAutoresizingMaskIntoConstraints = false
    checkboxLabel.text = checkboxTitle
    checkboxLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    checkboxLabel.textColor = NativeLuxuryTheme.ink
    checkboxLabel.numberOfLines = 0

    let checkboxRow = UIStackView(arrangedSubviews: [checkboxButton, checkboxLabel])
    checkboxRow.translatesAutoresizingMaskIntoConstraints = false
    checkboxRow.axis = .horizontal
    checkboxRow.alignment = .center
    checkboxRow.spacing = 10
    checkboxRow.isUserInteractionEnabled = true
    checkboxButton.addTarget(self, action: #selector(toggleCheckbox), for: .touchUpInside)
    checkboxRow.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleCheckbox)))

    confirmButton.setTitle(confirmTitle, for: .normal)
    confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)

    let cancelButton = UIButton(type: .system)
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.setTitle("取消", for: .normal)
    cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    cancelButton.setTitleColor(NativeLuxuryTheme.secondaryInk, for: .normal)
    var cancelConfiguration = UIButton.Configuration.plain()
    cancelConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
    cancelButton.configuration = cancelConfiguration
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

    let buttonStack = UIStackView(arrangedSubviews: [openButton, confirmButton, cancelButton])
    buttonStack.translatesAutoresizingMaskIntoConstraints = false
    buttonStack.axis = .vertical
    buttonStack.spacing = 10

    let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, checkboxRow, buttonStack])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 18

    view.addSubview(card)
    card.addSubview(stack)
    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22),
      card.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
      checkboxButton.widthAnchor.constraint(equalToConstant: 28),
      checkboxButton.heightAnchor.constraint(equalToConstant: 28),
    ])

    refreshCheckboxState()
  }

  @objc private func toggleCheckbox() {
    isChecked.toggle()
    refreshCheckboxState()
  }

  @objc private func openBluetoothTapped() {
    openBluetoothAction()
  }

  @objc private func confirmTapped() {
    guard isChecked else { return }
    dismiss(animated: true) { [confirmAction] in
      confirmAction()
    }
  }

  @objc private func cancelTapped() {
    dismiss(animated: true) { [cancelAction] in
      cancelAction()
    }
  }

  private func refreshCheckboxState() {
    let symbolName = isChecked ? "checkmark.square.fill" : "square"
    let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
    checkboxButton.setImage(UIImage(systemName: symbolName, withConfiguration: configuration), for: .normal)
    checkboxButton.accessibilityValue = isChecked ? "已选中" : "未选中"
    confirmButton.isEnabled = isChecked
    confirmButton.backgroundColor = isChecked ? NativeLuxuryTheme.ink : UIColor(red: 0.898, green: 0.878, blue: 0.831, alpha: 1)
    confirmButton.setTitleColor(isChecked ? .white : NativeLuxuryTheme.secondaryInk, for: .normal)
  }
}

enum NativePairingSuccessCleanupPolicy {
  enum Event {
    case didCompletePairing
    case didCompleteHandshake
  }

  static let pairingConfirmationAlertTitle = "确认配对"

  static func shouldDismissPairingUI(event: Event) -> Bool {
    switch event {
    case .didCompletePairing, .didCompleteHandshake:
      return true
    }
  }

  static func isPairingConfirmationAlert(title: String?) -> Bool {
    title == pairingConfirmationAlertTitle
  }
}

enum NativeTransferSizeSettingPolicy {
  static let originalID = "original"
  static let compressedID = "compressed"
  static let originalLabelText = "原图"
  static let compressedLabelText = "压缩"
  static let originalSymbolName = "photo"
  static let compressedSymbolName = "bolt.fill"
  static let switchWidth: CGFloat = 104
  static let switchHeight: CGFloat = 40
  static let switchLabelFontSize: CGFloat = 9.5
  static let switchSymbolPointSize: CGFloat = 11
  static let switchImagePlacement: NSDirectionalRectEdge = .top
  static let switchImagePadding: CGFloat = 1

  static func selectedID(preferCompressedDownloads: Bool) -> String {
    preferCompressedDownloads ? compressedID : originalID
  }

  static func preferCompressedDownloads(for selectedID: String) -> Bool {
    selectedID == compressedID
  }

  static func switchIsOn(preferCompressedDownloads: Bool) -> Bool {
    preferCompressedDownloads
  }

  static func preferCompressedDownloads(forSwitchIsOn isOn: Bool) -> Bool {
    isOn
  }

  static func statusText(preferCompressedDownloads: Bool) -> String {
    preferCompressedDownloads ? "下次连接使用压缩 ~3M" : "下次连接下载原图"
  }
}

final class NativeTransferSizeSwitchControl: UIControl {
  private let selectedBackground = UIView()
  private let originalButton = UIButton(type: .system)
  private let compressedButton = UIButton(type: .system)
  private var selectedLeadingConstraint: NSLayoutConstraint?

  var isOn: Bool = true {
    didSet { refresh(animated: true) }
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
    backgroundColor = UIColor.white
    layer.cornerRadius = NativeTransferSizeSettingPolicy.switchHeight / 2
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    clipsToBounds = true

    selectedBackground.translatesAutoresizingMaskIntoConstraints = false
    selectedBackground.backgroundColor = UIColor(red: 0.18, green: 0.37, blue: 0.29, alpha: 1)
    selectedBackground.layer.cornerRadius = (NativeTransferSizeSettingPolicy.switchHeight - 4) / 2
    selectedBackground.layer.cornerCurve = .continuous
    selectedBackground.isUserInteractionEnabled = false

    [originalButton, compressedButton].forEach { button in
      button.translatesAutoresizingMaskIntoConstraints = false
      button.configuration = .plain()
      button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
      button.configuration?.imagePlacement = NativeTransferSizeSettingPolicy.switchImagePlacement
      button.configuration?.imagePadding = NativeTransferSizeSettingPolicy.switchImagePadding
      button.configuration?.titleAlignment = .center
      button.titleLabel?.font = .systemFont(
        ofSize: NativeTransferSizeSettingPolicy.switchLabelFontSize,
        weight: .bold
      )
      button.tintColor = NativeLuxuryTheme.ink
    }
    configure(
      originalButton,
      title: NativeTransferSizeSettingPolicy.originalLabelText,
      symbolName: NativeTransferSizeSettingPolicy.originalSymbolName
    )
    configure(
      compressedButton,
      title: NativeTransferSizeSettingPolicy.compressedLabelText,
      symbolName: NativeTransferSizeSettingPolicy.compressedSymbolName
    )
    originalButton.addTarget(self, action: #selector(originalTapped), for: .touchUpInside)
    compressedButton.addTarget(self, action: #selector(compressedTapped), for: .touchUpInside)
    addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

    addSubview(selectedBackground)
    addSubview(originalButton)
    addSubview(compressedButton)

    let segmentWidth = (NativeTransferSizeSettingPolicy.switchWidth - 4) / 2
    let leading = selectedBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
    selectedLeadingConstraint = leading

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: NativeTransferSizeSettingPolicy.switchWidth),
      heightAnchor.constraint(equalToConstant: NativeTransferSizeSettingPolicy.switchHeight),

      selectedBackground.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      selectedBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      selectedBackground.widthAnchor.constraint(equalToConstant: segmentWidth),
      leading,

      originalButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      originalButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      originalButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      originalButton.widthAnchor.constraint(equalToConstant: segmentWidth),

      compressedButton.leadingAnchor.constraint(equalTo: originalButton.trailingAnchor),
      compressedButton.topAnchor.constraint(equalTo: originalButton.topAnchor),
      compressedButton.bottomAnchor.constraint(equalTo: originalButton.bottomAnchor),
      compressedButton.widthAnchor.constraint(equalTo: originalButton.widthAnchor),
    ])
    refresh(animated: false)
  }

  private func configure(_ button: UIButton, title: String, symbolName: String) {
    let symbol = UIImage(
      systemName: symbolName,
      withConfiguration: UIImage.SymbolConfiguration(
        pointSize: NativeTransferSizeSettingPolicy.switchSymbolPointSize,
        weight: .bold
      )
    )
    button.configuration?.image = symbol
    button.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
      .font: UIFont.systemFont(
        ofSize: NativeTransferSizeSettingPolicy.switchLabelFontSize,
        weight: .bold
      )
    ]))
  }

  private func refresh(animated: Bool) {
    selectedLeadingConstraint?.constant = isOn
      ? NativeTransferSizeSettingPolicy.switchWidth / 2
      : 2
    originalButton.tintColor = isOn ? NativeLuxuryTheme.secondaryInk : UIColor.white
    compressedButton.tintColor = isOn ? UIColor.white : NativeLuxuryTheme.secondaryInk
    originalButton.configuration?.baseForegroundColor = originalButton.tintColor
    compressedButton.configuration?.baseForegroundColor = compressedButton.tintColor
    accessibilityValue = isOn
      ? NativeTransferSizeSettingPolicy.compressedLabelText
      : NativeTransferSizeSettingPolicy.originalLabelText

    guard animated else {
      layoutIfNeeded()
      return
    }
    UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
      self.layoutIfNeeded()
    }
  }

  @objc private func originalTapped() {
    guard isOn else { return }
    isOn = false
    sendActions(for: .valueChanged)
  }

  @objc private func compressedTapped() {
    guard !isOn else { return }
    isOn = true
    sendActions(for: .valueChanged)
  }

  @objc private func toggleTapped() {
    isOn.toggle()
    sendActions(for: .valueChanged)
  }
}

final class NativeScanViewController: UIViewController {
  private let onSelect: (IOSCameraDiscoveredCamera) -> Void
  private let onCancel: () -> Void

  private var cameras: [IOSCameraDiscoveredCamera]
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

  init(
    initialCameras: [IOSCameraDiscoveredCamera],
    onSelect: @escaping (IOSCameraDiscoveredCamera) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.cameras = initialCameras
    self.onSelect = onSelect
    self.onCancel = onCancel
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
      emptyLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
    ])

    scanIndicator.startAnimating()
    rebuildCameraCards()
  }

  func update(cameras: [IOSCameraDiscoveredCamera]) {
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

  func markConnecting(to camera: IOSCameraDiscoveredCamera) {
    connectingCameraID = camera.id
    rebuildCameraCards()
  }

  @objc private func cancelTapped() {
    onCancel()
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

final class NativePairingPreparationCard: UIView {
  private let actionTitle: String?
  private let onAction: (() -> Void)?

  init(
    number: String,
    label: String,
    title: String,
    body: String,
    footnote: String? = nil,
    accentColor: UIColor,
    actionTitle: String? = nil,
    onAction: (() -> Void)? = nil
  ) {
    self.actionTitle = actionTitle
    self.onAction = onAction
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setupSubviews(
      number: number,
      label: label,
      title: title,
      body: body,
      footnote: footnote,
      accentColor: accentColor
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupSubviews(
    number: String,
    label: String,
    title: String,
    body: String,
    footnote: String?,
    accentColor: UIColor
  ) {
    backgroundColor = NativeLuxuryTheme.cardBackground.withAlphaComponent(0.72)
    layer.cornerRadius = 16
    layer.borderWidth = 1
    layer.borderColor = accentColor.withAlphaComponent(0.18).cgColor

    let badge = UILabel()
    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.text = number
    badge.textAlignment = .center
    badge.font = .systemFont(ofSize: 13, weight: .black)
    badge.textColor = accentColor
    badge.backgroundColor = accentColor.withAlphaComponent(0.12)
    badge.layer.cornerRadius = 14
    badge.clipsToBounds = true

    let labelView = UILabel()
    labelView.translatesAutoresizingMaskIntoConstraints = false
    labelView.text = label
    labelView.font = .systemFont(ofSize: 10, weight: .black)
    labelView.textColor = accentColor

    let titleView = UILabel()
    titleView.translatesAutoresizingMaskIntoConstraints = false
    titleView.text = title
    titleView.font = .systemFont(ofSize: 15, weight: .heavy)
    titleView.textColor = NativeLuxuryTheme.ink
    titleView.numberOfLines = 1
    titleView.adjustsFontSizeToFitWidth = true
    titleView.minimumScaleFactor = 0.85

    let bodyView = NativeLuxuryTheme.makeCopyLabel(body)
    bodyView.font = .systemFont(ofSize: 12, weight: .regular)
    bodyView.numberOfLines = 2
    bodyView.isHidden = !NativeHomePairingPreparationLayoutPolicy.showsLongInstructionBody

    let textStack = UIStackView(arrangedSubviews: [labelView, titleView, bodyView])
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.axis = .vertical
    textStack.spacing = 4

    if let footnote {
      let footnoteLabel = NativeLuxuryTheme.makeCopyLabel(footnote)
      footnoteLabel.font = .systemFont(ofSize: 11, weight: .semibold)
      footnoteLabel.textColor = NativeLuxuryTheme.secondaryInk
      footnoteLabel.numberOfLines = 1
      footnoteLabel.adjustsFontSizeToFitWidth = true
      footnoteLabel.minimumScaleFactor = 0.82
      textStack.addArrangedSubview(footnoteLabel)
    }

    if let actionTitle {
      let button = UIButton(type: .system)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.setTitle(actionTitle, for: .normal)
      NativeLuxuryTheme.styleCompactPillButton(button, accentColor: accentColor)
      NativeLuxuryTheme.setIcon("gearshape", on: button)
      button.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
      let actionRow = UIStackView(arrangedSubviews: [button, UIView()])
      actionRow.translatesAutoresizingMaskIntoConstraints = false
      actionRow.axis = .horizontal
      actionRow.spacing = 8
      textStack.addArrangedSubview(actionRow)
    }

    addSubview(badge)
    addSubview(textStack)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: NativeHomePairingPreparationLayoutPolicy.rowMinimumHeight),

      badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      badge.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      badge.widthAnchor.constraint(equalToConstant: 28),
      badge.heightAnchor.constraint(equalToConstant: 28),

      textStack.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
      textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
    ])
  }

  @objc private func actionTapped() {
    onAction?()
  }
}

final class NativeScanCameraCard: UIControl {
  private let camera: IOSCameraDiscoveredCamera
  private let isConnecting: Bool
  private let onTap: () -> Void

  init(camera: IOSCameraDiscoveredCamera, isConnecting: Bool, onTap: @escaping () -> Void) {
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
    badge.text = badgeText(for: camera.displayName)
    badge.textAlignment = .center
    badge.font = .systemFont(ofSize: 13, weight: .heavy)
    badge.textColor = NativeLuxuryTheme.ink
    badge.layer.cornerRadius = 23
    badge.layer.borderWidth = 1
    badge.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    badge.clipsToBounds = true

    let nameLabel = UILabel()
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.text = camera.displayName
    nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    nameLabel.textColor = NativeLuxuryTheme.ink

    let detailLabel = UILabel()
    detailLabel.translatesAutoresizingMaskIntoConstraints = false
    detailLabel.text = NativeHomeCameraCardCopyPolicy.unpairedDetailText(
      rssi: camera.rssi,
      shortID: String(camera.id.uuidString.prefix(8))
    )
    detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
    detailLabel.textColor = NativeLuxuryTheme.secondaryInk

    let pairButton = UIButton(type: .system)
    pairButton.translatesAutoresizingMaskIntoConstraints = false
    pairButton.configuration = .filled()
    pairButton.configuration?.cornerStyle = .capsule
    pairButton.configuration?.baseBackgroundColor = NativeLuxuryTheme.ink
    pairButton.configuration?.baseForegroundColor = NativeLuxuryTheme.cardBackground
    pairButton.configuration?.image = UIImage(systemName: "link", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
    pairButton.configuration?.imagePadding = 5
    pairButton.configuration?.attributedTitle = AttributedString(NativeHomeCameraCardCopyPolicy.unpairedActionTitle, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .bold)
    ]))
    pairButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = NativeLuxuryTheme.accent
    spinner.hidesWhenStopped = true

    addSubview(badge)
    addSubview(nameLabel)
    addSubview(detailLabel)
    addSubview(pairButton)
    addSubview(spinner)

    if isConnecting {
      spinner.startAnimating()
      pairButton.isHidden = true
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
      nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: pairButton.leadingAnchor, constant: -10),

      detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
      detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: pairButton.leadingAnchor, constant: -10),
      detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),

      pairButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      pairButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      pairButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
      pairButton.heightAnchor.constraint(equalToConstant: 36),

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

final class NativePairedCameraCard: UIView {
  private let record: IOSCameraRememberedCameraRecord
  private let presence: NativeHomeRememberedCameraPresence
  private let primaryActionTitle: String
  private let showsDisconnectAction: Bool
  private let onConnect: () -> Void
  private let onDisconnect: () -> Void
  private let onForget: () -> Void
  private let contentView = UIView()
  private let connectButton = UIButton(type: .system)
  private let disconnectButton = UIButton(type: .system)
  private let deleteButton = UIButton(type: .system)
  private var isDeleteRevealed = false

  init(
    record: IOSCameraRememberedCameraRecord,
    presence: NativeHomeRememberedCameraPresence,
    primaryActionTitle: String,
    showsDisconnectAction: Bool,
    onConnect: @escaping () -> Void,
    onDisconnect: @escaping () -> Void,
    onForget: @escaping () -> Void
  ) {
    self.record = record
    self.presence = presence
    self.primaryActionTitle = primaryActionTitle
    self.showsDisconnectAction = showsDisconnectAction
    self.onConnect = onConnect
    self.onDisconnect = onDisconnect
    self.onForget = onForget
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear
    setupSubviews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupSubviews() {
    contentView.translatesAutoresizingMaskIntoConstraints = false
    NativeLuxuryTheme.applyCardStyle(contentView, radius: 24)

    let profileHeader = UIView()
    profileHeader.translatesAutoresizingMaskIntoConstraints = false
    profileHeader.backgroundColor = NativeLuxuryTheme.accentSoft.withAlphaComponent(0.32)
    profileHeader.isHidden = !NativeHomePairedCameraCardLayoutPolicy.showsDecorativeProfileHeader

    let profileLabel = NativeLuxuryTheme.makeBrandLabel(NativeHomeAndroidParityCopy.cameraProfileTitle, size: 9)
    profileLabel.textColor = NativeLuxuryTheme.secondaryInk.withAlphaComponent(0.78)

    let menuButton = UIButton(type: .system)
    menuButton.translatesAutoresizingMaskIntoConstraints = false
    menuButton.configuration = .plain()
    menuButton.configuration?.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold))
    menuButton.tintColor = NativeLuxuryTheme.ink
    menuButton.accessibilityLabel = "删除相机"
    menuButton.addTarget(self, action: #selector(revealDeleteAction), for: .touchUpInside)

    let divider = UIView()
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.backgroundColor = NativeLuxuryTheme.accent.withAlphaComponent(0.10)
    divider.isHidden = !NativeHomePairedCameraCardLayoutPolicy.showsDecorativeProfileHeader

    let badge = UILabel()
    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.text = badgeText(for: record.identity.displayName)
    badge.textAlignment = .center
    badge.font = .systemFont(ofSize: 14, weight: .heavy)
    badge.textColor = NativeLuxuryTheme.ink
    badge.layer.cornerRadius = 26
    badge.layer.borderWidth = 1
    badge.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    badge.clipsToBounds = true

    let seriesLabel = UILabel()
    seriesLabel.translatesAutoresizingMaskIntoConstraints = false
    seriesLabel.text = "X SERIES"
    seriesLabel.textAlignment = .center
    seriesLabel.font = .systemFont(ofSize: 9, weight: .black)
    seriesLabel.textColor = NativeLuxuryTheme.secondaryInk
    seriesLabel.backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.055)
    seriesLabel.layer.cornerRadius = 10
    seriesLabel.clipsToBounds = true

    let nameLabel = UILabel()
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.text = record.identity.displayName
    nameLabel.font = .systemFont(ofSize: 20, weight: .heavy)
    nameLabel.textColor = NativeLuxuryTheme.ink
    nameLabel.numberOfLines = 1
    nameLabel.adjustsFontSizeToFitWidth = true
    nameLabel.minimumScaleFactor = 0.82

    let detailLabel = UILabel()
    detailLabel.translatesAutoresizingMaskIntoConstraints = false
    detailLabel.text = NativeHomeAndroidParityCopy.savedCameraLabel
    detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
    detailLabel.textColor = NativeLuxuryTheme.secondaryInk
    detailLabel.numberOfLines = 1
    detailLabel.adjustsFontSizeToFitWidth = true
    detailLabel.minimumScaleFactor = 0.82

    connectButton.translatesAutoresizingMaskIntoConstraints = false
    connectButton.configuration = .filled()
    connectButton.configuration?.cornerStyle = .capsule
    connectButton.configuration?.baseBackgroundColor = NativeLuxuryTheme.ink
    connectButton.configuration?.baseForegroundColor = NativeLuxuryTheme.cardBackground
    connectButton.configuration?.image = UIImage(systemName: "bolt.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
    connectButton.configuration?.imagePadding = 5
    connectButton.configuration?.attributedTitle = AttributedString(primaryActionTitle, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .bold)
    ]))
    connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)

    disconnectButton.translatesAutoresizingMaskIntoConstraints = false
    disconnectButton.configuration = .filled()
    disconnectButton.configuration?.cornerStyle = .capsule
    disconnectButton.configuration?.baseBackgroundColor = NativeLuxuryTheme.mutedFill
    disconnectButton.configuration?.baseForegroundColor = UIColor.systemRed
    disconnectButton.configuration?.image = UIImage(systemName: "xmark.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
    disconnectButton.configuration?.imagePadding = 5
    disconnectButton.configuration?.attributedTitle = AttributedString(
      NativeHomeCameraCardCopyPolicy.disconnectActionTitle,
      attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .bold)])
    )
    disconnectButton.layer.borderWidth = 1
    disconnectButton.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.18).cgColor
    disconnectButton.isHidden = !showsDisconnectAction
    disconnectButton.addTarget(self, action: #selector(disconnectTapped), for: .touchUpInside)

    let statusPanel = UIView()
    statusPanel.translatesAutoresizingMaskIntoConstraints = false
    statusPanel.backgroundColor = NativeHomePairedCameraCardLayoutPolicy.showsStatusPanelFrame
      ? NativeLuxuryTheme.warmFill
      : .clear
    statusPanel.layer.cornerRadius = NativeHomePairedCameraCardLayoutPolicy.showsStatusPanelFrame ? 16 : 0
    statusPanel.layer.borderWidth = NativeHomePairedCameraCardLayoutPolicy.showsStatusPanelFrame ? 1 : 0
    statusPanel.layer.borderColor = NativeHomePairedCameraCardLayoutPolicy.showsStatusPanelFrame
      ? NativeLuxuryTheme.hairline.cgColor
      : UIColor.clear.cgColor

    let statusLabel = UILabel()
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.text = NativeHomeCameraCardCopyPolicy.pairedDetailText(for: presence)
    statusLabel.font = .systemFont(ofSize: 11, weight: .heavy)
    statusLabel.textColor = NativeLuxuryTheme.accent

    let statusDetail = NativeLuxuryTheme.makeCopyLabel(
      NativeHomeAndroidParityCopy.statusPanelDetail(for: presence)
    )
    statusDetail.font = .systemFont(ofSize: 12, weight: .regular)

    deleteButton.translatesAutoresizingMaskIntoConstraints = false
    deleteButton.configuration = .filled()
    deleteButton.configuration?.cornerStyle = .capsule
    deleteButton.configuration?.baseBackgroundColor = UIColor.systemRed
    deleteButton.configuration?.baseForegroundColor = .white
    deleteButton.configuration?.image = UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
    deleteButton.accessibilityLabel = "删除已配对相机"
    deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
    deleteButton.alpha = 0
    deleteButton.isHidden = true

    let actionStack = UIStackView(arrangedSubviews: [connectButton, disconnectButton])
    actionStack.translatesAutoresizingMaskIntoConstraints = false
    actionStack.axis = .vertical
    actionStack.alignment = .fill
    actionStack.distribution = .fillEqually
    actionStack.spacing = 10

    addSubview(deleteButton)
    addSubview(contentView)
    contentView.addSubview(profileHeader)
    profileHeader.addSubview(profileLabel)
    profileHeader.addSubview(menuButton)
    contentView.addSubview(divider)
    contentView.addSubview(badge)
    contentView.addSubview(seriesLabel)
    contentView.addSubview(nameLabel)
    contentView.addSubview(detailLabel)
    contentView.addSubview(statusPanel)
    statusPanel.addSubview(statusLabel)
    statusPanel.addSubview(statusDetail)
    contentView.addSubview(actionStack)

    let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(revealDeleteAction))
    swipeLeft.direction = .left
    contentView.addGestureRecognizer(swipeLeft)
    let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(hideDeleteAction))
    swipeRight.direction = .right
    contentView.addGestureRecognizer(swipeRight)
    let tap = UITapGestureRecognizer(target: self, action: #selector(contentTapped))
    tap.cancelsTouchesInView = false
    contentView.addGestureRecognizer(tap)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: NativeHomePairedCameraCardLayoutPolicy.cardMinimumHeight),

      deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      deleteButton.widthAnchor.constraint(equalToConstant: 58),
      deleteButton.heightAnchor.constraint(equalToConstant: 46),

      contentView.topAnchor.constraint(equalTo: topAnchor),
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

      profileHeader.topAnchor.constraint(equalTo: contentView.topAnchor),
      profileHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      profileHeader.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      profileHeader.heightAnchor.constraint(
        equalToConstant: NativeHomePairedCameraCardLayoutPolicy.showsDecorativeProfileHeader ? 46 : 0
      ),

      profileLabel.leadingAnchor.constraint(equalTo: profileHeader.leadingAnchor, constant: 17),
      profileLabel.centerYAnchor.constraint(equalTo: profileHeader.centerYAnchor),

      menuButton.trailingAnchor.constraint(equalTo: profileHeader.trailingAnchor, constant: -12),
      menuButton.centerYAnchor.constraint(equalTo: profileHeader.centerYAnchor),
      menuButton.widthAnchor.constraint(equalToConstant: 38),
      menuButton.heightAnchor.constraint(equalToConstant: 38),

      divider.topAnchor.constraint(equalTo: profileHeader.bottomAnchor),
      divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1),

      badge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
      badge.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
      badge.widthAnchor.constraint(equalToConstant: 52),
      badge.heightAnchor.constraint(equalToConstant: 52),

      seriesLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 14),
      seriesLabel.topAnchor.constraint(equalTo: badge.topAnchor),
      seriesLabel.heightAnchor.constraint(equalToConstant: 20),
      seriesLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),

      nameLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 14),
      nameLabel.topAnchor.constraint(equalTo: seriesLabel.bottomAnchor, constant: 6),
      nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -14),

      detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
      detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),

      statusPanel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 17),
      statusPanel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -17),
      statusPanel.topAnchor.constraint(
        equalTo: detailLabel.bottomAnchor,
        constant: NativeHomePairedCameraCardLayoutPolicy.statusPanelTopSpacingAfterIdentity
      ),
      statusPanel.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -14),

      statusLabel.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 14),
      statusLabel.topAnchor.constraint(equalTo: statusPanel.topAnchor, constant: 12),
      statusLabel.trailingAnchor.constraint(equalTo: statusPanel.trailingAnchor, constant: -14),

      statusDetail.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
      statusDetail.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
      statusDetail.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
      statusDetail.bottomAnchor.constraint(equalTo: statusPanel.bottomAnchor, constant: -12),

      actionStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      actionStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
      actionStack.widthAnchor.constraint(greaterThanOrEqualToConstant: NativeHomePairedCameraCardLayoutPolicy.primaryGalleryActionMinimumWidth),
      connectButton.heightAnchor.constraint(equalToConstant: 36),
      disconnectButton.heightAnchor.constraint(equalToConstant: 36),
    ])
  }

  @objc private func connectTapped() {
    onConnect()
  }

  @objc private func disconnectTapped() {
    onDisconnect()
  }

  @objc private func deleteTapped() {
    onForget()
  }

  @objc private func revealDeleteAction() {
    guard !isDeleteRevealed else { return }
    isDeleteRevealed = true
    deleteButton.isHidden = false
    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
      self.contentView.transform = CGAffineTransform(translationX: -76, y: 0)
      self.deleteButton.alpha = 1
    }
  }

  @objc private func hideDeleteAction() {
    guard isDeleteRevealed else { return }
    isDeleteRevealed = false
    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
      self.contentView.transform = .identity
      self.deleteButton.alpha = 0
    } completion: { _ in
      self.deleteButton.isHidden = true
    }
  }

  @objc private func contentTapped() {
    if isDeleteRevealed {
      hideDeleteAction()
    }
  }

  private func badgeText(for deviceName: String) -> String {
    let upper = deviceName.uppercased()
    return String(upper.filter { $0.isLetter }.prefix(2))
  }
}
