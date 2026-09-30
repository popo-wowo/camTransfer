# iOS 连接基线对照表

日期：2026-09-30

本表只记录可核对的基线。日志头部 Build 号不等于 Git SHA；Build 18 的实际 SHA 尚未从包或发布记录取得，暂记为 unknown。

## 版本基线

| 项目 | Build 18 参考 | 当前 ios-connect |
|---|---|---|
| App Build | 18；Git SHA unknown | HEAD 18f9e44a |
| Compatibility revision | 待从 Build 18 包提取 | ios-fujifilm-compatibility-2026-08-07 |
| 连接主线 | 以已知可连接行为为准 | BLE/GATT → AP → Wi-Fi → PTP → GalleryReady |
| 证据性质 | 已安装包行为，待补 SHA | 本地源码；未等同于已安装包 |

## 四份日志第一 proven barrier

| 场景 | 日志 | 头部版本 | 已证明结果 | 第一问题屏障 |
|---|---|---|---|---|
| T30 | `/Users/g01d-01-1224/Desktop/传图/日志/诊断日志-20260830.log` | `202608151952` / iOS 26.5.2 | BLE/GATT/AP ready 成功；Wi-Fi apply 返回 nil；随后 worker 被取消 | `joinCameraWifi` 被 `CancellationError` 中断，之后被归类为 Wi-Fi association failure |
| X100 | `/Users/g01d-01-1224/Desktop/传图/日志/CamTransfer-Diagnostics-2026-08-24T00-11-28Z.log` | Build 15 / iOS 26.6 | ACK 后多次断开；后续部分尝试完成 Wi-Fi；PTP INIT 无稳定 ACK | 早期尝试为 ACK 后断开；后续失败尝试为网络/AP 前提失效后继续 INIT |
| M5-A | `/Users/g01d-01-1224/Desktop/传图/日志/CamTransfer-Diagnostics-2026-08-25T12-47-24Z.log` | `202608151950` / iOS 27.0 | ACK、OpenSession、目录、GalleryReady 全部成功 | 无连接屏障；作为成功回归样本 |
| M5-B | `/Users/g01d-01-1224/Desktop/传图/日志/CamTransfer-Diagnostics-2026-08-25T12-55-59Z.log` | Build 19 / iOS 27.0 | GalleryReady 成功；后续缩略图错误和 transaction mismatch | GalleryReady 后的媒体事务/会话完整性 |

## 官方 App 证据

### Android XApp 2.7.3(1), version code 63

- `WiFiHandOverService`：建立 WPA2 NetworkRequest，等待 `onAvailable`，在 capabilities 中比较 exact SSID，`onUnavailable` 按 retry 状态处理。
- `CameraConnectModel`：OPEN_TIMEOUT 30000 ms、间隔 5000 ms、最多六次 wrapper.open；取消统计路径本身存在缺陷，不能直接复制结果。
- `BTCameraModel.changeAPState`：区分 `0x8000`、`0x8001`、`0x8002`、`0x8003`，不能把所有非零状态合并。
- JADX 标记为未完全反编译的方法不用于推断 iOS 私有实现。

### 官方 iOS 历史抓包

文件：`.analysis/packet-captures/iphone-xapp-clean-rvi2-20260619-213437.pcap`

解析结果：

- 手机向相机发出 `0x1002`、`0x1008`、`0x1015`、`0x1016`、`0x101B`，以及一次 `0x9050`、`0x9053`、`0x9054`、`0x9055`。
- `0x9054` 和 `0x9055` 使用句柄 `0x10000001`，响应 `0x2001`。
- 样本包含 JPEG/Exif/FUJIFILM 数据。
- 没有 `0x9051/0x9052`，因此不能证明官方永远不使用 SearchMode 或 explicit ALL。
- 该抓包是历史单机型/单状态样本，不能直接代表当前所有官方版本。

## 本轮实施目标

1. 先修复 T30 的 cancellation 归因。
2. 再修复 X100 类 INIT 重试的网络/AP 前提和总预算。
3. 将 M5-B 的 transaction/framing mismatch 作为物理 session 失效处理。
4. 动态 resolver 只修复跨 physical session 复用问题，不新增未知机型 fallback。
5. 每一步都保留 M5-A/M5-B 的成功路径。

## 明确限制

- 未取得 Build 18 对应 Git SHA，不能做提交级别的完整 diff。
- 未做真机回归，不能宣称 Build 18 或当前包的成功率。
- 不把当前工作树中的 dirty WIP 视为本轮发布内容。
