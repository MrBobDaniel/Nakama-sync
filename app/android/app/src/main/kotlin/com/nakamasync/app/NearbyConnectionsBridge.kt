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
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

class NearbyConnectionsBridge(
    private val context: Context,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
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
    private val incomingAudioMixer = IncomingAudioMixer(
        context = context,
        sampleRate = DEFAULT_STREAM_SAMPLE_RATE,
        communicationAudioController = communicationAudioController,
        onPeerSpeakingChanged = { endpointId, isSpeaking ->
            updatePeerSpeaking(endpointId, isSpeaking)
        },
        onError = { message ->
            emit("error", message)
        },
    )

    private var eventSink: EventChannel.EventSink? = null
    private var roomId: String? = null
    private var displayName: String = "Nakama Sync Android"
    private var outgoingAudioFanout: OutgoingAudioFanout? = null
    private var pendingStartSessionResult: MethodChannel.Result? = null
    private var isDiscovering = false
    private var isDiscoveryStartInFlight = false
    private var discoveryStopRunnable: Runnable? = null
    private var isPushToTalkActive = false

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

                roomId = normalizedRoomId
                displayName = normalizedDisplayName
                startSession(result)
            }

            "setPushToTalkActive" -> {
                val isActive = call.argument<Boolean>("isActive") ?: false
                setPushToTalkActive(isActive, result)
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
        stopSession()
        roomId = requestedRoomId
        displayName = requestedDisplayName

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

        startDiscoveryBurst("Scanning briefly for nearby peers in this room.")
        result.success(null)
    }

    private fun setPushToTalkActive(isActive: Boolean, result: MethodChannel.Result) {
        val validatedEndpoints = connectedValidatedEndpointIds()
        if (isActive && validatedEndpoints.isEmpty()) {
            emit("error", "No validated Nearby peers are connected.")
            result.error("no_endpoint", "No validated Nearby peers are connected.", null)
            return
        }

        isPushToTalkActive = isActive

        if (isActive) {
            val fanout = outgoingAudioFanout ?: OutgoingAudioFanout(
                context = context,
                connectionsClient = connectionsClient,
                sampleRate = DEFAULT_STREAM_SAMPLE_RATE,
                communicationAudioController = communicationAudioController,
                onError = { message ->
                    emit("error", message)
                },
            ).also { createdFanout ->
                outgoingAudioFanout = createdFanout
                createdFanout.start()
            }

            fanout.syncEndpoints(validatedEndpoints)
            emit(
                "transmit_state",
                "Streaming microphone audio to ${validatedEndpoints.size} peer(s).",
                mapOf(
                    "isTransmitting" to true,
                    "audioSampleRate" to DEFAULT_STREAM_SAMPLE_RATE,
                ),
            )
        } else {
            connectedValidatedEndpointIds().forEach { endpointId ->
                sendAudioControl(endpointId, "audio_stop")
            }
            outgoingAudioFanout?.stop()
            outgoingAudioFanout = null
            emit("transmit_state", "Push-to-talk stream is idle.", mapOf("isTransmitting" to false))
        }

        result.success(null)
    }

    private fun stopSession() {
        isPushToTalkActive = false
        outgoingAudioFanout?.stop()
        outgoingAudioFanout = null
        incomingAudioMixer.stopAll()
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
        val payload = linkedMapOf<String, Any?>(
            "event" to event,
            "message" to message,
            "roomId" to roomId,
            "connectedPeers" to activeEndpoints.count { endpointRoomMatches[it] == true },
            "isDiscovering" to isDiscovering,
            "isReceivingAudio" to peerSessions.values.any { it.isSpeaking && it.isConnected },
            "isTransmitting" to (outgoingAudioFanout?.isRunning() == true),
            "peers" to peerSessions.values
                .sortedWith(compareBy<PeerSession>({ !it.isConnected }, { it.displayName.lowercase() }))
                .map { peer ->
                    mapOf(
                        "peerId" to peer.endpointId,
                        "displayName" to peer.displayName,
                        "isConnected" to peer.isConnected,
                        "isSpeaking" to peer.isSpeaking,
                        "streamSampleRate" to peer.streamSampleRate,
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
                isTransmitting = outgoingAudioFanout?.isRunning() == true,
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
    ) {
        val existing = peerSessions[endpointId]
        peerSessions[endpointId] = PeerSession(
            endpointId = endpointId,
            displayName = displayName?.ifBlank { existing?.displayName ?: "Nearby peer" }
                ?: existing?.displayName
                ?: "Nearby peer",
            isConnected = isConnected ?: existing?.isConnected ?: false,
            isSpeaking = isSpeaking ?: existing?.isSpeaking ?: false,
            streamSampleRate = streamSampleRate ?: existing?.streamSampleRate ?: DEFAULT_STREAM_SAMPLE_RATE,
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
            emit("peer_discovered", "Found nearby peer ${remoteName.ifBlank { "in this room" }}.")
            scheduleConnectionRequest(endpointId, remoteName)
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
                emit("transmit_state", "Push-to-talk stream is idle.", mapOf("isTransmitting" to false))
            }
            startDiscoveryBurst("Peer left range. Scanning briefly for reconnects.")
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
                        streamSampleRate = DEFAULT_STREAM_SAMPLE_RATE,
                    )
                    sendHandshake(endpointId)
                    if (isPushToTalkActive) {
                        outgoingAudioFanout?.addEndpoint(endpointId)
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
                emit("transmit_state", "Push-to-talk stream is idle.", mapOf("isTransmitting" to false))
            }
            startDiscoveryBurst("Peer disconnected. Scanning briefly for another nearby peer.")
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
            .put("preferredSampleRate", localAudioConfig.preferredSampleRate)
            .put("supportedSampleRates", JSONArray(localAudioConfig.supportedSampleRates))
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

        val localRoomId = roomId?.trim()
        val peerRoomId = json.optString("roomId").trim().ifEmpty { null }
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
            streamSampleRate = DEFAULT_STREAM_SAMPLE_RATE,
        )
        emit(
            "bytes_received",
            "Nearby peer metadata received.",
            mapOf(
                "peerId" to endpointId,
                "peerDisplayName" to remoteName,
                "audioSampleRate" to DEFAULT_STREAM_SAMPLE_RATE,
            ),
        )
    }

    private fun localEndpointInfo(): ByteArray {
        val localAudioConfig = buildLocalAudioConfig()
        return JSONObject()
            .put("roomId", roomId)
            .put("displayName", displayName)
            .put("preferredSampleRate", localAudioConfig.preferredSampleRate)
            .put("supportedSampleRates", JSONArray(localAudioConfig.supportedSampleRates))
            .toString()
            .toByteArray(Charsets.UTF_8)
    }

    private fun roomMatches(peerRoomId: String?): Boolean {
        val localRoomId = roomId?.trim()
        val normalizedPeerRoomId = peerRoomId?.trim()
        return localRoomId.isNullOrEmpty() || normalizedPeerRoomId == localRoomId
    }

    private fun parseEndpointInfo(endpointInfo: ByteArray?): NearbyEndpointInfo {
        if (endpointInfo == null || endpointInfo.isEmpty()) {
            return NearbyEndpointInfo()
        }

        val json = runCatching {
            JSONObject(String(endpointInfo, Charsets.UTF_8))
        }.getOrNull() ?: return NearbyEndpointInfo()

        return NearbyEndpointInfo(
            roomId = json.optString("roomId").ifBlank { null },
            displayName = json.optString("displayName").ifBlank { null },
            audioConfig = parseAudioConfig(json),
        )
    }

    private fun parseAudioConfig(json: JSONObject): NearbyAudioConfig {
        val supportedRatesJson = json.optJSONArray("supportedSampleRates")
        val supportedSampleRates = mutableListOf<Int>()
        if (supportedRatesJson != null) {
            for (index in 0 until supportedRatesJson.length()) {
                val rate = supportedRatesJson.optInt(index)
                if (rate > 0) {
                    supportedSampleRates.add(rate)
                }
            }
        }

        return NearbyAudioConfig(
            preferredSampleRate = json.optInt("preferredSampleRate", DEFAULT_STREAM_SAMPLE_RATE),
            supportedSampleRates = supportedSampleRates.ifEmpty { listOf(DEFAULT_STREAM_SAMPLE_RATE) },
        )
    }

    private fun buildLocalAudioConfig(): NearbyAudioConfig {
        return NearbyAudioConfig(
            preferredSampleRate = DEFAULT_STREAM_SAMPLE_RATE,
            supportedSampleRates = listOf(DEFAULT_STREAM_SAMPLE_RATE),
        )
    }

    private fun startDiscoveryBurst(message: String) {
        discoveryStopRunnable?.let(mainHandler::removeCallbacks)

        if (isDiscovering || isDiscoveryStartInFlight) {
            emit("session_started", message, mapOf("isDiscovering" to true))
            scheduleDiscoveryStop()
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
            scheduleDiscoveryStop()
        }.addOnFailureListener { error ->
            isDiscoveryStartInFlight = false
            isDiscovering = false
            emit("error", "Failed to discover peers: ${error.localizedMessage ?: "unknown error"}")
        }
    }

    private fun scheduleDiscoveryStop() {
        val runnable = Runnable {
            stopDiscovery()
            emit("discovery_idle", "Room is open. Listening for incoming connections.")
        }
        discoveryStopRunnable = runnable
        mainHandler.postDelayed(runnable, DISCOVERY_WINDOW_MILLIS)
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
                    { startDiscoveryBurst("Retrying a brief Nearby scan while this room stays open.") },
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
        val audioConfig: NearbyAudioConfig = NearbyAudioConfig(),
    )

    private data class NearbyAudioConfig(
        val preferredSampleRate: Int = DEFAULT_STREAM_SAMPLE_RATE,
        val supportedSampleRates: List<Int> = listOf(DEFAULT_STREAM_SAMPLE_RATE),
    )

    private data class PeerSession(
        val endpointId: String,
        val displayName: String,
        val isConnected: Boolean,
        val isSpeaking: Boolean,
        val streamSampleRate: Int,
    )

    private class PeerPcmBuffer(
        private val frameBytes: Int,
    ) {
        private val lock = Any()
        private val chunks = ArrayDeque<ByteArray>()
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
        private val communicationAudioController: CommunicationAudioController,
        private val onPeerSpeakingChanged: (String, Boolean) -> Unit,
        private val onError: (String) -> Unit,
    ) {
        private val isRunning = AtomicBoolean(false)
        private val peerBuffers = ConcurrentHashMap<String, PeerPcmBuffer>()
        private val readerWorkers = ConcurrentHashMap<String, ReaderWorker>()
        private val mixerExecutor = Executors.newSingleThreadExecutor()

        fun registerStream(endpointId: String, inputStream: java.io.InputStream) {
            stopEndpoint(endpointId)
            peerBuffers[endpointId] = PeerPcmBuffer(frameBytes())
            val worker = ReaderWorker(
                endpointId = endpointId,
                inputStream = BufferedInputStream(inputStream),
                frameBytes = frameBytes(),
                onAudioData = { bytes ->
                    peerBuffers[endpointId]?.append(bytes)
                    onPeerSpeakingChanged(endpointId, true)
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
            onPeerSpeakingChanged(endpointId, false)
        }

        fun stopAll() {
            readerWorkers.keys.toList().forEach(::stopEndpoint)
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
                    onError(error.localizedMessage ?: "Incoming audio mixer failed.")
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

        private class ReaderWorker(
            private val endpointId: String,
            private val inputStream: BufferedInputStream,
            private val frameBytes: Int,
            private val onAudioData: (ByteArray) -> Unit,
            private val onFinished: () -> Unit,
        ) {
            private val running = AtomicBoolean(true)
            private val executor = Executors.newSingleThreadExecutor()

            fun start() {
                executor.execute {
                    val buffer = ByteArray(frameBytes)
                    try {
                        while (running.get()) {
                            val count = inputStream.read(buffer)
                            if (count <= 0) {
                                break
                            }
                            onAudioData(buffer.copyOf(count))
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
        }
    }

    private class OutgoingAudioFanout(
        private val context: Context,
        private val connectionsClient: ConnectionsClient,
        private val sampleRate: Int,
        private val communicationAudioController: CommunicationAudioController,
        private val onError: (String) -> Unit,
    ) {
        private val isRunning = AtomicBoolean(false)
        private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        private val captureExecutor = Executors.newSingleThreadExecutor()
        private val endpointOutputs = ConcurrentHashMap<String, OutputStream>()
        private var audioRecord: AudioRecord? = null
        private var noiseSuppressor: NoiseSuppressor? = null
        private var acousticEchoCanceler: AcousticEchoCanceler? = null
        private var automaticGainControl: AutomaticGainControl? = null

        fun start() {
            if (!isRunning.compareAndSet(false, true)) {
                return
            }

            communicationAudioController.acquireCapture()
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
                    while (isRunning.get()) {
                        val readCount = record.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                        if (readCount > 0) {
                            broadcastFrame(buffer.copyOf(readCount))
                        }
                    }
                } catch (error: Exception) {
                    onError(error.localizedMessage ?: "Outgoing audio capture failed.")
                } finally {
                    stop()
                }
            }
        }

        fun syncEndpoints(endpointIds: Set<String>) {
            endpointOutputs.keys.toList()
                .filterNot(endpointIds::contains)
                .forEach(::removeEndpoint)
            endpointIds.forEach(::addEndpoint)
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
            audioRecord?.release()
            audioRecord = null
            captureExecutor.shutdownNow()
            communicationAudioController.releaseCapture()
        }

        fun isRunning(): Boolean = isRunning.get()

        private fun broadcastFrame(frame: ByteArray) {
            endpointOutputs.entries.toList().forEach { (endpointId, stream) ->
                try {
                    stream.write(frame)
                    stream.flush()
                } catch (_: Exception) {
                    removeEndpoint(endpointId)
                }
            }
        }

        private fun frameBytes(): Int {
            return sampleRate * PCM_BYTES_PER_SAMPLE * STREAM_CHUNK_MILLIS / 1_000
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
    }

    private class CommunicationAudioController(
        context: Context,
    ) {
        private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { }
        private val lock = Any()
        private var playbackUsers = 0
        private var captureUsers = 0
        private var audioFocusRequest: AudioFocusRequest? = null
        private var previousMode: Int? = null
        private var previousSpeakerphoneState: Boolean? = null
        private var previousMicrophoneMuteState: Boolean? = null

        fun acquirePlayback() {
            synchronized(lock) {
                val hadUsers = totalUsers() > 0
                playbackUsers += 1
                if (!hadUsers) {
                    previousMode = audioManager.mode
                    previousSpeakerphoneState = audioManager.isSpeakerphoneOn
                    previousMicrophoneMuteState = audioManager.isMicrophoneMute
                    requestFocusLocked()
                }
                applyRouteLocked()
            }
        }

        fun releasePlayback() {
            synchronized(lock) {
                if (playbackUsers == 0) {
                    return
                }
                playbackUsers -= 1
                applyRouteLocked()
                if (totalUsers() == 0) {
                    restoreLocked()
                }
            }
        }

        fun acquireCapture() {
            synchronized(lock) {
                val hadUsers = totalUsers() > 0
                captureUsers += 1
                if (!hadUsers) {
                    previousMode = audioManager.mode
                    previousSpeakerphoneState = audioManager.isSpeakerphoneOn
                    previousMicrophoneMuteState = audioManager.isMicrophoneMute
                    requestFocusLocked()
                }
                applyRouteLocked()
            }
        }

        fun releaseCapture() {
            synchronized(lock) {
                if (captureUsers == 0) {
                    return
                }
                captureUsers -= 1
                applyRouteLocked()
                if (totalUsers() == 0) {
                    restoreLocked()
                }
            }
        }

        private fun totalUsers(): Int = playbackUsers + captureUsers

        private fun requestFocusLocked() {
            val focusGain = AudioManager.AUDIOFOCUS_GAIN
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(focusGain)
                    .setOnAudioFocusChangeListener(focusChangeListener)
                    .setAcceptsDelayedFocusGain(false)
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
                audioManager.requestAudioFocus(
                    focusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    focusGain,
                )
            }
        }

        private fun applyRouteLocked() {
            if (totalUsers() == 0) {
                return
            }
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            audioManager.isSpeakerphoneOn = true
            if (captureUsers > 0) {
                audioManager.isMicrophoneMute = false
            }
        }

        private fun restoreLocked() {
            previousMode?.let { audioManager.mode = it }
            previousSpeakerphoneState?.let { audioManager.isSpeakerphoneOn = it }
            previousMicrophoneMuteState?.let { audioManager.isMicrophoneMute = it }
            previousMode = null
            previousSpeakerphoneState = null
            previousMicrophoneMuteState = null

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let(audioManager::abandonAudioFocusRequest)
                audioFocusRequest = null
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(focusChangeListener)
            }
        }
    }

    companion object {
        private const val REQUEST_PERMISSIONS_CODE = 3_101
        private const val DEFAULT_STREAM_SAMPLE_RATE = 16_000
        private const val PCM_BYTES_PER_SAMPLE = 2
        private const val STREAM_CHUNK_MILLIS = 20
        private const val DEFAULT_BUFFER_CHUNKS = 4
        private const val DISCOVERY_WINDOW_MILLIS = 15_000L
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
