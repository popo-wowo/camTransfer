package com.camtransfer.wifi

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.PatternMatcher
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout

private const val TAG = "WifiConnector"

class WifiConnector(private val context: Context) {

    private var network: Network? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    val connectedNetwork: Network? get() = network

    suspend fun connect(ssid: String, password: String = "00000000", timeoutMs: Long = 30_000): Network {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        disconnect()

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsidPattern(PatternMatcher(ssid, PatternMatcher.PATTERN_PREFIX))
            .setWpa2Passphrase(password)
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val deferred = CompletableDeferred<Network>()

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(net: Network) {
                Log.d(TAG, "WiFi available: $net")
                cm.bindProcessToNetwork(net)
                network = net
                deferred.complete(net)
            }

            override fun onUnavailable() {
                Log.w(TAG, "WiFi unavailable")
                deferred.completeExceptionally(Exception("无法连接相机 WiFi: $ssid"))
            }

            override fun onLost(net: Network) {
                Log.w(TAG, "WiFi lost: $net")
                if (network == net) {
                    network = null
                    cm.bindProcessToNetwork(null)
                }
            }
        }

        callback = cb
        cm.requestNetwork(request, cb)
        Log.d(TAG, "Requesting WiFi: ssid=$ssid")

        return withTimeout(timeoutMs) { deferred.await() }
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
