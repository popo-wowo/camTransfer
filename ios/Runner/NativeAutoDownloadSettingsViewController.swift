import UIKit

enum NativeAutoDownloadSettingsSavePolicy {
  static func resolvedRule(
    _ rule: CameraAutoDownloadRule,
    forcesEnabled: Bool
  ) -> CameraAutoDownloadRule {
    var resolvedRule = rule
    if forcesEnabled {
      resolvedRule.isEnabled = true
    }
    return resolvedRule
  }
}

final class NativeAutoDownloadSettingsViewController: UIViewController {
  private var rule: CameraAutoDownloadRule
  private let saveButtonTitle: String
  private let forcesEnabledOnSave: Bool
  private let onSave: (CameraAutoDownloadRule) -> Void

  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private let enableSwitch = UISwitch()
  private let disconnectSwitch = UISwitch()

  private var formatSegmentsRow1: UISegmentedControl!
  private var formatSegmentsRow2: UISegmentedControl!
  private var dateSegments: UISegmentedControl!
  private var statusSegments: UISegmentedControl!
  private var modeSegments: UISegmentedControl!
  private var datePicker: UIDatePicker?

  init(
    rule: CameraAutoDownloadRule,
    saveButtonTitle: String = "保存",
    forcesEnabledOnSave: Bool = false,
    onSave: @escaping (CameraAutoDownloadRule) -> Void
  ) {
    self.rule = rule
    self.saveButtonTitle = saveButtonTitle
    self.forcesEnabledOnSave = forcesEnabledOnSave
    self.onSave = onSave
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .light
    title = forcesEnabledOnSave ? "快速下载参数" : "自动下载规则"
    view.backgroundColor = NativeLuxuryTheme.background
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: saveButtonTitle, style: .done, target: self, action: #selector(saveTapped)
    )
    setupUI()
  }

  private func setupUI() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 20
    contentStack.layoutMargins = UIEdgeInsets(top: 20, left: 20, bottom: 40, right: 20)
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

    if !forcesEnabledOnSave {
      contentStack.addArrangedSubview(makeSwitchRow(title: "启用自动下载", toggle: enableSwitch, isOn: rule.isEnabled, action: #selector(enableChanged)))
    }

    // Format: two rows of 3
    let formatRow1Titles = ["全部格式", "JPG", "HEIF"]
    formatSegmentsRow1 = UISegmentedControl(items: formatRow1Titles)
    formatSegmentsRow1.addTarget(self, action: #selector(formatRow1Changed), for: .valueChanged)

    let formatRow2Titles = ["RAW", "JPG + HEIF", "JPG + RAW"]
    formatSegmentsRow2 = UISegmentedControl(items: formatRow2Titles)
    formatSegmentsRow2.addTarget(self, action: #selector(formatRow2Changed), for: .valueChanged)

    refreshFormatSelection()
    let formatStack = UIStackView(arrangedSubviews: [formatSegmentsRow1, formatSegmentsRow2])
    formatStack.axis = .vertical
    formatStack.spacing = 8
    contentStack.addArrangedSubview(makeSection(title: "下载格式", control: formatStack))

    // Date: 全部日期 / 今天 / 选择日期
    dateSegments = UISegmentedControl(items: ["全部日期", "今天", "选择日期"])
    dateSegments.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
    refreshDateSelection()

    let dateStack = UIStackView()
    dateStack.axis = .vertical
    dateStack.spacing = 8
    dateStack.addArrangedSubview(dateSegments)

    let picker = UIDatePicker()
    picker.datePickerMode = .date
    picker.preferredDatePickerStyle = .compact
    picker.addTarget(self, action: #selector(datePickerChanged), for: .valueChanged)
    if case .specificDate(let d) = rule.date {
      picker.date = d
    }
    picker.isHidden = !rule.date.isSpecificDate
    datePicker = picker
    dateStack.addArrangedSubview(picker)

    contentStack.addArrangedSubview(makeSection(title: "日期范围", control: dateStack))

    // Status
    statusSegments = UISegmentedControl(items: ["全部", "未下载的"])
    statusSegments.selectedSegmentIndex = rule.downloadStatus == .all ? 0 : 1
    statusSegments.addTarget(self, action: #selector(statusChanged), for: .valueChanged)
    contentStack.addArrangedSubview(makeSection(title: "下载范围", control: statusSegments))

    // Mode
    modeSegments = UISegmentedControl(items: ["原图", "压缩"])
    modeSegments.selectedSegmentIndex = rule.downloadMode == .original ? 0 : 1
    modeSegments.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
    contentStack.addArrangedSubview(makeSection(title: "下载质量", control: modeSegments))

    // Disconnect switch
    contentStack.addArrangedSubview(makeSwitchRow(title: "下载完自动断开", toggle: disconnectSwitch, isOn: rule.disconnectAfterDownload, action: #selector(disconnectChanged)))

    // Footer
    let footerLabel = UILabel()
    footerLabel.font = .preferredFont(forTextStyle: .footnote)
    footerLabel.textColor = .secondaryLabel
    footerLabel.numberOfLines = 0
    footerLabel.text = "连接相机后将自动按此规则筛选并开始下载，无需手动进入图库选择。"
    contentStack.addArrangedSubview(footerLabel)
  }

  // MARK: - Format helpers

  private static let formatRow1Cases: [CameraAutoDownloadFormat] = [.all, .jpg, .heif]
  private static let formatRow2Cases: [CameraAutoDownloadFormat] = [.raw, .jpgAndHeif, .jpgAndRaw]

  private func refreshFormatSelection() {
    if let idx = Self.formatRow1Cases.firstIndex(of: rule.format) {
      formatSegmentsRow1.selectedSegmentIndex = idx
      formatSegmentsRow2.selectedSegmentIndex = UISegmentedControl.noSegment
    } else if let idx = Self.formatRow2Cases.firstIndex(of: rule.format) {
      formatSegmentsRow1.selectedSegmentIndex = UISegmentedControl.noSegment
      formatSegmentsRow2.selectedSegmentIndex = idx
    }
  }

  private func refreshDateSelection() {
    switch rule.date {
    case .all:
      dateSegments.selectedSegmentIndex = 0
    case .today:
      dateSegments.selectedSegmentIndex = 1
    default:
      dateSegments.selectedSegmentIndex = 2
    }
  }

  // MARK: - Actions

  @objc private func enableChanged() {
    rule.isEnabled = enableSwitch.isOn
  }

  @objc private func disconnectChanged() {
    rule.disconnectAfterDownload = disconnectSwitch.isOn
  }

  @objc private func formatRow1Changed() {
    let idx = formatSegmentsRow1.selectedSegmentIndex
    guard Self.formatRow1Cases.indices.contains(idx) else { return }
    rule.format = Self.formatRow1Cases[idx]
    formatSegmentsRow2.selectedSegmentIndex = UISegmentedControl.noSegment
  }

  @objc private func formatRow2Changed() {
    let idx = formatSegmentsRow2.selectedSegmentIndex
    guard Self.formatRow2Cases.indices.contains(idx) else { return }
    rule.format = Self.formatRow2Cases[idx]
    formatSegmentsRow1.selectedSegmentIndex = UISegmentedControl.noSegment
  }

  @objc private func dateChanged() {
    switch dateSegments.selectedSegmentIndex {
    case 0:
      rule.date = .all
      datePicker?.isHidden = true
    case 1:
      rule.date = .today
      datePicker?.isHidden = true
    case 2:
      let pickerDate = datePicker?.date ?? Date()
      rule.date = .specificDate(pickerDate)
      datePicker?.isHidden = false
    default:
      break
    }
  }

  @objc private func datePickerChanged() {
    guard let picker = datePicker else { return }
    rule.date = .specificDate(picker.date)
  }

  @objc private func statusChanged() {
    rule.downloadStatus = statusSegments.selectedSegmentIndex == 0 ? .all : .notDownloaded
  }

  @objc private func modeChanged() {
    rule.downloadMode = modeSegments.selectedSegmentIndex == 0 ? .original : .compressed
  }

  @objc private func saveTapped() {
    let resolvedRule = NativeAutoDownloadSettingsSavePolicy.resolvedRule(rule, forcesEnabled: forcesEnabledOnSave)
    rule = resolvedRule
    onSave(resolvedRule)
    navigationController?.popViewController(animated: true)
  }

  // MARK: - Helpers

  private func makeSection(title: String, control: UIView) -> UIView {
    let label = UILabel()
    label.text = title
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.textColor = .secondaryLabel
    let stack = UIStackView(arrangedSubviews: [label, control])
    stack.axis = .vertical
    stack.spacing = 8
    return stack
  }

  private func makeSwitchRow(title: String, toggle: UISwitch, isOn: Bool, action: Selector) -> UIView {
    toggle.isOn = isOn
    toggle.addTarget(self, action: action, for: .valueChanged)
    let label = UILabel()
    label.text = title
    label.font = .preferredFont(forTextStyle: .body)
    let row = UIStackView(arrangedSubviews: [label, toggle])
    row.axis = .horizontal
    row.alignment = .center
    row.distribution = .equalSpacing
    return row
  }
}
