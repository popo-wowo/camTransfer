# Android Gallery Browse Modes Design

更新日期: 2026-07-03

## 目标

把“进入相册后的浏览行为”从连接主链路中彻底拆开，形成两个互不干扰的浏览模式：

1. `缩略图模式`
2. `高清预览模式`

相机侧 PTP 交互是单线程的，因此这两个模式不能只是 UI 上看起来不同，必须在架构上做到：

- 连接主链路只负责进入相册，不知道当前浏览模式。
- 进入相册后所有会占用相机 PTP 的操作都必须通过同一个串行调度入口。
- 缩略图、高清预览、后台 metadata、下载之间不允许并发争抢相机。
- 下载开始后，当前模式的其它后台加载必须完全暂停，直到整个下载队列完成后再恢复。

## 非目标

- 不改 BLE / Wi-Fi / PTP 连接主链路。
- 不新增第二套下载协议。
- 不在本次设计里解决 RAW 原图下载稳定性、下载失败重试策略或保存到系统相册之外的路径问题。
- 不做跨日期批量高清预览自动加载，也不做全库高清预览缓存。

## 模块边界

### Connection

职责:

- 负责 `ReconnectPairedBle -> TransferAuthorization -> ActivateCameraWifi -> WaitCameraWifiReady -> JoinCameraWifi -> ConnectPtp -> ConfirmGalleryMode -> LoadGallery`
- 输出已连接的 `CameraFileSource`
- 输出首批相册 handles / counts / placeholders 所需 state

禁止:

- 不知道当前是缩略图模式还是高清预览模式
- 不触发高清预览读取
- 不决定下载什么时候开始

### GalleryOperationScheduler

职责:

- 成为进入相册后所有相机 PTP 操作的唯一串行入口
- 串行调度以下类别：
  - `VisibleThumbnail`
  - `BackgroundMetadata`
  - `PreviewImage`
  - `Download`
- 提供“模式独占”和“下载独占”的暂停/恢复能力

禁止:

- 不存 UI 状态
- 不决定筛选条件
- 不维护 selection

### Thumbnail Browse Mode

职责:

- 管理占位符网格、可见缩略图、后台 metadata 补齐
- 响应筛选/排序/缩放列数
- 用户在此模式下选择、批量下载

禁止:

- 不读取高清预览图
- 下载进行时不继续缩略图、metadata、hidden-format 加载

### High Definition Preview Mode

职责:

- 以“单日期 + 一行一张 + 单线程顺序加载”的方式展示高清预览
- 每张卡片提供下载按钮
- 点击后直接使用已加载高清图进入全屏，不回退到缩略图链路

禁止:

- 不自动加载全部日期
- 不在预览未完成时启动下载
- 不在下载进行时继续排队新的高清预览请求

## 设计方案

### 入口与模式切换

- 仍然先执行唯一的连接主链路进入相册。
- 进入相册后，顶部提供模式切换：
  - `缩略图`
  - `高清预览`
- 默认进入 `缩略图模式`
- 切换模式只改变“进入相册后的数据读取策略和 UI 布局”，不触发重新连接、不重开 PTP、不重做 BLE/Wi-Fi。

推荐原因:

- 保持连接主链路单一且干净
- 用户可在已连接会话内切换浏览方式
- 模式差异留在 Gallery 模块内部，不污染主链路

### 独占调度规则

进入相册后的相机操作优先级和独占关系：

1. `Download`
2. `PreviewImage`
3. `VisibleThumbnail`
4. `BackgroundMetadata`

硬规则:

- 同一时刻只允许一个相机读取任务执行
- `Download` 开始后，暂停：
  - 缩略图队列
  - 后台 metadata
  - hidden-format / additional-files
  - 高清预览顺序加载
- `PreviewImage` 执行时，暂停缩略图队列
- `Thumbnail` 执行时，不允许自动插入 `PreviewImage`
- 所有暂停恢复必须是引用计数式，避免 `preview` 和 `transfer` 互相提前恢复

### 缩略图模式

保留现有相册网格作为基础，新增以下执行规则：

1. 页面可见时，按当前屏幕窗口请求缩略图。
2. 后台 `fullObjectInfo` 与 `hidden-format` 补齐继续存在，但优先级最低。
3. 用户点击下载并且队列开始执行后：
   - 页面停留在下载界面
   - 不再继续加载缩略图
   - 不再继续跑 `GetObjectInfo`
   - 不再继续跑 hidden-format 发现
4. 下载队列全部结束后，返回相册时再恢复缩略图和 metadata 加载。

这部分不是“尽量减少干扰”，而是“下载期间完全冻结缩略图模式的后台读取”。

### 高清预览模式

高清预览模式作为进入相册后的独立浏览模块。

UI 形态:

- 一行一张图
- 顶部显示当前日期和模式状态
- 每张卡片有：
  - 高清图区域
  - 文件基础信息
  - 单张下载按钮

加载规则:

1. 默认只加载“今天”的文件。
2. 用户可以切换日期，但一次只允许一个日期处于激活状态。
3. 当前日期的候选文件只保留支持高清预览的格式（当前按 JPEG / HEIF）。
4. 使用单线程顺序加载：
   - 第 1 张完成
   - 再开始第 2 张
   - 直到该日期结束
5. 切日期时：
   - 取消当前日期尚未开始的顺序任务
   - 保留已经加载好的缓存
   - 从新日期第 1 张重新开始顺序加载

下载规则:

1. 用户点某张图的下载按钮时，先把该文件加入下载待执行列表。
2. 如果当前有一张高清预览正在读，等待它结束。
3. 当前没有预览在读时，立即开始下载队列。
4. 下载开始后，暂停后续高清预览顺序加载。
5. 下载完成后，恢复当前日期剩余高清预览加载。

全屏规则:

- 只有该 handle 已经存在 `previewImages[handle]` 时，才允许进入高清全屏。
- 高清全屏直接使用已加载高清图字节。
- 不再为全屏额外触发缩略图或新的高清图读取。

## 组件拆分

### 新增 / 调整模块

1. `GalleryBrowseModeController`
   - 维护当前模式：`THUMBNAIL` / `HD_PREVIEW`
   - 维护高清预览当前日期
   - 维护模式切换时的暂停/恢复策略

2. `GalleryOperationGate`
   - 对现有 `GalleryRequestScheduler` 外包一层模式独占控制
   - 统一处理：
     - `pauseThumbnailsForTransfer`
     - `pausePreviewsForTransfer`
     - `pauseThumbnailsForPreview`
     - `resumeAfterExclusiveOperation`

3. `HighDefinitionPreviewSession`
   - 维护：
     - 当前日期
     - 当前日期的顺序列表
     - 当前顺序索引
     - 待下载 handles
     - 当前是否因下载而暂停

### 复用现有模块

- `GalleryFilesController`
  - 继续提供相册文件列表和 metadata 补齐
- `GalleryThumbnailController`
  - 继续负责缩略图队列，但要支持下载独占暂停
- `GalleryPreviewController`
  - 继续负责高清预览读取，但从“单文件临时请求”扩展到“顺序 session”
- `TransferService`
  - 继续负责实际下载队列，不新增第二套下载逻辑
- `BrowseViewModel`
  - 只负责组装模式 controller、thumbnail controller、preview controller、transfer callback

## 数据流

### 缩略图模式

```text
Connection -> CameraFileSource -> GalleryFilesController -> placeholder/files
                                    -> GalleryThumbnailController -> visible thumbnails
                                    -> Background metadata (lowest priority)

User download ->
  BrowseViewModel.prepareExclusiveTransfer()
  -> pause thumbnails
  -> pause metadata
  -> pause hd preview session
  -> TransferService.startTransfer()
  -> transfer finished
  -> resume previous mode loading
```

### 高清预览模式

```text
Connection -> CameraFileSource -> GalleryFilesController(files only)
User switches to HD preview ->
  GalleryBrowseModeController selects date=today
  -> HighDefinitionPreviewSession builds candidate list
  -> GalleryPreviewController sequentially loads one image at a time

User taps download on card ->
  enqueue handle in HD session
  wait current preview read completes
  pause remaining HD preview sequence
  TransferService.startTransfer()
  transfer finished
  resume HD sequence at next index
```

## 错误处理

### 缩略图模式

- 缩略图失败：只标记该缩略图失败，不触发模式切换
- metadata 失败：只停止后台 metadata，不影响当前网格
- 下载失败：队列按现有策略停住，缩略图模式保持暂停状态直到下载流程明确结束

### 高清预览模式

- 单张高清预览失败：
  - 标记该张失败
  - 顺序跳到下一张
  - 不影响当前日期其它项
- 当前日期无可预览文件：
  - 显示空状态
  - 不自动跳到其它日期
- 下载失败：
  - 使用现有下载错误提示
  - 恢复高清预览顺序加载

## 测试

必须新增或补齐以下测试：

1. `BrowseViewModel`
   - 模式切换不触发重新连接
   - 下载开始时同时暂停 thumbnail / metadata / preview
   - 下载结束后按当前模式恢复

2. `GalleryThumbnailController`
   - transfer pause 时不再接收新缩略图请求
   - transfer 完成后才能继续排队

3. `GalleryPreviewController`
   - 顺序只允许一次一张
   - 下载 pending 时等待当前预览完成后再进入下载
   - 下载过程中不继续读下一张预览
   - 切日期会重建顺序索引，但不污染已缓存图

4. `TransferService` / integration-style controller tests
   - 下载独占时，浏览模式后台任务被冻结
   - 整个下载队列结束前不会恢复后台加载

5. UI policy tests
   - 高清预览模式默认日期为今天
   - 高清预览列表是一列
   - 没有已加载高清图时，不允许进入高清全屏

## 实现顺序

1. 先补调度和暂停恢复测试
2. 引入 `GalleryBrowseModeController`
3. 改 `GalleryPreviewController` 为顺序 session
4. 改 `BrowseViewModel` 接通模式和下载独占
5. 改 `HighDefinitionPreviewScreen` 为单日期、一列、卡片下载
6. 最后调 `BrowseScreen` 顶部模式切换和全屏入口

## 风险与约束

- 当前仓库已有未完成的高清预览 UI 文件和相关改动，必须在实现时先对齐边界，不能继续让它直接与缩略图模式互相调用。
- 相机是单线程设备，本设计默认“宁可更慢，也不允许双通道抢占”。
- 如果后续需要做“预览缓存落盘”或“多日期分页”，应继续放在 `HighDefinitionPreviewSession` 内，不回流到连接主链路。
