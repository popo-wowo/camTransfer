# iOS 相册与快速下载终态架构设计

**状态：** 待用户最终审阅。

**替代范围：** 本文替代旧快速下载/相册架构描述，以及 `2026-07-26-ios-gallery-terminal-architecture-refactor.md` 中与本文冲突的模块设计。`2026-07-27-ios-download-stop-and-reuse-design.md` 作为下载停止的子设计继续有效。

## 1. 目标

把相册、快速下载、缩略图、高清预览和下载收口为职责清晰、可以复用、不会互相污染的终态架构。

核心要求：

- 相册和快速下载是两个独立功能；
- 两者复用同一套目录查询和筛选逻辑；
- 缩略图和高清预览使用完全独立的任务和缓存；
- 全部 PTP 操作只走一个物理命令通道；
- 手动、快速和恢复下载只走 Runtime 的一个顺序队列；
- 回到首页时，相机一定已经断开。

## 2. 总体架构

```text
CameraSessionRuntime
│  唯一相机会话所有者
│  唯一下载状态和顺序队列所有者
│
├── CameraCommandLane
│   └── 唯一物理 PTP 命令通道
│
├── CameraCatalogQueryEngine
│   └── 相册、快速下载共用的目录查询能力
│
├── CameraFilterEngine
│   └── 相册、快速下载共用的格式/日期/下载范围规则
│
├── CameraGallerySession
│   ├── 相册自己的筛选状态
│   ├── 相册自己的 Catalog 展示状态
│   ├── CameraGalleryThumbnailPipeline
│   └── CameraGalleryHDPreviewPipeline
│
└── QuickDownloadUseCase
    ├── 快速下载自己的规则
    ├── 查询本次需要下载的 handles
    └── 向 CameraSessionRuntime 提交下载
```

页面层只负责 UI 和导航：

```text
NativeConnectViewController
  -> 调用 QuickDownloadUseCase

NativeGalleryViewController
  -> 调用 CameraGallerySession

NativeDownloadListViewController
  -> 展示和停止 CameraSessionRuntime 下载
```

Controller 不直接执行 Catalog 查询、ObjectInfo 扫描、缩略图任务、高清任务或下载队列编排。

## 3. 模块职责与复用关系

| 模块 | 负责什么 | 谁复用 |
| --- | --- | --- |
| `CameraSessionRuntime` | 相机连接、会话生命周期、顺序下载队列、恢复、完成路由 | 全部功能 |
| `CameraCommandLane` | 串行执行所有物理 PTP 命令 | 全部相机操作 |
| `CameraCatalogQueryEngine` | 根据查询计划读取相机目录，返回不可变快照 | 相册、快速下载 |
| `CameraFilterEngine` | 统一格式、日期、下载范围规则，输出匹配 handles | 相册、快速下载 |
| `CameraGallerySession` | 相册筛选、Catalog 状态和页面数据 | 仅相册 |
| `CameraGalleryThumbnailPipeline` | 可见缩略图调度和缩略图缓存 | 仅缩略图模式 |
| `CameraGalleryHDPreviewPipeline` | 高清预览调度和高清缓存 | 仅高清模式 |
| `QuickDownloadUseCase` | 查询、筛选、提交快速下载和决定结束去向 | 仅快速下载 |

### 必须复用

- 目录查询能力；
- 格式、日期和下载范围筛选逻辑；
- HEIF 降级规则；
- 下载资格判断；
- PTP 命令通道；
- Runtime 下载队列。

### 必须独立

- 相册筛选状态和快速下载规则；
- 相册 Catalog 结果和快速下载本次查询结果；
- 相册手动下载质量和快速下载质量设置；
- 缩略图任务/缓存和高清任务/缓存。

快速下载只获得本次需要下载的 handles，不安装、不覆盖相册当前 Catalog 和筛选状态。

## 4. 共享筛选模块

相册和快速下载统一使用一个领域模型：

```swift
struct CameraMediaFilterRule: Equatable, Sendable {
  let formats: CameraMediaFormatSelection
  let date: CameraMediaDateSelection
  let downloadScope: CameraMediaDownloadScope
}

enum CameraMediaFormatSelection: Equatable, Sendable {
  case all
  case selected(Set<CameraMediaFormat>)
}

enum CameraMediaFormat: Hashable, Sendable {
  case jpg
  case raw
  case heif
}

enum CameraMediaDateSelection: Equatable, Sendable {
  case all
  case today
  case specificDay(Date)
}

enum CameraMediaDownloadScope: Equatable, Sendable {
  case all
  case notDownloaded
}
```

规则：

- 格式选项为：全部格式、JPG、RAW、HEIF；
- 全部格式与具体格式互斥；
- JPG、RAW、HEIF 可以多选；
- 日期只有：全部日期、今天、选择日期；
- 下载范围只有：全部、未下载的；
- 相册排序属于展示逻辑，不进入快速下载规则。

默认值：

| 入口 | 默认筛选 |
| --- | --- |
| 新相机首次进入相册 | 全部格式、全部日期、全部照片、最新优先 |
| 首次快速下载 | JPG、全部日期、未下载的、原图、下载完成后断开 |

相册筛选按相机保存。快速下载规则独立保存，两者互不修改。

## 5. 查询策略

`CameraFilterEngine` 只负责生成查询计划和投影结果；`CameraCatalogQueryEngine` 负责与相机交互。

```text
JPG                -> 相机端精确查询
RAW                -> 相机端精确查询
JPG + RAW          -> 分别精确查询，合并并去重
包含 HEIF          -> HEIF 降级路径
全部格式           -> 读取全部目录
```

HEIF 降级路径：

```text
读取全部目录
  -> 先按日期缩小候选 handles
  -> 读取候选 ObjectInfo
  -> 使用相机返回的格式信息判断格式
  -> 应用下载范围
  -> 输出最终 handles
```

约束：

- ObjectInfo 只参与本次筛选，不修改相册 Catalog 成员关系和顺序；
- 不使用文件名扩展名、缩略图内容或不可靠的 `formatLabel` 猜格式；
- HEIF 筛选必须完整成功才发布或开始下载，不能静默漏照片。

## 6. Catalog、缓存和异步结果

Catalog 是一次相机目录查询返回的不可变照片目录，包含有序 handles、日期分组和身份信息。

```swift
struct CameraGalleryCatalogIdentity: Hashable, Sendable {
  let cameraID: String
  let sessionEpoch: UUID
  let generation: CameraGalleryGenerationID
  let snapshotID: CameraGallerySnapshotID
}
```

每次新目录查询产生新的 generation：

- 旧查询可以完成必要的 PTP 清理；
- 旧查询结果不能覆盖当前页面；
- 同一相机会话、同一 handle 的图片缓存可以继续复用；
- 相机断开、切换相机或创建新会话时，Catalog 和两套预览缓存全部失效。

缩略图与高清预览分别拥有独立的 Task、队列、加载状态、内存缓存和磁盘缓存。两者只共享相机会话身份、媒体 handle 和 `CameraCommandLane`。

## 7. 相册流程

### 进入和筛选

```text
相机已连接
  -> 读取该相机保存的相册筛选
  -> 查询并安装相册自己的 Catalog
  -> 启动可见缩略图 Pipeline
```

切换筛选时停止旧 Catalog 子任务，执行新查询，只发布最新 generation。相册筛选不会修改快速下载规则。

### 缩略图与高清模式切换

```text
缩略图 -> 高清
  停止缩略图相机请求，保留缩略图缓存，启动高清 Pipeline

高清 -> 缩略图
  停止高清相机请求，保留高清缓存，恢复缩略图 Pipeline
```

两套 Pipeline 不同时向相机发送图片请求。

### 手动下载

```text
选择 handles
  -> Runtime 接受一个下载批次
  -> 停止并等待 Catalog/缩略图/高清相机任务
  -> 获取下载 lease
  -> 顺序下载
  -> 完成或取消
  -> 释放 lease
  -> Runtime 回到 galleryReady
  -> 返回相册
```

相册手动下载不自动断开。

### 退出相册

```text
用户点击返回
  -> 提示是否断开
  -> 用户确认
  -> 停止相册任务并断开相机
  -> 清空 Catalog 和预览缓存
  -> 回到首页
```

## 8. 快速下载流程

```text
首页点击快速下载
  -> 连接相机
  -> 读取快速下载规则
  -> 共用 QueryEngine 查询目录
  -> 共用 FilterEngine 输出 handles
  -> 向 Runtime 提交一个下载批次
  -> 顺序下载
```

快速下载不读取相册页面状态，不观察任意 Catalog `.ready`，也不修改相册保存的筛选。

结束路由：

```text
下载完成、取消或失败
├── 自动断开开启
│   -> 安全结束下载 -> 断开相机 -> 清空会话缓存 -> 回首页
│
└── 自动断开关闭
    -> 安全结束下载 -> 保持相机/PTP -> Runtime 回到 galleryReady
    -> 进入相册 -> 加载相册自己的筛选和 Catalog
```

进入相册后，只有断开相机才能回首页。

## 9. 下载所有权

`CameraSessionRuntime` 是唯一下载所有者，持有：

- 顺序队列和当前 handle；
- 每个 handle 的状态和进度；
- 成功、失败和取消状态；
- 后台执行和中断恢复；
- 下载 lease；
- 下载结束后的路由策略。

手动下载、快速下载和恢复下载调用同一个 Runtime 提交入口。

终态不创建 `CameraDownloadManager`，不增加第二个下载 owner、owner refcount、批次 generation 或重叠批次。

下载完成或取消只结束当前批次，不自动销毁健康的相机会话；是否断开由入口对应的完成策略决定。

## 10. 生命周期规则

| 事件 | 相册状态 | 缩略图缓存 | 高清缓存 | 相机连接 |
| --- | --- | --- | --- | --- |
| 相册切换筛选 | 新 Catalog generation | 保留可复用数据 | 保留可复用数据 | 保持 |
| 缩略图/高清切换 | 不变 | 保留 | 保留 | 保持 |
| 手动下载完成或取消 | 保留 | 保留 | 保留 | 保持 |
| 快速下载不自动断开 | 快速结果丢弃，相册加载自己的状态 | 按相册需要加载 | 按相册需要加载 | 保持 |
| 快速下载自动断开 | 失效 | 清空 | 清空 | 断开 |
| 相册退出 | 失效 | 清空 | 清空 | 断开 |
| transport loss/切换相机 | 失效 | 清空 | 清空 | 失效或重建 |

相册筛选配置按相机持久化，不属于连接缓存，断开后仍保留。

## 11. 物理命令串行化

所有相机操作最终经过同一个 `CameraCommandLane`：

```text
session mutation
  > download
  > HD preview
  > visible thumbnail
  > details/ObjectInfo
  > keep-alive
```

下载批次获得 lease 前，必须停止并等待已接纳的 Catalog、缩略图和高清任务到达安全边界；释放 lease 后才能恢复相册任务。

这只是一个物理 PTP 通道的串行调度，不代表存在多条下载线路或多个相机连接。

## 12. Controller 边界

`NativeConnectViewController` 只负责：

- 首页展示；
- 用户点击快速下载；
- 调用 `QuickDownloadUseCase`；
- 根据结果导航到首页或相册。

`NativeGalleryViewController` 只负责：

- 筛选交互；
- 照片选择；
- 缩略图/高清模式展示；
- 调用相册 UseCase；
- 导航到下载页。

`NativeDownloadListViewController` 只负责：

- 展示 Runtime 下载状态；
- 发送停止命令；
- 等待 Runtime 完成安全停止后导航。

Controller 不持有 Catalog generation、Catalog lifecycle Task、PTP 操作、下载 lease 或筛选实现。

## 13. 明确删除或禁止

- `CameraDownloadManager`；
- 快速下载 Catalog observer；
- 快速下载读取相册当前 presentation；
- `CameraAutoDownloadRuleFilter` 独立筛选实现；
- CatalogRuntime、相册 Policy、快速下载各自重复的日期/状态规则；
- 缩略图和高清预览共享缓存；
- 多个 PTP command lane；
- 多个下载 owner 或并发下载批次；
- Controller 直接执行相机任务；
- 正常下载结束后重建相机会话；
- 文件名扩展名作为格式成员关系依据。

## 14. 终态验收

- 相册和快速下载调用同一个查询与筛选模块；
- 两者的筛选状态和查询结果互不覆盖；
- 缩略图和高清预览拥有独立 Pipeline 和缓存；
- 所有 PTP 操作经过一个 `CameraCommandLane`；
- 所有下载入口经过一个 `CameraSessionRuntime` 队列；
- Controller 不再持有业务任务编排；
- 相机断开后 Catalog 和两套预览缓存全部失效；
- 相册手动下载结束后返回相册；
- 快速下载根据自动断开配置回首页或进入相册；
- 回到首页时相机一定已断开；
- 旧 Catalog 或媒体任务的迟到结果不能覆盖当前页面。

验证证据分层报告：

1. 单元测试和架构边界测试；
2. 全量 RunnerTests 基线对比；
3. iPhoneOS 签名构建；
4. 物理设备安装和启动；
5. 真实相机流程验收。

构建、安装或模拟器测试不能替代真实相机行为验收。
