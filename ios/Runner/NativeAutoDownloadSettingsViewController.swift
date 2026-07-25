import UIKit

final class NativeAutoDownloadSettingsViewController: UIViewController {
  private var rule: CameraAutoDownloadRule
  private let onSave: (CameraAutoDownloadRule) -> Void

  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private let enableSwitch = UISwitch()
  private let disconnectSwitch = UISwitch()
  private var formatButtons: [UIView] = []
  private var dateButtons: [UIView] = []
  private var statusButtons: [UIView] = []
  private var modeButtons: [UIView] = []

  init(rule: CameraAutoDownloadRule, onSave: @escaping (CameraAutoDownloadRule) -> Void) {
    self.rule = rule
    self.onSave = onSave
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .light
    title = "自动下载规则"
    view.backgroundColor = NativeLuxuryTheme.background
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "保存", style: .done, target: self, action: #selector(saveTapped)
    )
    setupUI()
    refreshUI()
  }

  private func setupUI() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 24
    contentStack.layoutMargins = UIEdgeInsets(top: 24, left: 20, bottom: 40, right: 20)
    contentStack.isLayoutMarginsRelativeArrangement = true

    view.addSubview(scrollView)
    scrollView.addSubview(contentStack)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
      contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
      contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
      contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])

    // Enable switch
    let enableRow = makeRow(title: "启用自动下载", accessory: enableSwitch)
    enableSwitch.isOn = rule.isEnabled
    enableSwitch.addTarget(self, action: #selector(enableChanged), for: .valueChanged)
    contentStack.addArrangedSubview(enableRow)

    // Format section
    let formatSection = makeSectionLabel("下载格式")
    contentStack.addArrangedSubview(formatSection)
    let formatStack = makeChipStack(
      items: CameraAutoDownloadFormat.allCases.map { ($0.rawValue, $0.displayTitle) },
      selectedID: rule.format.rawValue,
      action: #selector(formatTapped(_:))
    )
    formatButtons = formatStack.arrangedSubviews
    contentStack.addArrangedSubview(formatStack)

    // Date section
    let dateSection = makeSectionLabel("日期范围")
    contentStack.addArrangedSubview(dateSection)
    let dateStack = makeChipStack(
      items: CameraAutoDownloadDate.presets.map { (dateID($0), $0.displayTitle) },
      selectedID: dateID(rule.date),
      action: #selector(dateTapped(_:))
    )
    dateButtons = dateStack.arrangedSubviews
    contentStack.addArrangedSubview(dateStack)

    // Status section
    let statusSection = makeSectionLabel("下载范围")
    contentStack.addArrangedSubview(statusSection)
    let statusStack = makeChipStack(
      items: CameraAutoDownloadStatus.allCases.map { ($0.rawValue, $0.displayTitle) },
      selectedID: rule.downloadStatus.rawValue,
      action: #selector(statusTapped(_:))
    )
    statusButtons = statusStack.arrangedSubviews
    contentStack.addArrangedSubview(statusStack)

    // Download mode section
    let modeSection = makeSectionLabel("下载质量")
    contentStack.addArrangedSubview(modeSection)
    let modeStack = makeChipStack(
      items: [
        (CameraAutoDownloadMode.original.rawValue, "原图"),
        (CameraAutoDownloadMode.compressed.rawValue, "压缩"),
      ],
      selectedID: rule.downloadMode.rawValue,
      action: #selector(modeTapped(_:))
    )
    modeButtons = modeStack.arrangedSubviews
    contentStack.addArrangedSubview(modeStack)

    // Disconnect after download switch
    let disconnectRow = makeRow(title: "下载完自动断开", accessory: disconnectSwitch)
    disconnectSwitch.isOn = rule.disconnectAfterDownload
    disconnectSwitch.addTarget(self, action: #selector(disconnectChanged), for: .valueChanged)
    contentStack.addArrangedSubview(disconnectRow)

    // Summary
    let summaryLabel = UILabel()
    summaryLabel.font = .systemFont(ofSize: 13, weight: .regular)
    summaryLabel.textColor = NativeLuxuryTheme.ink.withAlphaComponent(0.6)
    summaryLabel.numberOfLines = 0
    summaryLabel.text = "连接相机后将自动按此规则筛选并开始下载，无需手动进入图库选择。"
    contentStack.addArrangedSubview(summaryLabel)
  }

  private func refreshUI() {
    let allFormatButtons = formatButtons.flatMap { row in
      (row as? UIStackView)?.arrangedSubviews.compactMap { $0 as? UIButton } ?? [row as? UIButton].compactMap { $0 }
    }
    for button in allFormatButtons {
      let selected = button.accessibilityIdentifier == rule.format.rawValue
      styleChip(button, selected: selected)
    }
    let allDateButtons = dateButtons.flatMap { row in
      (row as? UIStackView)?.arrangedSubviews.compactMap { $0 as? UIButton } ?? [row as? UIButton].compactMap { $0 }
    }
    for button in allDateButtons {
      let selected = button.accessibilityIdentifier == dateID(rule.date)
      styleChip(button, selected: selected)
    }
    let allStatusButtons = statusButtons.flatMap { row in
      (row as? UIStackView)?.arrangedSubviews.compactMap { $0 as? UIButton } ?? [row as? UIButton].compactMap { $0 }
    }
    for button in allStatusButtons {
      let selected = button.accessibilityIdentifier == rule.downloadStatus.rawValue
      styleChip(button, selected: selected)
    }
    let allModeButtons = modeButtons.flatMap { row in
      (row as? UIStackView)?.arrangedSubviews.compactMap { $0 as? UIButton } ?? [row as? UIButton].compactMap { $0 }
    }
    for button in allModeButtons {
      let selected = button.accessibilityIdentifier == rule.downloadMode.rawValue
      styleChip(button, selected: selected)
    }
  }

  @objc private func enableChanged() {
    rule.isEnabled = enableSwitch.isOn
  }

  @objc private func formatTapped(_ sender: UIButton) {
    guard let id = sender.accessibilityIdentifier,
          let format = CameraAutoDownloadFormat(rawValue: id) else { return }
    rule.format = format
    refreshUI()
  }

  @objc private func dateTapped(_ sender: UIButton) {
    guard let id = sender.accessibilityIdentifier else { return }
    rule.date = dateFromID(id)
    refreshUI()
  }

  @objc private func statusTapped(_ sender: UIButton) {
    guard let id = sender.accessibilityIdentifier,
          let status = CameraAutoDownloadStatus(rawValue: id) else { return }
    rule.downloadStatus = status
    refreshUI()
  }

  @objc private func modeTapped(_ sender: UIButton) {
    guard let id = sender.accessibilityIdentifier,
          let mode = CameraAutoDownloadMode(rawValue: id) else { return }
    rule.downloadMode = mode
    refreshUI()
  }

  @objc private func disconnectChanged() {
    rule.disconnectAfterDownload = disconnectSwitch.isOn
  }

  @objc private func saveTapped() {
    onSave(rule)
    navigationController?.popViewController(animated: true)
  }

  // MARK: - Helpers

  private func makeRow(title: String, accessory: UIView) -> UIView {
    let label = UILabel()
    label.text = title
    label.font = .systemFont(ofSize: 16, weight: .medium)
    label.textColor = NativeLuxuryTheme.ink
    let row = UIStackView(arrangedSubviews: [label, accessory])
    row.axis = .horizontal
    row.alignment = .center
    row.distribution = .equalSpacing
    return row
  }

  private func makeSectionLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: 14, weight: .semibold)
    label.textColor = NativeLuxuryTheme.ink.withAlphaComponent(0.7)
    return label
  }

  private func makeChipStack(
    items: [(id: String, title: String)],
    selectedID: String,
    action: Selector
  ) -> UIStackView {
    let wrapStack = UIStackView()
    wrapStack.axis = .vertical
    wrapStack.spacing = 8
    wrapStack.alignment = .leading

    var currentRow = UIStackView()
    currentRow.axis = .horizontal
    currentRow.spacing = 8

    for (index, item) in items.enumerated() {
      let button = UIButton(type: .system)
      button.setTitle(item.title, for: .normal)
      button.accessibilityIdentifier = item.id
      button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
      var config = UIButton.Configuration.filled()
      config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
      config.cornerStyle = .capsule
      button.configuration = config
      button.addTarget(self, action: action, for: .touchUpInside)
      styleChip(button, selected: item.id == selectedID)
      currentRow.addArrangedSubview(button)

      if (index + 1) % 3 == 0 || index == items.count - 1 {
        wrapStack.addArrangedSubview(currentRow)
        if index < items.count - 1 {
          currentRow = UIStackView()
          currentRow.axis = .horizontal
          currentRow.spacing = 8
        }
      }
    }
    return wrapStack
  }

  private func styleChip(_ button: UIButton, selected: Bool) {
    guard var config = button.configuration else { return }
    if selected {
      config.baseBackgroundColor = NativeLuxuryTheme.ink
      config.baseForegroundColor = .white
    } else {
      config.baseBackgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.08)
      config.baseForegroundColor = NativeLuxuryTheme.ink
    }
    button.configuration = config
  }

  private func dateID(_ date: CameraAutoDownloadDate) -> String {
    switch date {
    case .all: return "all"
    case .today: return "today"
    case .lastNDays(let n): return "last\(n)"
    }
  }

  private func dateFromID(_ id: String) -> CameraAutoDownloadDate {
    switch id {
    case "all": return .all
    case "today": return .today
    case "last3": return .lastNDays(3)
    case "last7": return .lastNDays(7)
    default: return .all
    }
  }
}
