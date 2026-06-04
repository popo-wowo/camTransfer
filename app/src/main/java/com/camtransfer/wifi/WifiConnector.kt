package com.camtransfer.wifi

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
            withTimeout(timeoutMs) { deferred.await() }
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

    fun disconnect() {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        callback?.let {
            cm.unregisterNetworkCallback(it)
            callback = null
        }
        cm.bindProcessToNetwork(null)
        network = null
    }
}
