# Android Gallery Preview And Transfer Roadmap

更新日期: 2026-06-19

本文记录 2026-06-19 原厂 XApp 抓包后，Android 相册缩略图、高清预览、原图导入和缓存的后续改造计划。执行前以 `docs/android-official-xapp-connection-analysis.md` 的证据等级为准，不把未证明的 fallback 放进主链路。

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

状态: 待讨论后实现。

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

### P0.3 原图导入压缩模式复核

状态: 待讨论和实机 A/B 验证。

现在的问题:

- 当前 Android 原图下载路径使用 `IMAGE_COMPRESSION_REAL_INFO(0xD227)=1` 后重新读 `ObjectInfo`，再分段 partial。
- 原厂 iPhone 抓包中，导入前使用的是 `IMAGE_FORCE_COMPRESSION(0xD226)=2`，再分段 partial。

为什么要复核:

- “导入”语义必须明确: 用户到底拿到原始尺寸 JPEG、相机压缩图，还是某种传输优化图。
- 如果 Android 和原厂状态位不一致，可能导致文件尺寸、画质、格式、EXIF 或兼容性不同。
- 后续如果支持“压缩导入/原图导入”两个模式，这个状态位会直接决定产品语义。

可能收益:

- 和原厂导入行为对齐，减少不可解释的尺寸/画质差异。
- 下载前通过重新 `ObjectInfo` 获取真实大小，避免按旧 metadata 或占位 size 下载。
- 分段 partial 可以继续保持独占 PTP，稳定性比并发下载更好。

可能问题:

- `D226=2` 是否对所有格式和机型都表示“完整原图/导入图”还需要更多样本。
- 与现有 `D227=1` 的关系不清楚，不能直接删除现有路径。
- 如果用户设置了压缩传输偏好，`D226=2` 是否绕过偏好需要确认。
- 修改导入路径会影响保存到系统相册的最终文件，必须用实机样张比对尺寸、EXIF、哈希和肉眼质量。

建议验证方式:

1. 同一张照片分别用当前 Android 路径、`D226=2` 路径、原厂 App 导入。
2. 比对文件大小、像素尺寸、EXIF、SOI/EOI、是否可被系统相册正常识别。
3. 再决定是否切换默认路径，或保留为可配置传输模式。

## P1

### 预览缓存

状态: 待设计。

为什么需要:

- 原厂单图打开一次会传约 `2MB` 高清预览。
- 没有缓存时，同一张图每次打开都要重新占用 PTP，体验会慢，也会和缩略图/导入竞争。

建议设计:

- 内存 LRU: 2-4 张当前会话预览。
- 磁盘缓存: 100-300MB，可按最近使用淘汰。
- cache key: `cameraId + handle + compressedSize + objectVersion/modifiedTime + previewMode(D226=1)`。
- 缓存只保存 screen preview，不和原图下载完成状态混用。

风险:

- handle 可能跨会话复用，key 不能只有 handle。
- 如果用户删除/重拍照片，旧缓存必须能失效。
- 磁盘缓存要限制总大小，避免占用用户存储。

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
3. 更新诊断日志字段，让每张图能看出命中的路径: `thumbnail/standard`、`preview/D226=1`、`original/D226=2`。
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
