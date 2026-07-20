import Photos
import UIKit

final class WiredCameraImportViewController: UIViewController {
  private let service = WiredCameraImportService()
  private let cacheStore = WiredCameraImportCacheStore()
  private let thumbnailCacheStore = WiredCameraThumbnailCacheStore()
  private var state = WiredCameraImportState()
  private var gallerySections: [WiredCameraImportDaySection] = []
  private var autoImportAttemptedItemIDs: Set<String> = []
  private var currentImportTotal = 0
  private var activeDownloadProgress: (itemID: String, completedBytes: Int64, totalBytes: Int64)?
  private var proofingServer: LocalProofingServer?
  private weak var proofingSheet: LocalProofingSessionViewController?
  private var previousInteractivePopGestureEnabled: Bool?
  private var importTask: Task<Void, Never>?
  private var isDeleting = false
  private var needsContentsAuthorization = false
  private var currentColumnCount: Int = {
    let stored = UserDefaults.standard.integer(forKey: "camtransfer.wiredGalleryColumnCount")
    if (NativeGalleryGridLayoutPolicy.minColumnCount...NativeGalleryGridLayoutPolicy.maxColumnCount).contains(stored) {
      return stored
    }
    return 3
  }()

  private let headerView = UIView()
  private let statusLabel = UILabel()
  private let deviceLabel = UILabel()
  private let permissionButton = UIButton(type: .system)
  private let selectAllButton = UIButton(type: .system)
  private let dateChips = NativeChipBarControl()
  private let formatChips = NativeChipBarControl()
  private let statusChips = NativeChipBarControl()
  private let collectionView: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 8
    layout.minimumLineSpacing = 12
    layout.sectionInset = UIEdgeInsets(top: 8, left: 12, bottom: 88, right: 12)
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    return collectionView
  }()
  private let bottomImportBar = UIView()
  private let bottomImportLabel = UILabel()
  private let deleteButton = UIButton(type: .system)
  private let importButton = UIButton(type: .system)
  private let activityIndicator = UIActivityIndicatorView(style: .medium)
  private let refreshControl = UIRefreshControl()

  override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = NativeGalleryChromeCopy.title
    view.backgroundColor = NativeLuxuryTheme.background
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.hidesBackButton = true
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "断开",
      style: .plain,
      target: self,
      action: #selector(disconnectTapped)
    )
    service.delegate = self
    service.downloadProgressHandler = { [weak self] itemID, completedBytes, totalBytes in
      self?.activeDownloadProgress = (itemID, completedBytes, totalBytes)
      self?.render()
    }
    configureViews()
    layoutViews()
    render()
    service.start()
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

  deinit {
    importTask?.cancel()
    proofingServer?.stop()
    service.stop()
  }

  private func configureViews() {
    headerView.backgroundColor = .clear

    statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
    statusLabel.textColor = NativeLuxuryTheme.secondaryInk
    statusLabel.numberOfLines = 0

    deviceLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    deviceLabel.textColor = NativeLuxuryTheme.accent
    deviceLabel.numberOfLines = 1

    permissionButton.setTitle("允许访问外部相机", for: .normal)
    NativeLuxuryTheme.styleSecondaryButton(permissionButton)
    permissionButton.addTarget(self, action: #selector(permissionTapped), for: .touchUpInside)

    var selectAllConfig = UIButton.Configuration.tinted()
    selectAllConfig.cornerStyle = .capsule
    selectAllConfig.baseForegroundColor = NativeLuxuryTheme.ink
    selectAllConfig.image = UIImage(systemName: "checkmark.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
    selectAllConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    selectAllButton.configuration = selectAllConfig
    selectAllButton.addTarget(self, action: #selector(selectAllTapped), for: .touchUpInside)

    dateChips.configure(items: [
      .init(id: "all", title: "全部日期"),
      .init(id: "today", title: "今天"),
      .init(id: "pickDate", title: "选择日期"),
      .init(id: "dateRange", title: "时间范围"),
    ], selectedID: "all")
    formatChips.configure(items: [
      .init(id: "all", title: "全部格式"),
      .init(id: "jpg", title: "JPG"),
      .init(id: "heif", title: "HEIF"),
      .init(id: "raw", title: "RAW"),
      .init(id: "video", title: "视频"),
    ], selectedID: "all")
    statusChips.configure(items: [
      .init(id: "all", title: "全部状态"),
      .init(id: "notImported", title: "未导入"),
      .init(id: "imported", title: "已导入"),
      .init(id: "proofingFavorite", title: "客户收藏"),
    ], selectedID: "all")
    [dateChips, formatChips, statusChips].forEach {
      $0.useCompactStyle = true
      $0.onSelected = { [weak self] _ in self?.chipFilterChanged() }
    }

    collectionView.dataSource = self
    collectionView.delegate = self
    refreshControl.addTarget(self, action: #selector(refreshTapped), for: .valueChanged)
    collectionView.refreshControl = refreshControl
    collectionView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handleGridPinch(_:))))
    collectionView.register(WiredCameraImportGridCell.self, forCellWithReuseIdentifier: WiredCameraImportGridCell.reuseID)
    collectionView.register(
      WiredCameraImportSectionHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: WiredCameraImportSectionHeaderView.reuseID
    )

    NativeLuxuryTheme.applyFloatingPillStyle(bottomImportBar)
    bottomImportBar.isHidden = true

    bottomImportLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    bottomImportLabel.textColor = NativeLuxuryTheme.ink
    bottomImportLabel.numberOfLines = 1

    var importConfig = UIButton.Configuration.filled()
    importConfig.cornerStyle = .capsule
    importConfig.title = "导入"
    importConfig.baseBackgroundColor = NativeLuxuryTheme.ink
    importConfig.baseForegroundColor = NativeLuxuryTheme.cardBackground
    importConfig.image = UIImage(systemName: "square.and.arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
    importConfig.imagePadding = 6
    importConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
    importConfig.attributedTitle = AttributedString("导入", attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    importButton.configuration = importConfig
    importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)

    var deleteConfig = UIButton.Configuration.tinted()
    deleteConfig.cornerStyle = .capsule
    deleteConfig.title = "删除"
    deleteConfig.baseBackgroundColor = .systemRed
    deleteConfig.baseForegroundColor = .systemRed
    deleteConfig.image = UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
    deleteConfig.imagePadding = 5
    deleteConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    deleteButton.configuration = deleteConfig
    deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
  }

  private func layoutViews() {
    [headerView, collectionView, bottomImportBar, activityIndicator].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview($0)
    }

    [statusLabel, deviceLabel, permissionButton, dateChips, formatChips, statusChips].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      headerView.addSubview($0)
    }

    [selectAllButton, bottomImportLabel, deleteButton, importButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      bottomImportBar.addSubview($0)
    }

    NSLayoutConstraint.activate([
      headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
      headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      statusLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
      statusLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),

      deviceLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
      deviceLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
      deviceLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),

      permissionButton.topAnchor.constraint(equalTo: deviceLabel.bottomAnchor, constant: 10),
      permissionButton.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),

      dateChips.topAnchor.constraint(equalTo: permissionButton.bottomAnchor, constant: 10),
      dateChips.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
      dateChips.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),

      formatChips.topAnchor.constraint(equalTo: dateChips.bottomAnchor, constant: 8),
      formatChips.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
      formatChips.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),

      statusChips.topAnchor.constraint(equalTo: formatChips.bottomAnchor, constant: 8),
      statusChips.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
      statusChips.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
      statusChips.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -8),

      collectionView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 6),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      bottomImportBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
      bottomImportBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
      bottomImportBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
      bottomImportBar.heightAnchor.constraint(equalToConstant: 56),

      selectAllButton.leadingAnchor.constraint(equalTo: bottomImportBar.leadingAnchor, constant: 10),
      selectAllButton.centerYAnchor.constraint(equalTo: bottomImportBar.centerYAnchor),
      selectAllButton.widthAnchor.constraint(equalToConstant: 38),
      selectAllButton.heightAnchor.constraint(equalToConstant: 38),

      bottomImportLabel.leadingAnchor.constraint(equalTo: selectAllButton.trailingAnchor, constant: 6),
      bottomImportLabel.centerYAnchor.constraint(equalTo: bottomImportBar.centerYAnchor),
      bottomImportLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -10),

      deleteButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -8),
      deleteButton.centerYAnchor.constraint(equalTo: bottomImportBar.centerYAnchor),
      deleteButton.heightAnchor.constraint(equalToConstant: 38),

      importButton.trailingAnchor.constraint(equalTo: bottomImportBar.trailingAnchor, constant: -10),
      importButton.centerYAnchor.constraint(equalTo: bottomImportBar.centerYAnchor),
      importButton.heightAnchor.constraint(equalToConstant: 38),

      activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      activityIndicator.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
    ])
  }

  private func render() {
    let selectedCount = state.selectedImportableItems.count
    let proofingFavoriteCount = state.proofingFavoriteItemIDs.count
    let importableCount = state.importableItems.count
    let filteredItems = state.filteredItems()
    let filteredImportableCount = filteredItems.filter(\.isImportable).count
    gallerySections = WiredCameraImportSectionPolicy.sections(from: filteredItems)

    if state.isImporting {
      if let progress = activeDownloadProgress, progress.totalBytes > 0 {
        let percent = Int((Double(progress.completedBytes) / Double(progress.totalBytes) * 100).rounded())
        statusLabel.text = "正在导入 \(state.importedCount + 1)/\(max(currentImportTotal, 1)) · \(percent)% · 请保持相机连接"
      } else {
        statusLabel.text = "正在导入 \(state.importedCount + 1)/\(max(currentImportTotal, 1))，请保持相机连接"
      }
    } else if state.isLoadingItems {
      statusLabel.text = state.items.isEmpty ? "正在读取相机目录" : "正在刷新相机目录 · 已先显示缓存"
    } else if let errorMessage = state.errorMessage {
      statusLabel.text = errorMessage
    } else if state.devices.isEmpty {
      statusLabel.text = "请用数据线连接相机，并在相机上选择 USB / PC 连接或照片传输模式"
    } else if !state.isLiveCatalogReady && !state.items.isEmpty {
      statusLabel.text = "正在读取相机实时目录 · 当前显示缓存，目录完成后才能导入"
    } else if state.items.isEmpty {
      statusLabel.text = "已发现相机，等待照片目录返回"
    } else {
      let filterApplied = state.filterState != WiredCameraImportFilterState()
      let countText = filterApplied ? "\(filteredItems.count) / \(state.items.count) 个文件" : "\(state.items.count) 个文件"
      statusLabel.text = "\(countText) · 可导入 \(importableCount) 个 · 已导入 \(state.importedItemIDs.count) · 客户收藏 \(proofingFavoriteCount) · 已选 \(selectedCount)"
    }

    if let device = state.selectedDevice {
      deviceLabel.text = "\(device.name) · \(device.transportName)"
    } else {
      deviceLabel.text = "未发现有线相机"
    }

    activityIndicator.isHidden = !state.isLoadingItems && !state.isImporting && !isDeleting
    state.isLoadingItems || state.isImporting || isDeleting ? activityIndicator.startAnimating() : activityIndicator.stopAnimating()
    permissionButton.isHidden = !needsContentsAuthorization
    let filteredIDs = Set(filteredItems.filter(\.isImportable).map(\.id))
    let allFilteredSelected = !filteredIDs.isEmpty && filteredIDs.isSubset(of: state.selectedItemIDs)
    var selectAllConfig = selectAllButton.configuration
    selectAllConfig?.image = UIImage(systemName: allFilteredSelected ? "checkmark.circle.fill" : "checkmark.circle")
    selectAllButton.configuration = selectAllConfig
    selectAllButton.accessibilityLabel = allFilteredSelected ? "取消全选" : "全选当前筛选"
    selectAllButton.isEnabled = filteredImportableCount > 0 && !state.isImporting && !isDeleting
    importButton.isEnabled = selectedCount > 0 && !state.isImporting && !isDeleting
    importButton.alpha = importButton.isEnabled ? 1 : 0.55
    let deletableItem = WiredCameraDeletePolicy.selectedItem(from: state, isDeleting: isDeleting)
    deleteButton.isHidden = selectedCount != 1
    deleteButton.isEnabled = deletableItem != nil
    deleteButton.alpha = deleteButton.isEnabled ? 1 : 0.55
    collectionView.isUserInteractionEnabled = !isDeleting
    updateImportButtonTitle(selectedCount: selectedCount)
    bottomImportBar.isHidden = selectedCount == 0
    bottomImportLabel.text = "已选 \(selectedCount) 个文件"
    proofingSheet?.updateSelectedCount(proofingFavoriteCount)
    updateDateFilterChips()
    updateNavigationLock()
    collectionView.reloadData()
  }

  private func updateNavigationLock() {
    let canLeave = WiredCameraImportNavigationPolicy.canLeaveImportScreen(isImporting: state.isImporting)
    navigationItem.leftBarButtonItem?.isEnabled = true
    navigationController?.interactivePopGestureRecognizer?.isEnabled = canLeave
    isModalInPresentation = !canLeave
  }

  @objc private func disconnectTapped() {
    guard state.isImporting else {
      leaveImportScreen()
      return
    }
    let alert = UIAlertController(
      title: "断开并返回？",
      message: "正在导入照片。只有主动断开后才能返回首页，当前导入会停止。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "断开", style: .destructive) { [weak self] _ in
      guard let self else { return }
      self.importTask?.cancel()
      self.state.isImporting = false
      self.service.stop()
      self.leaveImportScreen()
    })
    present(alert, animated: true)
  }

  private func leaveImportScreen() {
    proofingServer?.stop()
    service.stop()
    if let navigationController {
      navigationController.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  @objc private func refreshTapped() {
    state.errorMessage = nil
    state.isLoadingItems = state.selectedDeviceID != nil
    render()
    service.start()
    if let selectedDeviceID = state.selectedDeviceID {
      service.openDevice(id: selectedDeviceID)
    }
    refreshControl.endRefreshing()
  }

  @objc private func permissionTapped() {
    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(settingsURL)
  }

  @objc private func selectAllTapped() {
    state.toggleAllFilteredImportable()
    render()
  }

  @objc private func chipFilterChanged() {
    if dateChips.selectedID == "pickDate" {
      presentSpecificDatePicker()
      return
    }
    if dateChips.selectedID == "dateRange" {
      presentRangeStartPicker()
      return
    }
    state.filterState = WiredCameraImportFilterState(
      date: wiredDateFilter(for: dateChips.selectedID),
      format: wiredFormatFilter(for: formatChips.selectedID),
      importedStatus: wiredStatusFilter(for: statusChips.selectedID)
    )
    render()
    requestThumbnailsForVisibleItems()
  }

  private func updateDateFilterChips() {
    switch state.filterState.date {
    case .all:
      dateChips.setSelected("all")
    case .today:
      dateChips.setSelected("today")
    case .specificDay(let day):
      dateChips.refreshTitle(forID: "pickDate", title: dateChipLabel(for: day))
    case .range(let start, let end):
      dateChips.refreshTitle(forID: "dateRange", title: dateRangeChipLabel(start: start, end: end))
    }
  }

  @objc private func importTapped() {
    importItems(state.selectedImportableItems, completionPrefix: "导入完成")
  }

  @objc private func deleteTapped() {
    guard let item = WiredCameraDeletePolicy.selectedItem(from: state, isDeleting: isDeleting) else { return }
    let alert = UIAlertController(
      title: "从相机删除这张照片？",
      message: "\(item.name) · \(item.fileSizeText)\n\n只删除相机存储卡中的文件，不删除已经导入手机的副本。请只选择刚刚新拍、可以丢弃的测试照片。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "删除相机照片", style: .destructive) { [weak self] _ in
      self?.performDelete(item)
    })
    present(alert, animated: true)
  }

  private func performDelete(_ item: WiredCameraImportItem) {
    guard WiredCameraDeletePolicy.selectedItem(from: state, isDeleting: isDeleting)?.id == item.id else { return }
    isDeleting = true
    state.errorMessage = "正在请求相机删除 \(item.name)"
    render()

    service.deleteFile(for: item.id) { [weak self] result in
      guard let self else { return }
      self.isDeleting = false
      switch result {
      case .success:
        self.state.errorMessage = "相机报告删除成功：\(item.name)"
      case .failure(let error):
        self.state.errorMessage = "删除失败：\(error.localizedDescription)"
      }
      self.render()
    }
  }

  @objc private func proofingTapped() {
    startLocalProofingSession()
  }

  private func importItems(_ items: [WiredCameraImportItem], completionPrefix: String) {
    guard !items.isEmpty, !state.isImporting else { return }

    state.isImporting = true
    state.importedCount = 0
    currentImportTotal = items.count
    activeDownloadProgress = nil
    render()

    importTask?.cancel()
    importTask = Task { [weak self] in
      guard let self else { return }
      do {
        for item in items {
          try Task.checkCancellation()
          await MainActor.run {
            self.activeDownloadProgress = nil
            self.render()
          }
          let file = try await self.service.downloadFile(for: item.id)
          try Task.checkCancellation()
          try await WiredCameraPhotoLibrarySaver.save(file: file)
          try Task.checkCancellation()
          await MainActor.run {
            self.state.importedCount += 1
            self.activeDownloadProgress = nil
            self.state.markImported(itemID: item.id)
            if let deviceID = self.state.selectedDeviceID {
              WiredCameraImportHistoryStore.markImported(itemID: item.id, for: deviceID)
            }
            self.saveCacheSnapshot()
            self.render()
          }
        }
        await MainActor.run {
          self.state.isImporting = false
          self.currentImportTotal = 0
          self.activeDownloadProgress = nil
          self.state.errorMessage = "\(completionPrefix)：已保存 \(self.state.importedCount) 个文件"
          self.render()
          self.attemptAutoImportIfNeeded()
        }
      } catch {
        await MainActor.run {
          guard !Task.isCancelled else { return }
          self.state.isImporting = false
          self.currentImportTotal = 0
          self.activeDownloadProgress = nil
          let message = "CamTransferWired import failed error=\(error)"
          print(message)
          CameraVendorFileLogger.log(message)
          self.state.errorMessage = "导入失败：\(error.localizedDescription)"
          self.render()
        }
      }
    }
  }

  private func attemptAutoImportIfNeeded() {
    guard state.isLiveCatalogReady, !state.isImporting else { return }
    let items = WiredCameraAutoImportPolicy.itemsToImport(from: state)
      .filter { !autoImportAttemptedItemIDs.contains($0.id) }
    guard !items.isEmpty else { return }
    autoImportAttemptedItemIDs.formUnion(items.map(\.id))
    importItems(items, completionPrefix: "自动导入完成")
  }

  private func visibleItems() -> [WiredCameraImportItem] {
    state.filteredItems()
  }

  private func startLocalProofingSession() {
    let items = visibleItems()
    guard !items.isEmpty else {
      presentProofingError("当前没有可展示的照片")
      return
    }

    proofingServer?.stop()
    let token = LocalProofingSessionToken.make()
    let router = LocalProofingRequestRouter(
      sessionToken: token,
      photosProvider: { [weak self] in
        self?.visibleItems().map(LocalProofingPhotoMapper.photo(from:)) ?? []
      },
      favoriteIDsProvider: { [weak self] in
        self?.state.proofingFavoriteItemIDs ?? []
      },
      previewProvider: { [weak self] itemID in
        self?.previewJPEGData(for: itemID)
      },
      favoriteHandler: { [weak self] update in
        DispatchQueue.main.async {
          self?.applyProofingFavoriteUpdate(update)
        }
      }
    )

    let server = LocalProofingServer(router: router)
    server.onStateChange = { [weak self] status in
      DispatchQueue.main.async {
        self?.proofingSheet?.updateConnectionStatus(status)
      }
    }
    server.onRequestReceived = { [weak self] status in
      DispatchQueue.main.async {
        self?.proofingSheet?.updateConnectionStatus(status)
      }
    }
    do {
      let url = try server.start()
      proofingServer = server
      let port = UInt16(url.port ?? 8080)
      let endpoints = LocalProofingNetwork.shareEndpoints(port: port, token: token)
      presentProofingSheet(endpoints: endpoints.isEmpty ? [
        LocalProofingShareEndpoint(
          interface: LocalProofingNetworkInterface(name: "local", address: url.host ?? ""),
          url: url
        )
      ] : endpoints, favoriteCount: state.proofingFavoriteItemIDs.count)
      verifyLocalProofingServer(url: url)
    } catch {
      proofingServer = nil
      presentProofingError("现场选片启动失败：\(error.localizedDescription)")
    }
  }

  private func verifyLocalProofingServer(url: URL) {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    components.path = "/health"
    guard let healthURL = components.url else { return }
    proofingSheet?.updateConnectionStatus("本机自检中")
    URLSession.shared.dataTask(with: healthURL) { [weak self] data, response, error in
      let status: String
      if let httpResponse = response as? HTTPURLResponse,
         httpResponse.statusCode == 200,
         data?.isEmpty == false {
        status = "本机自检通过，等待客户手机访问"
      } else if let error {
        status = "本机自检失败：\(error.localizedDescription)"
      } else {
        status = "本机自检失败：服务无响应"
      }
      DispatchQueue.main.async {
        self?.proofingSheet?.updateConnectionStatus(status)
      }
    }.resume()
  }

  private func previewJPEGData(for itemID: String) -> Data? {
    guard let item = state.items.first(where: { $0.id == itemID }) else { return nil }
    return LocalProofingPreviewEncoder.jpegData(from: item.thumbnail)
  }

  private func applyProofingFavoriteUpdate(_ update: LocalProofingFavoriteUpdate) {
    guard let item = state.items.first(where: { $0.id == update.id }) else { return }
    state.setProofingFavorite(update.favorite, itemID: item.id)
    render()
  }

  private func presentProofingSheet(endpoints: [LocalProofingShareEndpoint], favoriteCount: Int) {
    let controller = LocalProofingSessionViewController(
      endpoints: endpoints,
      selectedCount: favoriteCount,
      onStop: { [weak self] in
        self?.proofingServer?.stop()
        self?.proofingServer = nil
      }
    )
    proofingSheet = controller
    let nav = UINavigationController(rootViewController: controller)
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }

  private func presentProofingError(_ message: String) {
    let alert = UIAlertController(title: "现场选片", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "知道了", style: .default))
    present(alert, animated: true)
  }

  private func wiredDateFilter(for id: String?) -> WiredCameraImportDateFilter {
    id == "today" ? .today : .all
  }

  private func presentSpecificDatePicker() {
    let days = availableCaptureDays()
    guard !days.isEmpty else {
      presentSimpleAlert(title: "选择日期", message: "相机文件里没有可识别日期")
      updateDateFilterChips()
      return
    }
    let alert = UIAlertController(title: "选择日期", message: nil, preferredStyle: .actionSheet)
    days.forEach { day in
      alert.addAction(UIAlertAction(title: fullDateLabel(for: day), style: .default) { [weak self] _ in
        guard let self else { return }
        self.state.filterState.date = .specificDay(day)
        self.render()
        self.requestThumbnailsForVisibleItems()
      })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
      self?.updateDateFilterChips()
    })
    presentFilterSheet(alert)
  }

  private func presentRangeStartPicker() {
    let days = availableCaptureDays()
    guard !days.isEmpty else {
      presentSimpleAlert(title: "选择时间范围", message: "相机文件里没有可识别日期")
      updateDateFilterChips()
      return
    }
    let alert = UIAlertController(title: "选择开始日期", message: nil, preferredStyle: .actionSheet)
    days.forEach { day in
      alert.addAction(UIAlertAction(title: fullDateLabel(for: day), style: .default) { [weak self] _ in
        self?.presentRangeEndPicker(start: day)
      })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
      self?.updateDateFilterChips()
    })
    presentFilterSheet(alert)
  }

  private func presentRangeEndPicker(start: Date) {
    let alert = UIAlertController(title: "选择结束日期", message: "开始：\(fullDateLabel(for: start))", preferredStyle: .actionSheet)
    availableCaptureDays().forEach { day in
      alert.addAction(UIAlertAction(title: fullDateLabel(for: day), style: .default) { [weak self] _ in
        guard let self else { return }
        self.state.filterState.date = .range(start, day)
        self.render()
        self.requestThumbnailsForVisibleItems()
      })
    }
    alert.addAction(UIAlertAction(title: "只选这一天", style: .default) { [weak self] _ in
      guard let self else { return }
      self.state.filterState.date = .range(start, start)
      self.render()
      self.requestThumbnailsForVisibleItems()
    })
    alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
      self?.updateDateFilterChips()
    })
    presentFilterSheet(alert)
  }

  private func availableCaptureDays(calendar: Calendar = Calendar(identifier: .gregorian)) -> [Date] {
    let days = state.items.compactMap { item -> Date? in
      guard let createdAt = item.createdAt else { return nil }
      return calendar.startOfDay(for: createdAt)
    }
    return Array(Set(days)).sorted(by: >)
  }

  private func dateChipLabel(for day: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd"
    return formatter.string(from: day)
  }

  private func dateRangeChipLabel(start: Date, end: Date) -> String {
    "\(dateChipLabel(for: min(start, end)))~\(dateChipLabel(for: max(start, end)))"
  }

  private func fullDateLabel(for day: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: day)
  }

  private func presentFilterSheet(_ alert: UIAlertController) {
    if let popover = alert.popoverPresentationController {
      popover.sourceView = dateChips
      popover.sourceRect = dateChips.bounds
    }
    present(alert, animated: true)
  }

  private func presentSimpleAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "知道了", style: .default))
    present(alert, animated: true)
  }

  private func wiredFormatFilter(for id: String?) -> WiredCameraImportFormatFilter {
    switch id {
    case "jpg":
      return .jpg
    case "heif":
      return .heif
    case "raw":
      return .raw
    case "video":
      return .video
    default:
      return .all
    }
  }

  private func wiredStatusFilter(for id: String?) -> WiredCameraImportStatusFilter {
    switch id {
    case "notImported":
      return .notImported
    case "imported":
      return .imported
    case "proofingFavorite":
      return .proofingFavorite
    default:
      return .all
    }
  }

  private func updateImportButtonTitle(selectedCount: Int) {
    var config = importButton.configuration
    let title = selectedCount > 0 ? "导入 \(selectedCount)" : "导入"
    config?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 12, weight: .bold)
    ]))
    importButton.configuration = config
  }

  private func loadCachedContent(for device: WiredCameraImportDevice) {
    if let snapshot = try? cacheStore.load(deviceID: device.id) {
      state.applyCache(snapshot)
    }
    state.importedItemIDs.formUnion(WiredCameraImportHistoryStore.importedItemIDs(for: device.id))
    mergeCachedThumbnailsForSelectedDevice()
  }

  private func mergeCachedThumbnailsForSelectedDevice() {
    guard let deviceID = state.selectedDeviceID else { return }
    for index in state.items.indices where state.items[index].thumbnail == nil {
      state.items[index].thumbnail = thumbnailCacheStore.loadThumbnail(deviceID: deviceID, itemID: state.items[index].id)
    }
  }

  private func saveCacheSnapshot() {
    guard let device = state.selectedDevice else { return }
    let snapshot = WiredCameraImportCacheSnapshot(
      device: device,
      items: state.items,
      importedItemIDs: state.importedItemIDs,
      cachedAt: Date()
    )
    try? cacheStore.save(snapshot)
  }

  private func requestThumbnailsForVisibleItems() {
    guard state.isLiveCatalogReady else { return }
    let items = visibleItems()
    let orderedIDs = items.map(\.id)
    let visibleIDs = collectionView.indexPathsForVisibleItems
      .sorted()
      .compactMap { item(at: $0)?.id }
    let initialWindow = Array(items.prefix(max(currentColumnCount * 3, 1)).map(\.id))
    let priorityIDs = WiredCameraThumbnailRequestWindowPolicy.itemIDsToRequest(
      orderedItemIDs: orderedIDs,
      visibleItemIDs: visibleIDs.isEmpty ? initialWindow : visibleIDs,
      columnCount: currentColumnCount
    )
    let missingThumbnailIDs = Set(items.filter { $0.thumbnail == nil }.map(\.id))
    service.requestThumbnails(in: priorityIDs.filter { missingThumbnailIDs.contains($0) })
  }

  @objc private func handleGridPinch(_ pinch: UIPinchGestureRecognizer) {
    guard pinch.state == .changed else { return }
    if pinch.scale > 1.45 {
      changeGridColumnCount(by: -1)
      pinch.scale = 1
    } else if pinch.scale < 0.7 {
      changeGridColumnCount(by: 1)
      pinch.scale = 1
    }
  }

  private func changeGridColumnCount(by delta: Int) {
    let next = NativeGalleryGridLayoutPolicy.clampedColumnCount(currentColumnCount + delta)
    guard next != currentColumnCount else { return }
    currentColumnCount = next
    UserDefaults.standard.set(next, forKey: "camtransfer.wiredGalleryColumnCount")
    collectionView.collectionViewLayout.invalidateLayout()
    requestThumbnailsForVisibleItems()
  }

  private func indexPathForVisibleItemID(_ itemID: String) -> IndexPath? {
    for sectionIndex in gallerySections.indices {
      guard let itemIndex = gallerySections[sectionIndex].items.firstIndex(where: { $0.id == itemID }) else {
        continue
      }
      return IndexPath(item: itemIndex, section: sectionIndex)
    }
    return nil
  }

  private func item(at indexPath: IndexPath) -> WiredCameraImportItem? {
    guard gallerySections.indices.contains(indexPath.section),
          gallerySections[indexPath.section].items.indices.contains(indexPath.item) else {
      return nil
    }
    return gallerySections[indexPath.section].items[indexPath.item]
  }

  private func presentPreview(startingAt index: Int) {
    guard WiredCameraImportNavigationPolicy.canOpenPreview(isImporting: state.isImporting) else {
      state.errorMessage = "正在导入，请先保持在照片筛选页面"
      render()
      return
    }
    let items = visibleItems()
    guard items.indices.contains(index) else { return }
    let controller = WiredCameraPhotoPreviewViewController(
      items: items,
      initialIndex: index,
      isImported: { [weak self] item in
        self?.state.importedItemIDs.contains(item.id) == true
      },
      canImport: { [weak self] item in
        guard let self else { return false }
        return self.state.isLiveCatalogReady && !self.state.isImporting && item.isImportable && !self.state.importedItemIDs.contains(item.id)
      },
      previewProvider: { [weak self] item in
        guard let self else {
          throw NSError(
            domain: "WiredCameraImportViewController.Preview",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "预览页面已关闭"]
          )
        }
        return try await self.service.requestPreview(for: item.id)
      },
      onImport: { [weak self] item in
        guard let self else { return }
        self.importItems([item], completionPrefix: "单张导入完成")
        self.dismiss(animated: true)
      }
    )
    let nav = UINavigationController(rootViewController: controller)
    nav.modalPresentationStyle = .fullScreen
    present(nav, animated: true)
  }

}

extension WiredCameraImportViewController: WiredCameraImportServiceDelegate {
  func wiredCameraImportServiceDidUpdateAuthorization(_ service: WiredCameraImportService, isAuthorized: Bool) {
    needsContentsAuthorization = !isAuthorized
    if !isAuthorized {
      state.errorMessage = "需要允许访问外部相机，才能读取连接线里的照片"
    }
    render()
  }

  func wiredCameraImportServiceDidUpdateDevices(_ service: WiredCameraImportService, devices: [WiredCameraImportDevice]) {
    let previousDeviceID = state.selectedDeviceID
    state.replaceDevices(devices)
    if previousDeviceID != state.selectedDeviceID, let device = state.selectedDevice {
      loadCachedContent(for: device)
    }
    render()
    if previousDeviceID != state.selectedDeviceID, let selectedDeviceID = state.selectedDeviceID {
      state.isLoadingItems = true
      render()
      service.openDevice(id: selectedDeviceID)
    }
  }

  func wiredCameraImportServiceDidStartLoadingItems(_ service: WiredCameraImportService) {
    state.isLoadingItems = true
    state.errorMessage = nil
    render()
  }

  func wiredCameraImportService(_ service: WiredCameraImportService, didUpdateItems items: [WiredCameraImportItem]) {
    state.isLoadingItems = false
    state.errorMessage = nil
    if let deviceID = state.selectedDeviceID {
      state.importedItemIDs.formUnion(WiredCameraImportHistoryStore.importedItemIDs(for: deviceID))
    }
    state.replaceItems(items)
    mergeCachedThumbnailsForSelectedDevice()
    saveCacheSnapshot()
    render()
    DispatchQueue.main.async { [weak self] in
      self?.requestThumbnailsForVisibleItems()
    }
    attemptAutoImportIfNeeded()
  }

  func wiredCameraImportService(_ service: WiredCameraImportService, didUpdateThumbnailFor itemID: String, thumbnail: UIImage) {
    guard let index = state.items.firstIndex(where: { $0.id == itemID }) else { return }
    state.items[index].thumbnail = thumbnail
    if let deviceID = state.selectedDeviceID {
      thumbnailCacheStore.saveThumbnail(thumbnail, deviceID: deviceID, itemID: itemID)
    }
    saveCacheSnapshot()
    if let indexPath = indexPathForVisibleItemID(itemID),
       let cell = collectionView.cellForItem(at: indexPath) as? WiredCameraImportGridCell {
      cell.setThumbnail(thumbnail)
    }
  }

  func wiredCameraImportService(_ service: WiredCameraImportService, didFailWith message: String) {
    state.isLoadingItems = false
    state.isImporting = false
    state.errorMessage = message
    render()
  }
}

extension WiredCameraImportViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  func numberOfSections(in collectionView: UICollectionView) -> Int {
    gallerySections.count
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
      withReuseIdentifier: WiredCameraImportGridCell.reuseID,
      for: indexPath
    ) as? WiredCameraImportGridCell else {
      return UICollectionViewCell()
    }
    guard let item = item(at: indexPath) else { return UICollectionViewCell() }
    cell.configure(
      item: item,
      isSelectedForImport: state.selectedItemIDs.contains(item.id),
      isImported: state.importedItemIDs.contains(item.id),
      isProofingFavorite: state.proofingFavoriteItemIDs.contains(item.id),
      isLiveCatalogReady: state.isLiveCatalogReady
    )
    cell.onSelectionTapped = { [weak self] in
      self?.state.toggleSelection(for: item)
      self?.render()
    }
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    viewForSupplementaryElementOfKind kind: String,
    at indexPath: IndexPath
  ) -> UICollectionReusableView {
    guard kind == UICollectionView.elementKindSectionHeader,
          gallerySections.indices.contains(indexPath.section),
          let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: WiredCameraImportSectionHeaderView.reuseID,
            for: indexPath
          ) as? WiredCameraImportSectionHeaderView else {
      return UICollectionReusableView()
    }
    header.configure(title: gallerySections[indexPath.section].title)
    return header
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard WiredCameraImportNavigationPolicy.canOpenPreview(isImporting: state.isImporting) else {
      state.errorMessage = "正在导入，请先保持在照片筛选页面"
      render()
      return
    }
    guard let item = item(at: indexPath),
          let flatIndex = visibleItems().firstIndex(where: { $0.id == item.id }) else {
      return
    }
    presentPreview(startingAt: flatIndex)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    requestThumbnailsForVisibleItems()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    requestThumbnailsForVisibleItems()
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let side = NativeGalleryGridLayoutPolicy.itemSide(
      forCollectionWidth: collectionView.bounds.width,
      horizontalInset: 12,
      interItemSpacing: 8,
      columns: currentColumnCount
    )
    return CGSize(width: side, height: side)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    insetForSectionAt section: Int
  ) -> UIEdgeInsets {
    let bottom: CGFloat = section == gallerySections.count - 1 ? 88 : 8
    return UIEdgeInsets(top: 0, left: 12, bottom: bottom, right: 12)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    referenceSizeForHeaderInSection section: Int
  ) -> CGSize {
    guard gallerySections.indices.contains(section) else { return .zero }
    return CGSize(width: collectionView.bounds.width, height: 38)
  }
}

private final class WiredCameraImportSectionHeaderView: UICollectionReusableView {
  static let reuseID = "WiredCameraImportSectionHeaderView"

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 15, weight: .black)
    label.textColor = NativeLuxuryTheme.ink
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(titleLabel)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title: String) {
    titleLabel.text = title
  }
}

private final class WiredCameraImportGridCell: UICollectionViewCell {
  static let reuseID = "WiredCameraImportGridCell"

  var onSelectionTapped: (() -> Void)?

  private let imageView = UIImageView()
  private let selectionButton = UIButton(type: .system)
  private let formatBadgeLabel = UILabel()
  private let statusBadgeLabel = UILabel()
  private let infoBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let titleLabel = UILabel()
  private let detailLabel = UILabel()

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
    selectionButton.isHidden = false
    selectionButton.isEnabled = true
    statusBadgeLabel.isHidden = true
    statusBadgeLabel.text = nil
    formatBadgeLabel.text = nil
    titleLabel.text = nil
    detailLabel.text = nil
    onSelectionTapped = nil
  }

  func configure(
    item: WiredCameraImportItem,
    isSelectedForImport: Bool,
    isImported: Bool,
    isProofingFavorite: Bool,
    isLiveCatalogReady: Bool
  ) {
    if let thumbnail = item.thumbnail {
      imageView.image = thumbnail
      imageView.tintColor = NativeLuxuryTheme.cardBackground
      imageView.contentMode = .scaleAspectFill
    } else {
      let symbolName = WiredCameraImportPolicy.mediaType(filename: item.name, uti: item.uti) == .video ? "video" : "photo"
      imageView.image = UIImage(systemName: symbolName)
      imageView.tintColor = NativeLuxuryTheme.secondaryInk.withAlphaComponent(0.45)
      imageView.contentMode = .center
    }
    imageView.alpha = item.isImportable ? 1 : 0.45
    titleLabel.text = item.name
    detailLabel.text = item.fileSizeText
    formatBadgeLabel.text = " \(item.formatLabel) "
    selectionButton.isHidden = !isLiveCatalogReady || !item.isImportable || isImported
    selectionButton.isEnabled = isLiveCatalogReady && item.isImportable && !isImported
    updateSelection(isSelectedForImport)
    if isProofingFavorite {
      statusBadgeLabel.text = " 客户收藏 "
      statusBadgeLabel.isHidden = false
    } else if !isLiveCatalogReady {
      statusBadgeLabel.text = " 缓存 "
      statusBadgeLabel.isHidden = false
    } else if isImported {
      statusBadgeLabel.text = " 已导入 "
      statusBadgeLabel.isHidden = false
    } else if !item.isImportable {
      statusBadgeLabel.text = " 不支持 "
      statusBadgeLabel.isHidden = false
    } else {
      statusBadgeLabel.isHidden = true
    }
  }

  func setThumbnail(_ image: UIImage) {
    imageView.image = image
    imageView.contentMode = .scaleAspectFill
  }

  private func setup() {
    contentView.backgroundColor = UIColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 1)
    contentView.layer.cornerRadius = 16
    contentView.clipsToBounds = true

    [imageView, selectionButton, formatBadgeLabel, statusBadgeLabel, infoBar].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview($0)
    }
    [titleLabel, detailLabel].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      infoBar.contentView.addSubview($0)
    }

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true

    selectionButton.tintColor = NativeLuxuryTheme.cardBackground
    selectionButton.backgroundColor = UIColor.white.withAlphaComponent(0.72)
    selectionButton.layer.cornerRadius = 13
    selectionButton.layer.borderWidth = 1.5
    selectionButton.layer.borderColor = NativeLuxuryTheme.cardBackground.withAlphaComponent(0.7).cgColor
    selectionButton.accessibilityLabel = "选择照片"
    selectionButton.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)

    formatBadgeLabel.font = .systemFont(ofSize: 7, weight: .heavy)
    formatBadgeLabel.textColor = NativeLuxuryTheme.ink
    formatBadgeLabel.textAlignment = .center
    formatBadgeLabel.backgroundColor = UIColor.white.withAlphaComponent(0.86)
    formatBadgeLabel.layer.cornerRadius = 5
    formatBadgeLabel.clipsToBounds = true

    statusBadgeLabel.font = .systemFont(ofSize: 7.5, weight: .heavy)
    statusBadgeLabel.textColor = NativeLuxuryTheme.cardBackground
    statusBadgeLabel.textAlignment = .center
    statusBadgeLabel.backgroundColor = NativeLuxuryTheme.ink.withAlphaComponent(0.78)
    statusBadgeLabel.layer.cornerRadius = 6
    statusBadgeLabel.clipsToBounds = true

    titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
    titleLabel.textColor = .white
    titleLabel.lineBreakMode = .byTruncatingMiddle

    detailLabel.font = .systemFont(ofSize: 9, weight: .medium)
    detailLabel.textColor = UIColor.white.withAlphaComponent(0.86)
    detailLabel.lineBreakMode = .byTruncatingTail

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      selectionButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
      selectionButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 7),
      selectionButton.widthAnchor.constraint(equalToConstant: 26),
      selectionButton.heightAnchor.constraint(equalToConstant: 26),

      statusBadgeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
      statusBadgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
      statusBadgeLabel.heightAnchor.constraint(equalToConstant: 14),
      statusBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),

      formatBadgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
      formatBadgeLabel.bottomAnchor.constraint(equalTo: infoBar.topAnchor, constant: -5),
      formatBadgeLabel.heightAnchor.constraint(equalToConstant: 12),
      formatBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),

      infoBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      infoBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      infoBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      titleLabel.topAnchor.constraint(equalTo: infoBar.contentView.topAnchor, constant: 5),
      titleLabel.leadingAnchor.constraint(equalTo: infoBar.contentView.leadingAnchor, constant: 7),
      titleLabel.trailingAnchor.constraint(equalTo: infoBar.contentView.trailingAnchor, constant: -7),

      detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
      detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      detailLabel.bottomAnchor.constraint(equalTo: infoBar.contentView.bottomAnchor, constant: -5),
    ])
  }

  private func updateSelection(_ isSelected: Bool) {
    if isSelected {
      selectionButton.setImage(UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .heavy)), for: .normal)
      selectionButton.tintColor = NativeLuxuryTheme.cardBackground
      selectionButton.backgroundColor = NativeLuxuryTheme.ink
      selectionButton.layer.borderWidth = 0
    } else {
      selectionButton.setImage(nil, for: .normal)
      selectionButton.backgroundColor = UIColor.white.withAlphaComponent(0.72)
      selectionButton.layer.borderWidth = 1.5
      selectionButton.layer.borderColor = NativeLuxuryTheme.cardBackground.withAlphaComponent(0.7).cgColor
    }
  }

  @objc private func selectionTapped() {
    onSelectionTapped?()
  }
}

private final class LocalProofingSessionViewController: UIViewController {
  private let endpoints: [LocalProofingShareEndpoint]
  private let onStop: () -> Void
  private var selectedEndpointIndex = 0
  private let endpointControl = UISegmentedControl()
  private let qrImageView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let urlLabel = UILabel()
  private let connectionStatusLabel = UILabel()
  private let selectedLabel = UILabel()
  private let copyButton = UIButton(type: .system)

  init(endpoints: [LocalProofingShareEndpoint], selectedCount: Int, onStop: @escaping () -> Void) {
    self.endpoints = endpoints
    self.onStop = onStop
    super.init(nibName: nil, bundle: nil)
    updateSelectedCount(selectedCount)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "现场选片"
    view.backgroundColor = NativeLuxuryTheme.background
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "停止",
      style: .done,
      target: self,
      action: #selector(stopTapped)
    )
    configureViews()
    layoutViews()
  }

  func updateSelectedCount(_ count: Int) {
    selectedLabel.text = "客户已收藏 \(count) 张"
  }

  private func configureViews() {
    endpoints.enumerated().forEach { index, endpoint in
      endpointControl.insertSegment(withTitle: endpoint.label, at: index, animated: false)
    }
    endpointControl.selectedSegmentIndex = selectedEndpointIndex
    endpointControl.isHidden = endpoints.count <= 1
    endpointControl.addTarget(self, action: #selector(endpointChanged), for: .valueChanged)

    qrImageView.contentMode = .scaleAspectFit
    qrImageView.backgroundColor = .white
    qrImageView.layer.cornerRadius = 8
    qrImageView.layer.masksToBounds = true

    titleLabel.text = "扫码打开选片墙"
    titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
    titleLabel.textColor = NativeLuxuryTheme.ink
    titleLabel.textAlignment = .center

    subtitleLabel.font = .systemFont(ofSize: 14, weight: .medium)
    subtitleLabel.textColor = NativeLuxuryTheme.secondaryInk
    subtitleLabel.textAlignment = .center
    subtitleLabel.numberOfLines = 0

    urlLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    urlLabel.textColor = NativeLuxuryTheme.secondaryInk
    urlLabel.numberOfLines = 2
    urlLabel.textAlignment = .center

    connectionStatusLabel.text = "服务启动中"
    connectionStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    connectionStatusLabel.textColor = NativeLuxuryTheme.secondaryInk
    connectionStatusLabel.numberOfLines = 2
    connectionStatusLabel.textAlignment = .center

    selectedLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    selectedLabel.textColor = NativeLuxuryTheme.accent
    selectedLabel.textAlignment = .center

    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.title = "复制链接"
    config.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
    config.imagePadding = 8
    config.baseBackgroundColor = NativeLuxuryTheme.ink
    config.baseForegroundColor = NativeLuxuryTheme.cardBackground
    copyButton.configuration = config
    copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

    updateDisplayedEndpoint()
  }

  private func layoutViews() {
    [endpointControl, qrImageView, titleLabel, subtitleLabel, urlLabel, connectionStatusLabel, selectedLabel, copyButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview($0)
    }

    NSLayoutConstraint.activate([
      endpointControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
      endpointControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      endpointControl.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      endpointControl.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

      qrImageView.topAnchor.constraint(equalTo: endpointControl.bottomAnchor, constant: 16),
      qrImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      qrImageView.widthAnchor.constraint(equalToConstant: 260),
      qrImageView.heightAnchor.constraint(equalTo: qrImageView.widthAnchor),

      titleLabel.topAnchor.constraint(equalTo: qrImageView.bottomAnchor, constant: 22),
      titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      urlLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
      urlLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      urlLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      connectionStatusLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 14),
      connectionStatusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      connectionStatusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      selectedLabel.topAnchor.constraint(equalTo: connectionStatusLabel.bottomAnchor, constant: 18),
      selectedLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      selectedLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      copyButton.topAnchor.constraint(equalTo: selectedLabel.bottomAnchor, constant: 18),
      copyButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      copyButton.heightAnchor.constraint(equalToConstant: 44),
      copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
    ])
  }

  @objc private func copyTapped() {
    UIPasteboard.general.string = currentEndpoint.url.absoluteString
    copyButton.configuration?.title = "已复制"
  }

  @objc private func endpointChanged() {
    selectedEndpointIndex = max(0, endpointControl.selectedSegmentIndex)
    copyButton.configuration?.title = "复制链接"
    updateDisplayedEndpoint()
  }

  private var currentEndpoint: LocalProofingShareEndpoint {
    endpoints[min(selectedEndpointIndex, endpoints.count - 1)]
  }

  private func updateDisplayedEndpoint() {
    let endpoint = currentEndpoint
    qrImageView.image = LocalProofingQRCode.image(for: endpoint.url.absoluteString, scale: 12)
    subtitleLabel.text = endpoint.hint
    urlLabel.text = endpoint.url.absoluteString
  }

  func updateConnectionStatus(_ status: String) {
    connectionStatusLabel.text = status
  }

  @objc private func stopTapped() {
    onStop()
    dismiss(animated: true)
  }
}

private final class WiredCameraPhotoPreviewViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
  private let items: [WiredCameraImportItem]
  private let isImported: (WiredCameraImportItem) -> Bool
  private let canImport: (WiredCameraImportItem) -> Bool
  private let previewProvider: (WiredCameraImportItem) async throws -> UIImage
  private let onImport: (WiredCameraImportItem) -> Void
  private var currentIndex: Int
  private var pageController: UIPageViewController!

  private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let closeButton = UIButton(type: .system)
  private let rotateButton = UIButton(type: .system)
  private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let importButton = UIButton(type: .system)

  init(
    items: [WiredCameraImportItem],
    initialIndex: Int,
    isImported: @escaping (WiredCameraImportItem) -> Bool,
    canImport: @escaping (WiredCameraImportItem) -> Bool,
    previewProvider: @escaping (WiredCameraImportItem) async throws -> UIImage,
    onImport: @escaping (WiredCameraImportItem) -> Void
  ) {
    self.items = items
    self.currentIndex = min(max(initialIndex, 0), max(items.count - 1, 0))
    self.isImported = isImported
    self.canImport = canImport
    self.previewProvider = previewProvider
    self.onImport = onImport
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = .black
    setup()
    refreshChrome()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: animated)
  }

  private func setup() {
    pageController = UIPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: .horizontal,
      options: [UIPageViewController.OptionsKey.interPageSpacing: 18]
    )
    pageController.dataSource = self
    pageController.delegate = self
    addChild(pageController)
    view.addSubview(pageController.view)
    pageController.view.translatesAutoresizingMaskIntoConstraints = false
    pageController.didMove(toParent: self)

    if items.indices.contains(currentIndex) {
      pageController.setViewControllers([makePage(for: currentIndex)], direction: .forward, animated: false)
    }

    [topBar, bottomBar].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview($0)
    }
    [closeButton, rotateButton, titleLabel, subtitleLabel].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      topBar.contentView.addSubview($0)
    }
    importButton.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.contentView.addSubview(importButton)

    closeButton.tintColor = .white
    closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
    closeButton.accessibilityLabel = "关闭"
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    rotateButton.tintColor = .white
    rotateButton.setImage(UIImage(systemName: "rotate.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
    rotateButton.accessibilityLabel = "旋转照片"
    rotateButton.addTarget(self, action: #selector(rotateTapped), for: .touchUpInside)

    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.textColor = .white
    titleLabel.textAlignment = .center
    titleLabel.lineBreakMode = .byTruncatingMiddle

    subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
    subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
    subtitleLabel.textAlignment = .center

    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.image = UIImage(systemName: "square.and.arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
    config.imagePadding = 6
    config.baseBackgroundColor = .white
    config.baseForegroundColor = NativeLuxuryTheme.ink
    config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
    importButton.configuration = config
    importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)

    NSLayoutConstraint.activate([
      pageController.view.topAnchor.constraint(equalTo: view.topAnchor),
      pageController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pageController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pageController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      topBar.topAnchor.constraint(equalTo: view.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 54),

      closeButton.leadingAnchor.constraint(equalTo: topBar.contentView.leadingAnchor, constant: 14),
      closeButton.bottomAnchor.constraint(equalTo: topBar.contentView.bottomAnchor, constant: -9),
      closeButton.widthAnchor.constraint(equalToConstant: 38),
      closeButton.heightAnchor.constraint(equalToConstant: 38),

      titleLabel.centerXAnchor.constraint(equalTo: topBar.contentView.centerXAnchor),
      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rotateButton.leadingAnchor, constant: -8),
      titleLabel.bottomAnchor.constraint(equalTo: subtitleLabel.topAnchor, constant: -2),

      subtitleLabel.centerXAnchor.constraint(equalTo: topBar.contentView.centerXAnchor),
      subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
      subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rotateButton.leadingAnchor, constant: -8),
      subtitleLabel.bottomAnchor.constraint(equalTo: topBar.contentView.bottomAnchor, constant: -10),

      rotateButton.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -14),
      rotateButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      rotateButton.widthAnchor.constraint(equalToConstant: 38),
      rotateButton.heightAnchor.constraint(equalToConstant: 38),

      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bottomBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -66),

      importButton.centerXAnchor.constraint(equalTo: bottomBar.contentView.centerXAnchor),
      importButton.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor, constant: 12),
    ])
  }

  private func makePage(for index: Int) -> WiredCameraPhotoPreviewPageController {
    WiredCameraPhotoPreviewPageController(
      item: items[index],
      index: index,
      previewProvider: previewProvider
    )
  }

  private func refreshChrome() {
    guard items.indices.contains(currentIndex) else { return }
    let item = items[currentIndex]
    titleLabel.text = item.name
    subtitleLabel.text = "\(currentIndex + 1) / \(items.count) · \(item.formatLabel) · \(item.fileSizeText)"
    let title: String
    let enabled: Bool
    if isImported(item) {
      title = "已导入"
      enabled = false
    } else if canImport(item) {
      title = "导入这一张"
      enabled = true
    } else {
      title = "暂不能导入"
      enabled = false
    }
    importButton.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([
      .font: UIFont.systemFont(ofSize: 13, weight: .bold)
    ]))
    importButton.isEnabled = enabled
    importButton.alpha = enabled ? 1 : 0.58
  }

  @objc private func closeTapped() {
    navigationController?.dismiss(animated: true) ?? dismiss(animated: true)
  }

  @objc private func rotateTapped() {
    guard let page = pageController.viewControllers?.first as? WiredCameraPhotoPreviewPageController else { return }
    page.rotateClockwise()
  }

  @objc private func importTapped() {
    guard items.indices.contains(currentIndex) else { return }
    let item = items[currentIndex]
    guard canImport(item) else { return }
    onImport(item)
    refreshChrome()
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerBefore viewController: UIViewController
  ) -> UIViewController? {
    guard let page = viewController as? WiredCameraPhotoPreviewPageController else { return nil }
    let previous = page.index - 1
    guard items.indices.contains(previous) else { return nil }
    return makePage(for: previous)
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerAfter viewController: UIViewController
  ) -> UIViewController? {
    guard let page = viewController as? WiredCameraPhotoPreviewPageController else { return nil }
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
          let page = pageController.viewControllers?.first as? WiredCameraPhotoPreviewPageController else { return }
    currentIndex = page.index
    refreshChrome()
  }
}

private final class WiredCameraPhotoPreviewPageController: UIViewController, UIScrollViewDelegate {
  let item: WiredCameraImportItem
  let index: Int

  private let scrollView = UIScrollView()
  private let imageView = UIImageView()
  private let placeholderView = UIImageView(image: UIImage(systemName: "photo"))
  private let previewActivityIndicator = UIActivityIndicatorView(style: .medium)
  private let previewStatusLabel = UILabel()
  private let previewProvider: (WiredCameraImportItem) async throws -> UIImage
  private var imageWidthConstraint: NSLayoutConstraint?
  private var imageHeightConstraint: NSLayoutConstraint?
  private var sourceImage: UIImage?
  private var manualRotationDegrees = 0
  private var didRequestPreview = false

  init(
    item: WiredCameraImportItem,
    index: Int,
    previewProvider: @escaping (WiredCameraImportItem) async throws -> UIImage
  ) {
    self.item = item
    self.index = index
    self.previewProvider = previewProvider
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 5
    scrollView.bouncesZoom = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.delegate = self

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true

    placeholderView.translatesAutoresizingMaskIntoConstraints = false
    placeholderView.tintColor = UIColor.white.withAlphaComponent(0.2)
    placeholderView.contentMode = .center

    previewActivityIndicator.translatesAutoresizingMaskIntoConstraints = false
    previewActivityIndicator.color = UIColor.white.withAlphaComponent(0.86)
    previewActivityIndicator.hidesWhenStopped = true

    previewStatusLabel.translatesAutoresizingMaskIntoConstraints = false
    previewStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    previewStatusLabel.textColor = UIColor.white.withAlphaComponent(0.78)
    previewStatusLabel.textAlignment = .center
    previewStatusLabel.numberOfLines = 2
    previewStatusLabel.isHidden = true

    view.addSubview(placeholderView)
    view.addSubview(scrollView)
    scrollView.addSubview(imageView)
    view.addSubview(previewActivityIndicator)
    view.addSubview(previewStatusLabel)

    let widthConstraint = imageView.widthAnchor.constraint(equalToConstant: 0)
    let heightConstraint = imageView.heightAnchor.constraint(equalToConstant: 0)
    imageWidthConstraint = widthConstraint
    imageHeightConstraint = heightConstraint

    NSLayoutConstraint.activate([
      placeholderView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      placeholderView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      placeholderView.widthAnchor.constraint(equalToConstant: 72),
      placeholderView.heightAnchor.constraint(equalToConstant: 72),

      previewActivityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      previewActivityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 54),

      previewStatusLabel.topAnchor.constraint(equalTo: previewActivityIndicator.bottomAnchor, constant: 8),
      previewStatusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      previewStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      previewStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      widthConstraint,
      heightConstraint,
    ])

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)

    if let thumbnail = item.thumbnail {
      setSourceImage(thumbnail)
    } else {
      placeholderView.isHidden = false
      imageView.image = UIImage(systemName: WiredCameraImportPolicy.mediaType(filename: item.name, uti: item.uti) == .video ? "video" : "photo")
      imageView.tintColor = UIColor.white.withAlphaComponent(0.22)
      imageView.contentMode = .center
      imageWidthConstraint?.constant = 96
      imageHeightConstraint?.constant = 96
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    requestLargerPreviewIfNeeded()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    if let image = imageView.image, sourceImage != nil {
      layout(image: image)
    } else {
      centerImage()
    }
  }

  func rotateClockwise() {
    guard sourceImage != nil else { return }
    manualRotationDegrees = NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(manualRotationDegrees)
    renderSourceImage()
  }

  private func setSourceImage(_ image: UIImage) {
    sourceImage = image
    renderSourceImage()
  }

  private func requestLargerPreviewIfNeeded() {
    guard !didRequestPreview else { return }
    didRequestPreview = true
    previewStatusLabel.text = "正在读取高清预览"
    previewStatusLabel.isHidden = false
    previewActivityIndicator.startAnimating()

    Task { [weak self] in
      guard let self else { return }
      do {
        let image = try await previewProvider(item)
        guard !Task.isCancelled else { return }
        setSourceImage(image)
        previewActivityIndicator.stopAnimating()
        previewStatusLabel.isHidden = true
      } catch {
        guard !Task.isCancelled else { return }
        previewActivityIndicator.stopAnimating()
        previewStatusLabel.text = "相机未提供高清预览，当前显示缩略图"
        previewStatusLabel.isHidden = false
      }
    }
  }

  private func renderSourceImage() {
    guard let sourceImage else { return }
    let image = NativePhotoPreviewImageRenderer.rendered(
      image: sourceImage,
      manualRotationDegrees: manualRotationDegrees
    )
    imageView.image = image
    imageView.contentMode = .scaleAspectFit
    placeholderView.isHidden = true
    layout(image: image)
  }

  private func layout(image: UIImage) {
    let bounds = view.bounds.size
    guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }
    let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
    imageWidthConstraint?.constant = image.size.width * scale
    imageHeightConstraint?.constant = image.size.height * scale
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
      let zoom: CGFloat = 2.6
      let location = gesture.location(in: imageView)
      let size = CGSize(width: scrollView.bounds.width / zoom, height: scrollView.bounds.height / zoom)
      let rect = CGRect(x: location.x - size.width / 2, y: location.y - size.height / 2, width: size.width, height: size.height)
      scrollView.zoom(to: rect, animated: true)
    }
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    imageView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerImage()
  }
}

private enum WiredCameraPhotoLibrarySaver {
  static func save(file: WiredCameraDownloadedFile) async throws {
    let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    let status: PHAuthorizationStatus
    if current == .notDetermined {
      status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    } else {
      status = current
    }

    guard status == .authorized || status == .limited else {
      throw NSError(
        domain: "WiredCameraPhotoLibrarySaver",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "没有相册写入权限"]
      )
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges({
        switch file.mediaType {
        case .photo, .raw:
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
              domain: "WiredCameraPhotoLibrarySaver",
              code: 2,
              userInfo: [NSLocalizedDescriptionKey: "保存到相册失败"]
            )
          )
        }
      }
    }
  }
}
