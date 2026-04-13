package com.nakamasync.app

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import android.util.Log
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.OutputStream
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

class NearbyConnectionsBridge(
    private val context: Context,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val logTag = "NakamaNearby"
    private val activity = context as? Activity
    private val strategy = Strategy.P2P_CLUSTER
    private val serviceId = "com.nakamasync.app.walkie"
    private val connectionsClient: ConnectionsClient = Nearby.getConnectionsClient(context)
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val communicationAudioController = CommunicationAudioController(context)
    private val activeEndpoints = linkedSetOf<String>()
    private val discoveredEndpoints = ConcurrentHashMap.newKeySet<String>()
    private val endpointRoomMatches = ConcurrentHashMap<String, Boolean>()
    private val endpointAudioConfigs = ConcurrentHashMap<String, NearbyAudioConfig>()
    private val peerSessions = ConcurrentHashMap<String, PeerSession>()
    private val pendingOutgoingConnections = ConcurrentHashMap.newKeySet<String>()
    private val pendingConnectionRequests = ConcurrentHashMap<String, Runnable>()
    private var eventSink: EventChannel.EventSink? = null
    private var roomId: String? = null
    private var displayName: String = "Nakama Sync Android"
    private var localPeerId: String = UUID.randomUUID().toString()
    private var localAudioConfig = NearbyAudioConfig()
    private var incomingAudioMixer = createIncomingAudioMixer()
    private var outgoingAudioFanout: OutgoingAudioFanout? = null
    private var pendingStartSessionResult: MethodChannel.Result? = null
    private var isDiscovering = false
    private var isDiscoveryStartInFlight = false
    private var discoveryStopRunnable: Runnable? = null
    private var isPushToTalkActive = false
    private var isVoiceActivationEnabled = false
    private var voiceActivationSensitivity = DEFAULT_VOICE_ACTIVATION_SENSITIVITY
    private var isMicrophoneMuted = false

    init {
        CommsSessionManager.setListener(
            object : CommsSessionManager.Listener {
                override fun onSystemSessionEnded(reason: String) {
                    mainHandler.post {
                        if (roomId == null) {
                            return@post
                        }
                        emit(
                            "error",
                            reason,
                            mapOf(
                                "isPersistentSessionActive" to false,
                                "isTelecomCallActive" to false,
                            ),
                        )
                        stopSession()
                    }
                }
            },
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startSession" -> {
                val roomArgument = call.argument<String>("roomId")
                val displayNameArgument = call.argument<String>("displayName")
                val normalizedRoomId = roomArgument?.trim()
                val normalizedDisplayName = displayNameArgument?.trim()
                if (normalizedRoomId.isNullOrEmpty() || normalizedDisplayName.isNullOrEmpty()) {
                    result.error("invalid_arguments", "roomId and displayName are required.", null)
                    return
                }

                roomId = normalizeRoomId(normalizedRoomId)
                displayName = normalizedDisplayName
                val arguments = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                localAudioConfig = parseAudioConfig(JSONObject(arguments))
                startSession(result)
            }

            "setPushToTalkActive" -> {
                val isActive = call.argument<Boolean>("isActive") ?: false
                setPushToTalkActive(isActive, result)
            }

            "configureVoiceActivation" -> {
                val isEnabled = call.argument<Boolean>("isEnabled") ?: false
                val sensitivity =
                    (call.argument<Number>("sensitivity")?.toDouble()
                        ?: DEFAULT_VOICE_ACTIVATION_SENSITIVITY)
                        .coerceIn(0.0, 1.0)
                configureVoiceActivation(isEnabled, sensitivity, result)
            }

            "setMicrophoneMuted" -> {
                val isMuted = call.argument<Boolean>("isMuted") ?: false
                setMicrophoneMuted(isMuted, result)
            }

            "stopSession" -> {
                stopSession()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        stopSession()
        CommsSessionManager.setListener(null)
        pendingStartSessionResult?.error("cancelled", "Nearby session setup was cancelled.", null)
        pendingStartSessionResult = null
        executor.shutdownNow()
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != REQUEST_PERMISSIONS_CODE) {
            return
        }

        val pendingResult = pendingStartSessionResult ?: return
        pendingStartSessionResult = null

        val allGranted = grantResults.isNotEmpty() &&
            grantResults.all { result -> result == PackageManager.PERMISSION_GRANTED }
        if (!allGranted) {
            emit("unsupported", "Nearby Connections requires Bluetooth, nearby devices, location, and microphone permissions.")
            pendingResult.error("missing_permissions", "Nearby Connections permissions are missing.", null)
            return
        }

        startSession(pendingResult)
    }

    private fun startSession(result: MethodChannel.Result) {
        if (!isPlayServicesAvailable()) {
            emit("unsupported", "Google Play services Nearby is unavailable.")
            result.error("play_services_unavailable", "Google Play services Nearby is unavailable.", null)
            return
        }

        val missingPermissions = getMissingPermissions()
        if (missingPermissions.isNotEmpty()) {
            val currentActivity = activity
            if (currentActivity == null) {
                emit("unsupported", "Nearby Connections permissions are missing and no Activity is available to request them.")
                result.error("missing_permissions", "Nearby Connections permissions are missing.", null)
                return
            }

            pendingStartSessionResult?.error("cancelled", "Nearby session setup was superseded by a new permission request.", null)
            pendingStartSessionResult = result
            currentActivity.requestPermissions(missingPermissions.toTypedArray(), REQUEST_PERMISSIONS_CODE)
            return
        }

        val requestedRoomId = roomId
        val requestedDisplayName = displayName
        val requestedPeerId = localPeerId
        val requestedAudioConfig = localAudioConfig
        stopSession()
        roomId = requestedRoomId
        displayName = requestedDisplayName
        localPeerId = requestedPeerId
        localAudioConfig = requestedAudioConfig
        incomingAudioMixer = createIncomingAudioMixer()

        val osSessionResult = CommsSessionManager.startSession(
            context = context,
            roomId = roomId.orEmpty(),
            displayName = displayName,
        )
        emit(
            "os_session_state",
            osSessionResult.message,
            mapOf(
                "isPersistentSessionActive" to osSessionResult.isForegroundServiceActive,
                "isTelecomCallActive" to osSessionResult.isConnectionServiceActive,
            ),
        )

        emit("session_started", "Opening room and starting Nearby advertising.", mapOf("isDiscovering" to true))

        val advertisingOptions = AdvertisingOptions.Builder()
            .setStrategy(strategy)
            .build()

        connectionsClient.startAdvertising(
            localEndpointInfo(),
            serviceId,
            connectionLifecycleCallback,
            advertisingOptions,
        ).addOnFailureListener { error ->
            emit("error", "Failed to advertise: ${error.localizedMessage ?: "unknown error"}")
        }

        startDiscoveryBurst("Scanning for nearby peers in this room.")
        result.success(null)
    }

    private fun setPushToTalkActive(isActive: Boolean, result: MethodChannel.Result) {
        if (isActive && isMicrophoneMuted) {
            emit("error", "Microphone permission is muted on this device.")
            result.error("microphone_muted", "Microphone is muted on this device.", null)
            return
        }

        val validatedEndpoints = connectedValidatedEndpointIds()
        if (isActive && validatedEndpoints.isEmpty()) {
            emit("error", "No validated Nearby peers are connected.")
            result.error("no_endpoint", "No validated Nearby peers are connected.", null)
            return
        }

        isPushToTalkActive = isActive

        if (isActive) {
            isVoiceActivationEnabled = false
            val fanout = outgoingAudioFanout ?: OutgoingAudioFanout(
                context = context,
                connectionsClient = connectionsClient,
                sampleRate = localAudioConfig.preferredSampleRate,
                codecForEndpoint = { endpointId -> agreedCodec(endpointId) },
                communicationAudioController = communicationAudioController,
                onTransmitStateChanged = { isTransmitting, message ->
                    emit(
                        "transmit_state",
                        message,
                        mapOf(
                            "isTransmitting" to isTransmitting,
                            "audioSampleRate" to localAudioConfig.preferredSampleRate,
                            "codec" to localAudioConfig.codec,
                        ),
                    )
                },
                onVoiceActivationArmedChanged = { isArmed ->
                    emit(
                        "voice_activation_state",
                        if (isArmed) {
                            "Voice activation is armed."
                        } else {
                            "Voice activation is idle."
                        },
                        mapOf("isVoiceActivationArmed" to isArmed),
                    )
                },
                onError = { message ->
                    emit("error", message)
                },
            ).also { createdFanout ->
                outgoingAudioFanout = createdFanout
                createdFanout.startManual(validatedEndpoints)
            }

            fanout.syncEndpoints(validatedEndpoints)
        } else {
            connectedValidatedEndpointIds().forEach { endpointId ->
                sendAudioControl(endpointId, "audio_stop")
            }
            outgoingAudioFanout?.stop()
            outgoingAudioFanout = null
        }

        result.success(null)
    }

    private fun configureVoiceActivation(
        isEnabled: Boolean,
        sensitivity: Double,
        result: MethodChannel.Result,
    ) {
        isVoiceActivationEnabled = isEnabled
        voiceActivationSensitivity = sensitivity
        isPushToTalkActive = false

        syncVoiceActivation()
        emit(
            "voice_activation_state",
            if (isEnabled) {
                "Voice activation configured."
            } else {
                "Voice activation disabled."
            },
            mapOf(
                "isVoiceActivationArmed" to (outgoingAudioFanout?.isVoiceActivationArmed() == true),
            ),
        )
        result.success(null)
    }

    private fun setMicrophoneMuted(
        isMuted: Boolean,
        result: MethodChannel.Result,
    ) {
        isMicrophoneMuted = isMuted
        if (isMuted) {
            isPushToTalkActive = false
            outgoingAudioFanout?.stop()
            outgoingAudioFanout = null
            connectedValidatedEndpointIds().forEach { endpointId ->
                sendAudioControl(endpointId, "audio_stop")
            }
        } else {
            syncVoiceActivation()
        }

        emit(
            "microphone_state",
            if (isMuted) {
                "Microphone muted on this device."
            } else {
                "Microphone unmuted on this device."
            },
            mapOf("isVoiceActivationArmed" to false),
        )
        result.success(null)
    }

    private fun stopSession() {
        isPushToTalkActive = false
        isVoiceActivationEnabled = false
        isMicrophoneMuted = false
        outgoingAudioFanout?.stop()
        outgoingAudioFanout = null
        incomingAudioMixer.stopAll()
        incomingAudioMixer = createIncomingAudioMixer()
        activeEndpoints.clear()
        discoveredEndpoints.clear()
        endpointRoomMatches.clear()
        endpointAudioConfigs.clear()
        peerSessions.clear()
        pendingOutgoingConnections.clear()
        pendingConnectionRequests.values.forEach(mainHandler::removeCallbacks)
        pendingConnectionRequests.clear()
        discoveryStopRunnable?.let(mainHandler::removeCallbacks)
        discoveryStopRunnable = null
        isDiscovering = false
        isDiscoveryStartInFlight = false
        connectionsClient.stopAllEndpoints()
        connectionsClient.stopAdvertising()
        connectionsClient.stopDiscovery()
        CommsSessionManager.stopSession(context)
        roomId = null
        localAudioConfig = NearbyAudioConfig()
    }

    private fun isPlayServicesAvailable(): Boolean {
        val status = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context)
        return status == ConnectionResult.SUCCESS
    }

    private fun getMissingPermissions(): List<String> {
        val permissions = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                add(Manifest.permission.BLUETOOTH_ADVERTISE)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.NEARBY_WIFI_DEVICES)
            }
        }

        return permissions.filter { permission ->
            ContextCompat.checkSelfPermission(context, permission) != PackageManager.PERMISSION_GRANTED
        }
    }

    private fun emit(event: String, message: String, extra: Map<String, Any?> = emptyMap()) {
        Log.i(
            logTag,
            buildString {
                append("event=")
                append(event)
                append(" roomId=")
                append(roomId ?: "null")
                append(" connectedPeers=")
                append(activeEndpoints.count { endpointRoomMatches[it] == true })
                append(" discovering=")
                append(isDiscovering)
                append(" tx=")
                append(outgoingAudioFanout?.isTransmittingActive() == true)
                append(" rx=")
                append(peerSessions.values.any { it.isSpeaking && it.isConnected })
                append(" message=")
                append(message)
                if (extra.isNotEmpty()) {
                    append(" extra=")
                    append(extra)
                }
            },
        )
        val payload = linkedMapOf<String, Any?>(
            "event" to event,
            "message" to message,
            "roomId" to roomId,
            "connectedPeers" to activeEndpoints.count { endpointRoomMatches[it] == true },
            "isDiscovering" to isDiscovering,
            "isReceivingAudio" to peerSessions.values.any { it.isSpeaking && it.isConnected },
            "isTransmitting" to (outgoingAudioFanout?.isTransmittingActive() == true),
            "transmitMode" to if (isVoiceActivationEnabled) "voice_activated" else "push_to_talk",
            "isVoiceActivationArmed" to (outgoingAudioFanout?.isVoiceActivationArmed() == true),
            "audioSampleRate" to localAudioConfig.preferredSampleRate,
            "codec" to localAudioConfig.codec,
            "frameDurationMs" to localAudioConfig.frameDurationMs,
            "transportVersion" to localAudioConfig.transportVersion,
            "peers" to peerSessions.values
                .sortedWith(compareBy<PeerSession>({ !it.isConnected }, { it.displayName.lowercase() }))
                .map { peer ->
                    mapOf(
                        "peerId" to peer.endpointId,
                        "displayName" to peer.displayName,
                        "isConnected" to peer.isConnected,
                        "isSpeaking" to peer.isSpeaking,
                        "streamSampleRate" to peer.streamSampleRate,
                        "codec" to peer.codec,
                    )
                },
        )
        payload.putAll(extra)
        CommsSessionManager.updateSessionState(context) { current ->
            current.copy(
                roomId = roomId,
                displayName = displayName,
                connectedPeers = activeEndpoints.count { endpointRoomMatches[it] == true },
                isDiscovering = isDiscovering,
                isReceivingAudio = peerSessions.values.any { it.isSpeaking && it.isConnected },
                isTransmitting = outgoingAudioFanout?.isTransmittingActive() == true,
                statusMessage = message,
                isSessionOpen = roomId != null,
            )
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(payload)
            return
        }

        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    private fun upsertPeer(
        endpointId: String,
        displayName: String?,
        isConnected: Boolean? = null,
        isSpeaking: Boolean? = null,
        streamSampleRate: Int? = null,
        codec: String? = null,
    ) {
        val existing = peerSessions[endpointId]
        peerSessions[endpointId] = PeerSession(
            endpointId = endpointId,
            displayName = displayName?.ifBlank { existing?.displayName ?: "Nearby peer" }
                ?: existing?.displayName
                ?: "Nearby peer",
            isConnected = isConnected ?: existing?.isConnected ?: false,
            isSpeaking = isSpeaking ?: existing?.isSpeaking ?: false,
            streamSampleRate = streamSampleRate ?: existing?.streamSampleRate ?: localAudioConfig.preferredSampleRate,
            codec = codec ?: existing?.codec ?: localAudioConfig.codec,
        )
    }

    private fun removePeer(endpointId: String) {
        peerSessions.remove(endpointId)
    }

    private fun updatePeerSpeaking(endpointId: String, isSpeaking: Boolean) {
        val existing = peerSessions[endpointId] ?: return
        if (existing.isSpeaking == isSpeaking) {
            return
        }
        peerSessions[endpointId] = existing.copy(isSpeaking = isSpeaking)
        communicationAudioController.updatePlaybackDucking(
            duckExternalAudio = peerSessions.values.any { it.isConnected && it.isSpeaking },
        )
        emit(
            "receive_state",
            if (isSpeaking) {
                "${existing.displayName} is speaking."
            } else {
                "${existing.displayName} stopped speaking."
            },
            mapOf(
                "peerId" to endpointId,
                "peerDisplayName" to existing.displayName,
                "isReceivingAudio" to peerSessions.values.any { it.isConnected && it.isSpeaking },
            ),
        )
    }

    private fun connectedValidatedEndpointIds(): Set<String> {
        return activeEndpoints.filterTo(linkedSetOf()) { endpointRoomMatches[it] == true }
    }

    private fun syncVoiceActivation() {
        if (!isVoiceActivationEnabled || isMicrophoneMuted) {
            outgoingAudioFanout?.stop()
            outgoingAudioFanout = null
            return
        }

        val validatedEndpoints = connectedValidatedEndpointIds()
        if (validatedEndpoints.isEmpty()) {
            outgoingAudioFanout?.stop()
            outgoingAudioFanout = null
            return
        }

        val fanout = outgoingAudioFanout ?: OutgoingAudioFanout(
            context = context,
            connectionsClient = connectionsClient,
            sampleRate = localAudioConfig.preferredSampleRate,
            codecForEndpoint = { endpointId -> agreedCodec(endpointId) },
            communicationAudioController = communicationAudioController,
            onTransmitStateChanged = { isTransmitting, message ->
                emit(
                    "transmit_state",
                    message,
                    mapOf(
                        "isTransmitting" to isTransmitting,
                        "audioSampleRate" to localAudioConfig.preferredSampleRate,
                        "codec" to localAudioConfig.codec,
                    ),
                )
                if (!isTransmitting) {
                    connectedValidatedEndpointIds().forEach { endpointId ->
                        sendAudioControl(endpointId, "audio_stop")
                    }
                }
            },
            onVoiceActivationArmedChanged = { isArmed ->
                emit(
                    "voice_activation_state",
                    if (isArmed) {
                        "Voice activation is armed."
                    } else {
                        "Voice activation is idle."
                    },
                    mapOf("isVoiceActivationArmed" to isArmed),
                )
            },
            onError = { message ->
                emit("error", message)
            },
        ).also {
            outgoingAudioFanout = it
            it.startVoiceActivated(
                sensitivity = voiceActivationSensitivity,
                initialEndpoints = validatedEndpoints,
            )
        }

        fanout.updateVoiceActivation(
            sensitivity = voiceActivationSensitivity,
            endpointIds = validatedEndpoints,
        )
    }

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            if (!discoveredEndpoints.add(endpointId)) {
                return
            }
            if (activeEndpoints.contains(endpointId) || pendingOutgoingConnections.contains(endpointId)) {
                return
            }

            val remoteEndpoint = parseEndpointInfo(info.endpointInfo)
            endpointAudioConfigs[endpointId] = remoteEndpoint.audioConfig
            if (!roomMatches(remoteEndpoint.roomId)) {
                return
            }

            val remoteName = remoteEndpoint.displayName ?: info.endpointName
            upsertPeer(endpointId, remoteName)
            if (shouldInitiateConnection(remoteEndpoint.peerId, endpointId)) {
                emit("peer_discovered", "Found nearby peer ${remoteName.ifBlank { "in this room" }}.")
                scheduleConnectionRequest(endpointId, remoteName)
            } else {
                emit("peer_discovered", "Found nearby peer ${remoteName.ifBlank { "in this room" }}. Waiting for inbound connection.")
            }
        }

        override fun onEndpointLost(endpointId: String) {
            cancelPendingConnectionRequest(endpointId)
            discoveredEndpoints.remove(endpointId)
            activeEndpoints.remove(endpointId)
            endpointRoomMatches.remove(endpointId)
            endpointAudioConfigs.remove(endpointId)
            incomingAudioMixer.stopEndpoint(endpointId)
            outgoingAudioFanout?.removeEndpoint(endpointId)
            removePeer(endpointId)
            emit("disconnected", "Nearby peer left range. Room remains open for reconnects.")
            if (isPushToTalkActive && connectedValidatedEndpointIds().isEmpty()) {
                outgoingAudioFanout?.stop()
                outgoingAudioFanout = null
            }
            syncVoiceActivation()
            startDiscoveryBurst("Peer left range. Continuing Nearby scan for reconnects.")
        }
    }

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            cancelPendingConnectionRequest(endpointId)
            val remoteEndpoint = parseEndpointInfo(info.endpointInfo)
            endpointAudioConfigs[endpointId] = remoteEndpoint.audioConfig
            if (!roomMatches(remoteEndpoint.roomId)) {
                endpointRoomMatches[endpointId] = false
                connectionsClient.rejectConnection(endpointId)
                emit("error", "Ignoring Nearby peer from a different room.")
                return
            }
            val remoteName = remoteEndpoint.displayName ?: info.endpointName
            upsertPeer(endpointId, remoteName)
            emit("connection_initiated", "Connection initiated with $remoteName.")
            connectionsClient.acceptConnection(endpointId, payloadCallback)
                .addOnFailureListener { error ->
                    emit("error", "Failed to accept connection: ${error.localizedMessage ?: "unknown error"}")
                }
        }

        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            cancelPendingConnectionRequest(endpointId)
            when (resolution.status.statusCode) {
                CommonStatusCodes.SUCCESS -> {
                    activeEndpoints.add(endpointId)
                    endpointRoomMatches[endpointId] = true
                    val remoteName = peerSessions[endpointId]?.displayName ?: "Nearby peer"
                    upsertPeer(
                        endpointId,
                        remoteName,
                        isConnected = true,
                        streamSampleRate = agreedSampleRate(endpointId),
                        codec = agreedCodec(endpointId),
                    )
                    sendHandshake(endpointId)
                    if (isPushToTalkActive) {
                        outgoingAudioFanout?.addEndpoint(endpointId)
                    }
                    if (isVoiceActivationEnabled) {
                        syncVoiceActivation()
                    }
                    emit("connected", "Connected to $remoteName over Nearby Connections.")
                }

                ConnectionsStatusCodes.STATUS_CONNECTION_REJECTED -> {
                    emit("error", "Nearby peer rejected the connection.")
                }

                else -> {
                    emit(
                        "error",
                        "Nearby connection failed: ${debugStatusLabel(resolution.status.statusCode)}.",
                    )
                }
            }
        }

        override fun onDisconnected(endpointId: String) {
            cancelPendingConnectionRequest(endpointId)
            activeEndpoints.remove(endpointId)
            endpointRoomMatches.remove(endpointId)
            endpointAudioConfigs.remove(endpointId)
            incomingAudioMixer.stopEndpoint(endpointId)
            outgoingAudioFanout?.removeEndpoint(endpointId)
            removePeer(endpointId)
            emit("disconnected", "Nearby peer disconnected. Room remains open for new connections.")
            if (isPushToTalkActive && connectedValidatedEndpointIds().isEmpty()) {
                outgoingAudioFanout?.stop()
                outgoingAudioFanout = null
            }
            syncVoiceActivation()
            startDiscoveryBurst("Peer disconnected. Continuing Nearby scan for another nearby peer.")
        }
    }

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            when (payload.type) {
                Payload.Type.STREAM -> {
                    if (endpointRoomMatches[endpointId] != true) {
                        emit("error", "Ignoring audio stream from unverified nearby peer.")
                        return
                    }
                    val inputStream = payload.asStream()?.asInputStream() ?: return
                    incomingAudioMixer.registerStream(endpointId, inputStream)
                    emit(
                        "stream_received",
                        "Incoming audio stream received from ${peerSessions[endpointId]?.displayName ?: "nearby peer"}.",
                    )
                }

                Payload.Type.BYTES -> handleBytesPayload(endpointId, payload)
                Payload.Type.FILE -> emit("file_received", "Received file payload from nearby peer.")
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
            if (update.status == PayloadTransferUpdate.Status.FAILURE) {
                emit("error", "Nearby payload transfer failed.")
            }
        }
    }

    private fun sendAudioControl(endpointId: String, type: String) {
        val localAudioConfig = buildLocalAudioConfig()
        val payload = JSONObject()
            .put("type", type)
            .put("roomId", roomId)
            .put("displayName", displayName)
            .put("peerId", localPeerId)
            .put("codec", localAudioConfig.codec)
            .put("preferredCodec", localAudioConfig.codec)
            .put("supportedCodecs", JSONArray(localAudioConfig.supportedCodecs))
            .put("preferredSampleRate", localAudioConfig.preferredSampleRate)
            .put("supportedSampleRates", JSONArray(localAudioConfig.supportedSampleRates))
            .put("frameDurationMs", localAudioConfig.frameDurationMs)
            .put("transportVersion", localAudioConfig.transportVersion)
            .toString()
            .toByteArray(Charsets.UTF_8)

        connectionsClient.sendPayload(endpointId, Payload.fromBytes(payload))
    }

    private fun sendHandshake(endpointId: String) {
        sendAudioControl(endpointId, "hello")
    }

    private fun handleBytesPayload(endpointId: String, payload: Payload) {
        val bytes = payload.asBytes() ?: return
        val json = runCatching {
            JSONObject(String(bytes, Charsets.UTF_8))
        }.getOrNull() ?: run {
            emit("bytes_received", "Received control payload from nearby peer.")
            return
        }

        when (json.optString("type")) {
            "audio_stop" -> {
                incomingAudioMixer.stopEndpoint(endpointId)
                return
            }

            "hello" -> Unit
            else -> {
                emit("bytes_received", "Received control payload from nearby peer.")
                return
            }
        }

        val localRoomId = normalizeRoomId(roomId)
        val peerRoomId = normalizeRoomId(json.optString("roomId").ifBlank { null })
        if (!localRoomId.isNullOrEmpty() && peerRoomId != localRoomId) {
            endpointRoomMatches[endpointId] = false
            activeEndpoints.remove(endpointId)
            outgoingAudioFanout?.removeEndpoint(endpointId)
            incomingAudioMixer.stopEndpoint(endpointId)
            connectionsClient.disconnectFromEndpoint(endpointId)
            removePeer(endpointId)
            emit("error", "Nearby peer is advertising a different room.")
            return
        }

        val remoteName = json.optString("displayName").ifBlank { peerSessions[endpointId]?.displayName ?: "Nearby peer" }
        endpointRoomMatches[endpointId] = true
        endpointAudioConfigs[endpointId] = parseAudioConfig(json)
        upsertPeer(
            endpointId,
            remoteName,
            isConnected = activeEndpoints.contains(endpointId),
            streamSampleRate = agreedSampleRate(endpointId),
            codec = agreedCodec(endpointId),
        )
        emit(
            "bytes_received",
            "Nearby peer metadata received.",
            mapOf(
                "peerId" to endpointId,
                "peerDisplayName" to remoteName,
                "audioSampleRate" to agreedSampleRate(endpointId),
                "codec" to agreedCodec(endpointId),
            ),
        )
    }

    private fun localEndpointInfo(): ByteArray {
        val localAudioConfig = buildLocalAudioConfig()
        return JSONObject()
            .put("roomId", roomId)
            .put("displayName", displayName)
            .put("peerId", localPeerId)
            .put("codec", localAudioConfig.codec)
            .put("preferredCodec", localAudioConfig.codec)
            .put("supportedCodecs", JSONArray(localAudioConfig.supportedCodecs))
            .put("preferredSampleRate", localAudioConfig.preferredSampleRate)
            .put("supportedSampleRates", JSONArray(localAudioConfig.supportedSampleRates))
            .put("frameDurationMs", localAudioConfig.frameDurationMs)
            .put("transportVersion", localAudioConfig.transportVersion)
            .toString()
            .toByteArray(Charsets.UTF_8)
    }

    private fun roomMatches(peerRoomId: String?): Boolean {
        val localRoomId = normalizeRoomId(roomId)
        val normalizedPeerRoomId = normalizeRoomId(peerRoomId)
        return localRoomId.isNullOrEmpty() || normalizedPeerRoomId == localRoomId
    }

    private fun normalizeRoomId(value: String?): String? {
        val normalized = value?.trim()?.lowercase()
        return if (normalized.isNullOrEmpty()) null else normalized
    }

    private fun shouldInitiateConnection(remotePeerId: String?, endpointId: String): Boolean {
        val normalizedRemotePeerId = remotePeerId?.trim()?.lowercase()
        val normalizedLocalPeerId = localPeerId.trim().lowercase()
        return if (normalizedRemotePeerId.isNullOrEmpty()) {
            endpointId.lowercase() >= normalizedLocalPeerId
        } else {
            normalizedLocalPeerId < normalizedRemotePeerId
        }
    }

    private fun parseEndpointInfo(endpointInfo: ByteArray?): NearbyEndpointInfo {
        if (endpointInfo == null || endpointInfo.isEmpty()) {
            return NearbyEndpointInfo()
        }

        val json = runCatching {
            JSONObject(String(endpointInfo, Charsets.UTF_8))
        }.getOrNull() ?: return NearbyEndpointInfo()

        return NearbyEndpointInfo(
            roomId = normalizeRoomId(json.optString("roomId").ifBlank { null }),
            displayName = json.optString("displayName").ifBlank { null },
            peerId = json.optString("peerId").ifBlank { null },
            audioConfig = parseAudioConfig(json),
        )
    }

    private fun parseAudioConfig(json: JSONObject): NearbyAudioConfig {
        return NearbyAudioConfig(
            codec = DEFAULT_CODEC,
            supportedCodecs = listOf(DEFAULT_CODEC),
            preferredSampleRate = DEFAULT_STREAM_SAMPLE_RATE,
            supportedSampleRates = listOf(DEFAULT_STREAM_SAMPLE_RATE),
            frameDurationMs = STREAM_CHUNK_MILLIS,
            transportVersion = CURRENT_TRANSPORT_VERSION,
        )
    }

    private fun buildLocalAudioConfig(): NearbyAudioConfig {
        return localAudioConfig
    }

    private fun audioConfigMismatchReason(remoteConfig: NearbyAudioConfig): String? {
        return when {
            remoteConfig.transportVersion != localAudioConfig.transportVersion ->
                "transport v${remoteConfig.transportVersion} does not match room transport v${localAudioConfig.transportVersion}"
            remoteConfig.codec != localAudioConfig.codec ->
                "codec ${remoteConfig.codec} does not match room codec ${localAudioConfig.codec}"
            remoteConfig.preferredSampleRate != localAudioConfig.preferredSampleRate ->
                "sample rate ${remoteConfig.preferredSampleRate} does not match room rate ${localAudioConfig.preferredSampleRate}"
            remoteConfig.frameDurationMs != localAudioConfig.frameDurationMs ->
                "frame duration ${remoteConfig.frameDurationMs}ms does not match room frame duration ${localAudioConfig.frameDurationMs}ms"
            else -> null
        }
    }

    private fun agreedSampleRate(endpointId: String): Int {
        // Keep one transport format per room until codec negotiation is fully room-wide.
        return localAudioConfig.preferredSampleRate
    }

    private fun agreedCodec(endpointId: String): String {
        // Avoid per-peer codec drift in the live transport. The local room profile
        // defines the active transport until Opus is reintroduced as a true room mode.
        return localAudioConfig.codec
    }

    private fun createIncomingAudioMixer(): IncomingAudioMixer {
        return IncomingAudioMixer(
            context = context,
            sampleRate = localAudioConfig.preferredSampleRate,
            codecForEndpoint = { endpointId -> agreedCodec(endpointId) },
            communicationAudioController = communicationAudioController,
            onPeerSpeakingChanged = { endpointId, isSpeaking ->
                updatePeerSpeaking(endpointId, isSpeaking)
            },
            onError = { message ->
                emit("error", message)
            },
        )
    }

    private fun startDiscoveryBurst(message: String) {
        discoveryStopRunnable?.let(mainHandler::removeCallbacks)

        if (isDiscovering || isDiscoveryStartInFlight) {
            emit("session_started", message, mapOf("isDiscovering" to true))
            return
        }

        val discoveryOptions = DiscoveryOptions.Builder()
            .setStrategy(strategy)
            .build()

        isDiscoveryStartInFlight = true
        isDiscovering = true
        connectionsClient.startDiscovery(
            serviceId,
            endpointDiscoveryCallback,
            discoveryOptions,
        ).addOnSuccessListener {
            isDiscoveryStartInFlight = false
            emit("session_started", message, mapOf("isDiscovering" to true))
        }.addOnFailureListener { error ->
            isDiscoveryStartInFlight = false
            isDiscovering = false
            emit("error", "Failed to discover peers: ${error.localizedMessage ?: "unknown error"}")
        }
    }

    private fun stopDiscovery() {
        discoveryStopRunnable?.let(mainHandler::removeCallbacks)
        discoveryStopRunnable = null
        if (!isDiscovering) {
            return
        }

        isDiscovering = false
        isDiscoveryStartInFlight = false
        connectionsClient.stopDiscovery()
    }

    private fun scheduleConnectionRequest(endpointId: String, remoteName: String) {
        if (activeEndpoints.contains(endpointId) || pendingOutgoingConnections.contains(endpointId)) {
            return
        }

        val runnable = Runnable {
            pendingConnectionRequests.remove(endpointId)
            if (activeEndpoints.contains(endpointId) || !discoveredEndpoints.contains(endpointId)) {
                return@Runnable
            }

            pendingOutgoingConnections.add(endpointId)
            connectionsClient.requestConnection(
                localEndpointInfo(),
                endpointId,
                connectionLifecycleCallback,
            ).addOnFailureListener { error ->
                pendingOutgoingConnections.remove(endpointId)
                discoveredEndpoints.remove(endpointId)
                handleRequestConnectionFailure(endpointId, remoteName, error)
            }
        }

        pendingConnectionRequests[endpointId] = runnable
        mainHandler.postDelayed(runnable, CONNECTION_REQUEST_DELAY_MILLIS)
    }

    private fun cancelPendingConnectionRequest(endpointId: String) {
        pendingOutgoingConnections.remove(endpointId)
        pendingConnectionRequests.remove(endpointId)?.let(mainHandler::removeCallbacks)
    }

    private fun handleRequestConnectionFailure(endpointId: String, remoteName: String, error: Exception) {
        val statusCode = error.asNearbyStatusCode()
        when (statusCode) {
            ConnectionsStatusCodes.STATUS_RADIO_ERROR,
            ConnectionsStatusCodes.STATUS_OUT_OF_ORDER_API_CALL,
            ConnectionsStatusCodes.STATUS_ALREADY_CONNECTED_TO_ENDPOINT, -> {
                emit(
                    "session_started",
                    "Nearby dial to ${remoteName.ifBlank { "peer" }} is deferred: ${userFacingStatus(statusCode)} Keeping the room open for inbound connections.",
                    mapOf("isDiscovering" to isDiscovering),
                )
                mainHandler.postDelayed(
                    { startDiscoveryBurst("Retrying Nearby scan while this room stays open.") },
                    CONNECTION_RETRY_DELAY_MILLIS,
                )
            }

            else -> {
                emit(
                    "error",
                    "Failed to request connection to ${remoteName.ifBlank { "peer" }}: ${userFacingStatus(statusCode)}.",
                )
            }
        }

        if (statusCode == ConnectionsStatusCodes.STATUS_RADIO_ERROR) {
            emit(
                "session_started",
                "Android Nearby radios are not fully ready (${radioStateSummary()}). Waiting for the peer to connect inbound or for the next scan retry.",
                mapOf("isDiscovering" to isDiscovering),
            )
        }

        cancelPendingConnectionRequest(endpointId)
    }

    private fun Exception.asNearbyStatusCode(): Int {
        return (this as? ApiException)?.statusCode ?: CommonStatusCodes.ERROR
    }

    private fun userFacingStatus(statusCode: Int): String {
        return when (statusCode) {
            ConnectionsStatusCodes.STATUS_RADIO_ERROR ->
                "the Android Bluetooth/Wi-Fi radio stack reported an error"
            ConnectionsStatusCodes.STATUS_OUT_OF_ORDER_API_CALL ->
                "Nearby was busy with another connection transition"
            ConnectionsStatusCodes.STATUS_ALREADY_CONNECTED_TO_ENDPOINT ->
                "the endpoint is already connected"
            else -> debugStatusLabel(statusCode)
        }
    }

    private fun debugStatusLabel(statusCode: Int): String {
        val debugCode = ConnectionsStatusCodes.getStatusCodeString(statusCode)
        return "$statusCode ($debugCode)"
    }

    private fun radioStateSummary(): String {
        val bluetoothEnabled = runCatching {
            val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            bluetoothManager?.adapter?.isEnabled
        }.getOrNull()
        val wifiEnabled = runCatching {
            val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifiManager?.isWifiEnabled
        }.getOrNull()

        val bluetoothState = bluetoothEnabled?.let { if (it) "Bluetooth on" else "Bluetooth off" } ?: "Bluetooth unknown"
        val wifiState = wifiEnabled?.let { if (it) "Wi-Fi on" else "Wi-Fi off" } ?: "Wi-Fi unknown"
        return "$bluetoothState, $wifiState"
    }

    private data class NearbyEndpointInfo(
        val roomId: String? = null,
        val displayName: String? = null,
        val peerId: String? = null,
        val audioConfig: NearbyAudioConfig = NearbyAudioConfig(),
    )

    private data class NearbyAudioConfig(
        val codec: String = DEFAULT_CODEC,
        val supportedCodecs: List<String> = listOf(DEFAULT_CODEC),
        val preferredSampleRate: Int = DEFAULT_STREAM_SAMPLE_RATE,
        val supportedSampleRates: List<Int> = listOf(DEFAULT_STREAM_SAMPLE_RATE),
        val frameDurationMs: Int = STREAM_CHUNK_MILLIS,
        val transportVersion: Int = CURRENT_TRANSPORT_VERSION,
    )

    private data class PeerSession(
        val endpointId: String,
        val displayName: String,
        val isConnected: Boolean,
        val isSpeaking: Boolean,
        val streamSampleRate: Int,
        val codec: String,
    )

    private class PeerPcmBuffer(
        private val frameBytes: Int,
    ) {
        private val lock = Any()
        private val chunks = ArrayDeque<ByteArray>()
        private val speechActivityTracker = SpeechActivityTracker(
            frameMillis = STREAM_CHUNK_MILLIS,
            sensitivity = 0.55,
        )
        private var headOffset = 0
        private var queuedBytes = 0

        fun append(data: ByteArray) {
            if (data.isEmpty()) {
                return
            }
            synchronized(lock) {
                chunks.addLast(data)
                queuedBytes += data.size
                trimLocked()
            }
        }

        fun drainFrame(): ByteArray? {
            synchronized(lock) {
                if (queuedBytes < frameBytes) {
                    return null
                }

                val frame = ByteArray(frameBytes)
                var written = 0
                while (written < frameBytes && chunks.isNotEmpty()) {
                    val head = chunks.first()
                    val available = head.size - headOffset
                    val copyCount = min(available, frameBytes - written)
                    System.arraycopy(head, headOffset, frame, written, copyCount)
                    written += copyCount
                    headOffset += copyCount
                    queuedBytes -= copyCount
                    if (headOffset >= head.size) {
                        chunks.removeFirst()
                        headOffset = 0
                    }
                }
                return frame
            }
        }

        fun updateSpeechActivity(frame: ByteArray): Boolean {
            synchronized(lock) {
                return speechActivityTracker.process(frame)
            }
        }

        private fun trimLocked() {
            val maxBufferedBytes = frameBytes * MAX_BUFFERED_FRAMES
            while (queuedBytes > maxBufferedBytes && chunks.isNotEmpty()) {
                val head = chunks.removeFirst()
                queuedBytes -= head.size - headOffset
                headOffset = 0
            }
        }
    }

    private class IncomingAudioMixer(
        private val context: Context,
        private val sampleRate: Int,
        private val codecForEndpoint: (String) -> String,
        private val communicationAudioController: CommunicationAudioController,
        private val onPeerSpeakingChanged: (String, Boolean) -> Unit,
        private val onError: (String) -> Unit,
    ) {
        private val isRunning = AtomicBoolean(false)
        private val peerBuffers = ConcurrentHashMap<String, PeerPcmBuffer>()
        private val readerWorkers = ConcurrentHashMap<String, ReaderWorker>()
        private val opusDecoders = ConcurrentHashMap<String, AndroidOpusDecoder>()
        private val mixerExecutor = Executors.newSingleThreadExecutor()

        fun registerStream(endpointId: String, inputStream: java.io.InputStream) {
            stopEndpoint(endpointId)
            peerBuffers[endpointId] = PeerPcmBuffer(frameBytes())
            val worker = ReaderWorker(
                endpointId = endpointId,
                inputStream = BufferedInputStream(inputStream),
                readBufferSize = max(frameBytes(), PACKET_HEADER_BYTES),
                onAudioData = { bytes ->
                    val decodedBytes = decodePacket(endpointId, bytes, codecForEndpoint(endpointId))
                    if (decodedBytes == null) {
                        return@ReaderWorker
                    }
                    val peerBuffer = peerBuffers[endpointId] ?: return@ReaderWorker
                    peerBuffer.append(decodedBytes)
                    onPeerSpeakingChanged(endpointId, peerBuffer.updateSpeechActivity(decodedBytes))
                },
                onFinished = {
                    stopEndpoint(endpointId)
                },
            )
            readerWorkers[endpointId] = worker
            worker.start()
            ensureMixerRunning()
        }

        fun stopEndpoint(endpointId: String) {
            readerWorkers.remove(endpointId)?.stop()
            peerBuffers.remove(endpointId)
            opusDecoders.remove(endpointId)?.release()
            onPeerSpeakingChanged(endpointId, false)
        }

        fun stopAll() {
            readerWorkers.keys.toList().forEach(::stopEndpoint)
            opusDecoders.values.forEach(AndroidOpusDecoder::release)
            opusDecoders.clear()
            if (isRunning.compareAndSet(true, false)) {
                communicationAudioController.releasePlayback()
            }
        }

        private fun ensureMixerRunning() {
            if (!isRunning.compareAndSet(false, true)) {
                return
            }

            mixerExecutor.execute {
                communicationAudioController.acquirePlayback()
                val audioTrack = buildAudioTrack(context, sampleRate, frameBytes())
                try {
                    audioTrack.play()
                    while (isRunning.get()) {
                        if (peerBuffers.isEmpty()) {
                            break
                        }

                        val mixedFrame = mixFrame()
                        if (mixedFrame != null) {
                            audioTrack.write(mixedFrame, 0, mixedFrame.size, AudioTrack.WRITE_BLOCKING)
                        }
                    }
                } catch (error: Exception) {
                    onError("Incoming audio mixer failed on Android: ${error.localizedMessage ?: "unknown error"}")
                } finally {
                    try {
                        audioTrack.stop()
                    } catch (_: Exception) {
                    }
                    audioTrack.release()
                    communicationAudioController.releasePlayback()
                    isRunning.set(false)
                }
            }
        }

        private fun mixFrame(): ByteArray? {
            val frames = peerBuffers.values.mapNotNull { it.drainFrame() }
            if (frames.isEmpty()) {
                Thread.sleep(STREAM_CHUNK_MILLIS.toLong())
                return null
            }

            val mixed = IntArray(frameBytes() / PCM_BYTES_PER_SAMPLE)
            frames.forEach { frame ->
                var sampleIndex = 0
                var byteIndex = 0
                while (byteIndex + 1 < frame.size && sampleIndex < mixed.size) {
                    val sample = (frame[byteIndex].toInt() and 0xFF) or (frame[byteIndex + 1].toInt() shl 8)
                    mixed[sampleIndex] += sample.toShort().toInt()
                    sampleIndex += 1
                    byteIndex += PCM_BYTES_PER_SAMPLE
                }
            }

            val output = ByteArray(frameBytes())
            mixed.forEachIndexed { index, value ->
                val clamped = value.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                output[index * PCM_BYTES_PER_SAMPLE] = (clamped.toInt() and 0xFF).toByte()
                output[index * PCM_BYTES_PER_SAMPLE + 1] = ((clamped.toInt() shr 8) and 0xFF).toByte()
            }
            return output
        }

        private fun frameBytes(): Int {
            return sampleRate * PCM_BYTES_PER_SAMPLE * STREAM_CHUNK_MILLIS / 1_000
        }

        private fun decodePacket(endpointId: String, packet: ByteArray, codec: String): ByteArray? {
            if (codec != OPUS_CODEC) {
                return packet
            }
            return try {
                val decoder = opusDecoders.getOrPut(endpointId) {
                    AndroidOpusDecoder(sampleRate)
                }
                decoder.decode(packet)
            } catch (error: Exception) {
                onError("Opus decode failed on Android: ${error.localizedMessage ?: "unknown error"}")
                null
            }
        }

        private class ReaderWorker(
            private val endpointId: String,
            private val inputStream: BufferedInputStream,
            private val readBufferSize: Int,
            private val onAudioData: (ByteArray) -> Unit,
            private val onFinished: () -> Unit,
        ) {
            private val running = AtomicBoolean(true)
            private val executor = Executors.newSingleThreadExecutor()
            private val pendingBytes = ArrayDeque<Byte>()

            fun start() {
                executor.execute {
                    val buffer = ByteArray(readBufferSize)
                    try {
                        while (running.get()) {
                            val count = inputStream.read(buffer)
                            if (count <= 0) {
                                break
                            }
                            appendIncomingBytes(buffer, count)
                        }
                    } catch (_: Exception) {
                    } finally {
                        stop()
                        onFinished()
                    }
                }
            }

            fun stop() {
                if (!running.compareAndSet(true, false)) {
                    return
                }
                try {
                    inputStream.close()
                } catch (_: Exception) {
                }
                executor.shutdownNow()
            }

            private fun appendIncomingBytes(buffer: ByteArray, count: Int) {
                repeat(count) { index ->
                    pendingBytes.addLast(buffer[index])
                }
                while (pendingBytes.size >= PACKET_HEADER_BYTES) {
                    val b0 = pendingBytes.removeFirst().toInt() and 0xFF
                    val b1 = pendingBytes.removeFirst().toInt() and 0xFF
                    val b2 = pendingBytes.removeFirst().toInt() and 0xFF
                    val b3 = pendingBytes.removeFirst().toInt() and 0xFF
                    val packetLength = (b0 shl 24) or (b1 shl 16) or (b2 shl 8) or b3
                    if (packetLength <= 0 || packetLength > MAX_PACKET_BYTES) {
                        pendingBytes.clear()
                        break
                    }
                    if (pendingBytes.size < packetLength) {
                        pendingBytes.addFirst(b3.toByte())
                        pendingBytes.addFirst(b2.toByte())
                        pendingBytes.addFirst(b1.toByte())
                        pendingBytes.addFirst(b0.toByte())
                        break
                    }
                    val packet = ByteArray(packetLength)
                    repeat(packetLength) { packetIndex ->
                        packet[packetIndex] = pendingBytes.removeFirst()
                    }
                    onAudioData(packet)
                }
            }
        }
    }

    private class OutgoingAudioFanout(
        private val context: Context,
        private val connectionsClient: ConnectionsClient,
        private val sampleRate: Int,
        private val codecForEndpoint: (String) -> String,
        private val communicationAudioController: CommunicationAudioController,
        private val onTransmitStateChanged: (Boolean, String) -> Unit,
        private val onVoiceActivationArmedChanged: (Boolean) -> Unit,
        private val onError: (String) -> Unit,
    ) {
        private val isRunning = AtomicBoolean(false)
        private val captureExecutor = Executors.newSingleThreadExecutor()
        private val lock = Any()
        private val endpointOutputs = ConcurrentHashMap<String, OutputStream>()
        private val endpointIds = linkedSetOf<String>()
        private val preRollFrames = ArrayDeque<ByteArray>()
        private val voiceActivationProcessor = VoiceActivationProcessor(
            frameMillis = STREAM_CHUNK_MILLIS,
            sensitivity = DEFAULT_VOICE_ACTIVATION_SENSITIVITY,
        )
        private var audioRecord: AudioRecord? = null
        private var noiseSuppressor: NoiseSuppressor? = null
        private var acousticEchoCanceler: AcousticEchoCanceler? = null
        private var automaticGainControl: AutomaticGainControl? = null
        private var opusEncoder: AndroidOpusEncoder? = null
        private var captureMode = CaptureMode.MANUAL
        private var isCurrentlyTransmitting = false
        private var isVoiceActivationArmed = false

        fun startManual(initialEndpoints: Set<String>) {
            captureMode = CaptureMode.MANUAL
            synchronized(lock) {
                endpointIds.clear()
                endpointIds.addAll(initialEndpoints)
            }
            startCaptureIfNeeded()
        }

        fun startVoiceActivated(
            sensitivity: Double,
            initialEndpoints: Set<String>,
        ) {
            captureMode = CaptureMode.VOICE_ACTIVATED
            voiceActivationProcessor.updateSensitivity(sensitivity)
            synchronized(lock) {
                endpointIds.clear()
                endpointIds.addAll(initialEndpoints)
            }
            startCaptureIfNeeded()
            setVoiceActivationArmed(initialEndpoints.isNotEmpty())
        }

        fun updateVoiceActivation(
            sensitivity: Double,
            endpointIds: Set<String>,
        ) {
            voiceActivationProcessor.updateSensitivity(sensitivity)
            synchronized(lock) {
                this.endpointIds.clear()
                this.endpointIds.addAll(endpointIds)
            }
            syncEndpoints(endpointIds)
            setVoiceActivationArmed(captureMode == CaptureMode.VOICE_ACTIVATED && endpointIds.isNotEmpty())
            if (endpointIds.isEmpty()) {
                stopTransmittingInternal(notify = true)
            }
        }

        fun isVoiceActivationArmed(): Boolean = isVoiceActivationArmed

        private fun startCaptureIfNeeded() {
            if (!isRunning.compareAndSet(false, true)) {
                return
            }

            communicationAudioController.acquireCapture(
                duckExternalAudio = captureMode == CaptureMode.MANUAL,
            )
            val minBufferSize = AudioRecord.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val frameBytes = frameBytes()
            val recordBuilder = AudioRecord.Builder()
                .setAudioSource(selectCaptureAudioSource())
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(max(minBufferSize, frameBytes * DEFAULT_BUFFER_CHUNKS))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                recordBuilder.setPrivacySensitive(true)
            }
            val record = recordBuilder.build()
            audioRecord = record
            attachVoiceEffects(record.audioSessionId)

            captureExecutor.execute {
                val buffer = ByteArray(frameBytes)
                try {
                    record.startRecording()
                    if (captureMode == CaptureMode.MANUAL) {
                        setTransmitting(
                            isTransmitting = true,
                            message = "Streaming microphone audio to ${endpointIdsSnapshot().size} peer(s).",
                        )
                    }
                    while (isRunning.get()) {
                        val readCount = record.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                        if (readCount > 0) {
                            handleCapturedFrame(buffer.copyOf(readCount))
                        }
                    }
                } catch (error: Exception) {
                    onError("Outgoing audio capture failed on Android: ${error.localizedMessage ?: "unknown error"}")
                } finally {
                    stop()
                }
            }
        }

        fun syncEndpoints(endpointIds: Set<String>) {
            synchronized(lock) {
                this.endpointIds.clear()
                this.endpointIds.addAll(endpointIds)
            }
            endpointOutputs.keys.toList()
                .filterNot(endpointIds::contains)
                .forEach(::removeEndpoint)
            if (captureMode == CaptureMode.MANUAL || isCurrentlyTransmitting) {
                endpointIds.forEach { endpointId ->
                    addEndpoint(endpointId)
                    if (captureMode == CaptureMode.VOICE_ACTIVATED && isCurrentlyTransmitting) {
                        replayPreRoll(endpointId)
                    }
                }
            }
        }

        fun addEndpoint(endpointId: String) {
            if (!isRunning.get() || endpointOutputs.containsKey(endpointId)) {
                return
            }

            val pipe = android.os.ParcelFileDescriptor.createPipe()
            val input = android.os.ParcelFileDescriptor.AutoCloseInputStream(pipe[0])
            val output = android.os.ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
            endpointOutputs[endpointId] = output
            connectionsClient.sendPayload(endpointId, Payload.fromStream(input))
        }

        fun removeEndpoint(endpointId: String) {
            endpointOutputs.remove(endpointId)?.let { stream ->
                try {
                    stream.close()
                } catch (_: Exception) {
                }
            }
        }

        fun stop() {
            setVoiceActivationArmed(false)
            stopTransmittingInternal(notify = true)
            if (!isRunning.compareAndSet(true, false)) {
                endpointOutputs.keys.toList().forEach(::removeEndpoint)
                return
            }

            endpointOutputs.keys.toList().forEach(::removeEndpoint)
            try {
                audioRecord?.stop()
            } catch (_: Exception) {
            }
            noiseSuppressor?.release()
            acousticEchoCanceler?.release()
            automaticGainControl?.release()
            noiseSuppressor = null
            acousticEchoCanceler = null
            automaticGainControl = null
            opusEncoder?.release()
            opusEncoder = null
            audioRecord?.release()
            audioRecord = null
            communicationAudioController.releaseCapture()
        }

        fun isRunning(): Boolean = isRunning.get()

        fun isTransmittingActive(): Boolean = isCurrentlyTransmitting

        private fun handleCapturedFrame(frame: ByteArray) {
            if (captureMode == CaptureMode.MANUAL) {
                if (endpointOutputs.isEmpty()) {
                    syncEndpoints(endpointIdsSnapshot())
                }
                broadcastFrame(frame)
                return
            }

            pushPreRollFrame(frame)
            val decision = voiceActivationProcessor.process(frame)
            if (decision.shouldStartTransmitting && !isCurrentlyTransmitting) {
                val endpoints = endpointIdsSnapshot()
                if (endpoints.isNotEmpty()) {
                    syncEndpoints(endpoints)
                    preRollFrames.forEach(::broadcastFrame)
                    setTransmitting(
                        isTransmitting = true,
                        message = "Voice activation opened transmit to ${endpoints.size} peer(s).",
                    )
                }
            }

            if (isCurrentlyTransmitting) {
                broadcastFrame(frame)
            }

            if (decision.shouldStopTransmitting && isCurrentlyTransmitting) {
                stopTransmittingInternal(notify = true)
            }
        }

        private fun broadcastFrame(frame: ByteArray) {
            endpointOutputs.entries.toList().forEach { (endpointId, stream) ->
                try {
                    val encodedPayload = encodePayload(frame, codecForEndpoint(endpointId)) ?: return@forEach
                    stream.write(encodePacket(encodedPayload))
                    stream.flush()
                } catch (_: Exception) {
                    removeEndpoint(endpointId)
                }
            }
        }

        private fun frameBytes(): Int {
            return sampleRate * PCM_BYTES_PER_SAMPLE * STREAM_CHUNK_MILLIS / 1_000
        }

        private fun endpointIdsSnapshot(): Set<String> {
            synchronized(lock) {
                return endpointIds.toSet()
            }
        }

        private fun pushPreRollFrame(frame: ByteArray) {
            synchronized(lock) {
                preRollFrames.addLast(frame)
                while (preRollFrames.size > VOICE_PRE_ROLL_FRAMES) {
                    preRollFrames.removeFirst()
                }
            }
        }

        private fun replayPreRoll(endpointId: String) {
            val stream = endpointOutputs[endpointId] ?: return
            val frames = synchronized(lock) { preRollFrames.toList() }
            frames.forEach { frame ->
                try {
                    val encodedPayload = encodePayload(frame, codecForEndpoint(endpointId)) ?: return@forEach
                    stream.write(encodePacket(encodedPayload))
                    stream.flush()
                } catch (_: Exception) {
                    removeEndpoint(endpointId)
                    return
                }
            }
        }

        private fun setVoiceActivationArmed(isArmed: Boolean) {
            if (isVoiceActivationArmed == isArmed) {
                return
            }
            isVoiceActivationArmed = isArmed
            onVoiceActivationArmedChanged(isArmed)
        }

        private fun setTransmitting(
            isTransmitting: Boolean,
            message: String,
        ) {
            if (isCurrentlyTransmitting == isTransmitting) {
                return
            }
            isCurrentlyTransmitting = isTransmitting
            communicationAudioController.updateCaptureDucking(
                duckExternalAudio = captureMode == CaptureMode.MANUAL || isTransmitting,
            )
            onTransmitStateChanged(isTransmitting, message)
        }

        private fun stopTransmittingInternal(notify: Boolean) {
            if (captureMode == CaptureMode.VOICE_ACTIVATED) {
                voiceActivationProcessor.resetSpeechState()
            }
            endpointOutputs.keys.toList().forEach(::removeEndpoint)
            if (notify && isCurrentlyTransmitting) {
                setTransmitting(false, "Transmit is idle.")
            } else {
                isCurrentlyTransmitting = false
            }
        }

        private fun attachVoiceEffects(audioSessionId: Int) {
            if (NoiseSuppressor.isAvailable()) {
                noiseSuppressor = NoiseSuppressor.create(audioSessionId)?.also { effect ->
                    effect.enabled = true
                }
            }
            if (AcousticEchoCanceler.isAvailable()) {
                acousticEchoCanceler = AcousticEchoCanceler.create(audioSessionId)?.also { effect ->
                    effect.enabled = true
                }
            }
            if (AutomaticGainControl.isAvailable()) {
                automaticGainControl = AutomaticGainControl.create(audioSessionId)?.also { effect ->
                    effect.enabled = true
                }
            }
        }

        private fun selectCaptureAudioSource(): Int {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaRecorder.AudioSource.VOICE_PERFORMANCE
            } else {
                MediaRecorder.AudioSource.VOICE_COMMUNICATION
            }
        }

        private enum class CaptureMode {
            MANUAL,
            VOICE_ACTIVATED,
        }

        private fun encodePacket(frame: ByteArray): ByteArray {
            val packet = ByteArray(PACKET_HEADER_BYTES + frame.size)
            val length = frame.size
            packet[0] = ((length ushr 24) and 0xFF).toByte()
            packet[1] = ((length ushr 16) and 0xFF).toByte()
            packet[2] = ((length ushr 8) and 0xFF).toByte()
            packet[3] = (length and 0xFF).toByte()
            System.arraycopy(frame, 0, packet, PACKET_HEADER_BYTES, frame.size)
            return packet
        }

        private fun encodePayload(frame: ByteArray, codec: String): ByteArray? {
            if (codec != OPUS_CODEC) {
                return frame
            }
            return try {
                val encoder = opusEncoder ?: AndroidOpusEncoder(sampleRate).also { opusEncoder = it }
                encoder.encode(frame)
            } catch (error: Exception) {
                onError("Opus encode failed on Android: ${error.localizedMessage ?: "unknown error"}")
                null
            }
        }
    }

    private class AndroidOpusEncoder(
        sampleRate: Int,
    ) {
        private val codec =
            MediaCodec.createEncoderByType(OPUS_MIME_TYPE).apply {
                val format = MediaFormat.createAudioFormat(OPUS_MIME_TYPE, sampleRate, 1).apply {
                    setInteger(MediaFormat.KEY_BIT_RATE, targetBitrate(sampleRate))
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, max(sampleRate / 25, 4096))
                }
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                start()
            }
        private val bufferInfo = MediaCodec.BufferInfo()
        private var presentationTimeUs = 0L

        fun encode(pcmFrame: ByteArray): ByteArray? {
            val inputIndex = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
            if (inputIndex >= 0) {
                codec.getInputBuffer(inputIndex)?.apply {
                    clear()
                    put(pcmFrame)
                }
                codec.queueInputBuffer(inputIndex, 0, pcmFrame.size, presentationTimeUs, 0)
                presentationTimeUs += STREAM_CHUNK_MILLIS * 1000L
            } else {
                return null
            }

            val packets = mutableListOf<ByteArray>()
            while (true) {
                val outputIndex = codec.dequeueOutputBuffer(bufferInfo, CODEC_TIMEOUT_US)
                when {
                    outputIndex >= 0 -> {
                        val outputBuffer = codec.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && bufferInfo.size > 0 &&
                            bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                        ) {
                            val packet = ByteArray(bufferInfo.size)
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            outputBuffer.get(packet)
                            packets.add(packet)
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ||
                        outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                    else -> break
                }
            }
            return when (packets.size) {
                0 -> null
                1 -> packets.first()
                else -> packets.fold(ByteArray(0)) { acc, bytes -> acc + bytes }
            }
        }

        fun release() {
            codec.stop()
            codec.release()
        }

        private fun targetBitrate(sampleRate: Int): Int {
            return when {
                sampleRate >= 48_000 -> 32_000
                sampleRate >= 24_000 -> 24_000
                else -> 16_000
            }
        }
    }

    private class AndroidOpusDecoder(
        sampleRate: Int,
    ) {
        private val codec =
            MediaCodec.createDecoderByType(OPUS_MIME_TYPE).apply {
                val format = MediaFormat.createAudioFormat(OPUS_MIME_TYPE, sampleRate, 1).apply {
                    setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                }
                configure(format, null, null, 0)
                start()
            }
        private val bufferInfo = MediaCodec.BufferInfo()
        private var presentationTimeUs = 0L

        fun decode(packet: ByteArray): ByteArray? {
            val inputIndex = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
            if (inputIndex >= 0) {
                codec.getInputBuffer(inputIndex)?.apply {
                    clear()
                    put(packet)
                }
                codec.queueInputBuffer(inputIndex, 0, packet.size, presentationTimeUs, 0)
                presentationTimeUs += STREAM_CHUNK_MILLIS * 1000L
            } else {
                return null
            }

            val pcmChunks = mutableListOf<ByteArray>()
            while (true) {
                val outputIndex = codec.dequeueOutputBuffer(bufferInfo, CODEC_TIMEOUT_US)
                when {
                    outputIndex >= 0 -> {
                        val outputBuffer = codec.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && bufferInfo.size > 0) {
                            val pcm = ByteArray(bufferInfo.size)
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            outputBuffer.get(pcm)
                            pcmChunks.add(pcm)
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ||
                        outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                    else -> break
                }
            }
            return when (pcmChunks.size) {
                0 -> null
                1 -> pcmChunks.first()
                else -> pcmChunks.fold(ByteArray(0)) { acc, bytes -> acc + bytes }
            }
        }

        fun release() {
            codec.stop()
            codec.release()
        }
    }

    private class VoiceActivationProcessor(
        private val frameMillis: Int,
        sensitivity: Double,
    ) {
        private var dynamicFloor = 0.008
        private var attackFrames = 0
        private var releaseFrames = 0
        private var isSpeechActive = false
        private var sensitivity = sensitivity

        fun updateSensitivity(sensitivity: Double) {
            this.sensitivity = sensitivity.coerceIn(0.0, 1.0)
        }

        fun resetSpeechState() {
            attackFrames = 0
            releaseFrames = 0
            isSpeechActive = false
        }

        fun process(frame: ByteArray): VoiceActivationDecision {
            val rms = frameRms(frame)
            val attackBoost = 0.02 - (sensitivity * 0.012)
            val releaseBoost = attackBoost * 0.55
            val startThreshold = max(dynamicFloor * 2.1, dynamicFloor + attackBoost)
            val stopThreshold = max(dynamicFloor * 1.45, dynamicFloor + releaseBoost)

            if (!isSpeechActive || rms < stopThreshold) {
                dynamicFloor = (dynamicFloor * 0.985) + (rms * 0.015)
            } else {
                dynamicFloor = (dynamicFloor * 0.998) + (rms * 0.002)
            }

            var shouldStart = false
            var shouldStop = false
            if (!isSpeechActive) {
                if (rms >= startThreshold) {
                    attackFrames += 1
                    if (attackFrames >= VOICE_ATTACK_FRAMES) {
                        attackFrames = 0
                        releaseFrames = 0
                        isSpeechActive = true
                        shouldStart = true
                    }
                } else {
                    attackFrames = 0
                }
            } else {
                if (rms < stopThreshold) {
                    releaseFrames += 1
                    if (releaseFrames * frameMillis >= VOICE_RELEASE_HANGOVER_MILLIS) {
                        releaseFrames = 0
                        attackFrames = 0
                        isSpeechActive = false
                        shouldStop = true
                    }
                } else {
                    releaseFrames = 0
                }
            }

            return VoiceActivationDecision(
                shouldStartTransmitting = shouldStart,
                shouldStopTransmitting = shouldStop,
            )
        }

        private fun frameRms(frame: ByteArray): Double {
            var sumSquares = 0.0
            var sampleCount = 0
            var index = 0
            while (index + 1 < frame.size) {
                val sample = ((frame[index].toInt() and 0xFF) or (frame[index + 1].toInt() shl 8)).toShort()
                val normalized = sample / 32768.0
                sumSquares += normalized * normalized
                sampleCount += 1
                index += PCM_BYTES_PER_SAMPLE
            }
            if (sampleCount == 0) {
                return 0.0
            }
            return kotlin.math.sqrt(sumSquares / sampleCount.toDouble())
        }
    }

    private data class VoiceActivationDecision(
        val shouldStartTransmitting: Boolean,
        val shouldStopTransmitting: Boolean,
    )

    private class SpeechActivityTracker(
        private val frameMillis: Int,
        sensitivity: Double,
    ) {
        private var dynamicFloor = 0.008
        private var attackFrames = 0
        private var releaseFrames = 0
        private var isSpeechActive = false
        private var sensitivity = sensitivity

        fun process(frame: ByteArray): Boolean {
            val rms = frameRms(frame)
            val attackBoost = 0.02 - (sensitivity * 0.012)
            val releaseBoost = attackBoost * 0.55
            val startThreshold = max(dynamicFloor * 2.1, dynamicFloor + attackBoost)
            val stopThreshold = max(dynamicFloor * 1.45, dynamicFloor + releaseBoost)

            if (!isSpeechActive || rms < stopThreshold) {
                dynamicFloor = (dynamicFloor * 0.985) + (rms * 0.015)
            } else {
                dynamicFloor = (dynamicFloor * 0.998) + (rms * 0.002)
            }

            if (!isSpeechActive) {
                if (rms >= startThreshold) {
                    attackFrames += 1
                    if (attackFrames >= VOICE_ATTACK_FRAMES) {
                        attackFrames = 0
                        releaseFrames = 0
                        isSpeechActive = true
                    }
                } else {
                    attackFrames = 0
                }
            } else if (rms < stopThreshold) {
                releaseFrames += 1
                if (releaseFrames * frameMillis >= VOICE_RELEASE_HANGOVER_MILLIS) {
                    releaseFrames = 0
                    attackFrames = 0
                    isSpeechActive = false
                }
            } else {
                releaseFrames = 0
            }

            return isSpeechActive
        }

        private fun frameRms(frame: ByteArray): Double {
            var sumSquares = 0.0
            var sampleCount = 0
            var index = 0
            while (index + 1 < frame.size) {
                val sample = ((frame[index].toInt() and 0xFF) or (frame[index + 1].toInt() shl 8)).toShort()
                val normalized = sample / 32768.0
                sumSquares += normalized * normalized
                sampleCount += 1
                index += PCM_BYTES_PER_SAMPLE
            }
            if (sampleCount == 0) {
                return 0.0
            }
            return kotlin.math.sqrt(sumSquares / sampleCount.toDouble())
        }
    }

    private class CommunicationAudioController(
        context: Context,
    ) {
        private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { }
        private val lock = Any()
        private var playbackUsers = 0
        private var captureUsers = 0
        private var duckingCaptureUsers = 0
        private var playbackDuckingActive = false
        private var audioFocusRequest: AudioFocusRequest? = null
        private var isLegacyFocusHeld = false
        private var previousMode: Int? = null
        private var previousMicrophoneMuteState: Boolean? = null

        fun acquirePlayback() {
            synchronized(lock) {
                val hadUsers = totalUsers() > 0
                playbackUsers += 1
                if (!hadUsers) {
                    previousMode = audioManager.mode
                    previousMicrophoneMuteState = audioManager.isMicrophoneMute
                }
                applyAudioStateLocked()
            }
        }

        fun updatePlaybackDucking(duckExternalAudio: Boolean) {
            synchronized(lock) {
                playbackDuckingActive = duckExternalAudio && playbackUsers > 0
                applyAudioStateLocked()
            }
        }

        fun releasePlayback() {
            synchronized(lock) {
                if (playbackUsers == 0) {
                    return
                }
                playbackUsers -= 1
                if (playbackUsers == 0) {
                    playbackDuckingActive = false
                }
                applyAudioStateLocked()
                if (totalUsers() == 0) {
                    restoreLocked()
                }
            }
        }

        fun acquireCapture(duckExternalAudio: Boolean) {
            synchronized(lock) {
                val hadUsers = totalUsers() > 0
                captureUsers += 1
                if (duckExternalAudio) {
                    duckingCaptureUsers += 1
                }
                if (!hadUsers) {
                    previousMode = audioManager.mode
                    previousMicrophoneMuteState = audioManager.isMicrophoneMute
                }
                applyAudioStateLocked()
            }
        }

        fun releaseCapture() {
            synchronized(lock) {
                if (captureUsers == 0) {
                    return
                }
                captureUsers -= 1
                duckingCaptureUsers = duckingCaptureUsers.coerceAtMost(captureUsers)
                applyAudioStateLocked()
                if (totalUsers() == 0) {
                    restoreLocked()
                }
            }
        }

        fun updateCaptureDucking(duckExternalAudio: Boolean) {
            synchronized(lock) {
                if (captureUsers == 0) {
                    return
                }
                duckingCaptureUsers = if (duckExternalAudio) captureUsers else 0
                applyAudioStateLocked()
            }
        }

        private fun totalUsers(): Int = playbackUsers + captureUsers
        private fun shouldHoldFocus(): Boolean = playbackDuckingActive || duckingCaptureUsers > 0
        private fun shouldUseCommunicationMode(): Boolean = playbackUsers > 0 || duckingCaptureUsers > 0

        private fun requestFocusLocked() {
            val focusGain = AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(focusGain)
                    .setOnAudioFocusChangeListener(focusChangeListener)
                    .setAcceptsDelayedFocusGain(false)
                    .setWillPauseWhenDucked(false)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build(),
                    )
                    .build()
                audioFocusRequest = request
                audioManager.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                val focusResult = audioManager.requestAudioFocus(
                    focusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    focusGain,
                )
                isLegacyFocusHeld = focusResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            }
        }

        private fun applyAudioStateLocked() {
            if (totalUsers() == 0) {
                return
            }
            if (shouldHoldFocus()) {
                if ((Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && audioFocusRequest == null) ||
                    (Build.VERSION.SDK_INT < Build.VERSION_CODES.O && !isLegacyFocusHeld)
                ) {
                    requestFocusLocked()
                }
            } else {
                abandonFocusLocked()
            }
            audioManager.mode = if (shouldUseCommunicationMode()) {
                AudioManager.MODE_IN_COMMUNICATION
            } else {
                previousMode ?: AudioManager.MODE_NORMAL
            }
            if (captureUsers > 0) {
                audioManager.isMicrophoneMute = false
            }
        }

        private fun restoreLocked() {
            abandonFocusLocked()
            previousMode?.let { audioManager.mode = it }
            previousMicrophoneMuteState?.let { audioManager.isMicrophoneMute = it }
            previousMode = null
            previousMicrophoneMuteState = null
            duckingCaptureUsers = 0
            playbackDuckingActive = false
        }

        private fun abandonFocusLocked() {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let(audioManager::abandonAudioFocusRequest)
                audioFocusRequest = null
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(focusChangeListener)
                isLegacyFocusHeld = false
            }
        }
    }

        companion object {
        private const val REQUEST_PERMISSIONS_CODE = 3_101
        private const val DEFAULT_CODEC = "pcm16"
        private const val OPUS_CODEC = "opus"
        private const val OPUS_MIME_TYPE = "audio/opus"
        private const val CURRENT_TRANSPORT_VERSION = 1
        private const val DEFAULT_STREAM_SAMPLE_RATE = 16_000
        private const val PCM_BYTES_PER_SAMPLE = 2
        private const val PACKET_HEADER_BYTES = 4
        private const val MAX_PACKET_BYTES = 64_000
        private const val CODEC_TIMEOUT_US = 10_000L
        private const val STREAM_CHUNK_MILLIS = 20
        private const val DEFAULT_BUFFER_CHUNKS = 4
        private const val VOICE_PRE_ROLL_FRAMES = 10
        private const val VOICE_ATTACK_FRAMES = 3
        private const val VOICE_RELEASE_HANGOVER_MILLIS = 700
        private const val DEFAULT_VOICE_ACTIVATION_SENSITIVITY = 0.55
        private const val CONNECTION_REQUEST_DELAY_MILLIS = 250L
        private const val CONNECTION_RETRY_DELAY_MILLIS = 2_000L
        private const val MAX_BUFFERED_FRAMES = 6
    }
}

private fun buildAudioTrack(
    context: Context,
    sampleRate: Int,
    frameBytes: Int,
): AudioTrack {
    val minBufferSize = AudioTrack.getMinBufferSize(
        sampleRate,
        AudioFormat.CHANNEL_OUT_MONO,
        AudioFormat.ENCODING_PCM_16BIT,
    )
    return AudioTrack.Builder()
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .build(),
        )
        .setAudioFormat(
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
        )
        .setTransferMode(AudioTrack.MODE_STREAM)
        .setBufferSizeInBytes(max(minBufferSize, frameBytes * 2))
        .build()
}
