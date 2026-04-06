package com.nakamasync.app

import android.net.Uri
import android.os.Build
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

class CallConnectionService : ConnectionService() {
    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection {
        val roomId = request?.extras?.getString(EXTRA_ROOM_ID).orEmpty()
        val displayName = request?.extras?.getString(EXTRA_DISPLAY_NAME)
            ?: "Nakama Sync Android"
        val connection = WalkieTalkieConnection(roomId = roomId, displayName = displayName)
        CommsSessionManager.onConnectionCreated(connection)
        return connection
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection {
        return FailedVoiceConnection()
    }

    private class FailedVoiceConnection : Connection() {
        init {
            setDisconnected(DisconnectCause(DisconnectCause.ERROR))
            destroy()
        }
    }

    companion object {
        const val EXTRA_ROOM_ID = "com.nakamasync.app.EXTRA_ROOM_ID"
        const val EXTRA_DISPLAY_NAME = "com.nakamasync.app.EXTRA_DISPLAY_NAME"
    }
}

internal class WalkieTalkieConnection(
    roomId: String,
    displayName: String,
) : Connection() {
    private var hasDisconnected = false

    init {
        setConnectionCapabilities(CAPABILITY_MUTE)
        setAddress(
            Uri.fromParts(PhoneAccount.SCHEME_TEL, roomId.ifBlank { "nakama-sync" }, null),
            TelecomManager.PRESENTATION_ALLOWED,
        )
        setCallerDisplayName(displayName, TelecomManager.PRESENTATION_ALLOWED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setConnectionProperties(PROPERTY_SELF_MANAGED)
        }
        setAudioModeIsVoip(true)
        setInitializing()
        setActive()
    }

    override fun onDisconnect() {
        disconnectWithReason("ConnectionService session ended from Android system UI.")
    }

    override fun onAbort() {
        disconnectWithReason("ConnectionService session aborted by Android.")
    }

    override fun onAnswer() {
        setActive()
    }

    fun disconnectLocally() {
        disconnectWithReason(
            reason = "ConnectionService session closed locally.",
            notifyManager = false,
        )
    }

    private fun disconnectWithReason(
        reason: String,
        notifyManager: Boolean = true,
    ) {
        if (hasDisconnected) {
            return
        }
        hasDisconnected = true
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL, reason))
        destroy()
        if (notifyManager) {
            CommsSessionManager.onConnectionDestroyed(reason)
        }
    }
}
