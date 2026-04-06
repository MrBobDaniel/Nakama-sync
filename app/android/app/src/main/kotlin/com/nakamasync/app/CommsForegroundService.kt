package com.nakamasync.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class CommsForegroundService : Service() {
    private var isForeground = false
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_UPDATE
        if (action == ACTION_STOP) {
            releaseWakeLock()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            isForeground = false
            return START_NOT_STICKY
        }

        val state = SessionState.fromIntent(intent)
        ensureNotificationChannel()
        acquireWakeLock()
        val notification = buildNotification(state)
        if (!isForeground) {
            startForeground(NOTIFICATION_ID, notification)
            isForeground = true
        } else {
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.notify(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        isForeground = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(state: SessionState): android.app.Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let { intent ->
            PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(
                if (state.roomId.isNullOrBlank()) {
                    "Nakama Sync comms"
                } else {
                    "Nakama Sync room ${state.roomId}"
                },
            )
            .setContentText(state.summaryText())
            .setStyle(NotificationCompat.BigTextStyle().bigText(state.detailsText()))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Nakama Sync Comms",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps walkie-talkie comms active while the device is locked."
            setShowBadge(false)
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) {
            return
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:commsPersistence",
        ).apply {
            setReferenceCounted(false)
            acquire(WAKELOCK_TIMEOUT_MILLIS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { lock ->
            if (lock.isHeld) {
                lock.release()
            }
        }
        wakeLock = null
    }

    data class SessionState(
        val roomId: String?,
        val displayName: String,
        val connectedPeers: Int,
        val isDiscovering: Boolean,
        val isReceivingAudio: Boolean,
        val isTransmitting: Boolean,
        val statusMessage: String,
        val isConnectionServiceActive: Boolean,
    ) {
        fun summaryText(): String {
            if (isTransmitting) {
                return "Transmitting to $connectedPeers peer(s)"
            }
            if (isReceivingAudio) {
                return "Receiving voice from nearby peer"
            }
            if (connectedPeers > 0) {
                return "Connected to $connectedPeers nearby peer(s)"
            }
            if (isDiscovering) {
                return "Scanning for nearby peers"
            }
            return "Room is open and listening in the background"
        }

        fun detailsText(): String {
            return buildString {
                append(summaryText())
                append(". ")
                append(statusMessage)
                if (isConnectionServiceActive) {
                    append(" Android ConnectionService priority is active.")
                }
            }
        }

        companion object {
            fun fromIntent(intent: Intent?): SessionState {
                return SessionState(
                    roomId = intent?.getStringExtra(EXTRA_ROOM_ID),
                    displayName = intent?.getStringExtra(EXTRA_DISPLAY_NAME)
                        ?: "Nakama Sync Android",
                    connectedPeers = intent?.getIntExtra(EXTRA_CONNECTED_PEERS, 0) ?: 0,
                    isDiscovering = intent?.getBooleanExtra(EXTRA_IS_DISCOVERING, false) ?: false,
                    isReceivingAudio = intent?.getBooleanExtra(EXTRA_IS_RECEIVING_AUDIO, false) ?: false,
                    isTransmitting = intent?.getBooleanExtra(EXTRA_IS_TRANSMITTING, false) ?: false,
                    statusMessage = intent?.getStringExtra(EXTRA_STATUS_MESSAGE)
                        ?: "Room is open and listening in the background.",
                    isConnectionServiceActive = intent?.getBooleanExtra(
                        EXTRA_IS_CONNECTION_SERVICE_ACTIVE,
                        false,
                    ) ?: false,
                )
            }
        }
    }

    companion object {
        private const val ACTION_UPDATE = "com.nakamasync.app.action.UPDATE_COMMS_NOTIFICATION"
        private const val ACTION_STOP = "com.nakamasync.app.action.STOP_COMMS_NOTIFICATION"
        private const val CHANNEL_ID = "nakama_sync_comms"
        private const val NOTIFICATION_ID = 4_201
        private const val WAKELOCK_TIMEOUT_MILLIS = 10 * 60 * 1000L

        private const val EXTRA_ROOM_ID = "room_id"
        private const val EXTRA_DISPLAY_NAME = "display_name"
        private const val EXTRA_CONNECTED_PEERS = "connected_peers"
        private const val EXTRA_IS_DISCOVERING = "is_discovering"
        private const val EXTRA_IS_RECEIVING_AUDIO = "is_receiving_audio"
        private const val EXTRA_IS_TRANSMITTING = "is_transmitting"
        private const val EXTRA_STATUS_MESSAGE = "status_message"
        private const val EXTRA_IS_CONNECTION_SERVICE_ACTIVE = "is_connection_service_active"

        fun createIntent(
            context: Context,
            state: CommsSessionManager.SessionState,
        ): Intent {
            return Intent(context, CommsForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_ROOM_ID, state.roomId)
                putExtra(EXTRA_DISPLAY_NAME, state.displayName)
                putExtra(EXTRA_CONNECTED_PEERS, state.connectedPeers)
                putExtra(EXTRA_IS_DISCOVERING, state.isDiscovering)
                putExtra(EXTRA_IS_RECEIVING_AUDIO, state.isReceivingAudio)
                putExtra(EXTRA_IS_TRANSMITTING, state.isTransmitting)
                putExtra(EXTRA_STATUS_MESSAGE, state.statusMessage)
                putExtra(
                    EXTRA_IS_CONNECTION_SERVICE_ACTIVE,
                    state.isConnectionServiceActive,
                )
            }
        }

        fun createStopIntent(context: Context): Intent {
            return Intent(context, CommsForegroundService::class.java).apply {
                action = ACTION_STOP
            }
        }
    }
}
