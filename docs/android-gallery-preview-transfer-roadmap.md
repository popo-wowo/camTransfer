# Android Gallery Preview And Transfer Roadmap

更新日期: 2026-07-04

本文记录 2026-06-19 原厂 XApp 抓包后，Android 相册缩略图、高清预览、原图导入和缓存的后续改造计划。执行前以 `docs/android-official-xapp-connection-analysis.md` 的证据等级为准，不把未证明的 fallback 放进主链路。

## 当前稳定基线

- 分支: `codex/android-raw-d621-diagnostics`
- 稳定 tag: `android-stable-20260704-thumbnail-hd-raw-fix`
- 提交: `db6ce45 Stabilize Android gallery preview loading`
- 状态: 已 push，可作为后续优化的回滚点。
- 实机现象: 进入相册速度恢复；缩略图恢复显示；高清预览模式下 `加入 RAW` 当前看起来正常。
- 后续所有优化必须以这个 tag 为基线小步推进，不能把连接、相册启动、缩略图、高清预览和下载混成一次大改。

## 2026-07-04 已提交稳定改动

以下内容已经进入稳定 tag，不再视为未提交实验。后续排查时优先以这些规则判断当前行为是否回归。

### 1. 下载目录配置

状态: 已实现基础能力，后续继续验证不同系统相册/文件管理器可见性。

目标:

- 下载到系统相册时支持按规则落到独立目录，降低直接混入大相册的隐私问题。
- 支持用户改成 SAF 自选目录。

实现:

- 新增 `DownloadFolderSettingsStore` 持久化下载目录配置，保存:
  - 保存模式: `RULE_MEDIASTORE` 或 `CUSTOM_TREE`
  - 根目录名
  - 是否按相机名创建子目录
  - 是否按日期创建子目录
  - SAF tree uri / label
- `GalleryService` 下载保存前先读取设置:
  - `RULE_MEDIASTORE` 走 `MediaStore`，通过 `RELATIVE_PATH` 生成 `相机名/日期` 目录。
  - `CUSTOM_TREE` 走 `DocumentsContract.createDocument` 写入用户选择的树目录。
- `BrowseScreen` 接入 `OpenDocumentTree`。
- `GalleryDialogs` 新增下载目录设置弹窗。
- `GalleryHeader` 新增目录设置入口。
- `TransferViewModel` 把当前相机展示名传给 `GalleryService` 用于目录命名。

### 2. 单图高清预览页和预览弹层改造

状态: 已实现高清预览模式基础能力，2026-07-04 稳定 tag 已修复 RAW sidecar 入队语义。

目标:

- 把单图打开和列表缩略图区分开。
- 单图支持走高清预览协议，不再只放大缩略图。

实现:

- 新增 `HighDefinitionPreviewScreen`，作为单独“高清预览模式”页面。
- `GalleryPreviewController` 新增:
  - 已加载高清预览 handle 集合
  - 正在加载高清预览 handle 集合
  - 强制加载请求
  - 更大的预览缓存容量
- `BrowseViewModel` 暴露高清预览状态和强制触发接口。
- `GalleryPreviewDialog` 改成底部悬浮操作条样式，承载:
  - 选择
  - 原图/压缩状态
  - 下载动作
  - 图片信息入口
- 文件信息优先显示当前已知 `ObjectInfo` 字段，不为了展示信息额外重走相机主链路。

2026-07-04 稳定结论:

- 高清预览模式是 Gallery 内部模式，不触发重新连接或重新进入 GalleryReady。
- 进入高清预览后会暂停缩略图和 metadata 后台请求，避免抢 PTP。
- 加入下载只是加入统一下载队列，真正下载仍通过同一个 TransferService。
- 模糊 HEIF/RAW 占位符配对后，显示项只保留 `HEIF` hint，RAW 侧车只保留 `RAW` hint。
- RAW-only 候选即使用户当前选择压缩，也必须按原图模式下载。
- 诊断日志 `HD preview session ... rawPairs=preview[hints]->raw[hints]` 用于排查 RAW 按钮是否对应正确 handle。

### 3. 相册页交互和筛选 UI 调整

状态: 部分已实现，缩略图显示回归已在 2026-07-04 修复；缩放/筛选快速切换仍需继续压测。

目标:

- 让日期范围筛选和相册顶部工具更清晰。
- 让缩略图请求更偏向当前可见区域。

实现:

- `GalleryUiPolicy` / `GalleryDialogs` 把日期范围筛选改成开始、结束两个明确输入框。
- `GalleryThumbnailController` 调整首屏与可见窗口请求规则:
  - 当前没有可见项时，主动给一个首屏窗口，而不是直接返回空。
  - 可见窗口请求优先于后台补齐。
- `GalleryFilesController` 调整完整 `ObjectInfo` 的节流，让首屏与可见区域优先。

2026-07-04 稳定结论:

- 为了加速进入相册，`D222-current-handle-snapshot` 已从阻塞启动路径降为非阻塞诊断。
- 列表缩略图读取不恢复 `9054` current-image prime；但 `GET_THUMB` 前必须做标准 `GET_OBJECT_INFO(handle)`。
- 这个标准 ObjectInfo 只发生在单个缩略图按需加载时，不属于进入相册前的阻塞主链路。

### 4. 相机名与配对辅助信息

目标:

- 下载目录、连接页和有线导入都能拿到更稳定的展示名。
- 配对清理时能更明确判断系统 bond 是否还残留。

实现:

- `CameraFileSource` 增加 `displayName`。
- `WiredCameraService` 从 USB manufacturer / product string 生成展示名。
- `CameraVendorPairingForgetPolicy` 增加剩余 bonded address 检查辅助方法。

### 5. Android 图库启动协议诊断改动

状态: 关键 blocker 已闭环，当前稳定 tag 继续保留必要日志。

目标:

- 把“正在读取相机照片数量”卡住的问题缩小到具体协议步骤。
- 只记录和主链路有关的底层证据，不再靠 UI 重试掩盖。

实现:

- BLE 图库启动 payload 从 `0100` 改成 `0300`，对齐当前已验证的 Android ReferenceApp 激活序列。
- `PtpConnection` 在 `9050 / D22B / 9053 / D620 / D621` 增加 packet-level trace。
- 从主链路 `loadCameraVendorGalleryObjectHandles()` 去掉稳定版里会主动写入的:
  - `setOfficialDefaultSearchModeForDiagnostic()`
  - `setOfficialAllFormatSearchModeForDiagnostic()`
- 给 `9053 / D620 / D621 / D22B` 增加更长的读取超时，避免还没收完包就直接按默认超时断掉。
- 针对当前机型 `9053` 首包出现“嵌套 legacy envelope”的现象，加入首包 normalize 和窄范围 header resync 诊断。

注意:

- 这一组改动属于协议诊断，不应直接视为稳定主链路定稿。
- 2026-07-02 已闭环“进图库卡在照片数量”的主 blocker：根因是 `9053 GetSpecifiedObjectCountGroupByDate` 首包 framing 错误，不是配对、Wi-Fi、PTP open 或 `9050/D22B`。
- 但 `D604=HEIF/RAW` 扩展阶段的第二种 `9053` 首包 shape 仍未完全闭环。

### 6. 当前阻塞点

截至当前 worktree，已确认:

- BLE 重连、相机 Wi-Fi 激活、Wi-Fi handoff、PTP INIT、`D212/DF01/DF28/D244/D226/D227` 已能走通。
- `loadCameraVendorGalleryObjectHandles()` 的第一个 blocker 已经定位并修复在 `9053`。
- 2026-07-02 成功日志证据:
  - `23:29:53.972` `9053` 开始
  - `23:30:00.393` `Legacy packet decoded ... payloadBytes=533 normalizedBytes=517`
  - `23:30:00.395` `Legacy command complete label=9053-count-group-by-date`
  - `23:30:00.479` `D620` 完成
  - `23:30:00.495` `D621` 完成
- 这证明旧问题不是连接失败，而是旧代码把 `9053` 首包当成普通 legacy data packet 处理，导致日期字符串 UTF-16 字节被误读成下一包包头。
- 当前剩余问题:
  - 后续 `D604=HEIF` 或 `D604=RAW` 扩展阶段再次读取 `9053` 时，日志出现第二种 shape：`length=664`
  - 当前样本里这类包仍会在首包 body 读取阶段超时
  - 因此后续协议工作要继续盯 `HEIF/RAW` 扩展 `9053`，而不是再回头怀疑配对/主链路

### 7. 2026-07-03 二次卡住与当前修正

状态: 已确认根因并已落到当前 Android 包。

现象:

- 2026-07-03 晚上的实机日志里，主链路已经走到:
  - `ReconnectPairedBle` 成功
  - `TransferAuthorization` 成功
  - `ActivateCameraWifi` 成功
  - `WaitCameraWifiReady` 成功
  - `JoinCameraWifi` 成功
  - `ConnectPtp` 成功
  - `ConfirmGalleryMode` 成功
- 但 `LoadGallery` 一开始连续卡在:
  - `9054-current-image-info` 超时 `7000 ms`
  - `9055-current-thumb` 超时 `7000 ms`
  - `9050-search-mode-desc-all` 再超时 `15000 ms`
- 最终“正在读取相机照片数量”阶段大约 `29 s` 后失败。

结论:

- 这次失败已经不是 BLE、Wi-Fi、PTP open 或 `9053` framing。
- 失败点收窄到 `LoadGallery` 最前面的 current-image context prime。
- `9054/9055` 在 Android 当前首屏链路里不是必需步骤；它们超时会污染首屏稳定性。

处理:

- 从 `PtpConnection.loadCameraVendorGalleryObjectHandles()` 的阻塞主链路中移除:
  - `9054 GetLatestObjectInfo(handle=0x10000001)`
  - `9055 GetExtensionThumb(handle=0x10000001)`
- 保留并继续依赖:
  - `9050 -> D22B -> 9053 -> D620 -> D621`
  - 以及必要的 `D604=HEIF/RAW` 扩展 `9053/D620/D621`

结果:

- 当前包已经恢复“可以进入相册”。
- 进入相册仍然偏慢，但慢点已经重新收敛为:
  - BLE 重连
  - 相机 AP ready 等待
  - Android 系统加入相机 Wi-Fi
  - `9050/9053` 本身的读取
- 这比之前“先被 `9054/9055` 白白耗掉 14 秒再失败”更接近可继续优化的状态。

### 8. 2026-07-04 缩略图与高清 RAW 修复

状态: 已提交、已 push、已打稳定 tag。

问题:

- 为了加速进入相册，移除阻塞 `9054` 后，列表缩略图一度不显示。
- 高清预览模式里 `加入 RAW` 在部分样本上会把普通 HEIF/JPG 候选加入队列，而不是 RAW 侧车。

根因:

- 缩略图回归不是 `GET_THUMB` 本身坏了，而是关闭 `9054` 的同时也跳过了标准 `GET_OBJECT_INFO(handle)`，导致单张缩略图读取缺少稳定对象上下文和返回的 `ObjectInfo`。
- RAW 入队问题来自初始 HEIF/RAW 模糊占位符。两个相邻 handle 在未解析真实 `ObjectInfo` 前都带 `HEIF + RAW` hint；如果 RAW 按钮直接使用这个占位符，下载模式和 UI 状态会把它当普通显示图候选处理。

处理:

- `PtpCommands.getThumbWithInfo()` 保持不走 `9054` 阻塞 prime，但在 `GET_THUMB` 前恢复标准 `GET_OBJECT_INFO(handle)`。
- `HighDefinitionPreviewSessionPolicy` 对模糊配对结果重写 hint:
  - `previewFile`: `HEIF`
  - `rawFile`: `RAW`
- `TransferQueueDownloadModePolicy` 把 RAW-only candidate 当 RAW 处理，强制 `ORIGINAL` 下载模式。
- `BrowseViewModel` 增加 `rawPairs` 诊断，后续如果某个日期配对错，可以直接看 `preview[hints]->raw[hints]`。

验证:

- `testDebugUnitTest` 目标风险集通过。
- `compileDebugKotlin` 通过。
- `git diff --check` 通过。
- `installDebug` 成功安装到 Android 手机。
- 用户实机反馈“这波看起来好像没问题”。

后续注意:

- 不要为了缩略图恢复把 `9054/9055` 放回 GalleryReady 前。
- 不要把 RAW sidecar 配对做成 hidden gap 猜码主路径；当前只在 HD 预览项合并层做展示/下载语义修正。
- 如果后续发现某个日期 RAW 仍错配，优先调整 sidecar pairing policy 和日志，而不是改连接或图库启动协议。

## 下一轮优化顺序

P0/P1 继续按下面顺序推进:

1. 实机复核下载独占: 点击下载必须跳转下载页，并确认缩略图、metadata、HD preview 全部暂停到队列结束。
2. 实机复核缩略图可见窗口: 缩放列数、筛选、快速滚动时，当前屏幕 handles 必须优先加载，不能留下永远不加载的空洞。
3. 实机复核 HD 预览 active window: 当前可见图优先，上方少量、下方更多；切日期和快速滚动时从当前屏幕开始加载。
4. HD 预览 RAW 配对继续取证: 收集异常日期的 `rawPairs` 日志，只在 sidecar 层修，不污染主链路。
5. 缓存与内存上限: HD 预览只保留会话缓存并在相册返回主界面/断开/reset 时清理；缩略图已增加内存 LRU、磁盘旁路缓存和 `200MB / 500MB / 1GB` 长期上限。

## 后续高风险功能: 删除相机照片

状态: 待办，先做调试验证，不进入当前 P0/P1 主链路优化。

证据:

- 官方 Android XApp native 库里存在相机端删除能力，见 `docs/android-official-xapp-connection-analysis.md` 的“官方 App 删除相机照片能力边界”。
- 当前证据只能证明 SDK/库有 `DeleteObject` / `DeleteImage` 能力，不能证明普通导入相册 UI 已向用户开放删除相机存储卡照片。

设计原则:

- 删除是破坏性写操作，必须作为独立 `Camera Mutating Operation` 链路处理，不能混入缩略图、高清预览、下载或 GalleryReady 主链路。
- 删除执行期间必须独占 PTP，暂停 thumbnail、metadata、HD preview、download entry 等其他相机请求。
- UI 必须二次确认，并明确“从相机存储卡删除，不能靠手机本地缓存恢复”。
- JPG/HEIF + RAW 组合不能静默全删。第一版应明确区分“删除当前显示文件”和“同时删除 RAW sidecar”。
- 成功后必须刷新相机目录状态，至少重新读取 `9053/D620/D621` 或用等价的局部刷新策略，确保日期数量、占位符、筛选和 RAW 配对一致。
- 失败时不能删除本地下载文件、下载标记、缩略图/HD 缓存；只能标记删除失败并提示用户重试。

建议验证路径:

1. 新增隐藏调试入口或开发命令，只允许测试卡/测试照片使用。
2. 通过统一 PTP 调度器独占执行标准 `DeleteObject(0x100B)`，参数为目标 handle。
3. 记录 response code、耗时、删除前后 `9053/D620/D621` 数量变化、目标 handle 是否仍可 `GET_OBJECT_INFO`。
4. 如果标准 `DeleteObject` 返回不支持，再考虑 vendor delete 能力，但必须先抓官方 payload 或验证 native 对应行为，不能靠猜码进入正式功能。
5. 调试验证通过后，再设计正式 UI 和恢复策略。

### 9. 2026-07-04 HD 预览缓存工程优化

状态: 已实现，等待实机长时间浏览验证。

问题:

- `hd-preview-cache` 原来按 handle 写入磁盘，容易被误当成长期缓存。
- 用户往回滚动到已加载过的 HD 预览时，active window 恢复会同步 `readBytes()`，存在滚动卡顿风险。

处理:

- active window 的磁盘恢复改为 `Dispatchers.IO` 协程执行。
- 内存 preview cache 加锁，避免 IO 恢复和预览下载同时更新 `LinkedHashMap`。
- HD 预览缓存明确为本次浏览会话资产，不计入长期缓存。
- 相册返回 CONNECT 主界面、断开相机或 `GalleryPreviewController.reset()` 时删除 `hd-preview-cache`，不保留高清预览图。

验证:

- 新增策略测试覆盖长期缓存统计不包含 `hd-preview-cache`。
- 当前风险测试集和 `compileDebugKotlin` 通过。

边界:

- 不改变 `D226 -> GET_OBJECT_INFO -> GET_PARTIAL_OBJECT` 高清预览协议。
- 不改变连接、D621、缩略图、下载主链路。
- 不把 HD 预览磁盘缓存和原图/压缩下载结果混用。
- 不把高清预览图跨启动持久化。

### 10. 2026-07-04 缓存大小展示、上限与下载记录轻量化

状态: 已实现，等待实机 UI 观察。

目标:

- 相册页右上区域展示当前 app 可清理缓存大小，但不能影响进入相册、缩略图、高清预览或下载。
- 用户可选择长期缓存上限 `200MB / 500MB / 1GB`，默认 `500MB`。
- 下载完成后的“已下载”标记继续可用，但退出后不再持久化重型 thumbnail bytes。

实现:

- 新增 `AppCacheUsagePolicy`，只统计 app `cacheDir` 下明确可清理的白名单目录:
  - `thumbnail-disk-cache`
  - `diagnostics`
- `BrowseScreen` 进入相册时用 `produceState + Dispatchers.IO` 异步计算一次缓存大小。
- `GalleryHeader` 显示 `缓存 xx` 和 `清理缓存` 入口；入口打开 `CacheSettingsDialog`，可调整上限或清理可清理缓存。
- `AppCacheSettingsStore` 持久化用户上限选项；`trimToLimit()` 按最旧文件清理，只处理白名单目录。
- `DownloadedFileRecordCodec.encode()` 不再把 `CameraFile.thumbnail` 写入 SharedPreferences 记录；旧记录里如果带 thumbnail 仍兼容读取。

边界:

- 不统计、不清理配对/连接信息。
- 不统计、不清理 MediaStore / SAF 里用户已经下载保存的照片或视频。
- 不改变下载文件保存路径、下载模式、PTP 读写协议。
- 不统计、不清理本次浏览会话的 `hd-preview-cache`；高清预览退出时由 preview controller 清理。

### 11. 2026-07-04 缩略图内存缓存上限

状态: 已实现，等待大图库长时间浏览观察。

目标:

- 避免 `GalleryThumbnailController` 里的额外 thumbnail bytes map 随 handle 数无限增长。
- 不改变缩略图请求协议、不改变可见窗口策略、不影响已显示图片。

实现:

- 新增 `ThumbnailMemoryCache`，默认最多保留 300 个 handle 的 thumbnail bytes。
- 写入同一个 handle 时刷新 LRU 顺序。
- 超过上限时删除最旧 entry。
- `GalleryThumbnailController.cachedThumbnails()` 继续返回 snapshot，供 `GalleryFilesController` 合并时使用。

边界:

- 这个缓存不是磁盘缓存，App 退出后不会保留。
- 这个缓存不主动移除 `CameraFile.thumbnail` 里已经合并到当前页面的数据，避免滚动中出现已显示图片突然变回占位符。
- 真正要进一步降低整页内存，需要另开任务设计页面列表 thumbnail 的窗口化/磁盘恢复策略。

### 12. 2026-07-04 缩略图磁盘缓存旁路

状态: 已实现，等待实机二次进入相册验证。

目标:

- 长期只保留缩略图缓存，减少重复进入相册后再次向相机请求同一批缩略图。
- 不让缓存参与占位符、日期分组、格式筛选、下载等主链路判断。

实现:

- `GalleryThumbnailController.loadThumbnailNow()` 在请求相机前先读取 `thumbnail-disk-cache`。
- 命中本地缓存时直接 `mergeThumbnail()` 更新 UI，并记录 `Thumbnail loaded ... source=disk` 日志。
- 未命中时保持原链路: `getThumbnailWithInfo(handle)`，返回后先更新 UI，再把磁盘写入调度到独立后台 job。
- cache key 包含 handle、format、compressedSize、filename，避免只按 handle 复用导致错图。
- 为避免拖慢缩略图串行加载，磁盘写入和每 32 次写入后的 trim 都不在缩略图请求 worker 里执行。
- 缓存大小统计等文件列表加载完成并延迟后再后台执行，不在相册首屏立即递归扫描。

边界:

- 不改变 PTP 单线程调度器。
- 不改变首屏 D621/9053/ObjectInfo 发现链路。
- 不改变下载互斥门；下载开始后缩略图请求仍会暂停。

## 已确定结论

1. 列表缩略图、单图高清预览、原图导入是三类不同数据，不应混用。
2. 原厂普通相册浏览、单图预览、放大、导入都复用 `192.168.0.1:55740` PTP command socket。
3. 原厂单图打开不是下载完整原图，也不是放大 `640x480` 缩略图，而是:
   - `SET_DEVICE_PROP_VALUE(0xD226)=1`
   - `GET_OBJECT_INFO(handle)`
   - `GET_PARTIAL_OBJECT(handle, 0, ObjectInfo.compressedSize)`
   - 本次样本返回完整 `3840x2560` JPEG，约 `2MB`
4. 原厂放大期间没有明显图片数据传输，说明放大使用单图打开时已经拿到的高清预览。
5. 原厂导入前设置 `SET_DEVICE_PROP_VALUE(0xD226)=2`，然后分段 `GET_PARTIAL_OBJECT` 拼出完整 `7728x5152` JPEG。
6. `GET_PARTIAL_OBJECT` 在本次抓包里用于高清预览和原图导入，不是缩略图兜底证据。

## P0

### P0.1 去掉缩略图 `GET_PARTIAL_OBJECT` fallback

状态: 已执行。

原因:

- 抓包没有证明原厂使用 partial object 做列表缩略图。
- 历史 Android 日志证明 partial fallback 可能返回不完整 JPEG，或者返回带原图尺寸 header 的大图，导致 UI 卡顿和显示异常。
- 缩略图失败应该暴露为缩略图失败，不应该偷偷读原图/预览片段。

代码方向:

- `getThumbWithInfo()` 标准 `GET_THUMB` 不可用时直接失败。
- 保留 JPEG 完整性校验给高清预览和原图导入使用。

### P0.2 高清预览协议

状态: Android 已按原厂路径实现，仍需更多机型实机复测。

“高清预览协议”指的是原厂单图打开时使用的 PTP 顺序:

1. 设置 `IMAGE_FORCE_COMPRESSION(0xD226)=1`。
2. 重新读取 `GET_OBJECT_INFO(handle)`。
3. 使用新的 `ObjectInfo.compressedSize` 作为读取长度。
4. 发 `GET_PARTIAL_OBJECT(handle, 0, compressedSize)`。
5. 校验返回数据是完整图片，至少 JPEG 要有 EOI。
6. 退出时恢复 `D226=0`。

为什么要改:

- 当前 Android `getPreviewImage()` 只按最多 `256KB` 读取 partial；这通常不够一张可放大的预览图。
- 原厂样本证明 `D226=1` 后可以得到约 `2MB / 3840x2560` 的完整预览 JPEG。
- 这正好解释“原厂打开单图清晰，而我们糊”的差异。

收益:

- 单图打开后不再只是拉伸缩略图。
- 放大时可以直接使用已加载的高清预览，不必边缩放边重新请求。
- 预览数据量约 `2MB`，远小于完整原图，交互速度和清晰度之间比较平衡。

风险:

- `D226` 是相机全局/会话级状态，必须在 `finally` 中恢复为 `0`，否则可能影响后续缩略图或导入。
- 如果预览请求和缩略图、导入并发，会污染同一条 PTP 状态机；必须通过统一调度器串行。
- 不同相机型号、JPEG/HEIF/RAW 组合可能返回不同尺寸或格式，需要实机日志记录。
- 如果 `ObjectInfo.compressedSize` 异常，不能无限制读取；需要上限和完整性校验。

建议实现边界:

- 只先支持 JPEG/HEIF 的 screen preview。
- 不把这条路径当缩略图 fallback。
- 失败时 UI 继续显示缩略图，但记录明确诊断日志。

已落地行为:

- 单图打开触发 `GalleryPreviewController` 的 `PreviewImage` 优先级请求，并暂停缩略图队列，避免并发污染 PTP 状态。
- 协议层先确认对象是 JPEG/HEIF，再设置 `IMAGE_FORCE_COMPRESSION(0xD226)=1`。
- 设置后重新 `GET_OBJECT_INFO(handle)`，使用 fresh `ObjectInfo.compressedSize` 读取 screen preview，不再使用旧的 `256KB` 截断。
- screen preview 设置了 `8MB` 上限，异常尺寸直接失败并保留缩略图显示。
- JPEG 预览必须通过 SOI/EOI 完整性校验；退出时在 `finally` 中 reset `D226=0`。
- 预览页新增 `!` 信息入口，字段来自当前 `ObjectInfo`，包括文件名、格式、尺寸、缩略图尺寸、大小、拍摄时间、handle、存储、方向等；这个入口不触发新的相机请求。

### P0.3 原图/压缩导入模式

状态: Android 已实现按本次下载选择传递模式；仍需要更多机型和 JPG/RAW A/B 文件比对。

已落地行为:

- UI 点击下载时把当前模式写入队列项，后续下载不再依赖可变的全局偏好。
- BLE `ImageResizeSetting(82A9F452)` 只作为相机全局/初始状态来源，不再决定本次队列项的最终下载模式。
- 原图模式按原厂下载前切换: `IMAGE_FORCE_COMPRESSION(0xD226)=2`，重新读 `ObjectInfo`，再分段 partial，完成后 reset `D226=0`。
- 压缩模式按原厂下载前切换: `OBJECT_COMPRESSION_SETTING(0xD22E)=1`，再设置 `IMAGE_FORCE_COMPRESSION(0xD226)=1`，重新读 `ObjectInfo`，再分段 partial，完成后 reset `D226=0`。
- `D226/D227/D22E` 写入使用 PTP `UINT16` payload，不是 4-byte integer。实机 `D226/D227` 读取返回 2 bytes；宽度错误会导致后续对象尺寸仍停在小图级别。
- 压缩导入和原图导入都不能保存列表缩略图缓存。下载结果必须来自写入模式后的 fresh `ObjectInfo` 和 `GET_PARTIAL_OBJECT`。
- 2026-06-24 X-T5 实机复测发现 HEIF/JPG 压缩下载如果误用 `D226=2` 会得到缩略图级别的小传输图大小；2026-06-26 反编译确认 `D226=2` 是原图导入模式，不是压缩模式。
- socket closed / Not connected 这类连接失效错误会停止剩余队列，并把后续 pending 项标记为需要重新进入相册后重试。

为什么要复核:

- “导入”语义必须明确: 用户到底拿到原始尺寸 JPEG、相机压缩图，还是某种传输优化图。
- 如果 Android 和原厂状态位不一致，可能导致文件尺寸、画质、格式、EXIF 或兼容性不同。
- 后续如果支持“压缩导入/原图导入”两个模式，这个状态位会直接决定产品语义。

可能收益:

- 和原厂导入行为对齐，减少不可解释的尺寸/画质差异。
- 下载前通过重新 `ObjectInfo` 获取真实大小，避免按旧 metadata 或占位 size 下载。
- 分段 partial 可以继续保持独占 PTP，稳定性比并发下载更好。

可能问题:

- `D22E=1 + D226=1` 压缩路径仍需要用 JPG/HEIF/RAW 样张和原厂 App 导出结果做 A/B 比对。
- `D227=1` 保留为初始化复位对象，不再作为下载前原图/压缩模式切换。
- 修改导入路径会影响保存到系统相册的最终文件，必须用实机样张比对尺寸、EXIF、哈希和肉眼质量。
- 如果 `Download mode prepare` 的 PTP response 成功但 `Download partial` 的 `freshSize/readSize` 仍是几百 KB，说明协议状态或尺寸读取仍未完全复刻，不能把这个结果标成压缩或原图成功。
- 大 RAW 下载仍要继续做实机稳定性验证；如果 `D226=1/2` 路径仍在特定机型断开，再单独处理分段大小、重连/重试或保存策略。

建议验证方式:

1. 同一张照片分别用 Android 原图、Android 压缩、原厂 App 导入。
2. 比对文件大小、像素尺寸、EXIF、SOI/EOI、是否可被系统相册正常识别。
3. 对 RAW 单独验证 `D226=1/2` 路径的超时、断点/重试、失败后是否停止队列。

## P1

### 预览缓存

状态: 已收敛为会话缓存。

为什么需要:

- 原厂单图打开一次会传约 `2MB` 高清预览。
- 没有缓存时，同一张图每次打开都要重新占用 PTP，体验会慢，也会和缩略图/导入竞争。

建议设计:

- 当前会话内可复用已打开过的高清预览。
- 返回 CONNECT 主界面、断开相机或 reset 后清理 `hd-preview-cache`，不跨启动保留。
- 长期跨启动缓存只保留缩略图，不保留高清预览图。
- 缓存只保存 screen preview，不和原图下载完成状态混用。

风险:

- handle 可能跨会话复用，key 不能只有 handle。
- 如果用户删除/重拍照片，旧缓存必须能失效。
- 高清预览如果跨启动保留，会快速占用用户存储；当前明确禁止跨启动保留。

### 请求调度器优先级

状态: 待实现。

当前 `GalleryRequestScheduler` 已经用 mutex 保证 PTP 串行，但 priority 还没有真正调度效果。后续应升级为单 worker priority queue:

1. `DownloadOriginal`
2. `PreviewImage`
3. `VisibleThumbnail`
4. `PreviewNeighborThumbnail`
5. `BackgroundMetadata`

这样才能保证当前用户动作优先，不让后台 metadata 或缩略图抢 PTP。

### 相邻高清预览预取

状态: 等 P0.2 和缓存完成后再做。

策略:

- 当前图高清预览加载完成后，空闲时预取左右各 1 张。
- 用户滑动到下一张时优先命中缓存。
- 下载中、当前预览加载中、缩略图首屏未完成时不预取。

## P2

1. 把接口命名从 `getPreviewImage()` 进一步明确为 `getScreenPreview()`，避免默认 fallback 到 `getFile()`。
2. 给 `D226` 状态切换、预览失败 reset、导入独占 PTP 增加协议级单元测试。
3. 更新诊断日志字段，让每张图能看出命中的路径: `thumbnail/standard`、`preview/D226=1`、`download/original/D226=2`、`download/compressed/D22E=1+D226=1`。
4. 更新用户可见文案，区分“正在加载预览”和“正在导入原图”。

## 原厂缓存目前能知道什么

能确定:

- 原厂打开单图后，放大期间没有明显继续下载图片数据。
- 因此原厂至少在当前单图页面内持有已下载的高清预览。
- 原厂列表缩略图和单图高清预览不是同一份数据。

不能确定:

- 原厂是否把高清预览写入磁盘缓存。
- 原厂磁盘缓存大小、淘汰策略、key 设计。
- 原厂是否跨 App 重启复用高清预览。
- 原厂是否对相邻图片做预取。

我们的设计结论:

- 不能声称“原厂一定有磁盘缓存”。
- 但 Android 侧应设计预览缓存，因为这是当前体验和 PTP 互斥模型下的必要工程优化。
- 缓存策略可以自研，只要不改变协议语义，并且能用日志验证命中率。
