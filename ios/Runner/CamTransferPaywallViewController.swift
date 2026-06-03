import StoreKit
import UIKit

final class CamTransferPaywallViewController: UIViewController {
  private let access = CamTransferProAccessController.shared
  private let store = CamTransferProStore.shared
  private let reason: CamTransferProRestrictionReason?

  private var selectedOption: CamTransferProPurchaseOption = .lifetime
  private var planCards: [CamTransferProPurchaseOption: CamTransferPlanCard] = [:]
  private var priceLabels: [CamTransferProPurchaseOption: UILabel] = [:]

  private let primaryButton = UIButton(type: .system)
  private let statusLabel = UILabel()
  private let restoreButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)

  init(reason: CamTransferProRestrictionReason? = nil) {
    self.reason = reason
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
    setupUI()
    updateSelection()
    loadStoreProducts()
  }

  private func setupUI() {
    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = false

    let content = UIStackView()
    content.translatesAutoresizingMaskIntoConstraints = false
    content.axis = .vertical
    content.spacing = 14

    view.addSubview(scrollView)
    scrollView.addSubview(content)

    content.addArrangedSubview(makeHeader())
    content.addArrangedSubview(makePlanRow())
    content.addArrangedSubview(makePrimaryButton())
    content.addArrangedSubview(makeSecondaryRow())

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
      content.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
      content.bottomAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18),

      primaryButton.heightAnchor.constraint(equalToConstant: 50)
    ])
  }

  private func makeHeader() -> UIView {
    let container = UIStackView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.axis = .vertical
    container.spacing = 12

    let topLine = UIStackView()
    topLine.translatesAutoresizingMaskIntoConstraints = false
    topLine.axis = .horizontal
    topLine.alignment = .center
    topLine.distribution = .equalSpacing

    let trial = makeBadge(access.configuration.trialText, background: NativeLuxuryTheme.ink, foreground: .white)
    let freeHint = UILabel()
    freeHint.translatesAutoresizingMaskIntoConstraints = false
    freeHint.text = trialStatusText()
    freeHint.textColor = NativeLuxuryTheme.secondaryInk
    freeHint.font = .systemFont(ofSize: 12, weight: .semibold)

    topLine.addArrangedSubview(trial)
    topLine.addArrangedSubview(freeHint)

    let title = NativeLuxuryTheme.makeTitleLabel(reason?.title ?? "一起把 CamTransfer 做得更好。", size: 26)
    let copy = NativeLuxuryTheme.makeCopyLabel(
      reason?.message ?? "为了让传图更稳定、更省心，我们会持续打磨相机适配、下载体验和更多皮肤。喜欢这个方向的话，可以用 Pro 支持我们继续做好它。"
    )

    let chips = UIStackView()
    chips.translatesAutoresizingMaskIntoConstraints = false
    chips.axis = .horizontal
    chips.spacing = 7
    chips.distribution = .fillEqually
    ["不限张数", "原图 / RAW", "批量导出", "更多皮肤"].forEach {
      chips.addArrangedSubview(makeChip($0))
    }

    let valueLine = UILabel()
    valueLine.translatesAutoresizingMaskIntoConstraints = false
    valueLine.text = "Pro 是对后续适配、体验和设计细节的支持。长期使用建议终身 Pro。"
    valueLine.textColor = UIColor(red: 0.25, green: 0.43, blue: 0.32, alpha: 1)
    valueLine.font = .systemFont(ofSize: 12, weight: .bold)
    valueLine.numberOfLines = 0

    container.addArrangedSubview(topLine)
    container.addArrangedSubview(title)
    container.addArrangedSubview(copy)
    container.addArrangedSubview(chips)
    container.addArrangedSubview(valueLine)
    return container
  }

  private func makePlanRow() -> UIStackView {
    let row = UIStackView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.axis = .horizontal
    row.spacing = 8
    row.distribution = .fillEqually

    let freeCard = CamTransferPlanCard(
      tag: "免费",
      title: "基础版",
      price: "¥0",
      summary: access.configuration.freePlanText,
      detail: "适合偶尔导几张"
    )
    freeCard.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    let monthlyCard = makePaidPlanCard(
      option: .monthly,
      tag: "月度",
      title: "月度 Pro",
      summary: "完整体验",
      detail: "含更多皮肤"
    )

    let lifetimeCard = makePaidPlanCard(
      option: .lifetime,
      tag: "推荐",
      title: "终身 Pro",
      summary: "一次买断",
      detail: "长期支持开发"
    )

    row.addArrangedSubview(freeCard)
    row.addArrangedSubview(monthlyCard)
    row.addArrangedSubview(lifetimeCard)
    return row
  }

  private func makePaidPlanCard(
    option: CamTransferProPurchaseOption,
    tag: String,
    title: String,
    summary: String,
    detail: String
  ) -> CamTransferPlanCard {
    let card = CamTransferPlanCard(
      tag: tag,
      title: title,
      price: option.fallbackPriceText,
      summary: summary,
      detail: detail
    )
    card.addTarget(self, action: #selector(planTapped(_:)), for: .touchUpInside)
    card.accessibilityIdentifier = option.productID
    planCards[option] = card
    priceLabels[option] = card.priceLabel
    return card
  }

  private func makePrimaryButton() -> UIButton {
    primaryButton.translatesAutoresizingMaskIntoConstraints = false
    primaryButton.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)
    NativeLuxuryTheme.stylePrimaryButton(primaryButton)
    NativeLuxuryTheme.setIcon("checkmark.seal.fill", on: primaryButton)
    return primaryButton
  }

  private func makeSecondaryRow() -> UIStackView {
    let container = UIStackView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.axis = .vertical
    container.spacing = 10

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.textAlignment = .center
    statusLabel.textColor = NativeLuxuryTheme.secondaryInk
    statusLabel.font = .systemFont(ofSize: 12, weight: .regular)
    statusLabel.numberOfLines = 0
    statusLabel.text = "购买由 App Store 处理，可随时恢复购买。"

    let row = UIStackView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.axis = .horizontal
    row.alignment = .center
    row.distribution = .equalCentering

    configureTextButton(restoreButton, title: "恢复购买", action: #selector(restoreTapped))
    configureTextButton(closeButton, title: "继续受限使用", action: #selector(closeTapped))

    row.addArrangedSubview(restoreButton)
    row.addArrangedSubview(closeButton)
    container.addArrangedSubview(statusLabel)
    container.addArrangedSubview(row)
    return container
  }

  private func configureTextButton(_ button: UIButton, title: String, action: Selector) {
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    button.tintColor = NativeLuxuryTheme.secondaryInk
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  @objc private func planTapped(_ sender: CamTransferPlanCard) {
    guard let option = planCards.first(where: { $0.value === sender })?.key else { return }
    selectedOption = option
    updateSelection()
  }

  private func updateSelection() {
    for (option, card) in planCards {
      card.setSelected(option == selectedOption, emphasized: option == .lifetime)
    }
    let title: String
    switch selectedOption {
    case .monthly:
      title = "开始月度 Pro"
    case .lifetime:
      title = "解锁终身 Pro"
    }
    primaryButton.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 15, weight: .semibold)
    ]))
  }

  private func loadStoreProducts() {
    Task { [weak self] in
      guard let self else { return }
      do {
        let products = try await store.loadProducts()
        await MainActor.run {
          for product in products {
            guard let option = CamTransferProPurchaseOption.allCases.first(where: { $0.productID == product.id }) else {
              continue
            }
            self.priceLabels[option]?.text = self.displayPrice(for: product, option: option)
          }
        }
      } catch {
        await MainActor.run {
          self.statusLabel.text = error.localizedDescription
        }
      }
    }
  }

  private func displayPrice(for product: Product, option: CamTransferProPurchaseOption) -> String {
    switch option {
    case .monthly:
      return "\(product.displayPrice)/月"
    case .lifetime:
      return product.displayPrice
    }
  }

  private func setBusy(_ isBusy: Bool, message: String?) {
    primaryButton.isEnabled = !isBusy
    restoreButton.isEnabled = !isBusy
    closeButton.isEnabled = !isBusy
    primaryButton.alpha = isBusy ? 0.62 : 1
    statusLabel.text = message ?? "购买由 App Store 处理，可随时恢复购买。"
  }

  private func trialStatusText() -> String {
    if access.isTrialActive() {
      return "剩余约 \(access.trialDaysRemaining()) 天"
    }
    return "免费版仍可继续使用"
  }

  @objc private func unlockTapped() {
    setBusy(true, message: "正在连接 App Store...")
    Task { [weak self] in
      guard let self else { return }
      do {
        let didUnlock = try await store.purchase(selectedOption)
        await MainActor.run {
          self.setBusy(false, message: didUnlock ? "已解锁 Pro。" : "已取消购买。")
          if didUnlock {
            self.dismiss(animated: true)
          }
        }
      } catch {
        await MainActor.run {
          self.setBusy(false, message: error.localizedDescription)
        }
      }
    }
  }

  @objc private func restoreTapped() {
    setBusy(true, message: "正在恢复购买...")
    Task { [weak self] in
      guard let self else { return }
      do {
        let restored = try await store.restorePurchases()
        await MainActor.run {
          self.setBusy(false, message: restored ? "已恢复 Pro。" : "没有找到可恢复的 Pro 购买。")
          if restored {
            self.dismiss(animated: true)
          }
        }
      } catch {
        await MainActor.run {
          self.setBusy(false, message: error.localizedDescription)
        }
      }
    }
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  private func makeBadge(_ text: String, background: UIColor, foreground: UIColor) -> UILabel {
    let label = PaddingLabel(horizontal: 10, vertical: 5)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = text
    label.textColor = foreground
    label.backgroundColor = background
    label.font = .systemFont(ofSize: 10, weight: .heavy)
    label.layer.cornerRadius = 12
    label.clipsToBounds = true
    return label
  }

  private func makeChip(_ text: String) -> UILabel {
    let label = PaddingLabel(horizontal: 9, vertical: 6)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = text
    label.textAlignment = .center
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.backgroundColor = UIColor.white.withAlphaComponent(0.7)
    label.font = .systemFont(ofSize: 10, weight: .semibold)
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.82
    label.layer.cornerRadius = 13
    label.layer.borderWidth = 1
    label.layer.borderColor = NativeLuxuryTheme.hairline.cgColor
    label.clipsToBounds = true
    return label
  }
}

private final class CamTransferPlanCard: UIControl {
  let priceLabel = UILabel()

  private let tagLabel = PaddingLabel(horizontal: 8, vertical: 4)
  private let titleLabel = UILabel()
  private let summaryLabel = UILabel()
  private let detailLabel = UILabel()

  init(tag: String, title: String, price: String, summary: String, detail: String) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    layer.cornerRadius = 20
    layer.borderWidth = 1
    accessibilityLabel = "\(title)，\(price)，\(summary)"

    tagLabel.text = tag
    tagLabel.font = .systemFont(ofSize: 9, weight: .heavy)
    tagLabel.textAlignment = .center
    tagLabel.layer.cornerRadius = 10
    tagLabel.clipsToBounds = true

    titleLabel.text = title
    titleLabel.font = .systemFont(ofSize: 12, weight: .heavy)
    titleLabel.textColor = NativeLuxuryTheme.ink
    titleLabel.adjustsFontSizeToFitWidth = true
    titleLabel.minimumScaleFactor = 0.72

    priceLabel.text = price
    priceLabel.font = .systemFont(ofSize: 24, weight: .heavy)
    priceLabel.textColor = NativeLuxuryTheme.ink
    priceLabel.adjustsFontSizeToFitWidth = true
    priceLabel.minimumScaleFactor = 0.66

    summaryLabel.text = summary
    summaryLabel.font = .systemFont(ofSize: 10, weight: .semibold)
    summaryLabel.textColor = NativeLuxuryTheme.secondaryInk
    summaryLabel.numberOfLines = 2

    detailLabel.text = detail
    detailLabel.font = .systemFont(ofSize: 9, weight: .semibold)
    detailLabel.textColor = NativeLuxuryTheme.secondaryInk.withAlphaComponent(0.72)
    detailLabel.numberOfLines = 2

    let stack = UIStackView(arrangedSubviews: [tagLabel, titleLabel, priceLabel, summaryLabel, detailLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 6
    stack.isUserInteractionEnabled = false

    addSubview(stack)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 148),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
    ])

    setSelected(false, emphasized: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setSelected(_ isSelected: Bool, emphasized: Bool) {
    self.isSelected = isSelected
    backgroundColor = isSelected
      ? UIColor(red: 0.99, green: 0.94, blue: 0.82, alpha: 0.98)
      : UIColor.white.withAlphaComponent(0.72)
    layer.borderColor = (isSelected ? NativeLuxuryTheme.accent : NativeLuxuryTheme.hairline).cgColor
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = isSelected ? 0.12 : 0.035
    layer.shadowRadius = isSelected ? 18 : 10
    layer.shadowOffset = CGSize(width: 0, height: isSelected ? 10 : 5)

    tagLabel.backgroundColor = emphasized
      ? UIColor(red: 0.86, green: 0.74, blue: 0.51, alpha: isSelected ? 0.42 : 0.25)
      : UIColor.black.withAlphaComponent(isSelected ? 0.08 : 0.05)
    tagLabel.textColor = emphasized
      ? UIColor(red: 0.34, green: 0.25, blue: 0.12, alpha: 1)
      : NativeLuxuryTheme.secondaryInk
    detailLabel.textColor = emphasized
      ? UIColor(red: 0.25, green: 0.43, blue: 0.32, alpha: 1)
      : NativeLuxuryTheme.secondaryInk.withAlphaComponent(0.72)
  }
}

private final class PaddingLabel: UILabel {
  private let horizontal: CGFloat
  private let vertical: CGFloat

  init(horizontal: CGFloat, vertical: CGFloat) {
    self.horizontal = horizontal
    self.vertical = vertical
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + horizontal * 2, height: size.height + vertical * 2)
  }

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.insetBy(dx: horizontal, dy: vertical))
  }
}
