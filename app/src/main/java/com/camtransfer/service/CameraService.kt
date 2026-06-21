package com.camtransfer.service

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.camtransfer.ble.CameraVendorBleHandshake
import com.camtransfer.ble.CameraVendorBleScanner
import com.camtransfer.ble.CameraVendorBleTransferActivationPolicy
import com.camtransfer.ble.CameraVendorConnectedDeviceNameStore
import com.camtransfer.model.CameraFile
import com.camtransfer.protocol.CameraVendorPtpIdentityPolicy
import com.camtransfer.protocol.PtpCommands
import com.camtransfer.protocol.PtpConnection
import com.camtransfer.service.connection.CameraGalleryConnectionCoordinator
import com.camtransfer.service.gallery.PtpCameraGallerySource
import com.camtransfer.service.pairing.CameraPairingService
import com.camtransfer.wifi.CameraVendorWifiJoinPolicy
import com.camtransfer.wifi.WifiConnector

private const val TAG = "CameraService"

class CameraService(override val context: Context) : CameraFileSource {

    private val scanner = CameraVendorBleScanner(context)
    private var handshake: CameraVendorBleHandshake? = null
    private var handshakeUpdatedAtMs: Long = 0L
    private val wifiConnector = WifiConnector(context)
    private val pairingStore = CameraVendorPairedCameraStore(context)
    private val transferPrefs = context.getSharedPreferences("camtransfer.transfer", Context.MODE_PRIVATE)
    val connection = PtpConnection()
    val commands by lazy { PtpCommands(connection, context) }
    private val gallerySource by lazy { PtpCameraGallerySource(context, connection, commands) }
    private val pairingService by lazy {
        CameraPairingService(
            context = context,
            scanner = scanner,
            pairingStore = pairingStore,
            currentHandshake = { handshake },
            publishHandshake = ::publishHandshake,
            rememberedRecordFor = ::rememberedRecordFor,
        )
    }
    private val galleryConnectionCoordinator by lazy {
        CameraGalleryConnectionCoordinator(
            context = context,
            scanner = scanner,
            wifiConnector = wifiConnector,
            pairingStore = pairingStore,
            connection = connection,
            rememberedPairing = ::rememberedPairing,
            currentHandshake = { handshake },
            currentHandshakeAgeMs = { SystemClock.elapsedRealtime() - handshakeUpdatedAtMs },
            publishHandshake = ::publishHandshake,
            clearHandshake = ::clearHandshake,
            rememberedRecordFor = ::rememberedRecordFor,
            preferCompressedDownloads = ::preferCompressedDownloads,
            ptpClientName = ::cameraVendorPtpClientName,
        )
    }

    @SuppressLint("MissingPermission")
    fun rememberedPairing(): CameraVendorPairedCameraRecord? {
        return pairingStore.load()
    }

    fun pairedCameras(): List<CameraVendorPairedCameraRecord> =
        pairingStore.loadAll()

    fun selectedCameraId(): String? =
        rememberedPairing()?.cameraId

    fun selectPairedCamera(cameraId: String) {
        pairingStore.select(cameraId)
        clearHandshake()
    }

    fun renamePairedCamera(cameraId: String, localDisplayName: String?) {
        pairingStore.renameLocalDisplayName(cameraId, localDisplayName)
    }

    fun registrationConsistencyIssue(): CameraConnectionIssue? {
        val canReadSystemBonds = CameraBluetoothPermissionPolicy.canReadSystemBonds(context)
        if (!canReadSystemBonds) {
            DiagnosticLog.append(context, TAG, "Skipped registration consistency check: missing BLUETOOTH_CONNECT")
        }
        val savedRegistration = pairingStore.load()
        val systemBonds = systemBluetoothBonds()
        DiagnosticLog.append(
            context,
            TAG,
            "Registration consistency check saved=${savedRegistration != null} " +
                "cameraId=${savedRegistration?.cameraId.orEmpty()} " +
                "savedBluetoothAddressPresent=${!savedRegistration?.bluetoothAddress.isNullOrBlank()} " +
                "registeredTerminalNamePresent=${!savedRegistration?.registeredTerminalName.isNullOrBlank()} " +
                "registeredTerminalNameLength=${savedRegistration?.registeredTerminalName.orEmpty().length} " +
                "canReadSystemBonds=$canReadSystemBonds systemBondCount=${systemBonds.size}",
        )
        val issue = CameraVendorPairingRegistrationPolicy.issueFor(
            savedRegistration = savedRegistration,
            systemBonds = systemBonds,
            canReadSystemBonds = canReadSystemBonds,
        )
        DiagnosticLog.append(
            context,
            TAG,
            "Registration consistency result issue=${issue?.failure ?: "none"} action=${issue?.primaryAction ?: "none"}",
        )
        if (issue == null) {
            val registeredTerminalName = savedRegistration?.registeredTerminalName
            if (!registeredTerminalName.isNullOrBlank()) {
                val repaired = CameraVendorConnectedDeviceNameStore(context).rememberRegisteredTerminalName(registeredTerminalName)
                DiagnosticLog.append(
                    context,
                    TAG,
                    "Registered terminal name cache sync repaired=$repaired length=${registeredTerminalName.length}",
                )
            }
        }
        return issue
    }

    @SuppressLint("MissingPermission")
    private fun systemBluetoothBonds(): List<CameraVendorSystemBluetoothBond> {
        if (!CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) return emptyList()
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        return manager.adapter.bondedDevices
            ?.map { device ->
                CameraVendorSystemBluetoothBond(
                    name = device.name.orEmpty(),
                    address = device.address.orEmpty(),
                    bondState = device.bondState,
                )
            }
            .orEmpty()
    }

    suspend fun connectToCamera(
        onStatus: (String) -> Unit = {},
        onStep: (CameraConnectionStep) -> Unit = {},
    ) {
        pairWithCamera(onStatus, onStep)
        confirmPairing(onStatus, onStep)
        connectPairedCameraToGallery(onStatus, onStep)
    }

    suspend fun connectExistingCameraWifiToGallery(
        onStatus: (String) -> Unit = {},
        onStep: (CameraConnectionStep) -> Unit = {},
    ): Boolean {
        onStep(CameraConnectionStep.ExistingPtpProbe)
        onStatus("正在检测已连接的相机 WiFi/PTP...")
        return runCatching {
            onStep(CameraConnectionStep.ConnectPtp)
            connection.connect(clientName = cameraVendorPtpClientName())
            CameraSessionKeepAlive.start(context)
            onStep(CameraConnectionStep.LoadGallery)
            onStatus("已连接")
            Log.d(TAG, "Existing camera PTP connection established")
            DiagnosticLog.append(context, TAG, "Existing camera PTP connection established")
            true
        }.getOrElse { error ->
            if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
            CameraSessionKeepAlive.stop(context)
            connection.disconnect()
            Log.d(TAG, "Existing camera PTP probe failed: ${error.message}")
            DiagnosticLog.append(context, TAG, "Existing camera PTP probe failed", error)
            false
        }
    }

    suspend fun pairWithCamera(
        onStatus: (String) -> Unit = {},
        onStep: (CameraConnectionStep) -> Unit = {},
    ) {
        pairingService.pairWithCamera(onStatus, onStep)
    }

    suspend fun confirmPairing(
        onStatus: (String) -> Unit = {},
        onStep: (CameraConnectionStep) -> Unit = {},
    ) {
        pairingService.confirmPairing(onStatus, onStep)
    }

    suspend fun refreshPairedCameraOnlineStatus(onStatus: (String) -> Unit = {}): Boolean {
        return galleryConnectionCoordinator.refreshRememberedCameraBleOnlineStatus(onStatus)
    }

    suspend fun connectPairedCameraToGallery(
        onStatus: (String) -> Unit = {},
        onStep: (CameraConnectionStep) -> Unit = {},
    ) {
        runCatching {
            galleryConnectionCoordinator.connectToGallery(onStatus, onStep)
            CameraSessionKeepAlive.start(context)
        }.onFailure {
            CameraSessionKeepAlive.stop(context)
        }.getOrThrow()
    }

    suspend fun resetGalleryConnectionBeforeRetry() {
        DiagnosticLog.append(context, TAG, "Reset gallery connection before retry")
        CameraSessionKeepAlive.stop(context)
        connection.disconnect()
        wifiConnector.disconnect()
        handshake?.disconnect()
        clearHandshake()
    }

    suspend fun retryCameraWifiToGallery(
        onStatus: (String) -> Unit = {},
        onStep: (CameraConnectionStep) -> Unit = {},
    ) {
        runCatching {
            if (CameraVendorWifiJoinPolicy.SHOULD_PROBE_EXISTING_PTP_BEFORE_WIFI_REQUEST) {
                onStatus("正在确认手机是否已经手动连上相机 Wi-Fi")
                DiagnosticLog.append(context, TAG, "Probing existing PTP before retrying WiFi request")
                if (connectExistingCameraWifiToGallery(onStatus, onStep)) return
            }
            val wifiConfigurations = handshake?.wifiConfigurations().orEmpty()
            if (wifiConfigurations.isEmpty()) {
                throw IllegalStateException("本次相机蓝牙授权没有返回 Wi-Fi 配置，请重新点进入相机相册走完整连接流程。")
            }
            DiagnosticLog.append(context, TAG, "Retrying camera WiFi/PTP without BLE activation")
            galleryConnectionCoordinator.connectWifiAndPtp(wifiConfigurations, onStatus, onStep)
            CameraSessionKeepAlive.start(context)
        }.onFailure {
            CameraSessionKeepAlive.stop(context)
        }.getOrThrow()
    }

    private fun cameraVendorPtpClientName(): String {
        val rememberedName = rememberedPairing()?.registeredTerminalName?.takeIf { it.isNotBlank() }
        val decision = CameraVendorConnectedDeviceNameStore(context).currentDecision()
        val terminalName = rememberedName ?: decision.name
        val source = if (rememberedName != null) "paired_camera_registered_terminal_name" else decision.source
        DiagnosticLog.append(
            context,
            TAG,
            "Terminal name consistency before PTP rememberedPresent=${rememberedName != null} " +
                "rememberedLength=${rememberedName.orEmpty().length} storeSource=${decision.source} " +
                "storeLength=${decision.name.length} same=${rememberedName == null || rememberedName == decision.name}",
        )
        val ptpName = CameraVendorPtpIdentityPolicy.legacyInitFriendlyName(terminalName)
        DiagnosticLog.append(
            context,
            TAG,
            "PTP client name decision name=$ptpName source=$source " +
                "rawLength=${decision.rawLength} normalizedLength=${decision.normalizedLength} " +
                "utf16BytesWithNull=${ptpName.toByteArray(Charsets.UTF_16LE).size + 2}",
        )
        return ptpName
    }

    private fun publishHandshake(hs: CameraVendorBleHandshake) {
        handshake = hs
        handshakeUpdatedAtMs = SystemClock.elapsedRealtime()
    }

    private fun clearHandshake() {
        handshake = null
        handshakeUpdatedAtMs = 0L
    }

    private fun rememberedRecordFor(hs: CameraVendorBleHandshake): CameraVendorPairedCameraRecord {
        val wifiConfigurations = hs.referenceAppWifiConfigurations()
        val record = CameraVendorPairedCameraRecord(
            deviceName = hs.cameraName(),
            serialNumber = hs.cameraSerial(),
            wifiConfigurations = wifiConfigurations,
            bluetoothAddress = hs.bluetoothAddress(),
            cameraId = CameraVendorCameraIdentityPolicy.cameraId(
                serialNumber = hs.cameraSerial(),
                deviceName = hs.cameraName(),
                bluetoothAddress = hs.bluetoothAddress(),
                wifiSsid = wifiConfigurations.firstOrNull()?.ssid,
            ),
            registeredTerminalName = CameraVendorConnectedDeviceNameStore(context).currentDecision().name,
            lastConnectedAtMillis = System.currentTimeMillis(),
        )
        DiagnosticLog.append(
            context,
            TAG,
            "Remembered pairing record prepared cameraId=${record.cameraId} " +
                "bluetoothAddressPresent=${!record.bluetoothAddress.isNullOrBlank()} " +
                "registeredTerminalNamePresent=${!record.registeredTerminalName.isNullOrBlank()} " +
                "registeredTerminalNameLength=${record.registeredTerminalName.orEmpty().length}",
        )
        return record
    }

    @SuppressLint("MissingPermission")
    private fun rememberedBluetoothAddressCandidates(
        remembered: CameraVendorPairedCameraRecord,
    ): List<String> {
        val systemBonds = if (CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) {
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            manager.adapter.bondedDevices
                ?.map { device ->
                    CameraVendorBleEndpointPolicy.SystemBond(
                        name = device.name.orEmpty(),
                        address = device.address.orEmpty(),
                    )
                }
                .orEmpty()
        } else {
            DiagnosticLog.append(context, TAG, "Skipped system BLE endpoint candidates: missing BLUETOOTH_CONNECT")
            emptyList()
        }
        val candidates = CameraVendorBleEndpointPolicy.identityVerifiedCandidates(
            remembered = remembered,
            systemBonds = systemBonds,
        )
        Log.d(
            TAG,
            "Remembered BLE endpoint candidates for ${remembered.cameraId}: ${
                candidates.joinToString { "${it.address}/${it.source}" }
            }",
        )
        DiagnosticLog.append(context, TAG, "Remembered BLE address candidates count=${candidates.size}")
        return candidates.map { it.address }
    }

    override suspend fun listFiles(): List<CameraFile> {
        return gallerySource.listFiles()
    }

    override suspend fun fastInitialFiles(): List<CameraFile> {
        return gallerySource.fastInitialFiles()
    }

    override suspend fun getThumbnail(handle: Int): ByteArray {
        return gallerySource.getThumbnail(handle)
    }

    override suspend fun getThumbnailWithInfo(handle: Int): CameraThumbnail {
        return gallerySource.getThumbnailWithInfo(handle)
    }

    override suspend fun resolveFile(handle: Int): CameraFile? {
        return gallerySource.resolveFile(handle)
    }

    override suspend fun resolveAdditionalFiles(knownHandles: List<Int>): List<CameraFile> {
        return gallerySource.resolveAdditionalFiles(knownHandles)
    }

    override suspend fun getPreviewImage(handle: Int): ByteArray {
        return gallerySource.getPreviewImage(handle)
    }

    override suspend fun getFile(handle: Int): ByteArray {
        return gallerySource.getFile(handle)
    }

    fun getFileStream(handle: Int) = commands.getObjectStream(handle)

    fun preferCompressedDownloads(): Boolean =
        if (transferPrefs.contains(TRANSFER_COMPRESSION_KEY)) {
            transferPrefs.getBoolean(
                TRANSFER_COMPRESSION_KEY,
                CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads(),
            )
        } else {
            CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads()
        }

    fun setPreferCompressedDownloads(preferCompressedDownloads: Boolean) {
        transferPrefs.edit().putBoolean(TRANSFER_COMPRESSION_KEY, preferCompressedDownloads).apply()
        DiagnosticLog.append(
            context,
            TAG,
            "Transfer size preference=${if (preferCompressedDownloads) "compressed" else "original"}",
        )
    }

    override suspend fun disconnect() {
        DiagnosticLog.append(context, TAG, "Disconnecting services")
        CameraSessionKeepAlive.stop(context)
        connection.disconnect()
        wifiConnector.disconnect()
        handshake?.disconnect()
        clearHandshake()
    }

    suspend fun forgetPairing() {
        resetConnectionForFreshPairing()
    }

    suspend fun resetConnectionForFreshPairing() {
        DiagnosticLog.append(context, TAG, "Reset connection for fresh pairing")
        val remembered = rememberedPairing()
        val bluetoothAddresses = remembered
            ?.let {
                (listOfNotNull(it.bluetoothAddress) + rememberedBluetoothAddressCandidates(it))
                    .filter { address -> address.isNotBlank() }
                    .distinct()
            }
            .orEmpty() + CameraVendorPairingRegistrationPolicy.systemCameraBondAddresses(systemBluetoothBonds())
        disconnect()
        val cleanupAddresses = bluetoothAddresses.distinct()
        pairingStore.rememberDeletedBluetoothAddresses(cleanupAddresses)
        removeSystemBluetoothBonds(cleanupAddresses)
        pairingStore.clear()
        CameraVendorTerminalIdentityStore(context).clearRegisteredTerminalName()
        DiagnosticLog.append(context, TAG, "Cleared pairing store and registered terminal name for fresh pairing")
    }

    @SuppressLint("MissingPermission")
    private fun removeSystemBluetoothBonds(bluetoothAddresses: List<String>) {
        val normalizedAddresses = bluetoothAddresses
            .map(CameraVendorPairingForgetPolicy::normalizeBluetoothAddress)
            .toSet()
        if (normalizedAddresses.isEmpty()) return
        if (!CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) {
            DiagnosticLog.append(context, TAG, "Skipped system BLE bond removal: missing BLUETOOTH_CONNECT")
            return
        }

        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        manager.adapter.bondedDevices
            ?.filter { device ->
                CameraVendorPairingForgetPolicy.normalizeBluetoothAddress(device.address) in normalizedAddresses
            }
            ?.forEach { device ->
                runCatching { removeSystemBluetoothBond(device) }
                    .onSuccess { removed ->
                        DiagnosticLog.append(context, TAG, "System BLE bond remove requested success=$removed")
                    }
                    .onFailure { error ->
                        DiagnosticLog.append(context, TAG, "System BLE bond remove failed", error)
                    }
            }
    }

    private fun removeSystemBluetoothBond(device: BluetoothDevice): Boolean {
        val method = device.javaClass.getMethod("removeBond")
        return method.invoke(device) as? Boolean ?: false
    }

    private companion object {
        const val TRANSFER_COMPRESSION_KEY = "downloadCompressionEnabled"
    }
}
