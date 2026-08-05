import Foundation
import UIKit

final class NativeGalleryModeControl: UIControl {
  private let thumbnailButton = UIButton(type: .system)
  private let highDefinitionButton = UIButton(type: .system)
  private let selectedBackgroundColor = NativeLuxuryTheme.ink

  var selectedSegmentIndex: Int = 0 {
    didSet {
      let normalized = selectedSegmentIndex == 1 ? 1 : 0
      if selectedSegmentIndex != normalized {
        selectedSegmentIndex = normalized
        return
      }
      updateAppearance()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.035)
    layer.cornerRadius = 18
    clipsToBounds = true

    configureButton(
      thumbnailButton,
      title: "缩略",
      image: UIImage(
        systemName: "circle.grid.2x2.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
      )
    )
    configureButton(highDefinitionButton, title: "高清", image: nil)
    thumbnailButton.addTarget(self, action: #selector(thumbnailTapped), for: .touchUpInside)
    highDefinitionButton.addTarget(self, action: #selector(highDefinitionTapped), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [thumbnailButton, highDefinitionButton])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .fill
    stack.distribution = .fillEqually
    stack.spacing = 0
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    updateAppearance()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureButton(_ button: UIButton, title: String, image: UIImage?) {
    button.translatesAutoresizingMaskIntoConstraints = false
    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.image = image
    configuration.imagePlacement = .leading
    configuration.imagePadding = 4
    configuration.cornerStyle = .capsule
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
    configuration.titleLineBreakMode = .byClipping
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = UIFont.systemFont(ofSize: 14, weight: .black)
      return outgoing
    }
    button.configuration = configuration
  }

  private func updateAppearance() {
    applyAppearance(to: thumbnailButton, selected: selectedSegmentIndex == 0)
    applyAppearance(to: highDefinitionButton, selected: selectedSegmentIndex == 1)
  }

  private func applyAppearance(to button: UIButton, selected: Bool) {
    button.configuration?.baseBackgroundColor = selected ? selectedBackgroundColor : .clear
    button.configuration?.baseForegroundColor = selected ? NativeLuxuryTheme.cardBackground : NativeLuxuryTheme.ink
  }

  @objc private func thumbnailTapped() {
    guard selectedSegmentIndex != 0 else { return }
    selectedSegmentIndex = 0
    sendActions(for: .valueChanged)
  }

  @objc private func highDefinitionTapped() {
    guard selectedSegmentIndex != 1 else { return }
    selectedSegmentIndex = 1
    sendActions(for: .valueChanged)
  }
}

final class NativeGalleryViewController: UIViewController, UIGestureRecognizerDelegate {
  private let summary: CameraVendorConnectionSummary
  private let rememberedPeripheralID: UUID?
  private let runtime: CameraSessionRuntime
  private let hdPreviewCache: NativeGalleryHighDefinitionPreviewCache?
  private var galleryRenderState = NativeGalleryRenderState(
    presentation: .unavailable
  )
  private var catalogPresentation: CameraGalleryPresentation {
    galleryRenderState.presentation
  }
  private var gallerySections: [NativeGalleryDaySection] {
    galleryRenderState.sections
  }
  private var selectedHandles: Set<Int> = []
  private var filterState = NativeGalleryFilterState()
  private var currentPreferCompressedDownloads: Bool
  private var visibleThumbnailRefreshWorkItem: DispatchWorkItem?
  private var lastSubmittedThumbnailViewportIdentity: NativeGalleryThumbnailViewportIdentity?
  private var thumbnailRehydrateTasks: [Int: Task<Void, Never>] = [:]
  private let thumbnailImageCache = NSCache<NSString, UIImage>()
  private var thumbnailCacheKeysByHandle: [Int: NSString] = [:]
  private var runtimePresentationObserverID: UUID?
  private var incrementalCatalogObserverID: UUID?
  private var galleryPreviewObserverID: UUID?
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

  // MARK: - HD Preview Mode

  private var browseMode: NativeGalleryBrowseMode = .thumbnail
  private var hdPresentationState: NativeGalleryHDPreviewState?
  private var hdRenderedSectionDisplayHandles: [[Int]] = []
  private var hdPreviewDecodeTasks: [Int: Task<Void, Never>] = [:]
  private let hdPreviewImageCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 16
    cache.totalCostLimit = 96 * 1024 * 1024
    return cache
  }()
  private var hdPreviewImageCacheKeysByHandle: [Int: NSString] = [:]
  private var hdDecodeFailureLoggedKeys: Set<NSString> = []
  private var hdCacheEvictionObserverID: UUID?
  private var hdTransitionTask: Task<Void, Never>?
  private var hdPreviewSnapshotRefreshWorkItem: DispatchWorkItem?
  private var pendingHDPreviewSnapshotCatalogIdentity: CameraGalleryCatalogIdentity?
  private let browseModeControl = NativeGalleryModeControl()

  private let galleryFilterButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var configuration = UIButton.Configuration.plain()
    configuration.title = "筛选"
    configuration.image = UIImage(
      systemName: "slider.horizontal.3",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
    configuration.imagePlacement = .leading
    configuration.imagePadding = 6
    configuration.titleLineBreakMode = .byClipping
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
      return outgoing
    }
    configuration.baseBackgroundColor = .clear
    configuration.baseForegroundColor = NativeLuxuryTheme.ink
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.titleLabel?.numberOfLines = 1
    button.titleLabel?.lineBreakMode = .byClipping
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.titleLabel?.minimumScaleFactor = 0.9
    return button
  }()

  private let galleryToolsButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var configuration = UIButton.Configuration.plain()
    configuration.title = "工具"
    configuration.image = UIImage(
      systemName: "square.stack.3d.up",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
    configuration.imagePlacement = .leading
    configuration.imagePadding = 6
    configuration.titleLineBreakMode = .byClipping
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
      return outgoing
    }
    configuration.baseBackgroundColor = .clear
    configuration.baseForegroundColor = NativeLuxuryTheme.ink
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.titleLabel?.numberOfLines = 1
    button.titleLabel?.lineBreakMode = .byClipping
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.titleLabel?.minimumScaleFactor = 0.9
    button.showsMenuAsPrimaryAction = true
    return button
  }()

  private lazy var galleryToolRow: UIStackView = {
    let stack = UIStackView(arrangedSubviews: [galleryFilterButton, browseModeControl, galleryToolsButton])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .center
    stack.distribution = .equalSpacing
    stack.spacing = 0
    return stack
  }()

  private let hdCollectionView: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = NativeGalleryHDPreviewLayoutPolicy.interItemSpacing
    layout.sectionInset = .zero
    let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
    cv.translatesAutoresizingMaskIntoConstraints = false
    cv.backgroundColor = NativeLuxuryTheme.background
    cv.register(NativeGalleryHDPreviewCell.self, forCellWithReuseIdentifier: NativeGalleryHDPreviewCell.reuseIdentifier)
    cv.register(
      NativeGallerySectionHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: NativeGallerySectionHeaderView.reuseIdentifier
    )
    cv.isHidden = true
    return cv
  }()

  private let hdStatusLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .bold)
    label.textColor = .white
    label.textAlignment = .center
    label.backgroundColor = UIColor.black.withAlphaComponent(0.48)
    label.layer.cornerRadius = 12
    label.clipsToBounds = true
    label.isHidden = true
    return label
  }()

  private lazy var hdTopChipRow: UIStackView = {
    let stack = UIStackView(arrangedSubviews: [hdStatusLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8
    stack.isHidden = true
    return stack
  }()

  private let galleryBackButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "chevron.left",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
    )
    config.baseForegroundColor = NativeLuxuryTheme.ink
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    button.configuration = config
    button.accessibilityLabel = "返回"
    return button
  }()
  private let galleryHeaderTitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = NativeGalleryChromeCopy.title
    label.font = .systemFont(ofSize: 16, weight: .black)
    label.textColor = NativeLuxuryTheme.ink
    label.textAlignment = .center
    return label
  }()
  private let galleryHeaderCountLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 13, weight: .bold)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.textAlignment = .left
    label.isHidden = true
    return label
  }()
  private lazy var galleryHeaderTitleStack: UIStackView = {
    let stack = UIStackView(arrangedSubviews: [galleryHeaderTitleLabel, galleryHeaderCountLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .firstBaseline
    stack.spacing = 8
    return stack
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
  private lazy var galleryStatusRow: UIStackView = {
    let row = UIStackView(arrangedSubviews: [loadingSpinner, copyLabel])
    row.translatesAutoresizingMaskIntoConstraints = false
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    return row
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
  private let downloadScopeChips = NativeChipBarControl()
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
  private var collapsedSections: Set<Int> = []
  private var isFilterPanelExpanded = false
  private var collectionTopToToolRowConstraint: NSLayoutConstraint?
  private var collectionTopToExpandedFilterConstraint: NSLayoutConstraint?
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
    layout.minimumInteritemSpacing = NativeGalleryGridLayoutPolicy.androidGridSpacing
    layout.minimumLineSpacing = NativeGalleryGridLayoutPolicy.androidGridSpacing
    layout.sectionInset = UIEdgeInsets(
      top: 0,
      left: NativeGalleryAndroidParityGridPolicy.horizontalInset,
      bottom: 0,
      right: NativeGalleryAndroidParityGridPolicy.horizontalInset
    )
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

  private let filteredEmptyTitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = NativeGalleryEmptyStatePolicy.title
    label.font = .systemFont(ofSize: 17, weight: .bold)
    label.textColor = NativeLuxuryTheme.ink
    label.textAlignment = .center
    return label
  }()

  private let filteredEmptyMessageLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = NativeGalleryEmptyStatePolicy.message
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.textAlignment = .center
    label.numberOfLines = 0
    return label
  }()

  private let showAllPhotosButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var configuration = UIButton.Configuration.filled()
    configuration.title = NativeGalleryEmptyStatePolicy.actionTitle
    configuration.cornerStyle = .capsule
    configuration.baseBackgroundColor = NativeLuxuryTheme.ink
    configuration.baseForegroundColor = NativeLuxuryTheme.cardBackground
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)
    button.configuration = configuration
    return button
  }()

  private lazy var filteredEmptyContainer: UIStackView = {
    let icon = UIImageView(
      image: UIImage(
        systemName: "line.3.horizontal.decrease.circle",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .light)
      )
    )
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.tintColor = NativeLuxuryTheme.secondaryInk.withAlphaComponent(0.55)
    icon.contentMode = .scaleAspectFit

    let stack = UIStackView(arrangedSubviews: [
      icon,
      filteredEmptyTitleLabel,
      filteredEmptyMessageLabel,
      showAllPhotosButton,
    ])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 10
    stack.isHidden = true
    return stack
  }()

  init(
    summary: CameraVendorConnectionSummary,
    rememberedPeripheralID: UUID? = nil,
    runtime: CameraSessionRuntime
  ) {
    self.summary = summary
    self.rememberedPeripheralID = rememberedPeripheralID
    self.runtime = runtime
    self.hdPreviewCache = runtime.galleryPreviewCache
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
    incrementalCatalogObserverID = runtime.observeIncrementalCatalogUpdates { [weak self] catalog, delta in
      guard let self else { return }
      self.galleryRenderState = self.galleryRenderState.applyingIncremental(
        presentation: catalog,
        delta: delta
      )
      if self.browseMode == .highDefinition,
         let catalogIdentity = self.runtime.galleryCatalogIdentity {
        self.scheduleHDPreviewSnapshotRefresh(
          expectedCatalogIdentity: catalogIdentity
        )
      }
      let handles = delta.changedHandles
      let retryableFailedHandles = handles.filter { handle in
        guard let item = catalog.items.first(where: { $0.handle == handle }),
              let entry = catalog.entries.first(where: { $0.summary.handle == handle }) else {
          return false
        }
        return item.thumbnailData == nil && entry.thumbnail.state == .failed
      }
      self.invalidateThumbnailDecodes(forHandles: delta.orientationChangedHandles)
      if delta.requiresStructuralRefresh {
        self.selectedHandles.formIntersection(catalog.items.map(\.handle))
        self.collapsedSections.removeAll()
        self.refreshStatusText()
        self.collectionView.reloadData()
        self.refreshGalleryEmptyState()
      }
      // Decode new thumbnail data to UIImage cache for changed handles
      var rehydrateRequests: [(handle: Int, data: Data)] = []
      for handle in handles {
        guard let item = catalog.items.first(where: { $0.handle == handle }),
              let data = item.thumbnailData,
              !self.hasCurrentDecodedThumbnailImage(for: handle) else {
          continue
        }
        rehydrateRequests.append((handle: handle, data: data))
      }
      if !rehydrateRequests.isEmpty {
        self.rehydrateCachedThumbnailImages(rehydrateRequests)
      } else {
        self.refreshVisibleCells(forHandles: handles)
      }
      if !retryableFailedHandles.isEmpty {
        self.scheduleVisibleThumbnailRefresh(after: 0.25)
      }
    }
    galleryPreviewObserverID = runtime.observeGalleryPreview { [weak self] publication in
      guard let self else { return }
      switch publication {
      case .state(let catalogIdentity, let state):
        guard catalogIdentity == self.runtime.galleryCatalogIdentity else { return }
        self.applyHDPreviewState(state)
      case .preview(let mediaIdentity, let state):
        guard mediaIdentity.catalog == self.runtime.galleryCatalogIdentity else { return }
        self.applyHDPreviewState(state)
      }
    }
    hdCacheEvictionObserverID = hdPreviewCache?.observeEvictions { [weak self] handle in
      self?.removeDecodedHDPreview(for: handle)
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
    let incrementalObserverID = incrementalCatalogObserverID
    let previewObserverID = galleryPreviewObserverID
    let cacheEvictionObserverID = hdCacheEvictionObserverID
    let previewCache = hdPreviewCache
    let runtime = runtime
    visibleThumbnailRefreshWorkItem?.cancel()
    hdPreviewSnapshotRefreshWorkItem?.cancel()
    let thumbnailRehydrateTasks = thumbnailRehydrateTasks
    let hdPreviewDecodeTasks = hdPreviewDecodeTasks
    let hdTransitionTask = hdTransitionTask
    Task { @MainActor in
      await hdTransitionTask?.value
      thumbnailRehydrateTasks.values.forEach { $0.cancel() }
      hdPreviewDecodeTasks.values.forEach { $0.cancel() }
      if let observerID {
        runtime.removeObserver(observerID)
      }
      if let incrementalObserverID {
        runtime.removeObserver(incrementalObserverID)
      }
      if let previewObserverID {
        runtime.removeObserver(previewObserverID)
      }
      if let cacheEvictionObserverID {
        previewCache?.removeEvictionObserver(cacheEvictionObserverID)
      }
      runtime.send(.galleryPresentationDetached)
    }
  }

  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    cancelHDPreviewDecodeTasks()
    hdPreviewImageCache.removeAllObjects()
    hdPreviewImageCacheKeysByHandle.removeAll()
    hdDecodeFailureLoggedKeys.removeAll()
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
    scheduleVisibleThumbnailRefresh(after: 0)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    visibleThumbnailRefreshWorkItem?.cancel()
    visibleThumbnailRefreshWorkItem = nil
    lastSubmittedThumbnailViewportIdentity = nil
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

    let headerBar = UIView()
    headerBar.translatesAutoresizingMaskIntoConstraints = false
    let headerStack = UIStackView(arrangedSubviews: [headerBar])
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    headerStack.axis = .vertical
    headerStack.spacing = NativeGalleryTopChromePolicy.statusSpacing
    let headerFrame = NativeTopHeaderFrameView()
    headerBar.addSubview(galleryBackButton)
    headerBar.addSubview(galleryHeaderTitleStack)
    headerFrame.addSubview(headerStack)
    view.addSubview(headerFrame)
    view.addSubview(galleryStatusRow)

    view.addSubview(statusLabel)
    view.addSubview(diagnosticsView)

    dateChips.configure(items: [
      .init(id: "all", title: "全部"),
      .init(id: "today", title: "今天"),
      .init(id: "pickDate", title: "选择日期"),
    ], selectedID: "all")
    formatChips.allowsMultipleSelection = true
    formatChips.exclusiveSelectionID = "all"
    formatChips.configure(items: [
      .init(id: "all", title: "全部格式"),
      .init(id: "jpg", title: "JPG"),
      .init(id: "raw", title: "RAW"),
      .init(id: "heif", title: "HEIF"),
      .init(id: "video", title: "视频"),
    ], selectedIDs: ["all"])
    downloadScopeChips.configure(items: [
      .init(id: "all", title: "全部下载状态"),
      .init(id: "notDownloaded", title: "未下载"),
    ], selectedID: "all")
    sortChips.configure(items: [
      .init(id: "newest", title: NativeGalleryChromeCopy.sortOptionTitles[0]),
      .init(id: "oldest", title: NativeGalleryChromeCopy.sortOptionTitles[1]),
      .init(id: "notDownloaded", title: NativeGalleryChromeCopy.sortOptionTitles[2]),
    ], selectedID: "newest")
    dateChips.onSelected = { [weak self] selectedID in self?.dateChipSelected(selectedID) }
    sortChips.onSelected = { [weak self] _ in self?.chipFilterChanged() }
    formatChips.onSelectionChanged = { [weak self] _ in self?.chipFilterChanged() }
    downloadScopeChips.onSelected = { [weak self] _ in self?.chipFilterChanged() }

    filterContentStack.addArrangedSubview(dateChips)
    filterContentStack.addArrangedSubview(formatChips)
    filterContentStack.addArrangedSubview(downloadScopeChips)
    filterContentStack.addArrangedSubview(sortChips)

    view.addSubview(galleryToolRow)
    view.addSubview(filterContentStack)
    view.addSubview(collectionView)
    view.addSubview(hdCollectionView)
    view.addSubview(filteredEmptyContainer)
    view.addSubview(hdTopChipRow)
    view.addSubview(bottomDownloadBar)
    view.addSubview(toastLabel)
    bottomDownloadBar.addSubview(bottomSelectAllButton)
    bottomDownloadBar.addSubview(bottomDownloadLabel)
    bottomDownloadBar.addSubview(bottomCompressionSwitch)
    bottomDownloadBar.addSubview(bottomDownloadButton)

    galleryBackButton.addTarget(self, action: #selector(exitGalleryTapped), for: .touchUpInside)
    galleryFilterButton.addTarget(self, action: #selector(toggleFilterPanel), for: .touchUpInside)
    configureGalleryToolsMenu()
    bottomSelectAllButton.addTarget(self, action: #selector(selectAllTapped), for: .touchUpInside)
    bottomCompressionSwitch.addTarget(self, action: #selector(bottomTransferSizeChanged), for: .valueChanged)
    bottomCompressionSwitch.accessibilityLabel = "下载尺寸"
    bottomCompressionSwitch.isOn = NativeTransferSizeSettingPolicy.switchIsOn(
      preferCompressedDownloads: currentPreferCompressedDownloads
    )
    bottomDownloadButton.addTarget(self, action: #selector(downloadSelectedTapped), for: .touchUpInside)
    showAllPhotosButton.addTarget(self, action: #selector(showAllPhotosTapped), for: .touchUpInside)

    collectionView.dataSource = self
    collectionView.delegate = self

    hdCollectionView.dataSource = self
    hdCollectionView.delegate = self

    browseModeControl.addTarget(self, action: #selector(browseModeChanged(_:)), for: .valueChanged)

    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleGalleryPinch(_:)))
    collectionView.addGestureRecognizer(pinch)
    collectionView.addGestureRecognizer(dragSelectionGesture)

    let collectionTopToToolRowConstraint = collectionView.topAnchor.constraint(
      equalTo: galleryToolRow.bottomAnchor,
      constant: NativeGalleryAndroidParityLayoutPolicy.filterToGridSpacing
    )
    let collectionTopToExpandedFilterConstraint = collectionView.topAnchor.constraint(
      equalTo: filterContentStack.bottomAnchor,
      constant: NativeGalleryAndroidParityLayoutPolicy.filterToGridSpacing
    )
    self.collectionTopToToolRowConstraint = collectionTopToToolRowConstraint
    self.collectionTopToExpandedFilterConstraint = collectionTopToExpandedFilterConstraint

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
      galleryBackButton.widthAnchor.constraint(equalToConstant: 34),
      galleryBackButton.heightAnchor.constraint(equalToConstant: 34),
      galleryHeaderTitleStack.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
      galleryHeaderTitleStack.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
      galleryHeaderTitleStack.leadingAnchor.constraint(greaterThanOrEqualTo: galleryBackButton.trailingAnchor, constant: NativeGalleryTopChromePolicy.actionSpacing),
      galleryHeaderTitleStack.trailingAnchor.constraint(lessThanOrEqualTo: headerBar.trailingAnchor, constant: -8),

      galleryStatusRow.topAnchor.constraint(equalTo: headerFrame.bottomAnchor, constant: 0),
      galleryStatusRow.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor, constant: 2),
      galleryStatusRow.trailingAnchor.constraint(lessThanOrEqualTo: headerFrame.trailingAnchor, constant: -2),

      statusLabel.topAnchor.constraint(equalTo: galleryStatusRow.bottomAnchor, constant: 0),
      statusLabel.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),

      diagnosticsView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 0),
      diagnosticsView.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      diagnosticsView.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),
      diagnosticsView.heightAnchor.constraint(equalToConstant: 0),

      galleryToolRow.topAnchor.constraint(
        equalTo: diagnosticsView.bottomAnchor,
        constant: NativeGalleryAndroidParityLayoutPolicy.filterTopSpacing
      ),
      galleryToolRow.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      galleryToolRow.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),
      galleryToolRow.heightAnchor.constraint(equalToConstant: NativeGalleryAndroidParityChromePolicy.toolRowHeight),
      galleryFilterButton.widthAnchor.constraint(equalToConstant: 74),
      galleryFilterButton.heightAnchor.constraint(equalToConstant: 38),
      browseModeControl.heightAnchor.constraint(equalToConstant: 38),
      galleryToolsButton.widthAnchor.constraint(equalToConstant: 74),
      galleryToolsButton.heightAnchor.constraint(equalToConstant: 38),

      filterContentStack.topAnchor.constraint(equalTo: galleryToolRow.bottomAnchor, constant: 8),
      filterContentStack.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      filterContentStack.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),

      collectionTopToToolRowConstraint,
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      filteredEmptyContainer.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
      filteredEmptyContainer.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor, constant: -36),
      filteredEmptyContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 36),
      filteredEmptyContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -36),

      hdCollectionView.topAnchor.constraint(equalTo: collectionView.topAnchor),
      hdCollectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hdCollectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hdCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      hdTopChipRow.topAnchor.constraint(equalTo: hdCollectionView.topAnchor, constant: 12),
      hdTopChipRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      hdStatusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
      hdStatusLabel.heightAnchor.constraint(equalToConstant: 30),

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
        pinchHintBubble.topAnchor.constraint(equalTo: galleryToolRow.bottomAnchor, constant: 12),
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
    guard NativeGalleryExitPolicy.shouldTerminateCameraCommunication(
      hasActiveCameraCommunication: hasActiveCameraCommunication,
      userConfirmedExit: true
    ) else {
      leaveGallery()
      return
    }
    runtime.exitGalleryAndDisconnect(reason: "user-confirmed-gallery-exit")
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
            canSelectStillItem(item) else {
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
        let endItem = collectionView.indexPathForItem(at: location).flatMap { galleryItem(at: $0) }
        let endHandle = endItem?.handle
        let canSelectEndHandle = endItem.map(canSelectStillItem) ?? false
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
          canSelectStillItem(item) else {
      return
    }
    dragSelectionLastEndHandle = item.handle
    let selectableHandles = selectableStillHandles(from: catalogPresentation.items)
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

  private func dateChipSelected(_ selectedID: String) {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    switch selectedID {
    case "all": filterState.date = .all
    case "today": filterState.date = .today
    case "pickDate":
      presentDatePicker()
      return
    default:
      return
    }
    chipFilterChanged()
  }

  @objc private func chipFilterChanged() {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    let selectedFormats = Set(formatChips.selectedIDs.compactMap(CameraMediaFormat.init(rawValue:)))
    filterState.formats = CameraMediaFormatSelection.normalized(selectedFormats)
    filterState.downloadScope = downloadScopeChips.selectedID == "notDownloaded" ? .notDownloaded : .all

    appendDiagnostic(
      "[OBS] GALLERY_FILTER_UI_APPLIED " +
      "date=\(dateChips.selectedID ?? "nil") " +
      "formats=\(formatChips.selectedIDs.sorted()) " +
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

    submitGalleryIntent()
    refreshFilterSummary()
  }

  private func configureGalleryToolsMenu() {
    galleryToolsButton.menu = UIMenu(children: [
      UIAction(title: "现场分享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
        self?.localProofingTapped()
      },
      UIAction(title: "下载中心", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
        self?.showDownloadListForCurrentTasks()
      },
    ])
  }

  private func submitGalleryIntent() {
    prioritizeGalleryInteraction()
    appendDiagnostic(
      "[OBS] GALLERY_CATALOG_INTENT_SUBMITTED " +
      "date=\(dateChips.selectedID ?? "all") formats=\(formatChips.selectedIDs.sorted())"
    )
    runtime.submitGalleryFilter(
      rule: filterState.rule,
      sort: filterState.sortIntent
    )
  }

  @objc private func showAllPhotosTapped() {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(
      isDownloading: runtime.isDownloading
    ) else { return }
    filterState = NativeGalleryFilterState(sort: filterState.sort)
    applyFilterStateToControls()
    filteredEmptyContainer.isHidden = true
    submitGalleryIntent()
    refreshFilterSummary()
    showToast("已显示全部照片")
  }

  @objc private func toggleFilterPanel() {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    isFilterPanelExpanded.toggle()
    updateFilterPanelLayout(animated: true)
  }

  private func updateFilterPanelLayout(animated: Bool) {
    filterContentStack.isHidden = !isFilterPanelExpanded
    filterChevronLabel.text = isFilterPanelExpanded ? "⌃" : "⌄"
    if isFilterPanelExpanded {
      collectionTopToToolRowConstraint?.isActive = false
      collectionTopToExpandedFilterConstraint?.isActive = true
    } else {
      collectionTopToExpandedFilterConstraint?.isActive = false
      collectionTopToToolRowConstraint?.isActive = true
    }
    let updates = { self.view.layoutIfNeeded() }
    if animated {
      UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut], animations: updates)
    } else {
      updates()
    }
  }

  // MARK: - HD Preview Mode

  @objc private func browseModeChanged(_ sender: NativeGalleryModeControl) {
    let mode: NativeGalleryBrowseMode = sender.selectedSegmentIndex == 1 ? .highDefinition : .thumbnail
    switchBrowseMode(mode)
  }

  private func switchBrowseMode(_ mode: NativeGalleryBrowseMode) {
    guard mode != browseMode else { return }
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      browseModeControl.selectedSegmentIndex = browseMode == .thumbnail ? 0 : 1
      showToast("正在下载，无法切换浏览模式")
      return
    }

    browseMode = mode
    galleryFilterButton.isEnabled = true
    switch mode {
    case .thumbnail:
      hdPreviewSnapshotRefreshWorkItem?.cancel()
      hdPreviewSnapshotRefreshWorkItem = nil
      pendingHDPreviewSnapshotCatalogIdentity = nil
      cancelHDPreviewDecodeTasks()
      hdCollectionView.isHidden = true
      collectionView.isHidden = false
      hdTopChipRow.isHidden = true
      enqueueHDTransition { [weak self] in
        await self?.runtime.switchGalleryPreviewMode(.thumbnail)
        await MainActor.run { [weak self] in
          self?.lastSubmittedThumbnailViewportIdentity = nil
          self?.scheduleVisibleThumbnailRefresh(after: 0)
        }
      }
      view.backgroundColor = NativeLuxuryTheme.background
    case .highDefinition:
      visibleThumbnailRefreshWorkItem?.cancel()
      visibleThumbnailRefreshWorkItem = nil

      collectionView.isHidden = true
      hdCollectionView.isHidden = false
      view.backgroundColor = NativeLuxuryTheme.background
      startHDPreviewLoading()
    }
    refreshGalleryEmptyState()
    refreshBottomDownloadBar()
  }

  private func startHDPreviewLoading() {
    guard let catalogIdentity = runtime.galleryCatalogIdentity else { return }
    let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(
      sections: gallerySections
    )
    hdRenderedSectionDisplayHandles = []
    applyHDPreviewState(NativeGalleryHDPreviewState(
      snapshot: snapshot,
      loadedHandles: runtime.galleryHDPreviewLoadedHandles(for: catalogIdentity)
    ))
    hdCollectionView.layoutIfNeeded()
    let visibleHandles = hdVisibleHandles()
    enqueueHDTransition { [weak self] in
      guard let self else { return }
      await self.runtime.switchGalleryPreviewMode(
        .highDefinition,
        snapshot: snapshot,
        visibleHandles: visibleHandles
      )
    }
  }

  private func enqueueHDTransition(_ operation: @escaping @MainActor () async -> Void) {
    let previous = hdTransitionTask
    hdTransitionTask = Task { @MainActor in
      await previous?.value
      await operation()
    }
  }

  private func scheduleHDPreviewSnapshotRefresh(
    expectedCatalogIdentity: CameraGalleryCatalogIdentity
  ) {
    pendingHDPreviewSnapshotCatalogIdentity = expectedCatalogIdentity
    guard hdPreviewSnapshotRefreshWorkItem == nil else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.hdPreviewSnapshotRefreshWorkItem = nil
      guard self.browseMode == .highDefinition,
            let catalogIdentity = self.pendingHDPreviewSnapshotCatalogIdentity else {
        self.pendingHDPreviewSnapshotCatalogIdentity = nil
        return
      }
      self.pendingHDPreviewSnapshotCatalogIdentity = nil
      let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(
        sections: self.gallerySections
      )
      self.enqueueHDTransition { [weak self] in
        guard let self else { return }
        await self.runtime.updateGalleryHDPreviewSnapshot(
          snapshot,
          expectedCatalogIdentity: catalogIdentity
        )
      }
    }
    hdPreviewSnapshotRefreshWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
  }

  private func hdVisibleHandles() -> [Int] {
    guard let snapshot = hdPresentationState?.snapshot else { return [] }
    return hdCollectionView.indexPathsForVisibleItems
      .sorted {
        $0.section == $1.section ? $0.item < $1.item : $0.section < $1.section
      }
      .compactMap { snapshot.item(at: $0)?.displayItem.handle }
  }

  private func applyHDPreviewState(_ state: NativeGalleryHDPreviewState?) {
    guard browseMode == .highDefinition else { return }
    hdPresentationState = state
    if state == nil {
      cancelHDPreviewDecodeTasks()
    }
    let sectionHandles = state?.snapshot.sectionDisplayHandles ?? []
    if sectionHandles != hdRenderedSectionDisplayHandles {
      hdRenderedSectionDisplayHandles = sectionHandles
      hdCollectionView.reloadData()
    } else {
      for indexPath in hdCollectionView.indexPathsForVisibleItems {
        guard let item = state?.snapshot.item(at: indexPath),
              let cell = hdCollectionView.cellForItem(at: indexPath) as? NativeGalleryHDPreviewCell else {
          continue
        }
        configureHDCell(cell, previewItem: item)
      }
    }
    updateHDStatusLabel(state)
    scheduleHDPreviewDecodes(for: state)
  }

  private func refreshHDCell(for handle: Int) {
    guard browseMode == .highDefinition else { return }
    guard let snapshot = hdPresentationState?.snapshot,
          let indexPath = snapshot.indexPath(forDisplayHandle: handle),
          let item = snapshot.item(at: indexPath) else {
      return
    }
    if let cell = hdCollectionView.cellForItem(at: indexPath) as? NativeGalleryHDPreviewCell {
      configureHDCell(cell, previewItem: item)
    }
  }

  private func updateHDStatusLabel(_ state: NativeGalleryHDPreviewState?) {
    guard let state, state.totalCount > 0 else {
      hdTopChipRow.isHidden = true
      return
    }
    hdStatusLabel.text = "  \(state.loadedCount)/\(state.totalCount)  "
    hdStatusLabel.isHidden = false
    hdTopChipRow.isHidden = false
  }

  private func hdLoadState(for item: CameraVendorGalleryItem) -> NativeGalleryHDPreviewCell.LoadState {
    let handle = item.handle
    if let image = cachedHDPreviewImage(for: handle) {
      return .loaded(image)
    }
    if let key = decodedHDPreviewCacheKey(for: handle, target: verticalHDDecodeTarget()) {
      return hdDecodeFailureLoggedKeys.contains(key.storageKey) ? .failed : .loading
    }
    // Non-previewable items (RAW, video) can't be HD-loaded
    if !NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(item: item, hasPreviewImage: false) {
      return .waiting
    }
    if hdPresentationState?.loadState.failedHandles.contains(handle) == true { return .failed }
    if hdPresentationState?.loadState.loadingHandles.contains(handle) == true { return .loading }
    return .waiting
  }

  private func verticalHDDecodeTarget() -> NativeGalleryHDDecodeTarget {
    .verticalCard(maxPixelSize: NativeGalleryHDDecodeSizingPolicy.verticalCardMaxPixelSize(
      renderedWidth: max(1, hdCollectionView.bounds.width),
      displayScale: view.window?.screen.scale ?? UIScreen.main.scale
    ))
  }

  private func decodedHDPreviewCacheKey(
    for handle: Int,
    target: NativeGalleryHDDecodeTarget
  ) -> NativeGalleryDecodedHDPreviewCacheKey? {
    guard let catalogIdentity = runtime.galleryCatalogIdentity,
          let preview = runtime.peekCachedGalleryHDPreview(for: handle) else { return nil }
    return NativeGalleryDecodedHDPreviewCacheKey(
      sessionEpoch: catalogIdentity.sessionEpoch,
      handle: handle,
      orientation: preview.objectOrientation,
      target: target
    )
  }

  private func cachedHDPreviewImage(for handle: Int) -> UIImage? {
    guard let expectedKey = decodedHDPreviewCacheKey(
      for: handle,
      target: verticalHDDecodeTarget()
    )?.storageKey,
          hdPreviewImageCacheKeysByHandle[handle] == expectedKey else { return nil }
    return hdPreviewImageCache.object(forKey: expectedKey)
  }

  private func scheduleHDPreviewDecodes(for state: NativeGalleryHDPreviewState?) {
    guard let state else { return }
    let visibleHandles = hdVisibleHandles()
    let candidates = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
      orderedHandles: state.snapshot.loadableDisplayHandles,
      visibleHandles: visibleHandles.isEmpty
        ? Array(state.snapshot.loadableDisplayHandles.prefix(3))
        : visibleHandles,
      limit: 8
    )
    for handle in candidates where state.loadedHandles.contains(handle) {
      scheduleHDPreviewDecode(for: handle)
    }
  }

  private func scheduleHDPreviewDecode(for handle: Int) {
    guard browseMode == .highDefinition,
          hdPreviewDecodeTasks[handle] == nil,
          cachedHDPreviewImage(for: handle) == nil,
          let catalogIdentity = runtime.galleryCatalogIdentity,
          let preview = runtime.peekCachedGalleryHDPreview(for: handle) else { return }
    let target = verticalHDDecodeTarget()
    let cacheKey = NativeGalleryDecodedHDPreviewCacheKey(
      sessionEpoch: catalogIdentity.sessionEpoch,
      handle: handle,
      orientation: preview.objectOrientation,
      target: target
    )
    guard !hdDecodeFailureLoggedKeys.contains(cacheKey.storageKey) else { return }
    hdPreviewDecodeTasks[handle] = Task { @MainActor [weak self] in
      let image = await NativeGalleryHDTargetDecoder.decodedImage(
        from: preview.data,
        objectOrientation: preview.objectOrientation,
        target: target,
        diagnosticHandle: handle
      )
      guard let self else { return }
      self.hdPreviewDecodeTasks.removeValue(forKey: handle)
      guard !Task.isCancelled,
            self.browseMode == .highDefinition,
            self.runtime.galleryCatalogIdentity == catalogIdentity,
            self.decodedHDPreviewCacheKey(for: handle, target: target) == cacheKey else { return }
      guard let image else {
        if self.hdDecodeFailureLoggedKeys.insert(cacheKey.storageKey).inserted {
          CameraVendorFileLogger.log(
            "[OBS] HD_PREVIEW_DECODE_FAILED handle=0x\(String(format: "%08X", handle)) " +
            "bytes=\(preview.data.count) orientation=\(preview.objectOrientation.map(String.init) ?? "unknown")"
          )
        }
        self.refreshHDCell(for: handle)
        return
      }
      self.hdDecodeFailureLoggedKeys.remove(cacheKey.storageKey)
      let previousKey = self.hdPreviewImageCacheKeysByHandle[handle]
      let decodedCost = max(1, Int(image.size.width * image.size.height * 4))
      self.hdPreviewImageCache.setObject(image, forKey: cacheKey.storageKey, cost: decodedCost)
      self.hdPreviewImageCacheKeysByHandle[handle] = cacheKey.storageKey
      if let previousKey, previousKey != cacheKey.storageKey {
        self.hdPreviewImageCache.removeObject(forKey: previousKey)
      }
      self.refreshHDCellAfterDecode(handle: handle, image: image)
    }
  }

  private func refreshHDCellAfterDecode(handle: Int, image: UIImage) {
    guard let snapshot = hdPresentationState?.snapshot,
          let indexPath = snapshot.indexPath(forDisplayHandle: handle),
          hdCollectionView.indexPathsForVisibleItems.contains(indexPath) else { return }
    let decodedAspectRatio = image.size.height > 0 ? image.size.width / image.size.height : 1.5
    if abs(decodedAspectRatio - 1.5) > 0.01 {
      UIView.performWithoutAnimation {
        hdCollectionView.performBatchUpdates {
          hdCollectionView.reloadItems(at: [indexPath])
        }
      }
    } else {
      refreshHDCell(for: handle)
    }
  }

  private func cancelHDPreviewDecodeTasks() {
    hdPreviewDecodeTasks.values.forEach { $0.cancel() }
    hdPreviewDecodeTasks.removeAll()
  }

  private func removeDecodedHDPreview(for handle: Int) {
    hdPreviewDecodeTasks.removeValue(forKey: handle)?.cancel()
    if let key = hdPreviewImageCacheKeysByHandle.removeValue(forKey: handle) {
      hdPreviewImageCache.removeObject(forKey: key)
      hdDecodeFailureLoggedKeys.remove(key)
    }
  }

  private func retryHDPreviewDecode(for handle: Int) {
    if let key = decodedHDPreviewCacheKey(for: handle, target: verticalHDDecodeTarget()) {
      hdDecodeFailureLoggedKeys.remove(key.storageKey)
    }
    runtime.retryGalleryHDPreview(handle: handle)
  }

  private func configureHDCell(
    _ cell: NativeGalleryHDPreviewCell,
    previewItem: NativeGalleryHDPreviewItem
  ) {
    let item = previewItem.displayItem
    let handle = item.handle
    let state = hdLoadState(for: item)
    let allowsDisplayQueueWithoutImage = NativeGalleryHDDownloadRequestPolicy.isRaw(item)
    let hasLoadedPreview: Bool
    if case .loaded = state {
      hasLoadedPreview = true
    } else {
      hasLoadedPreview = false
    }
    let isQueued = selectedHandles.contains(handle)
    let hasRaw = previewItem.rawSidecar != nil
    let isRawQueued = previewItem.rawSidecar.map { selectedHandles.contains($0.handle) } ?? false
    let displayQueueState = hdCardQueueState(
      handle: handle,
      isLocallyQueued: isQueued,
      previewLoadState: state
    )
    let rawQueueState = previewItem.rawSidecar.map {
      hdCardQueueState(
        handle: $0.handle,
        isLocallyQueued: isRawQueued,
        previewLoadState: state
      )
    } ?? .idle

    cell.configure(
      loadState: state,
      hasRawSidecar: hasRaw,
      allowsDisplayQueueWithoutImage: allowsDisplayQueueWithoutImage,
      displayQueueState: displayQueueState,
      rawQueueState: rawQueueState
    )

    // Use image size from loaded preview, else default 3:2 landscape
    if case .loaded(let image) = state {
      cell.setAspectRatio(width: image.size.width, height: image.size.height)
    } else {
      cell.setAspectRatio(width: 3, height: 2)
    }

    cell.onQueueTapped = { [weak self] in
      guard let self else { return }
      if case .failed = state {
        self.retryHDPreviewDecode(for: handle)
        return
      }
      guard (hasLoadedPreview || allowsDisplayQueueWithoutImage),
            NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: self.runtime.isDownloading),
            NativeGalleryDownloadSelectionPolicy.canSelect(
              downloadState: self.runtime.downloadState(for: handle)
            ) else { return }
      self.toggleSelection(for: item)
      self.refreshHDCell(for: handle)
    }
    cell.onQueueRawTapped = { [weak self] in
      guard let self else { return }
      if case .failed = state {
        self.retryHDPreviewDecode(for: handle)
        return
      }
      guard let rawSidecar = previewItem.rawSidecar,
            case .loaded = state,
            NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: self.runtime.isDownloading),
            NativeGalleryDownloadSelectionPolicy.canSelect(
              downloadState: self.runtime.downloadState(for: rawSidecar.handle)
            ) else {
        return
      }
      self.toggleSelection(for: rawSidecar)
      self.refreshHDCell(for: handle)
    }
    cell.onImageTapped = { [weak self] in
      guard let self else { return }
      if case .loaded = state {
        if let flatIndex = self.catalogPresentation.items.firstIndex(where: { $0.handle == handle }) {
          self.presentPreview(startingAt: flatIndex)
        }
      }
    }
  }

  private func hdCardQueueState(
    handle: Int,
    isLocallyQueued: Bool,
    previewLoadState: NativeGalleryHDPreviewCell.LoadState
  ) -> NativeGalleryHDCardQueueState {
    if case .failed = previewLoadState { return .failed }
    switch runtime.downloadState(for: handle) {
    case .idle:
      return isLocallyQueued ? .queued : .idle
    case .queued:
      return .queued
    case .downloading:
      return .downloading
    case .saved:
      return .saved
    case .failed:
      return .failed
    }
  }

  @objc private func localProofingTapped() {
    presentNotice(title: "现场分享", message: "iOS 现场分享服务还没有接入，下一步会按 Android localproofing 模块移植本地分享和二维码。")
  }

  private func presentDatePicker() {
    let now = Date()
    let initialDate: Date
    if case let .specificDay(day) = filterState.date {
      initialDate = day
    } else {
      initialDate = now
    }
    let picker = NativeDatePickerController(
      initialDate: initialDate,
      onCancel: { [weak self] in
        self?.dismiss(animated: true)
        self?.dateChips.setSelected(self?.dateFilterChipID() ?? "all")
      },
      onConfirm: { [weak self] date in
        guard let self else { return }
        self.dismiss(animated: true)
        guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: self.runtime.isDownloading) else {
          return
        }
        self.filterState.date = .specificDay(date)
        self.dateChips.refreshTitle(forID: "pickDate", title: self.dateChipTitle(for: date))
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
    case .specificDay: return "pickDate"
    }
  }

  private func dateChipTitle(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日"
    return formatter.string(from: date)
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

  private func selectableStillHandles(
    from items: [CameraVendorGalleryItem]
  ) -> Set<Int> {
    let supportedHandles = items.compactMap { item in
      CameraVendorGalleryDownloadPolicy.isSupportedStill(item) ? item.handle : nil
    }
    return Set(runtime.downloadableHandles(from: supportedHandles))
  }

  private func canSelectStillItem(_ item: CameraVendorGalleryItem) -> Bool {
    CameraVendorGalleryDownloadPolicy.isSupportedStill(item) &&
      NativeGalleryDownloadSelectionPolicy.canSelect(
        downloadState: runtime.downloadState(for: item.handle)
      )
  }

  @objc private func selectAllTapped() {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    let selectableHandles = selectableStillHandles(from: catalogPresentation.items)
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
  private func applyCatalogPresentation(_ presentation: CameraGalleryPresentation) {
    let previousPresentation = catalogPresentation
    let previousItems = catalogPresentation.items
    guard let nextRenderState = galleryRenderState.replacingPresentation(presentation) else {
      refreshStatusText()
      refreshGalleryEmptyState()
      return
    }
    let isCatalogReplacement = previousPresentation.generation != presentation.generation ||
      previousPresentation.intent != presentation.intent
    galleryRenderState = nextRenderState
    let sort: NativeGallerySortMode
    switch presentation.intent.sort {
    case .newest: sort = .newest
    case .oldest: sort = .oldest
    case .notDownloaded: sort = .notDownloaded
    }
    filterState = NativeGalleryFilterState(
      formats: presentation.intent.rule.formats,
      date: presentation.intent.rule.date,
      downloadScope: presentation.intent.rule.downloadScope,
      sort: sort
    )
    applyFilterStateToControls()
    selectedHandles.formIntersection(presentation.items.map(\.handle))
    let handlesNeedingReDecode = NativeGalleryOrientationRefreshPolicy.handlesNeedingThumbnailReDecode(
      existingItems: previousItems,
      resolvedItems: presentation.items
    )
    invalidateThumbnailDecodes(forHandles: handlesNeedingReDecode)
    collapsedSections.removeAll()
    refreshStatusText()
    collectionView.reloadData()
    if isCatalogReplacement {
      visibleThumbnailRefreshWorkItem?.cancel()
      visibleThumbnailRefreshWorkItem = nil
      lastSubmittedThumbnailViewportIdentity = nil
      collectionView.layoutIfNeeded()
      collectionView.setContentOffset(
        CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
        animated: false
      )
      collectionView.layoutIfNeeded()
      if browseMode == .highDefinition {
        hdCollectionView.layoutIfNeeded()
        hdCollectionView.setContentOffset(
          CGPoint(x: 0, y: -hdCollectionView.adjustedContentInset.top),
          animated: false
        )
        hdCollectionView.layoutIfNeeded()
      }
    }
    refreshGalleryEmptyState()

    if case .ready = presentation.state {
      if browseMode == .highDefinition {
        startHDPreviewLoading()
      } else {
        scheduleVisibleThumbnailRefresh(after: 0)
      }
      if !presentation.items.isEmpty {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
          self?.showPinchHintIfNeeded()
        }
      }
    }
  }

  private func applyFilterStateToControls() {
    switch filterState.date {
    case .all:
      dateChips.setSelected("all")
    case .today:
      dateChips.setSelected("today")
    case .specificDay:
      dateChips.setSelected("pickDate")
    }
    switch filterState.formats {
    case .all:
      formatChips.setSelectedIDs(["all"])
    case .selected(let formats):
      formatChips.setSelectedIDs(Set(formats.map(\.rawValue)))
    }
    downloadScopeChips.setSelected(
      filterState.downloadScope == .notDownloaded ? "notDownloaded" : "all"
    )
    switch filterState.sort {
    case .newest:
      sortChips.setSelected("newest")
    case .oldest:
      sortChips.setSelected("oldest")
    case .notDownloaded:
      sortChips.setSelected("notDownloaded")
    }
  }

  private func invalidateThumbnailDecodes(forHandles handles: Set<Int>) {
    for handle in handles {
      thumbnailRehydrateTasks.removeValue(forKey: handle)?.cancel()
      CameraVendorFileLogger.log("[ORIENTATION_THUMBNAIL] stale handle=\(handle) reason=late-object-info")
    }
  }

  private func decodedThumbnailCacheKey(for handle: Int) -> NativeGalleryDecodedThumbnailCacheKey? {
    guard let sessionEpoch = runtime.galleryCatalogIdentity?.sessionEpoch else { return nil }
    let orientation = catalogPresentation.items.first(where: { $0.handle == handle })?.orientation
    return NativeGalleryDecodedThumbnailCacheKey(
      sessionEpoch: sessionEpoch,
      handle: handle,
      orientation: orientation
    )
  }

  private func cachedThumbnailImage(for handle: Int) -> UIImage? {
    guard let storedKey = thumbnailCacheKeysByHandle[handle] else { return nil }
    return thumbnailImageCache.object(forKey: storedKey)
  }

  private func hasCurrentDecodedThumbnailImage(for handle: Int) -> Bool {
    guard let expectedKey = decodedThumbnailCacheKey(for: handle)?.storageKey,
          thumbnailCacheKeysByHandle[handle] == expectedKey else { return false }
    return thumbnailImageCache.object(forKey: expectedKey) != nil
  }

  private func openDownloadCenter(for handles: [Int]) {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      showDownloadListForCurrentTasks()
      return
    }
    let candidateRequests: [CameraSessionQueuedDownload]
    if browseMode == .highDefinition, let snapshot = hdPresentationState?.snapshot {
      let selected = Set(handles)
      candidateRequests = NativeGalleryHDDownloadRequestPolicy.requests(
        displayItems: snapshot.items
          .map(\.displayItem)
          .filter { selected.contains($0.handle) },
        rawHandles: snapshot.items
          .compactMap(\.rawSidecar?.handle)
          .filter { selected.contains($0) },
        preferCompressedDisplay: currentPreferCompressedDownloads
      )
    } else {
      candidateRequests = handles.compactMap { handle in
        UInt32(exactly: handle).map {
          CameraSessionQueuedDownload(handle: $0, mode: currentTransferDownloadMode)
        }
      }
    }
    let downloadableHandles = Set(
      candidateRequests.map { Int($0.handle) }.filter {
        switch runtime.downloadState(for: $0) {
        case .idle, .failed, .saved:
          return true
        case .queued, .downloading:
          return false
        }
      }
    )
    let requestsToDownload = candidateRequests.filter {
      downloadableHandles.contains(Int($0.handle))
    }
    let handlesToDownload = requestsToDownload.map { Int($0.handle) }
    guard !handlesToDownload.isEmpty else {
      showToast("选中的照片正在下载中")
      return
    }
    let itemsToDownload = catalogPresentation.items.filter { handlesToDownload.contains($0.handle) }
    let previousSelection = selectedHandles
    let startDownload = { [weak self] in
      guard let self else { return }
      guard self.runtime.submitDownload(CameraDownloadSubmission(
        id: UUID(),
        requests: requestsToDownload,
        origin: .gallery,
        completionPolicy: .returnToGallery
      )) else {
        self.showToast("下载未启动，请重新进入相册后重试")
        return
      }
      self.selectedHandles = NativeGalleryPostDownloadSelectionPolicy.selectionAfterStartingDownload(
        selectedHandles: self.selectedHandles
      )
      self.finishOpeningDownloadCenter(
        handlesToDownload: handlesToDownload,
        itemsToDownload: itemsToDownload,
        previousSelection: previousSelection
      )
    }
    startDownload()
  }

  private func finishOpeningDownloadCenter(
    handlesToDownload: [Int],
    itemsToDownload: [CameraVendorGalleryItem],
    previousSelection: Set<Int>
  ) {
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
      galleryHeaderCountLabel.isHidden = true
      galleryStatusRow.isHidden = false
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
      galleryHeaderCountLabel.isHidden = true
      galleryStatusRow.isHidden = false
      copyLabel.text = "加载失败：\(errorMessage)"
      copyLabel.textColor = NativeLuxuryTheme.secondaryInk
      refreshFilterSummary()
      refreshBottomDownloadBar()
      return
    }

    let total = catalogPresentation.items.count
    galleryHeaderCountLabel.text = total > 0 ? "\(total) 张" : nil
    galleryHeaderCountLabel.isHidden = total == 0
    galleryStatusRow.isHidden = true
    copyLabel.text = ""
    copyLabel.textColor = NativeLuxuryTheme.secondaryInk
    refreshFilterSummary()
    refreshBottomDownloadBar()
  }

  private func refreshGalleryEmptyState() {
    filteredEmptyContainer.isHidden = !NativeGalleryEmptyStatePolicy.shouldShow(
      itemCount: catalogPresentation.items.count,
      isLoading: catalogPresentation.isLoading,
      errorMessage: catalogPresentation.errorMessage,
      filterState: filterState
    )
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
    }
    let formatText: String
    switch filterState.formats {
    case .all:
      formatText = "全部格式"
    case .selected(let formats):
      formatText = CameraMediaFormat.allCases.filter(formats.contains).map(\.displayTitle).joined(separator: "+")
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
    let downloadScopeText = filterState.downloadScope == .notDownloaded ? "未下载" : "全部下载状态"
    filterSummaryLabel.text = "\(dateText) · \(formatText) · \(downloadScopeText) · \(sortText)"
    galleryFilterButton.accessibilityValue = filterSummaryLabel.text
  }

  private func refreshBottomDownloadBar() {
    if browseMode == .highDefinition, let snapshot = hdPresentationState?.snapshot {
      let presentation = NativeGalleryHDBottomBarPolicy.presentation(
        snapshotDownloadHandles: Array(snapshot.allDownloadHandles),
        queuedHandles: selectedHandles
      )
      bottomDownloadBar.isHidden = false
      bottomSelectAllButton.isHidden = true
      bottomDownloadLabel.text = "\(presentation.title) · 共 \(presentation.totalCount) 张"
      bottomDownloadButton.isEnabled = presentation.queuedCount > 0 && !runtime.isDownloading
      bottomCompressionSwitch.isEnabled = !runtime.isDownloading
      return
    }
    let summary = NativeGallerySelectionSummaryPolicy.summary(
      items: catalogPresentation.items,
      state: selectionProjectionState
    )
    bottomDownloadBar.isHidden = false
    bottomSelectAllButton.isHidden = false
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
    galleryToolsButton.isEnabled = true
    let selectableCount = NativeGallerySelectionSummaryPolicy.summary(
      items: catalogPresentation.items,
      state: selectionProjectionState
    )
      .totalSelectableCount
    selectAllButtonItem?.isEnabled = NativeGalleryDownloadBarPolicy.canToggleSelectAll(
      totalSelectableCount: selectableCount,
      isDownloading: runtime.isDownloading
    )
  }

  private func galleryEntryViewState(for handle: Int) -> CameraGalleryEntryViewState? {
    catalogPresentation.entries.first { $0.summary.handle == handle }
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
    let entriesByHandle = Dictionary(uniqueKeysWithValues: catalogPresentation.entries.map { ($0.summary.handle, $0) })
    let retryableFailedHandles = requestedHandles.filter { handle in
      itemsByHandle[handle]?.thumbnailData == nil &&
        entriesByHandle[handle]?.thumbnail.state == .failed
    }
    let nextViewportIdentity = runtime.galleryCatalogIdentity.map {
      NativeGalleryThumbnailViewportIdentity(
        catalogIdentity: $0,
        orderedHandles: requestedHandles,
        retryableFailedHandles: retryableFailedHandles
      )
    }
    var handles: [Int] = []
    var rehydrateRequests: [(handle: Int, data: Data)] = []
    for handle in requestedHandles {
      guard let item = itemsByHandle[handle] else { continue }
      switch NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: item.thumbnailData,
        cachedImage: hasCurrentDecodedThumbnailImage(for: handle)
          ? cachedThumbnailImage(for: handle)
          : nil,
        hasFailedThumbnailRequest: entriesByHandle[handle]?.thumbnail.state == .failed
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
    guard let nextViewportIdentity,
          NativeGalleryThumbnailViewportSubmissionPolicy.shouldSubmit(
            previous: lastSubmittedThumbnailViewportIdentity,
            next: nextViewportIdentity
          ) else { return }
    lastSubmittedThumbnailViewportIdentity = nextViewportIdentity
    CameraVendorFileLogger.log(
      "[OBS] THUMBNAIL_VIEWPORT_SUBMIT generation=\(nextViewportIdentity.catalogIdentity.generation.rawValue) " +
      "visible=\(visibleHandles.count) requested=\(requestedHandles.count) " +
      "camera=\(handles.count) rehydrate=\(rehydrateRequests.count) " +
      "retryableFailed=\(retryableFailedHandles.count)"
    )
    runtime.requestVisibleGalleryThumbnails(
      handles: handles,
      expectedCatalogIdentity: nextViewportIdentity.catalogIdentity
    )
  }

  private func rehydrateCachedThumbnailImages(_ requests: [(handle: Int, data: Data)]) {
    for request in requests where thumbnailRehydrateTasks[request.handle] == nil {
      let handle = request.handle
      let data = request.data
      thumbnailRehydrateTasks[handle] = Task { [weak self] in
        let decodeContext: (orientation: Int?, cacheKey: NativeGalleryDecodedThumbnailCacheKey)? = await MainActor.run { [weak self] in
          guard let self,
                let cacheKey = self.decodedThumbnailCacheKey(for: handle) else { return nil }
          let orientation = self.catalogPresentation.items.first(where: { $0.handle == handle })?.orientation
          return (orientation, cacheKey)
        }
        guard let decodeContext else { return }
        let decodedImage = await NativeGalleryThumbnailDecodePipeline.decodedImage(
          from: data,
          objectOrientation: decodeContext.orientation,
          diagnosticHandle: handle
        )
        await MainActor.run { [weak self] in
          guard let self else { return }
          self.thumbnailRehydrateTasks.removeValue(forKey: handle)
          guard !Task.isCancelled,
                let decodedImage,
                self.decodedThumbnailCacheKey(for: handle) == decodeContext.cacheKey else { return }
          let storageKey = decodeContext.cacheKey.storageKey
          let previousStorageKey = self.thumbnailCacheKeysByHandle[handle]
          self.thumbnailImageCache.setObject(decodedImage, forKey: storageKey)
          self.thumbnailCacheKeysByHandle[handle] = storageKey
          if let previousStorageKey, previousStorageKey != storageKey {
            self.thumbnailImageCache.removeObject(forKey: previousStorageKey)
          }
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
    visibleThumbnailRefreshWorkItem?.cancel()
    visibleThumbnailRefreshWorkItem = nil
  }

  private func pauseVisibleThumbnailLoadingForBackground() {
    guard NativeGalleryPresentationLifecyclePolicy.shouldPauseThumbnailRequests(
      applicationState: UIApplication.shared.applicationState,
      hasActiveCameraCommunication: hasActiveCameraCommunication
    ) else {
      return
    }
    visibleThumbnailRefreshWorkItem?.cancel()
    visibleThumbnailRefreshWorkItem = nil
    appendDiagnostic("[后台] 已暂停缩略图请求，保留相机连接")
  }

  private func scheduleVisibleThumbnailRefresh(after delay: TimeInterval = 0.15) {
    // Don't load thumbnails during HD preview mode — PTP transport is exclusive
    guard browseMode == .thumbnail else { return }
    guard NativeGalleryThumbnailLoadingPolicy.shouldStartCatalogWork(
      runtimeCanAcceptCatalogCommands: runtime.canAcceptCatalogCommands,
      isDownloading: runtime.isDownloading
    ) else {
      return
    }
    guard visibleThumbnailRefreshWorkItem == nil else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.visibleThumbnailRefreshWorkItem = nil
      self.loadVisibleThumbnails()
    }
    visibleThumbnailRefreshWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func toggleSelection(for item: CameraVendorGalleryItem) {
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      return
    }
    guard selectedHandles.contains(item.handle) || canSelectStillItem(item) else { return }
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
    let selectableHandles = selectableStillHandles(from: gallerySections[sectionIndex].items)
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

  private func toggleSectionCollapse(at sectionIndex: Int) {
    guard gallerySections.indices.contains(sectionIndex) else { return }
    if collapsedSections.contains(sectionIndex) {
      collapsedSections.remove(sectionIndex)
    } else {
      collapsedSections.insert(sectionIndex)
    }
    UIView.performWithoutAnimation {
      let activeCollectionView = browseMode == .highDefinition ? hdCollectionView : collectionView
      activeCollectionView.reloadSections(IndexSet(integer: sectionIndex))
    }
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
      thumbnailImage: cachedThumbnailImage(for: item.handle)
    )
    cell.onSelectionTapped = { [weak self, weak cell] in
      guard let self,
            let cell,
            let indexPath = self.collectionView.indexPath(for: cell),
            let currentItem = self.galleryItem(at: indexPath) else {
        return
      }
      guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: self.runtime.isDownloading) else {
        return
      }
      guard self.canSelectStillItem(currentItem) else { return }
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
    let selectableHandles = selectableStillHandles(from: section.items)
    let allSelected = !selectableHandles.isEmpty && selectableHandles.isSubset(of: selectedHandles)
    let isCollapsed = collapsedSections.contains(indexPath.section)
    header.configure(
      dateTitle: NativeGallerySectionPolicy.dateTitle(for: section.day),
      countTitle: "\(section.items.count) 张",
      selectionTitle: allSelected ? "取消" : "全选",
      sortTitle: isCollapsed ? "▲" : "▼"
    )
    header.onSelectionTapped = { [weak self] in
      self?.toggleSelection(forSectionAt: indexPath.section)
    }
    header.onSortTapped = { [weak self] in
      self?.toggleSectionCollapse(at: indexPath.section)
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
    guard catalogPresentation.items.indices.contains(index) else { return }
    let selectedItem = catalogPresentation.items[index]
    guard CameraVendorGalleryDownloadPolicy.isSupportedStill(selectedItem) else { return }
    guard NativeGalleryNavigationPolicy.canOpenPreview(isDownloading: runtime.isDownloading) else {
      showToast("正在下载，请先保持在照片筛选页面")
      return
    }
    switch browseMode {
    case .thumbnail:
      break
    case .highDefinition:
      presentHDFullScreenPreview(startingAt: selectedItem.handle)
      return
    }
    guard let previewImageCache = runtime.galleryPreviewCache else { return }
    let previewItems = catalogPresentation.items.filter(
      CameraVendorGalleryDownloadPolicy.isSupportedStill
    )
    guard let previewIndex = previewItems.firstIndex(where: { $0.handle == selectedItem.handle }),
          let previewCatalogIdentity = runtime.galleryCatalogIdentity else { return }

    enqueueHDTransition { [weak self] in
      guard let self else { return }
      await self.runtime.suspendGalleryContentWorkForFullScreenPreview()
      guard self.runtime.galleryCatalogIdentity == previewCatalogIdentity else {
        await self.runtime.resumeGalleryContentWorkAfterFullScreenPreview()
        return
      }

      let controller = NativePhotoPreviewViewController(
        items: previewItems,
        initialIndex: previewIndex,
        runtime: self.runtime,
        previewImageCache: previewImageCache,
        previewCatalogIdentity: previewCatalogIdentity,
        onPreviewClosed: { [weak self] handle, openingCatalogIdentity in
          guard let self else { return }
          self.enqueueHDTransition { [weak self] in
            guard let self else { return }
            await self.runtime.resumeGalleryContentWorkAfterFullScreenPreview()
            if self.browseMode == .thumbnail {
              if self.runtime.galleryCatalogIdentity == openingCatalogIdentity,
                 let indexPath = self.indexPath(forHandle: handle) {
                self.collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
              }
              self.lastSubmittedThumbnailViewportIdentity = nil
              self.scheduleVisibleThumbnailRefresh(after: 0)
            } else {
              self.runtime.updateGalleryHDPreviewVisibleHandles(self.hdVisibleHandles())
            }
          }
        },
        shouldLoadPreviewThumbnail: { [weak self] in
          NativeGalleryPriorityDownloadPolicy.shouldLoadPreviewThumbnail(
            isDownloading: self?.runtime.isDownloading == true
          )
        },
        cachedThumbnailImageProvider: { [weak self] handle in
          self?.cachedThumbnailImage(for: handle)
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

      guard let navigationController = self.navigationController else {
        await self.runtime.resumeGalleryContentWorkAfterFullScreenPreview()
        return
      }
      navigationController.pushViewController(controller, animated: true)
    }
  }

  private func presentHDFullScreenPreview(startingAt handle: Int) {
    guard let snapshot = hdPresentationState?.snapshot,
          let catalogIdentity = runtime.galleryCatalogIdentity else { return }
    let orderedItems = snapshot.items.compactMap { previewItem -> CameraVendorGalleryItem? in
      let item = previewItem.displayItem
      return NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
        item: item,
        hasPreviewImage: false
      ) ? item : nil
    }
    guard orderedItems.contains(where: { $0.handle == handle }) else { return }
    let controller = NativeGalleryHDFullScreenViewController(
      context: NativeGalleryHDFullScreenContext(
        catalogIdentity: catalogIdentity,
        orderedItems: orderedItems,
        initialHandle: handle
      ),
      runtime: runtime,
      cachedThumbnailImageProvider: { [weak self] handle in
        self?.cachedThumbnailImage(for: handle)
      },
      onClosed: { [weak self] currentHandle, openingCatalogIdentity in
        guard let self,
              self.browseMode == .highDefinition,
              let currentSnapshot = self.hdPresentationState?.snapshot,
              let indexPath = NativeGalleryHDFullScreenReturnPolicy.indexPath(
                handle: currentHandle,
                openingCatalogIdentity: openingCatalogIdentity,
                currentCatalogIdentity: self.runtime.galleryCatalogIdentity,
                snapshot: currentSnapshot
              ) else {
          return
        }
        self.hdCollectionView.scrollToItem(
          at: indexPath,
          at: .centeredVertically,
          animated: false
        )
        self.hdCollectionView.layoutIfNeeded()
        self.runtime.restoreGalleryHDPreviewListFocus(
          visibleHandles: self.hdVisibleHandles()
        )
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
  static func decoded(
    from data: Data,
    objectOrientation: Int? = nil,
    diagnosticHandle: Int? = nil
  ) -> UIImage? {
    guard let raw = decodeRaw(data: data) else { return nil }
    let cropped = cropBlackBars(raw) ?? raw
    if cropped.imageOrientation != .up {
      if let diagnosticHandle {
        CameraVendorFileLogger.log(
          "[OBS] ORIENTATION_DECISION handle=0x\(String(format: "%08X", diagnosticHandle)) " +
          "source=uiimage object=\(objectOrientation.map(String.init) ?? "unknown") " +
          "decoded=\(Int(cropped.size.width))x\(Int(cropped.size.height)) " +
          "uiOrientation=\(cropped.imageOrientation.rawValue) selected=0 alreadyApplied=true"
        )
      }
      return NativePhotoPreviewImageRenderer.rendered(image: cropped, manualRotationDegrees: 0)
    }
    let decision = NativePhotoPreviewRotationPolicy.rotationDecision(
      objectOrientation: objectOrientation,
      decodedWidth: Int(cropped.size.width),
      decodedHeight: Int(cropped.size.height),
      imageData: data
    )
    if let diagnosticHandle {
      CameraVendorFileLogger.log(
        "[OBS] ORIENTATION_DECISION handle=0x\(String(format: "%08X", diagnosticHandle)) " +
        "source=\(decision.source) object=\(objectOrientation.map(String.init) ?? "unknown") " +
        "metadataDegrees=\(decision.metadataDegrees.map(String.init) ?? "none") " +
        "decoded=\(Int(cropped.size.width))x\(Int(cropped.size.height)) " +
        "selected=\(decision.degrees) alreadyApplied=\(decision.rotationAlreadyApplied)"
      )
    }
    return NativePhotoPreviewImageRenderer.rendered(
      image: cropped,
      manualRotationDegrees: decision.degrees
    )
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

final class NativeDownloadListViewController: UIViewController {
  private let runtime: CameraSessionRuntime
  private let itemsProvider: () -> [CameraVendorGalleryItem]
  private let stateProvider: (Int) -> CameraVendorDownloadState
  private let progressProvider: (Int) -> String?
  private let isTransferActiveProvider: () -> Bool
  private let onClearDownloadCache: (CameraVendorGalleryItem) -> Void
  private var previousNavigationBarHidden: Bool?
  private var previousInteractivePopGestureEnabled: Bool?
  private var isStoppingForExit = false

  /// Called externally when a download thumbnail is generated from the temp file.
  func setDownloadThumbnail(handle: Int, image: UIImage) {
    thumbnailImageCache.setObject(image, forKey: NSNumber(value: handle))
    collectionView.reloadData()
  }
  private var runtimePresentationObserverID: UUID?
  private var incrementalCatalogObserverID: UUID?
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
    onClearDownloadCache: @escaping (CameraVendorGalleryItem) -> Void
  ) {
    self.runtime = runtime
    self.itemsProvider = itemsProvider
    self.stateProvider = stateProvider
    self.progressProvider = progressProvider
    self.isTransferActiveProvider = isTransferActiveProvider
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
    runtime.onDownloadThumbnailGenerated = { [weak self] handle, image in
      self?.setDownloadThumbnail(handle: Int(handle), image: image)
    }
    incrementalCatalogObserverID = runtime.observeIncrementalCatalogUpdates { [weak self] _, delta in
      guard let self else { return }
      let handles = delta.changedHandles
      // Thumbnail arrived — rehydrate and refresh visible cells
      let items = self.itemsProvider()
      for handle in handles {
        guard let item = items.first(where: { $0.handle == handle }),
              item.thumbnailData != nil,
              self.thumbnailImageCache.object(forKey: NSNumber(value: handle)) == nil else {
          continue
        }
        self.rehydrateCachedThumbnailIfNeeded(for: item)
      }
      self.collectionView.reloadData()
    }
    refreshSummary()
    refreshEmptyState()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    cancelThumbnailRehydrateTasks()
    let runtime = runtime
    let presentationObserverID = runtimePresentationObserverID
    let incrementalObserverID = incrementalCatalogObserverID
    Task { @MainActor in
      runtime.onDownloadThumbnailGenerated = nil
      if let presentationObserverID {
        runtime.removeObserver(presentationObserverID)
      }
      if let incrementalObserverID {
        runtime.removeObserver(incrementalObserverID)
      }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NativeLuxuryTheme.applyNavigationAppearance(to: navigationController)
    applyTopChromeNavigationState(animated: animated)
    protectDownloadExitNavigation()
    collectionView.reloadData()
    refreshSummary()
    refreshEmptyState()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    restoreDownloadExitNavigation()
    if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
      restoreTopChromeNavigationState(animated: animated)
    }
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    .darkContent
  }

  private func protectDownloadExitNavigation() {
    guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
    if previousInteractivePopGestureEnabled == nil {
      previousInteractivePopGestureEnabled = gesture.isEnabled
    }
    gesture.isEnabled = false
  }

  private func restoreDownloadExitNavigation() {
    guard let gesture = navigationController?.interactivePopGestureRecognizer,
          let wasEnabled = previousInteractivePopGestureEnabled else { return }
    gesture.isEnabled = wasEnabled
    previousInteractivePopGestureEnabled = nil
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
    guard !isStoppingForExit else { return }
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
      guard let self, !self.isStoppingForExit else { return }
      self.isStoppingForExit = true
      self.refreshSummary()
      let runtime = self.runtime
      Task { @MainActor in
        await runtime.stopDownloadAndWait()
      }
    })
    present(alert, animated: true)
  }

  @objc private func clearRecordsTapped() {
    guard !isStoppingForExit, clearRecordsButton.isEnabled else { return }
    clearRecordsButton.isEnabled = false
    clearRecordsButton.configuration?.showsActivityIndicator = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self else { return }
      self.runtime.send(.clearAllSavedDownloadHistory)
      NotificationCenter.default.post(name: .nativeDownloadStateDidChange, object: nil)
      self.collectionView.reloadData()
      self.refreshSummary()
      self.refreshEmptyState()
      self.clearRecordsButton.configuration?.showsActivityIndicator = false
      self.clearRecordsButton.isEnabled = true
    }
  }

  @objc private func downloadStateDidChange() {
    let isTransferActive = isTransferActiveProvider()
    if isTransferActive {
      hasObservedActiveTransfer = true
    }

    // For items that just became .saved, request their thumbnails from camera
    let items = itemsProvider()
    var newlySavedHandles: [Int] = []
    for item in items {
      let state = stateProvider(item.handle)
      if state == .saved, thumbnailImageCache.object(forKey: NSNumber(value: item.handle)) == nil {
        newlySavedHandles.append(item.handle)
      }
    }

    collectionView.reloadData()
    refreshSummary()
    refreshEmptyState()

    // When downloads finish (PTP lane free), request thumbnails for saved items
    if hasObservedActiveTransfer,
       !isTransferActive,
       !newlySavedHandles.isEmpty,
       let expectedCatalogIdentity = runtime.galleryCatalogIdentity {
      runtime.requestVisibleGalleryThumbnails(
        handles: newlySavedHandles,
        expectedCatalogIdentity: expectedCatalogIdentity
      )
    }

    guard hasObservedActiveTransfer,
          !isTransferActive,
          navigationController?.topViewController === self else { return }
    hasObservedActiveTransfer = false
  }

  private func refreshEmptyState() {
    let isEmpty = itemsProvider().isEmpty
    emptyContainer.isHidden = !isEmpty
    collectionView.isHidden = isEmpty
  }

  private func refreshSummary() {
    if isStoppingForExit {
      summaryLabel.text = "正在停止下载…"
      headerSpinner.startAnimating()
      clearRecordsButton.isHidden = true
      clearRecordsButton.isEnabled = false
      clearRecordsButton.alpha = 0.48
      backButton.isEnabled = false
      backButton.alpha = 0.48
      return
    }
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
    // Try Photo Library thumbnail first (for already-downloaded photos)
    let cachedImage = thumbnailImageCache.object(forKey: NSNumber(value: item.handle))
    cell.configure(
      item: item,
      isSelected: false,
      downloadState: stateProvider(item.handle),
      thumbnailImage: cachedImage,
      showsSelection: false,
      dimsUndownloaded: true
    )
    if cachedImage == nil {
      loadPhotoLibraryThumbnailIfNeeded(for: item)
    }
    rehydrateCachedThumbnailIfNeeded(for: item)
  }

  private func loadPhotoLibraryThumbnailIfNeeded(for item: CameraVendorGalleryItem) {
    let handle = item.handle
    guard thumbnailImageCache.object(forKey: NSNumber(value: handle)) == nil,
          thumbnailRehydrateTasks[handle] == nil else { return }

    // Get the real filename from multiple sources
    var filename = item.filename
    if filename.isEmpty || filename.hasPrefix("0x") {
      // Try the runtime's current catalog items (may have been updated by ObjectInfo)
      if let catalogItem = runtime.presentation.catalog.items.first(where: { $0.handle == handle }),
         !catalogItem.filename.isEmpty, !catalogItem.filename.hasPrefix("0x") {
        filename = catalogItem.filename
      }
    }
    if filename.isEmpty || filename.hasPrefix("0x") {
      // Try download history (items saved with real filenames)
      let historyItems = runtime.downloadHistoryItems()
      if let historyItem = historyItems.first(where: { $0.handle == handle }) {
        filename = historyItem.filename
      }
    }
    guard !filename.isEmpty, !filename.hasPrefix("0x") else {
      CameraVendorFileLogger.log("[PHOTO_LIB_THUMB] skip handle=\(handle) reason=no-filename item.filename=\(item.filename)")
      return
    }

    CameraVendorFileLogger.log("[PHOTO_LIB_THUMB] requesting handle=\(handle) filename=\(filename)")
    thumbnailRehydrateTasks[handle] = Task { [weak self] in
      CameraPhotoLibraryProvider.thumbnail(forFilename: filename, targetSize: CGSize(width: 200, height: 200)) { [weak self] image in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.thumbnailRehydrateTasks.removeValue(forKey: handle)
          if let image {
            CameraVendorFileLogger.log("[PHOTO_LIB_THUMB] loaded handle=\(handle) filename=\(filename)")
            self.thumbnailImageCache.setObject(image, forKey: NSNumber(value: handle))
            self.collectionView.reloadData()
          } else {
            CameraVendorFileLogger.log("[PHOTO_LIB_THUMB] not-found handle=\(handle) filename=\(filename)")
          }
        }
      }
    }
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
          objectOrientation: orientation,
          diagnosticHandle: handle
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
    let items = itemsProvider()
    guard items.indices.contains(indexPath.item) else { return cell }
    let item = items[indexPath.item]
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
    if collectionView === hdCollectionView {
      return hdPresentationState?.snapshot.sections.count ?? 0
    }
    return gallerySections.isEmpty ? 1 : gallerySections.count
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    if collectionView === hdCollectionView {
      guard let snapshot = hdPresentationState?.snapshot,
            snapshot.sections.indices.contains(section),
            !collapsedSections.contains(section) else { return 0 }
      return snapshot.sections[section].items.count
    }
    guard gallerySections.indices.contains(section) else { return 0 }
    if collapsedSections.contains(section) { return 0 }
    return gallerySections[section].items.count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    if collectionView === hdCollectionView {
      guard let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: NativeGalleryHDPreviewCell.reuseIdentifier,
        for: indexPath
      ) as? NativeGalleryHDPreviewCell else {
        return UICollectionViewCell()
      }
      if let item = hdPresentationState?.snapshot.item(at: indexPath) {
        configureHDCell(cell, previewItem: item)
      }
      return cell
    }

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
    guard kind == UICollectionView.elementKindSectionHeader else {
      return collectionView.dequeueReusableSupplementaryView(
        ofKind: kind,
        withReuseIdentifier: NativeGallerySectionHeaderView.reuseIdentifier,
        for: indexPath
      )
    }
    let header = collectionView.dequeueReusableSupplementaryView(
      ofKind: kind,
      withReuseIdentifier: NativeGallerySectionHeaderView.reuseIdentifier,
      for: indexPath
    ) as! NativeGallerySectionHeaderView

    if collectionView === hdCollectionView {
      guard let snapshot = hdPresentationState?.snapshot,
            snapshot.sections.indices.contains(indexPath.section) else {
        header.configure(dateTitle: "", countTitle: "", selectionTitle: "", sortTitle: "")
        return header
      }
      let hdSection = snapshot.sections[indexPath.section]
      let isCollapsed = collapsedSections.contains(indexPath.section)
      header.configure(
        dateTitle: NativeGallerySectionPolicy.dateTitle(for: hdSection.day),
        countTitle: "\(hdSection.items.count) 张",
        selectionTitle: "",
        sortTitle: isCollapsed ? "▲" : "▼"
      )
      header.onSelectionTapped = nil
      header.onSortTapped = { [weak self] in
        self?.toggleSectionCollapse(at: indexPath.section)
      }
    } else {
      guard gallerySections.indices.contains(indexPath.section) else {
        header.configure(dateTitle: "", countTitle: "", selectionTitle: "", sortTitle: "")
        return header
      }
      configureGalleryHeader(header, at: indexPath)
    }
    return header
  }
}

extension NativeGalleryViewController: UICollectionViewDelegateFlowLayout {
  func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    if collectionView === hdCollectionView {
      if let handle = hdPresentationState?.snapshot.item(at: indexPath)?.displayItem.handle {
        scheduleHDPreviewDecode(for: handle)
      }
      return
    }
    scheduleVisibleThumbnailRefresh()
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    if collectionView === hdCollectionView {
      // Tap handled by cell's onImageTapped closure
      return
    }
    guard let item = galleryItem(at: indexPath),
          let flatIndex = catalogPresentation.items.firstIndex(where: { $0.handle == item.handle }) else {
      return
    }
    presentPreview(startingAt: flatIndex)
  }

  private var horizontalInsetForCurrentLayout: CGFloat {
    NativeGalleryAndroidParityGridPolicy.horizontalInset
  }

  private var spacingForCurrentLayout: CGFloat {
    NativeGalleryGridLayoutPolicy.androidGridSpacing
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    if collectionView === hdCollectionView {
      let width = collectionView.bounds.width
      let handle = hdPresentationState?.snapshot.item(at: indexPath)?.displayItem.handle
      if let handle, let image = cachedHDPreviewImage(for: handle) {
        let height = NativeGalleryHDPreviewLayoutPolicy.cellHeight(
          forWidth: width,
          imageWidth: image.size.width,
          imageHeight: image.size.height
        )
        return CGSize(width: width, height: height)
      }
      return CGSize(width: width, height: width * NativeGalleryHDPreviewLayoutPolicy.defaultAspectRatio)
    }

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
    if collectionView === hdCollectionView {
      return .zero
    }
    let inset = horizontalInsetForCurrentLayout
    let bottom: CGFloat = section == max(gallerySections.count - 1, 0) ? 96 : 4
    return UIEdgeInsets(top: 0, left: inset, bottom: bottom, right: inset)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    referenceSizeForHeaderInSection section: Int
  ) -> CGSize {
    if collectionView === hdCollectionView {
      guard let snapshot = hdPresentationState?.snapshot,
            snapshot.sections.indices.contains(section) else { return .zero }
      return CGSize(
        width: collectionView.bounds.width,
        height: NativeGalleryAndroidParityGridPolicy.sectionHeaderHeight
      )
    }
    guard gallerySections.indices.contains(section) else { return .zero }
    return CGSize(
      width: collectionView.bounds.width,
      height: NativeGalleryAndroidParityGridPolicy.sectionHeaderHeight
    )
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    minimumInteritemSpacingForSectionAt section: Int
  ) -> CGFloat {
    if collectionView === hdCollectionView { return 0 }
    return spacingForCurrentLayout
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    minimumLineSpacingForSectionAt section: Int
  ) -> CGFloat {
    if collectionView === hdCollectionView {
      return NativeGalleryHDPreviewLayoutPolicy.interItemSpacing
    }
    return spacingForCurrentLayout
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      if scrollView === hdCollectionView {
        hdScrollDidSettle()
      } else {
        scheduleVisibleThumbnailRefresh(after: 0.05)
      }
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === hdCollectionView, browseMode == .highDefinition else { return }
    let visibleHandles = hdVisibleHandles()
    guard !visibleHandles.isEmpty else { return }
    runtime.updateGalleryHDPreviewVisibleHandles(visibleHandles)
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if scrollView === hdCollectionView {
      hdScrollDidSettle()
    } else {
      scheduleVisibleThumbnailRefresh(after: 0.05)
    }
  }

  private func hdScrollDidSettle() {
    guard browseMode == .highDefinition else { return }
    runtime.updateGalleryHDPreviewVisibleHandles(hdVisibleHandles())
  }

}

final class NativeGallerySectionHeaderView: UICollectionReusableView {
  static let reuseIdentifier = "NativeGallerySectionHeaderView"

  var onSelectionTapped: (() -> Void)?
  var onSortTapped: (() -> Void)?

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.systemFont(ofSize: 15, weight: .black)
    label.textColor = NativeLuxuryTheme.ink
    label.numberOfLines = 1
    return label
  }()

  private let countLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    label.textColor = NativeLuxuryTheme.secondaryInk
    label.textAlignment = .left
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

  private let sortButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    )
    config.baseForegroundColor = NativeLuxuryTheme.secondaryInk
    config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
    button.configuration = config
    return button
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = NativeLuxuryTheme.background
    addSubview(titleLabel)
    addSubview(countLabel)
    addSubview(selectionButton)
    addSubview(sortButton)
    selectionButton.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)
    sortButton.addTarget(self, action: #selector(sortTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),

      countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
      countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      selectionButton.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -6),
      selectionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      selectionButton.heightAnchor.constraint(equalToConstant: 28),

      sortButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      sortButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      sortButton.widthAnchor.constraint(equalToConstant: 28),
      sortButton.heightAnchor.constraint(equalToConstant: 28),
      countLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectionButton.leadingAnchor, constant: -8),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onSelectionTapped = nil
    onSortTapped = nil
  }

  func configure(dateTitle: String, countTitle: String, selectionTitle: String, sortTitle: String) {
    titleLabel.text = dateTitle
    countLabel.text = countTitle
    selectionButton.configuration?.attributedTitle = AttributedString(selectionTitle, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    let isCollapsed = sortTitle == "▲"
    let chevronName = isCollapsed ? "chevron.right" : "chevron.down"
    sortButton.configuration?.image = UIImage(
      systemName: chevronName,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    )
  }

  @objc private func selectionTapped() {
    onSelectionTapped?()
  }

  @objc private func sortTapped() {
    onSortTapped?()
  }
}

final class NativeGalleryGridCell: UICollectionViewCell {
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
      ? item.thumbnailData.flatMap {
        CameraVendorGalleryThumbnailRenderer.decoded(
          from: $0,
          objectOrientation: item.orientation,
          diagnosticHandle: item.handle
        )
      }
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
    case .idle, .failed, .saved:
      return true
    case .queued, .downloading:
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
