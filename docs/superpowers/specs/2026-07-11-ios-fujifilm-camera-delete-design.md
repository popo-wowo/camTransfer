# iOS 富士相机照片删除设计

## 目标

在 CamTransfer 已建立的 iOS 富士相机 Wi-Fi/PTP 图库会话中，验证并实现从相机存储卡删除指定照片的能力。

第一阶段只提供受控的真机诊断入口，用 X-T5 和一张新拍测试照片确认协议。协议验证成功后，第二阶段才开放正式用户界面。Android 不在本轮范围内，但最终协议结论需要能够复用。

## 已确认的协议事实

- 标准 PTP 删除操作码为 `DeleteObject (0x100B)`。
- 富士 XApp 原厂 native 调用链包含 `XSDK_DeleteImage -> CCameraCommandReadImage::DeleteObject -> FTL_PTP_DeleteObject`。
- XApp 的 Wi-Fi PTP/IP 实现对删除请求发送一个对象句柄参数，使用无数据阶段。
- 原厂实现部分路径会在删除后等待富士事件 `0xC006`，等待上限约 3 秒。
- libgphoto2 的富士设备能力资料显示 X-T4、X-T3、X-S10、X100VI 等多款相机声明支持 `0x100B`；其通用删除实现使用对象句柄和可选格式参数。
- 当前 CamTransfer 的 iOS PTP session 已具备串行发送无数据命令的能力，但尚未声明 `0x100B`，图库服务也没有删除接口。
- X-T5 当前走 `cameraVendorLegacy` 富士封包：`[length][dataPhase][operationCode][transactionID][parameters]`。

这些证据说明该能力值得实机验证，但不能据此宣称所有富士型号和固件都支持删除。

## 方案选择

### 方案 A：原厂单参数请求

报文参数只包含目标照片的 object handle：

```text
DeleteObject(0x100B, handle)
```

这是 X-T5 的首选策略，因为它与 XApp 的 Wi-Fi native 实现一致。

### 方案 B：标准双参数请求

报文参数包含目标 handle 和 `formatCode = 0`：

```text
DeleteObject(0x100B, handle, 0)
```

该策略对应标准 PTP/libgphoto2 的调用形态，只在方案 A 明确返回 `0x2006 ParameterNotSupported`，或型号 profile 已通过独立实机验证时使用。`0x2005 OperationNotSupported` 直接判定当前会话不支持删除，不得改用方案 B。方案 A 已成功或执行结果不明确时也不得继续执行方案 B。

### 完成策略 C：原厂事件确认

删除报文仍使用方案 A，但在发送前预先准备等待 `0xC006` 事件。收到 `0x2001` 后，最多等待 3 秒，再刷新相机对象列表。

该策略用于处理“命令成功但相机目录尚未刷新”的型号或状态，不是第三种删除报文，也不会对同一对象重复发送删除命令。第一轮 X-T5 诊断默认预先监听 `0xC006`，即使最终只需响应码和目录刷新即可确认成功。

### 明确排除

- 不实现或测试 `DeleteObject(0xFFFFFFFF)`。
- 不调用原厂 `ExecClearObject` 路径。
- 不自动选择现有照片作为测试对象。
- 不并发删除多个对象。
- 不因超时自动重试同一删除命令，因为第一次命令可能已经在相机端生效。

## 架构

### PTP 协议层

在 `CameraVendorPtpOperationCode` 增加 `deleteObject = 0x100B`。

`CameraVendorPtpSession` 新增一个内部删除方法，输入为 object handle 和诊断策略。它复用现有 command lock 和 transaction ID，禁止绕过串行命令通道。

协议层返回结构化结果：

- 使用的策略；
- PTP response code；
- 是否观察到 `0xC006`；
- 删除后的对象验证结果；
- 原始错误分类。

### 图库能力层

删除是写操作，不并入只读的 catalog、thumbnail 或 details source。新增独立的 `CameraGalleryMutationService`，只暴露：

```text
deleteObject(handle, strategy)
```

`CameraGallerySession` 组合该能力。没有通过型号验证的 adapter 可以报告不支持，而不影响只读图库。

### 会话协调

删除必须取得图库 session 的独占操作权：

1. 暂停新缩略图、详情和高清预览请求。
2. 阻止下载队列启动新的相机读取。
3. 等待当前 PTP 命令结束。
4. 执行一次删除。
5. 重新枚举对象 handle。
6. 清除被删除对象对应的内存缩略图、预览和详情缓存。
7. 恢复图库读取。

已有下载到手机相册的文件和下载历史不删除。相机删除与手机照片删除是两个独立动作。

## 第一阶段：真机诊断入口

诊断入口只在开发构建中显示，放在图库诊断区域，不进入正式图库主操作栏。

用户必须主动选择一张照片。执行前展示：

- 相机型号；
- object handle；
- 文件名；
- 拍摄时间；
- 文件格式；
- “只删除相机存储卡文件，不删除已导入手机的副本”的说明。

确认按钮使用明确文案“删除这张测试照片”。不提供全选或批量入口。

诊断执行顺序：

1. 首先运行方案 A。
2. 如果返回 `0x2001`，不再尝试其他报文；直接重新枚举验证。
3. 如果命令明确返回 `0x2006 ParameterNotSupported`，才允许用户手动选择方案 B 再试；`0x2005 OperationNotSupported` 直接停止。
4. 如果返回 `0x2001` 但第一次目录刷新仍看到该 handle，等待发送前已经预备的 `0xC006` 事件并延迟刷新，不重复发送删除命令。
5. 如果无法判断命令是否已执行，停止并要求重新进入图库确认，不自动重试。

## 第二阶段：正式产品入口

只有 X-T5 实机验证通过后才进入本阶段。

正式入口支持用户选中照片后选择“从相机删除”。确认框必须包含数量、不可恢复提示以及手机副本不受影响的说明。

批量删除按 handle 串行执行，任何一项失败立即停止。结果必须区分：

- 全部成功；
- 部分成功；
- 未执行；
- 执行结果未知。

部分成功时保留失败项选择状态，并刷新整个相机对象列表，不能只依赖本地乐观删除。

## 响应码和错误处理

实现前修正并补齐 PTP 响应码映射：

- `0x2001`: OK
- `0x2005`: OperationNotSupported
- `0x2006`: ParameterNotSupported
- `0x2009`: InvalidObjectHandle
- `0x200A`: DevicePropNotSupported
- `0x200D`: ObjectWriteProtected
- `0x200E`: StoreReadOnly
- `0x200F`: AccessDenied
- `0x2012`: PartialDeletion
- `0x2013`: StoreNotAvailable

当前 Android 常量把 `0x200A` 标成 `STORE_READ_ONLY`，后续 Android 适配时必须修正；iOS 本轮使用独立、正确的错误分类。

受保护照片、锁定存储卡、只读存储和权限拒绝必须显示具体原因，不得统一显示为连接失败。

## 安全约束

- `handle == 0` 和 `handle == 0xFFFFFFFF` 在发送前直接拒绝。
- 必须有当前图库中可见且可解析的对象记录，不能接收任意手输 handle。
- 删除前后记录 handle、文件名、策略和响应码，但不记录照片内容。
- 删除操作不进入自动重试策略。
- App 进入后台、PTP session 变化或相机通信 generation 变化时取消尚未发送的操作。
- response 已返回 OK 后，即使 UI task 被取消，也必须完成一次只读目录刷新以确定最终状态。

## 验证标准

### 单元测试

- 方案 A 生成 16-byte 富士 legacy 请求，只有一个 handle 参数。
- 方案 B 生成 20-byte 请求，第二参数为 0。
- 拒绝 0 和 `0xFFFFFFFF`。
- OK 后不执行第二个删除策略。
- 超时或结果未知时不自动重试。
- 正确分类删除相关 PTP response code。
- 删除成功后从 repository、选择状态和图片缓存中移除对应 handle。

### X-T5 真机验证

1. 新拍一张专用测试照片并记录相机端文件名。
2. CamTransfer 连接 X-T5 Wi-Fi，进入 GalleryReady。
3. 在诊断入口选择该测试照片。
4. 执行方案 A，记录完整 PTP 请求摘要和 response code。
5. 重新枚举对象列表，确认目标 handle 消失。
6. 在相机回放界面确认文件不存在。
7. 重新进入 CamTransfer 图库，确认照片没有因缓存重新出现。

仅当第 4 至第 7 步全部成立，才能宣称 X-T5 Wi-Fi 删除成功。

## 后续兼容策略

首个成功版本按“已验证型号 + 固件”开放，不以“富士全系列”作为默认能力。后续型号复用相同诊断流程验证；如果某型号要求方案 B 或事件确认，则把差异记录在 `FujifilmXSeriesProfile`，不在 UI 层写型号判断。
