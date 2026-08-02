import UIKit

enum NativeAutoDownloadSettingsSavePolicy {
  static func resolvedRule(
    _ rule: CameraAutoDownloadRule,
    forcesEnabled _: Bool
  ) -> CameraAutoDownloadRule {
    var resolvedRule = rule
    resolvedRule.isEnabled = true
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
  private let disconnectSwitch = UISwitch()

  private let formatChips = NativeChipBarControl()
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

    let formatIDs = ["all", "jpg", "raw", "heif"]
    formatChips.allowsMultipleSelection = true
    formatChips.exclusiveSelectionID = "all"
    formatChips.configure(
      items: formatIDs.map { NativeChipBarControl.Item(id: $0, title: formatTitle(for: $0)) },
      selectedIDs: selectedFormatIDs
    )
    formatChips.onSelectionChanged = { [weak self] selectedIDs in
      self?.updateFormats(selectedIDs)
    }
    contentStack.addArrangedSubview(makeSection(title: "下载格式", control: formatChips))

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
    if case .specificDay(let d) = rule.filter.date {
      picker.date = d
    }
    picker.isHidden = !rule.filter.date.isSpecificDay
    datePicker = picker
    dateStack.addArrangedSubview(picker)

    contentStack.addArrangedSubview(makeSection(title: "日期范围", control: dateStack))

    // Status
    statusSegments = UISegmentedControl(items: ["全部", "未下载的"])
    statusSegments.selectedSegmentIndex = rule.filter.downloadScope == .all ? 0 : 1
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
    footerLabel.text = "点击快速下载后，将按此规则筛选并开始下载。"
    contentStack.addArrangedSubview(footerLabel)
  }

  private var selectedFormatIDs: Set<String> {
    switch rule.filter.formats {
    case .all:
      return ["all"]
    case .selected(let formats):
      return Set(formats.map(\.rawValue))
    }
  }

  private func formatTitle(for id: String) -> String {
    id == "all" ? "全部格式" : id.uppercased()
  }

  private func updateFormats(_ selectedIDs: Set<String>) {
    let formats = Set(selectedIDs.compactMap(CameraMediaFormat.init(rawValue:)))
    rule.filter = CameraMediaFilterRule(
      formats: CameraMediaFormatSelection.normalized(formats),
      date: rule.filter.date,
      downloadScope: rule.filter.downloadScope
    )
  }

  private func refreshDateSelection() {
    switch rule.filter.date {
    case .all:
      dateSegments.selectedSegmentIndex = 0
    case .today:
      dateSegments.selectedSegmentIndex = 1
    default:
      dateSegments.selectedSegmentIndex = 2
    }
  }

  // MARK: - Actions

  @objc private func disconnectChanged() {
    rule.disconnectAfterDownload = disconnectSwitch.isOn
  }

  @objc private func dateChanged() {
    let date: CameraMediaDateSelection
    switch dateSegments.selectedSegmentIndex {
    case 0:
      date = .all
      datePicker?.isHidden = true
    case 1:
      date = .today
      datePicker?.isHidden = true
    case 2:
      let pickerDate = datePicker?.date ?? Date()
      date = .specificDay(pickerDate)
      datePicker?.isHidden = false
    default:
      return
    }
    rule.filter = CameraMediaFilterRule(
      formats: rule.filter.formats,
      date: date,
      downloadScope: rule.filter.downloadScope
    )
  }

  @objc private func datePickerChanged() {
    guard let picker = datePicker else { return }
    rule.filter = CameraMediaFilterRule(
      formats: rule.filter.formats,
      date: .specificDay(picker.date),
      downloadScope: rule.filter.downloadScope
    )
  }

  @objc private func statusChanged() {
    rule.filter = CameraMediaFilterRule(
      formats: rule.filter.formats,
      date: rule.filter.date,
      downloadScope: statusSegments.selectedSegmentIndex == 0 ? .all : .notDownloaded
    )
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
