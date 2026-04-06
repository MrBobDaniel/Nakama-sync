package com.nakamasync.app

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.core.content.ContextCompat

object CommsSessionManager {
    interface Listener {
        fun onSystemSessionEnded(reason: String)
    }

    data class StartResult(
        val isForegroundServiceActive: Boolean,
        val isConnectionServiceActive: Boolean,
        val message: String,
    )

    data class SessionState(
        val roomId: String? = null,
        val displayName: String = "Nakama Sync Android",
        val connectedPeers: Int = 0,
        val isDiscovering: Boolean = false,
        val isReceivingAudio: Boolean = false,
        val isTransmitting: Boolean = false,
        val statusMessage: String = "Room is idle.",
        val isSessionOpen: Boolean = false,
        val isConnectionServiceActive: Boolean = false,
    )

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var listener: Listener? = null

    @Volatile
    private var activeConnection: WalkieTalkieConnection? = null

    @Volatile
    private var latestState = SessionState()

    @Volatile
    private var suppressDisconnectCallback = false

    fun setListener(listener: Listener?) {
        this.listener = listener
    }

    fun startSession(
        context: Context,
        roomId: String,
        displayName: String,
    ): StartResult {
        rememberContext(context)
        latestState = SessionState(
            roomId = roomId,
            displayName = displayName,
            isDiscovering = true,
            statusMessage = "Android comms persistence is active.",
            isSessionOpen = true,
        )

        val foregroundStarted = startForegroundService(context)
        val connectionStarted = startConnectionServiceCall(context, roomId)
        updateForegroundService(context)

        val message = buildString {
            append(
                if (foregroundStarted) {
                    "Android foreground service is active"
                } else {
                    "Android foreground service could not be started"
                },
            )
            append(
                if (connectionStarted) {
                    "; ConnectionService call is active."
                } else {
                    "; ConnectionService call is unavailable on this device/build."
                },
            )
        }

        return StartResult(
            isForegroundServiceActive = foregroundStarted,
            isConnectionServiceActive = connectionStarted,
            message = message,
        )
    }

    fun updateSessionState(
        context: Context,
        transform: (SessionState) -> SessionState,
    ) {
        rememberContext(context)
        latestState = transform(latestState)
        if (latestState.isSessionOpen) {
            updateForegroundService(context)
        }
    }

    fun stopSession(context: Context) {
        rememberContext(context)
        latestState = latestState.copy(
            isSessionOpen = false,
            isDiscovering = false,
            isReceivingAudio = false,
            isTransmitting = false,
            connectedPeers = 0,
            statusMessage = "Android comms persistence stopped.",
            isConnectionServiceActive = false,
        )

        suppressDisconnectCallback = true
        activeConnection?.disconnectLocally()
        activeConnection = null
        suppressDisconnectCallback = false

        stopForegroundService(context)
    }

    internal fun onConnectionCreated(connection: WalkieTalkieConnection) {
        activeConnection = connection
        latestState = latestState.copy(isConnectionServiceActive = true)
        appContext?.let(::updateForegroundService)
    }

    internal fun onConnectionDestroyed(reason: String) {
        activeConnection = null
        latestState = latestState.copy(isConnectionServiceActive = false)
        appContext?.let(::updateForegroundService)

        if (!suppressDisconnectCallback) {
            mainHandler.post {
                listener?.onSystemSessionEnded(reason)
            }
        }
    }

    private fun rememberContext(context: Context) {
        appContext = context.applicationContext
    }

    private fun startForegroundService(context: Context): Boolean {
        return runCatching {
            ContextCompat.startForegroundService(
                context,
                CommsForegroundService.createIntent(context, latestState),
            )
        }.isSuccess
    }

    private fun updateForegroundService(context: Context) {
        runCatching {
            ContextCompat.startForegroundService(
                context,
                CommsForegroundService.createIntent(context, latestState),
            )
        }
    }

    private fun stopForegroundService(context: Context) {
        runCatching {
            context.startService(CommsForegroundService.createStopIntent(context))
        }
    }

    private fun startConnectionServiceCall(
        context: Context,
        roomId: String,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }

        val telecomManager = context.getSystemService(TelecomManager::class.java) ?: return false
        val accountHandle = phoneAccountHandle(context)
        val phoneAccount = PhoneAccount.builder(accountHandle, "Nakama Sync Walkie-Talkie")
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .setShortDescription("Keeps the Nakama Sync comms lane active while locked.")
            .setSupportedUriSchemes(listOf(PhoneAccount.SCHEME_TEL))
            .build()

        return runCatching {
            telecomManager.registerPhoneAccount(phoneAccount)
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, accountHandle)
                putBoolean(TelecomManager.EXTRA_START_CALL_WITH_SPEAKERPHONE, true)
                putString(CallConnectionService.EXTRA_ROOM_ID, roomId)
                putString(CallConnectionService.EXTRA_DISPLAY_NAME, latestState.displayName)
            }
            val callAddress = Uri.fromParts(
                PhoneAccount.SCHEME_TEL,
                roomId.ifBlank { "nakama-sync" },
                null,
            )
            telecomManager.placeCall(callAddress, extras)
        }.isSuccess
    }

    private fun phoneAccountHandle(context: Context): PhoneAccountHandle {
        return PhoneAccountHandle(
            ComponentName(context, CallConnectionService::class.java),
            PHONE_ACCOUNT_ID,
        )
    }

    private const val PHONE_ACCOUNT_ID = "nakama_sync_walkie_account"
}
