import Foundation
import UIKit

final class NativeGalleryViewController: UIViewController, UIGestureRecognizerDelegate {
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

  // MARK: - HD Preview Mode

  private var browseMode: NativeGalleryBrowseMode = .thumbnail
  private let hdPreviewCache = NativeGalleryHighDefinitionPreviewCache()
  private var hdPresentationState: NativeGalleryHDPreviewState?
  private var hdRenderedDisplayHandles: [Int] = []
  private var hdTransitionTask: Task<Void, Never>?
  private lazy var hdCoordinator = NativeGalleryHDPreviewCoordinator(
    cache: hdPreviewCache,
    suspendChildWork: { [weak self] in
      await self?.runtime.suspendGalleryChildWorkForHighDefinitionPreview()
    },
    resumeChildWork: { [weak self] in
      await self?.runtime.resumeGalleryChildWorkAfterHighDefinitionPreview()
    },
    fetchPreview: { [weak self] handle in
      guard let self else { throw CancellationError() }
      return try await self.runtime.requestPreviewImageWithInfo(for: handle)
    },
    publish: { [weak self] state in
      self?.applyHDPreviewState(state)
    }
  )

  private let browseModeSegment: UISegmentedControl = {
    let control = UISegmentedControl(items: ["缩略", "高清"])
    control.translatesAutoresizingMaskIntoConstraints = false
    control.selectedSegmentIndex = 0
    control.selectedSegmentTintColor = NativeLuxuryTheme.ink
    control.setTitleTextAttributes([
      .foregroundColor: NativeLuxuryTheme.cardBackground,
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ], for: .selected)
    control.setTitleTextAttributes([
      .foregroundColor: NativeLuxuryTheme.ink,
      .font: UIFont.systemFont(ofSize: 12, weight: .semibold)
    ], for: .normal)
    return control
  }()

  private let hdCollectionView: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = NativeGalleryHDPreviewLayoutPolicy.interItemSpacing
    layout.sectionInset = .zero
    let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
    cv.translatesAutoresizingMaskIntoConstraints = false
    cv.backgroundColor = .black
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
    let hdTransitionTask = hdTransitionTask
    let hdCoordinator = hdCoordinator
    let hdPreviewCache = hdPreviewCache
    Task { @MainActor in
      visibleThumbnailRefreshTask?.cancel()
      await hdTransitionTask?.value
      await hdCoordinator.stop(resumeCatalogChildWork: false)
      hdPreviewCache.reset()
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
    if browseMode == .highDefinition, !runtime.isDownloading {
      hdCoordinator.resumeAfterDownload()
    }
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

    view.addSubview(browseModeSegment)
    view.addSubview(filterStack)
    view.addSubview(collectionView)
    view.addSubview(hdCollectionView)
    view.addSubview(hdStatusLabel)
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

    hdCollectionView.dataSource = self
    hdCollectionView.delegate = self

    browseModeSegment.addTarget(self, action: #selector(browseModeChanged(_:)), for: .valueChanged)

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

      browseModeSegment.topAnchor.constraint(equalTo: filterStack.bottomAnchor, constant: 8),
      browseModeSegment.leadingAnchor.constraint(equalTo: headerFrame.leadingAnchor),
      browseModeSegment.trailingAnchor.constraint(equalTo: headerFrame.trailingAnchor),
      browseModeSegment.heightAnchor.constraint(equalToConstant: 32),

      collectionView.topAnchor.constraint(
        equalTo: browseModeSegment.bottomAnchor,
        constant: NativeGalleryAndroidParityLayoutPolicy.filterToGridSpacing
      ),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      hdCollectionView.topAnchor.constraint(equalTo: collectionView.topAnchor),
      hdCollectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hdCollectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hdCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      hdStatusLabel.topAnchor.constraint(equalTo: hdCollectionView.topAnchor, constant: 12),
      hdStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      hdStatusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
      hdStatusLabel.heightAnchor.constraint(equalToConstant: 24),

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

  // MARK: - HD Preview Mode

  @objc private func browseModeChanged(_ sender: UISegmentedControl) {
    let mode: NativeGalleryBrowseMode = sender.selectedSegmentIndex == 1 ? .highDefinition : .thumbnail
    switchBrowseMode(mode)
  }

  private func switchBrowseMode(_ mode: NativeGalleryBrowseMode) {
    guard mode != browseMode else { return }
    guard NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: runtime.isDownloading) else {
      browseModeSegment.selectedSegmentIndex = browseMode == .thumbnail ? 0 : 1
      showToast("正在下载，无法切换浏览模式")
      return
    }

    browseMode = mode
    switch mode {
    case .thumbnail:
      hdCollectionView.isHidden = true
      collectionView.isHidden = false
      hdStatusLabel.isHidden = true
      enqueueHDTransition { [weak self] in
        await self?.hdCoordinator.stop(resumeCatalogChildWork: true)
      }
      view.backgroundColor = NativeLuxuryTheme.background
      scheduleVisibleThumbnailRefresh(after: 0.05)
    case .highDefinition:
      visibleThumbnailRefreshTask?.cancel()
      visibleThumbnailRefreshTask = nil

      collectionView.isHidden = true
      hdCollectionView.isHidden = false
      view.backgroundColor = .black
      startHDPreviewLoading()
    }
  }

  private func startHDPreviewLoading() {
    let activeDate = preferredHDActiveDate()
    let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(
      items: catalogPresentation.items,
      activeDate: activeDate
    )
    hdRenderedDisplayHandles = []
    applyHDPreviewState(NativeGalleryHDPreviewState(
      snapshot: snapshot,
      loadedHandles: hdPreviewCache.loadedHandles
    ))
    let visibleHandles = hdVisibleHandles()
    enqueueHDTransition { [weak self] in
      guard let self else { return }
      await self.hdCoordinator.activate(
        snapshot: snapshot,
        visibleHandles: visibleHandles
      )
    }
  }

  private func preferredHDActiveDate() -> Date {
    switch filterState.date {
    case .specificDay(let date):
      return date
    case .range(_, let to):
      return NativeGalleryHDPreviewSessionPolicy.preferredActiveDate(
        items: catalogPresentation.items,
        currentDate: to
      )
    case .all, .today:
      return NativeGalleryHDPreviewSessionPolicy.preferredActiveDate(
        items: catalogPresentation.items,
        currentDate: Date()
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

  private func hdVisibleHandles() -> [Int] {
    guard let snapshot = hdPresentationState?.snapshot else { return [] }
    return hdCollectionView.indexPathsForVisibleItems
      .sorted { $0.item < $1.item }
      .compactMap { snapshot.items[hdSafe: $0.item]?.displayItem.handle }
  }

  private func applyHDPreviewState(_ state: NativeGalleryHDPreviewState?) {
    guard browseMode == .highDefinition else { return }
    hdPresentationState = state
    let handles = state?.snapshot.displayHandles ?? []
    if handles != hdRenderedDisplayHandles {
      hdRenderedDisplayHandles = handles
      hdCollectionView.reloadData()
    } else {
      for indexPath in hdCollectionView.indexPathsForVisibleItems {
        guard let item = state?.snapshot.items[hdSafe: indexPath.item],
              let cell = hdCollectionView.cellForItem(at: indexPath) as? NativeGalleryHDPreviewCell else {
          continue
        }
        configureHDCell(cell, previewItem: item)
      }
      hdCollectionView.collectionViewLayout.invalidateLayout()
    }
    updateHDStatusLabel(state)
  }

  private func refreshHDCell(for handle: Int) {
    guard browseMode == .highDefinition else { return }
    guard let items = hdPresentationState?.snapshot.items,
          let row = items.firstIndex(where: { $0.displayItem.handle == handle }) else {
      return
    }
    let indexPath = IndexPath(item: row, section: 0)
    if let cell = hdCollectionView.cellForItem(at: indexPath) as? NativeGalleryHDPreviewCell {
      configureHDCell(cell, previewItem: items[row])
    }
  }

  private func updateHDStatusLabel(_ state: NativeGalleryHDPreviewState?) {
    guard let state, state.totalCount > 0 else {
      hdStatusLabel.isHidden = true
      return
    }
    hdStatusLabel.text = "  \(state.loadedCount)/\(state.totalCount)  "
    hdStatusLabel.isHidden = false
  }

  private func hdLoadState(for item: CameraVendorGalleryItem) -> NativeGalleryHDPreviewCell.LoadState {
    let handle = item.handle
    if let data = hdPreviewCache.restoreLoadedData(for: handle) {
      if let image = CameraVendorGalleryThumbnailRenderer.decoded(
        from: data,
        objectOrientation: hdPreviewCache.restoreLoadedPreview(for: handle)?.objectOrientation
      ) {
        return .loaded(image)
      }
      return .failed
    }
    // Non-previewable items (RAW, video) can't be HD-loaded
    if !NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(item: item, hasPreviewImage: false) {
      return .waiting
    }
    if hdPresentationState?.loadState.failedHandles.contains(handle) == true { return .failed }
    if hdPresentationState?.loadState.loadingHandles.contains(handle) == true { return .loading }
    return .waiting
  }

  private func configureHDCell(
    _ cell: NativeGalleryHDPreviewCell,
    previewItem: NativeGalleryHDPreviewItem
  ) {
    let item = previewItem.displayItem
    let handle = item.handle
    let state = hdLoadState(for: item)
    let isQueued = selectedHandles.contains(handle)
    let hasRaw = previewItem.rawSidecar != nil
    let isRawQueued = previewItem.rawSidecar.map { selectedHandles.contains($0.handle) } ?? false

    cell.configure(
      loadState: state,
      hasRawSidecar: hasRaw,
      isQueued: isQueued,
      isRawQueued: isRawQueued
    )

    // Use image size from loaded preview, else default 3:2 landscape
    if case .loaded(let image) = state {
      cell.setAspectRatio(width: image.size.width, height: image.size.height)
    } else {
      cell.setAspectRatio(width: 3, height: 2)
    }

    cell.onQueueTapped = { [weak self] in
      guard let self,
            NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: self.runtime.isDownloading),
            NativeGalleryDownloadSelectionPolicy.canSelect(
              downloadState: self.runtime.downloadState(for: handle)
            ) else { return }
      self.toggleSelection(for: item)
      self.refreshHDCell(for: handle)
    }
    cell.onQueueRawTapped = { [weak self] in
      guard let self,
            let rawSidecar = previewItem.rawSidecar,
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
    let candidateRequests: [CameraSessionQueuedDownload]
    if browseMode == .highDefinition, let snapshot = hdPresentationState?.snapshot {
      let selected = Set(handles)
      candidateRequests = NativeGalleryHDDownloadRequestPolicy.requests(
        displayHandles: snapshot.items
          .map(\.displayItem.handle)
          .filter { selected.contains($0) },
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
    let downloadableHandles = Set(runtime.downloadableHandles(
      from: candidateRequests.map { Int($0.handle) }
    ))
    let requestsToDownload = candidateRequests.filter {
      downloadableHandles.contains(Int($0.handle))
    }
    let handlesToDownload = requestsToDownload.map { Int($0.handle) }
    guard !handlesToDownload.isEmpty else {
      showToast("已下载过，无需重复下载")
      return
    }
    let itemsToDownload = catalogPresentation.items.filter { handlesToDownload.contains($0.handle) }
    let previousSelection = selectedHandles
    selectedHandles = NativeGalleryPostDownloadSelectionPolicy.selectionAfterStartingDownload(
      selectedHandles: selectedHandles
    )
    let startDownload = { [weak self] in
      guard let self else { return }
      self.runtime.send(.startDownloadRequests(requestsToDownload))
      self.finishOpeningDownloadCenter(
        handlesToDownload: handlesToDownload,
        itemsToDownload: itemsToDownload,
        previousSelection: previousSelection
      )
    }
    if browseMode == .highDefinition {
      enqueueHDTransition { [weak self] in
        guard let self else { return }
        await self.hdCoordinator.pauseForDownload()
        startDownload()
      }
      return
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
    // Don't load thumbnails during HD preview mode — PTP transport is exclusive
    guard browseMode == .thumbnail else { return }
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

final class NativeDownloadListViewController: UIViewController {
  private let runtime: CameraSessionRuntime
  private let itemsProvider: () -> [CameraVendorGalleryItem]
  private let stateProvider: (Int) -> CameraVendorDownloadState
  private let progressProvider: (Int) -> String?
  private let isTransferActiveProvider: () -> Bool
  private let onTerminateDownload: () -> Void
  private let onClearDownloadCache: (CameraVendorGalleryItem) -> Void
  var onMovedFromParent: (() -> Void)?
  private var previousNavigationBarHidden: Bool?

  /// Called externally when a download thumbnail is generated from the temp file.
  func setDownloadThumbnail(handle: Int, image: UIImage) {
    thumbnailImageCache.setObject(image, forKey: NSNumber(value: handle))
    collectionView.reloadData()
  }
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
    runtime.observeIncrementalCatalogUpdates { [weak self] _, handles in
      guard let self else { return }
      // Thumbnail arrived — rehydrate and refresh visible cells
      let items = self.itemsProvider()
      for handle in handles {
        guard let item = items.first(where: { $0.handle == handle }),
              let data = item.thumbnailData,
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
      onMovedFromParent?()
      onMovedFromParent = nil
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
    if hasObservedActiveTransfer, !isTransferActive, !newlySavedHandles.isEmpty {
      runtime.requestVisibleGalleryThumbnails(handles: newlySavedHandles)
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
    if collectionView === hdCollectionView { return 1 }
    return gallerySections.isEmpty ? 1 : gallerySections.count
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    if collectionView === hdCollectionView {
      return hdPresentationState?.snapshot.items.count ?? 0
    }
    guard gallerySections.indices.contains(section) else { return 0 }
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
      if let item = hdPresentationState?.snapshot.items[hdSafe: indexPath.item] {
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
    if collectionView === hdCollectionView { return }
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
    if collectionView === hdCollectionView {
      let width = collectionView.bounds.width
      let handle = hdPresentationState?.snapshot.items[hdSafe: indexPath.item]?.displayItem.handle
      // Use actual image dimensions from cache if loaded, otherwise default 3:2 landscape
      if let handle, let data = hdPreviewCache.restoreLoadedData(for: handle),
         let image = UIImage(data: data) {
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
    guard gallerySections.indices.contains(section) else { return .zero }
    if collectionView === hdCollectionView {
      return .zero
    }
    return CGSize(width: collectionView.bounds.width, height: 44)
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

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if scrollView === hdCollectionView {
      hdScrollDidSettle()
    } else {
      scheduleVisibleThumbnailRefresh(after: 0.05)
    }
  }

  private func hdScrollDidSettle() {
    guard browseMode == .highDefinition else { return }
    hdCoordinator.updateVisibleHandles(hdVisibleHandles())
  }
}

final class NativeGallerySectionHeaderView: UICollectionReusableView {
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
