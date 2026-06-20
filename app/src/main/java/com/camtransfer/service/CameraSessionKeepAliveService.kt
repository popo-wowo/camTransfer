package com.camtransfer.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.content.ContextCompat
import com.camtransfer.R

private const val KEEP_ALIVE_TAG = "CameraSessionKeepAlive"

object CameraSessionKeepAlive {
    fun start(context: Context) {
        val intent = Intent(context, CameraSessionKeepAliveService::class.java)
            .setAction(CameraSessionKeepAliveService.ACTION_START)
        ContextCompat.startForegroundService(context.applicationContext, intent)
    }

    fun stop(context: Context) {
        val intent = Intent(context, CameraSessionKeepAliveService::class.java)
        context.applicationContext.stopService(intent)
    }
}

class CameraSessionKeepAliveService : Service() {
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                startForegroundSession()
                acquireLocks()
                return START_NOT_STICKY
            }
        }
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun startForegroundSession() {
        ensureNotificationChannel()
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_camtransfer)
            .setContentTitle("CamTransfer 正在保持相机连接")
            .setContentText("锁屏或切到后台时继续保持相机 Wi-Fi 和相册通信")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        DiagnosticLog.append(applicationContext, KEEP_ALIVE_TAG, "Foreground keep-alive started")
    }

    private fun acquireLocks() {
        if (wifiLock?.isHeld != true) {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifiLock = wifiManager
                ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "$KEEP_ALIVE_TAG:wifi")
                ?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        if (wakeLock?.isHeld != true) {
            val powerManager = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$KEEP_ALIVE_TAG:wake")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        DiagnosticLog.append(
            applicationContext,
            KEEP_ALIVE_TAG,
            "Locks held wifi=${wifiLock?.isHeld == true} wake=${wakeLock?.isHeld == true}",
        )
    }

    private fun releaseLocks() {
        runCatching {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        }
        runCatching {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        }
        wifiLock = null
        wakeLock = null
        DiagnosticLog.append(applicationContext, KEEP_ALIVE_TAG, "Locks released")
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "相机连接保活",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "保持相机 Wi-Fi 和相册通信"
            }
        )
    }

    companion object {
        const val ACTION_START = "com.camtransfer.action.START_CAMERA_SESSION_KEEP_ALIVE"
        const val ACTION_STOP = "com.camtransfer.action.STOP_CAMERA_SESSION_KEEP_ALIVE"
        private const val CHANNEL_ID = "camera_session_keep_alive"
        private const val NOTIFICATION_ID = 4201
    }
}
