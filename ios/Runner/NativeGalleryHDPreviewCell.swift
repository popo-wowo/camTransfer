import UIKit

// MARK: - HD Preview Cell

final class NativeGalleryHDPreviewCell: UICollectionViewCell {
  static let reuseIdentifier = "NativeGalleryHDPreviewCell"

  enum LoadState {
    case waiting
    case loading
    case loaded(UIImage)
    case failed
  }

  var onQueueTapped: (() -> Void)?
  var onQueueRawTapped: (() -> Void)?
  var onImageTapped: (() -> Void)?

  private let imageView: UIImageView = {
    let view = UIImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentMode = .scaleAspectFit
    view.clipsToBounds = true
    view.backgroundColor = .black
    return view
  }()

  private let statusLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textColor = UIColor.white.withAlphaComponent(0.72)
    label.textAlignment = .center
    label.isHidden = true
    return label
  }()

  private let spinner: UIActivityIndicatorView = {
    let view = UIActivityIndicatorView(style: .medium)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.color = .white
    view.hidesWhenStopped = true
    return view
  }()

  private let queueButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.attributedTitle = AttributedString("加入", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    config.baseBackgroundColor = NativeLuxuryTheme.accent
    config.baseForegroundColor = .white
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
    config.cornerStyle = .capsule
    button.configuration = config
    return button
  }()

  private let queueRawButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.filled()
    config.attributedTitle = AttributedString("加入 RAW", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    config.baseBackgroundColor = NativeLuxuryTheme.accent.withAlphaComponent(0.72)
    config.baseForegroundColor = .white
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
    config.cornerStyle = .capsule
    button.configuration = config
    button.isHidden = true
    return button
  }()

  private let buttonStack: UIStackView = {
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.spacing = 8
    stack.alignment = .center
    return stack
  }()

  private var heightConstraint: NSLayoutConstraint?

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
    statusLabel.isHidden = true
    statusLabel.text = nil
    spinner.stopAnimating()
    onQueueTapped = nil
    onQueueRawTapped = nil
    onImageTapped = nil
    queueRawButton.isHidden = true
    queueButton.isEnabled = false
    queueRawButton.isEnabled = false
  }

  private func setup() {
    contentView.backgroundColor = .black
    contentView.clipsToBounds = true

    contentView.addSubview(imageView)
    contentView.addSubview(statusLabel)
    contentView.addSubview(spinner)

    buttonStack.addArrangedSubview(queueRawButton)
    buttonStack.addArrangedSubview(queueButton)
    contentView.addSubview(buttonStack)

    queueButton.addTarget(self, action: #selector(queueTapped), for: .touchUpInside)
    queueRawButton.addTarget(self, action: #selector(queueRawTapped), for: .touchUpInside)

    let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
    contentView.addGestureRecognizer(tap)

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      statusLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

      spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

      buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
    ])
  }

  // MARK: - Configuration

  func configure(
    loadState: LoadState,
    hasRawSidecar: Bool,
    allowsDisplayQueueWithoutImage: Bool = false,
    displayQueueState: NativeGalleryHDCardQueueState,
    rawQueueState: NativeGalleryHDCardQueueState
  ) {
    let hasImage: Bool
    switch loadState {
    case .waiting:
      hasImage = false
      imageView.image = nil
      statusLabel.text = allowsDisplayQueueWithoutImage ? "RAW 原片" : "等待预览"
      statusLabel.isHidden = false
      spinner.stopAnimating()
    case .loading:
      hasImage = false
      imageView.image = nil
      statusLabel.isHidden = true
      spinner.startAnimating()
    case .loaded(let image):
      hasImage = true
      imageView.image = image
      statusLabel.isHidden = true
      spinner.stopAnimating()
    case .failed:
      hasImage = false
      imageView.image = nil
      statusLabel.text = "预览失败"
      statusLabel.isHidden = false
      spinner.stopAnimating()
    }

    queueRawButton.isHidden = !hasRawSidecar
    updateQueueButton(
      title: NativeGalleryHDCardActionPolicy.displayTitle(
        hasImage: hasImage,
        allowsQueueWithoutImage: allowsDisplayQueueWithoutImage,
        state: displayQueueState
      ),
      enabled: NativeGalleryHDCardActionPolicy.canQueue(
        hasImage: hasImage,
        allowsQueueWithoutImage: allowsDisplayQueueWithoutImage,
        state: displayQueueState
      ),
      queued: displayQueueState == .queued
    )
    updateRawQueueButton(
      title: NativeGalleryHDCardActionPolicy.rawTitle(hasImage: hasImage, state: rawQueueState),
      enabled: hasRawSidecar && NativeGalleryHDCardActionPolicy.canQueue(hasImage: hasImage, state: rawQueueState),
      queued: rawQueueState == .queued
    )
  }

  func setAspectRatio(width: CGFloat, height: CGFloat) {
    if let existing = heightConstraint {
      existing.isActive = false
    }
    let ratio = NativeGalleryHDPreviewLayoutPolicy.clampedAspectRatio(
      imageWidth: width, imageHeight: height
    )
    let constraint = contentView.heightAnchor.constraint(
      equalTo: contentView.widthAnchor, multiplier: ratio
    )
    constraint.priority = .defaultHigh
    constraint.isActive = true
    heightConstraint = constraint
  }

  private func updateQueueButton(title: String, enabled: Bool, queued: Bool) {
    let alpha: CGFloat = queued ? 0.72 : 1.0
    queueButton.isEnabled = enabled
    queueButton.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    queueButton.configuration?.baseBackgroundColor = NativeLuxuryTheme.accent.withAlphaComponent(enabled ? alpha : 0.35)
  }

  private func updateRawQueueButton(title: String, enabled: Bool, queued: Bool) {
    let alpha: CGFloat = queued ? 0.72 : 1.0
    queueRawButton.isEnabled = enabled
    queueRawButton.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    queueRawButton.configuration?.baseBackgroundColor = NativeLuxuryTheme.accent.withAlphaComponent(enabled ? alpha : 0.35)
  }

  // MARK: - Actions

  @objc private func queueTapped() {
    onQueueTapped?()
  }

  @objc private func queueRawTapped() {
    onQueueRawTapped?()
  }

  @objc private func imageTapped() {
    onImageTapped?()
  }
}

// MARK: - Layout Policy

enum NativeGalleryHDPreviewLayoutPolicy {
  static let interItemSpacing: CGFloat = 2
  static let minAspectRatio: CGFloat = 0.45
  static let maxAspectRatio: CGFloat = 2.4
  static let defaultAspectRatio: CGFloat = 1.0 / 1.5 // 2:3 portrait → height/width

  static func clampedAspectRatio(imageWidth: CGFloat, imageHeight: CGFloat) -> CGFloat {
    guard imageWidth > 0, imageHeight > 0 else { return defaultAspectRatio }
    let ratio = imageHeight / imageWidth
    return min(maxAspectRatio, max(minAspectRatio, ratio))
  }

  static func cellHeight(forWidth width: CGFloat, imageWidth: CGFloat, imageHeight: CGFloat) -> CGFloat {
    let ratio = clampedAspectRatio(imageWidth: imageWidth, imageHeight: imageHeight)
    return floor(width * ratio)
  }
}

// MARK: - Safe Array Subscript

extension Array {
  subscript(hdSafe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
