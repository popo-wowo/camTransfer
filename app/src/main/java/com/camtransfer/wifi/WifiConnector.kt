package com.camtransfer.wifi

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.MacAddress
import android.os.PatternMatcher
import android.os.SystemClock
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiManager
import android.util.Log
import com.camtransfer.service.DiagnosticLog
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

private const val TAG = "WifiConnector"

class WifiConnector(private val context: Context) {

    private var network: Network? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    val connectedNetwork: Network? get() = network

    suspend fun connect(
        configuration: CameraVendorWifiNetworkConfiguration,
        timeoutMs: Long = 30_000,
    ): Network {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

        disconnect()
        alreadyConnectedCameraWifi(cm, wifiManager, configuration)?.let { existing ->
            DiagnosticLog.append(context, TAG, "WiFi already connected before request hasBssid=${configuration.bssid != null}")
            cm.bindProcessToNetwork(existing)
            network = existing
            return existing
        }

        val builder = WifiNetworkSpecifier.Builder()
            .setSsidPattern(PatternMatcher(configuration.ssid, PatternMatcher.PATTERN_LITERAL))
            .setWpa2Passphrase(configuration.passphrase)
        if (configuration.isHidden) {
            builder.setIsHiddenSsid(true)
        }
        configuration.bssid?.let { bssid ->
            runCatching {
                builder.setBssid(MacAddress.fromString(bssid))
            }.onFailure { error ->
                DiagnosticLog.append(context, TAG, "WiFi BSSID ignored: invalid format", error)
            }
        }
        val specifier = builder.build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val deferred = CompletableDeferred<Network>()
        val requestStartMs = SystemClock.elapsedRealtime()

        fun elapsedMs(): Long = SystemClock.elapsedRealtime() - requestStartMs

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(net: Network) {
                Log.d(TAG, "WiFi available: $net elapsedMs=${elapsedMs()}")
                DiagnosticLog.append(
                    context,
                    TAG,
                    "WiFi available elapsedMs=${elapsedMs()} hidden=${configuration.isHidden} hasBssid=${configuration.bssid != null}",
                )
                cm.bindProcessToNetwork(net)
                network = net
                deferred.complete(net)
            }

            override fun onUnavailable() {
                Log.w(TAG, "WiFi unavailable elapsedMs=${elapsedMs()}")
                DiagnosticLog.append(
                    context,
                    TAG,
                    "WiFi unavailable elapsedMs=${elapsedMs()} hidden=${configuration.isHidden} hasBssid=${configuration.bssid != null}",
                )
                deferred.completeExceptionally(Exception("无法连接相机 WiFi: ${configuration.ssid}"))
            }

            override fun onLost(net: Network) {
                Log.w(TAG, "WiFi lost: $net")
                if (network == net) {
                    network = null
                    cm.bindProcessToNetwork(null)
                }
            }
        }

        runCatching {
            wifiManager?.startScan() == true
        }.onSuccess { started ->
            DiagnosticLog.append(context, TAG, "WiFi active scan requested started=$started")
        }.onFailure { error ->
            DiagnosticLog.append(context, TAG, "WiFi active scan request failed", error)
        }

        callback = cb
        cm.requestNetwork(request, cb)
        Log.d(
            TAG,
            "Requesting WiFi: ssid=${configuration.ssid} hidden=${configuration.isHidden} " +
                "hasBssid=${configuration.bssid != null} passphraseLength=${configuration.passphrase.length}",
        )
        DiagnosticLog.append(
            context,
            TAG,
            "WiFi request started hidden=${configuration.isHidden} hasBssid=${configuration.bssid != null} " +
                "timeoutMs=$timeoutMs passphraseLength=${configuration.passphrase.length}",
        )

        return try {
            awaitRequestedOrExistingNetwork(cm, wifiManager, configuration, deferred, timeoutMs, ::elapsedMs)
        } catch (error: TimeoutCancellationException) {
            DiagnosticLog.append(
                context,
                TAG,
                "WiFi request timed out elapsedMs=${elapsedMs()} hidden=${configuration.isHidden} " +
                    "hasBssid=${configuration.bssid != null} timeoutMs=$timeoutMs",
            )
            disconnect()
            throw error
        }
    }

    private suspend fun awaitRequestedOrExistingNetwork(
        cm: ConnectivityManager,
        wifiManager: WifiManager?,
        configuration: CameraVendorWifiNetworkConfiguration,
        deferred: CompletableDeferred<Network>,
        timeoutMs: Long,
        elapsedMs: () -> Long,
    ): Network = withTimeout(timeoutMs) {
        var lastKnownSsid: String? = null
        var lastKnownBssid: String? = null
        var matchedNetwork: Network? = null
        while (matchedNetwork == null) {
            alreadyConnectedCameraWifi(cm, wifiManager, configuration)?.let { existing ->
                DiagnosticLog.append(
                    context,
                    TAG,
                    "WiFi current network matched elapsedMs=${elapsedMs()} hasBssid=${configuration.bssid != null}",
                )
                cm.bindProcessToNetwork(existing)
                network = existing
                matchedNetwork = existing
            }

            if (matchedNetwork == null) {
                currentWifiIdentity(wifiManager)?.let { identity ->
                    if (identity.ssid != lastKnownSsid || identity.bssid != lastKnownBssid) {
                        lastKnownSsid = identity.ssid
                        lastKnownBssid = identity.bssid
                        DiagnosticLog.append(
                            context,
                            TAG,
                            "WiFi current network not matched elapsedMs=${elapsedMs()} " +
                                "ssidKnown=${!identity.ssid.isNullOrBlank()} bssidKnown=${!identity.bssid.isNullOrBlank()}",
                        )
                    }
                }

                val networkFromRequest = withTimeoutOrNull(CURRENT_WIFI_POLL_INTERVAL_MS) {
                    deferred.await()
                }
                if (networkFromRequest != null) matchedNetwork = networkFromRequest
            }
        }
        matchedNetwork
    }

    @SuppressLint("MissingPermission")
    private fun alreadyConnectedCameraWifi(
        cm: ConnectivityManager,
        wifiManager: WifiManager?,
        configuration: CameraVendorWifiNetworkConfiguration,
    ): Network? {
        val identity = currentWifiIdentity(wifiManager) ?: return null
        if (!CameraCurrentWifiMatchPolicy.matches(identity.ssid, identity.bssid, configuration)) return null
        return cm.allNetworks.firstOrNull { net ->
            cm.getNetworkCapabilities(net)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        } ?: cm.activeNetwork
    }

    @SuppressLint("MissingPermission")
    private fun currentWifiIdentity(wifiManager: WifiManager?): CurrentWifiIdentity? =
        runCatching {
            val info = wifiManager?.connectionInfo ?: return null
            CurrentWifiIdentity(ssid = info.ssid, bssid = info.bssid)
        }.getOrNull()

    fun disconnect() {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        callback?.let {
            cm.unregisterNetworkCallback(it)
            callback = null
        }
        cm.bindProcessToNetwork(null)
        network = null
    }

    private data class CurrentWifiIdentity(
        val ssid: String?,
        val bssid: String?,
    )

    private companion object {
        const val CURRENT_WIFI_POLL_INTERVAL_MS = 500L
    }
}

internal object CameraCurrentWifiMatchPolicy {
    fun matches(
        currentSsid: String?,
        currentBssid: String?,
        configuration: CameraVendorWifiNetworkConfiguration,
    ): Boolean {
        val ssid = normalizedSsid(currentSsid)
        if (ssid == null || !ssid.equals(configuration.ssid, ignoreCase = true)) return false
        val expectedBssid = configuration.bssid?.lowercase()
        if (expectedBssid != null) {
            return currentBssid?.lowercase() == expectedBssid
        }
        return true
    }

    private fun normalizedSsid(raw: String?): String? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty() || trimmed.equals("<unknown ssid>", ignoreCase = true)) return null
        return trimmed.removeSurrounding("\"").takeIf { it.isNotBlank() }
    }
}
