package com.nakamasync.app

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle

class CallConnectionService : ConnectionService() {
    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection {
        return FailedVoiceConnection()
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
}
