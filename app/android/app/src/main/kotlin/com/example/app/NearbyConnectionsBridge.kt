package com.example.app

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
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import android.net.wifi.WifiManager
import org.json.JSONObject

class NearbyConnectionsBridge(
    private val context: Context,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val activity = context as? Activity
    private val strategy = Strategy.P2P_POINT_TO_POINT
    private val serviceId = "com.example.app.walkie"
    private val connectionsClient: ConnectionsClient = Nearby.getConnectionsClient(context)
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val audioFocusController = AudioFocusController(context)
    private val activeEndpoints = linkedSetOf<String>()
    private val discoveredEndpoints = ConcurrentHashMap.newKeySet<String>()
    private val receivedStreams = ConcurrentHashMap<Long, Payload>()
    private val endpointRoomMatches = ConcurrentHashMap<String, Boolean>()
    private val pendingOutgoingConnections = ConcurrentHashMap.newKeySet<String>()
    private val pendingConnectionRequests = ConcurrentHashMap<String, Runnable>()

    private var eventSink: EventChannel.EventSink? = null
    private var roomId: String? = null
    private var displayName: String = "Nakama Android"
    private var currentAudioStreamer: AudioStreamer? = null
    private var pendingStartSessionResult: MethodChannel.Result? = null
    private var isDiscovering = false
    private var isDiscoveryStartInFlight = false
    private var discoveryStopRunnable: Runnable? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startSession" -> {
                val roomArgument = call.argument<String>("roomId")
                val displayNameArgument = call.argument<String>("displayName")
                if (roomArgument.isNullOrBlank() || displayNameArgument.isNullOrBlank()) {
                    result.error("invalid_arguments", "roomId and displayName are required.", null)
                    return
                }

                roomId = roomArgument
                displayName = displayNameArgument
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

        stopSession()

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
        val endpointId = activeEndpoints.firstOrNull { endpointRoomMatches[it] == true }
        if (endpointId == null) {
            emit("error", "No validated Nearby peer is connected.")
            result.error("no_endpoint", "No validated Nearby peer is connected.", null)
            return
        }

        if (isActive) {
            if (currentAudioStreamer == null) {
                currentAudioStreamer = AudioStreamer(
                    context = context,
                    connectionsClient = connectionsClient,
                    endpointId = endpointId,
                    audioFocusController = audioFocusController,
                    onEnded = {
                        currentAudioStreamer = null
                        emit("transmit_state", "Push-to-talk stream ended.", mapOf("isTransmitting" to false))
                    },
                ).also { streamer ->
                    streamer.start()
                    emit("transmit_state", "Streaming microphone audio over Nearby Connections.", mapOf("isTransmitting" to true))
                }
            }
        } else {
            currentAudioStreamer?.stop()
            currentAudioStreamer = null
            emit("transmit_state", "Push-to-talk stream is idle.", mapOf("isTransmitting" to false))
        }

        result.success(null)
    }

    private fun stopSession() {
        currentAudioStreamer?.stop()
        currentAudioStreamer = null
        activeEndpoints.clear()
        discoveredEndpoints.clear()
        receivedStreams.clear()
        endpointRoomMatches.clear()
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
            "connectedPeers" to activeEndpoints.size,
            "isDiscovering" to isDiscovering,
        )
        payload.putAll(extra)
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(payload)
            return
        }

        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            if (!discoveredEndpoints.add(endpointId)) {
                return
            }

            if (activeEndpoints.isNotEmpty() || pendingOutgoingConnections.contains(endpointId)) {
                return
            }

            val remoteEndpoint = parseEndpointInfo(info.endpointInfo)
            if (!roomMatches(remoteEndpoint.roomId)) {
                return
            }

            val remoteName = remoteEndpoint.displayName ?: info.endpointName
            emit("peer_discovered", "Found nearby peer ${remoteName.ifBlank { "in this room" }}.")
            scheduleConnectionRequest(endpointId, remoteName)
        }

        override fun onEndpointLost(endpointId: String) {
            cancelPendingConnectionRequest(endpointId)
            discoveredEndpoints.remove(endpointId)
            if (activeEndpoints.remove(endpointId)) {
                emit("disconnected", "Nearby peer left range. Room remains open for reconnects.")
                startDiscoveryBurst("Peer left range. Scanning briefly for reconnects.")
            }
        }
    }

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            cancelPendingConnectionRequest(endpointId)
            val remoteEndpoint = parseEndpointInfo(info.endpointInfo)
            if (!roomMatches(remoteEndpoint.roomId)) {
                endpointRoomMatches[endpointId] = false
                connectionsClient.rejectConnection(endpointId)
                emit("error", "Ignoring Nearby peer from a different room.")
                return
            }

            emit("connection_initiated", "Connection initiated with ${remoteEndpoint.displayName ?: info.endpointName}.")
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
                    stopDiscovery()
                    sendHandshake(endpointId)
                    emit("connected", "Connected to nearby peer over Nearby Connections.")
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
            emit("disconnected", "Nearby peer disconnected. Room remains open for new connections.")
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
                    receivedStreams[payload.id] = payload
                    emit("stream_received", "Incoming audio stream received from nearby peer.")
                    playIncomingStream(payload)
                }

                Payload.Type.BYTES -> {
                    handleBytesPayload(endpointId, payload)
                }

                Payload.Type.FILE -> {
                    emit("file_received", "Received file payload from nearby peer.")
                }
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
            if (update.status == PayloadTransferUpdate.Status.FAILURE) {
                emit("error", "Nearby payload transfer failed.")
                receivedStreams.remove(update.payloadId)
            }

            if (update.status == PayloadTransferUpdate.Status.SUCCESS) {
                receivedStreams.remove(update.payloadId)
            }
        }
    }

    private fun playIncomingStream(payload: Payload) {
        executor.execute {
            val inputStream = payload.asStream()?.asInputStream() ?: return@execute
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val previousMode = audioManager.mode
            val previousSpeakerphoneState = audioManager.isSpeakerphoneOn
            audioFocusController.acquire()
            emit("receive_state", "Receiving nearby voice audio.", mapOf("isReceivingAudio" to true))
            val minBufferSize = AudioTrack.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val audioTrack = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(minBufferSize.coerceAtLeast(SAMPLE_BUFFER_BYTES))
                .build()

            val bufferedInput = BufferedInputStream(inputStream)
            val buffer = ByteArray(SAMPLE_BUFFER_BYTES)

            try {
                // Force incoming speech to the loudspeaker instead of the call earpiece.
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                audioManager.isSpeakerphoneOn = true
                audioTrack.play()
                while (true) {
                    val count = bufferedInput.read(buffer)
                    if (count <= 0) {
                        break
                    }
                    audioTrack.write(buffer, 0, count)
                }
            } finally {
                bufferedInput.close()
                audioTrack.stop()
                audioTrack.release()
                audioManager.mode = previousMode
                audioManager.isSpeakerphoneOn = previousSpeakerphoneState
                audioFocusController.release()
                emit("receive_state", "Incoming voice audio is idle.", mapOf("isReceivingAudio" to false))
            }
        }
    }

    private fun sendHandshake(endpointId: String) {
        val handshake = JSONObject()
            .put("type", "hello")
            .put("roomId", roomId)
            .put("displayName", displayName)
            .toString()
            .toByteArray(Charsets.UTF_8)

        connectionsClient.sendPayload(endpointId, Payload.fromBytes(handshake))
    }

    private fun handleBytesPayload(endpointId: String, payload: Payload) {
        val bytes = payload.asBytes() ?: return
        val json = runCatching {
            JSONObject(String(bytes, Charsets.UTF_8))
        }.getOrNull() ?: run {
            emit("bytes_received", "Received control payload from nearby peer.")
            return
        }

        if (json.optString("type") != "hello") {
            emit("bytes_received", "Received control payload from nearby peer.")
            return
        }

        val peerRoomId = json.optString("roomId")
        if (roomId != null && peerRoomId != roomId) {
            endpointRoomMatches[endpointId] = false
            activeEndpoints.remove(endpointId)
            currentAudioStreamer?.stop()
            currentAudioStreamer = null
            connectionsClient.disconnectFromEndpoint(endpointId)
            emit("error", "Nearby peer is advertising a different room.")
            return
        }

        endpointRoomMatches[endpointId] = true
        emit(
            "bytes_received",
            "Nearby peer metadata received.",
            mapOf("peerDisplayName" to json.optString("displayName")),
        )
    }

    private fun localEndpointInfo(): ByteArray {
        return JSONObject()
            .put("roomId", roomId)
            .put("displayName", displayName)
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
        )
    }

    private fun startDiscoveryBurst(message: String) {
        if (activeEndpoints.isNotEmpty()) {
            return
        }

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
        if (activeEndpoints.isNotEmpty() || pendingOutgoingConnections.contains(endpointId)) {
            return
        }

        val runnable = Runnable {
            pendingConnectionRequests.remove(endpointId)
            if (activeEndpoints.isNotEmpty() || !discoveredEndpoints.contains(endpointId)) {
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
    )

    private class AudioStreamer(
        private val context: Context,
        private val connectionsClient: ConnectionsClient,
        private val endpointId: String,
        private val audioFocusController: AudioFocusController,
        private val onEnded: () -> Unit,
    ) {
        private val isRunning = AtomicBoolean(false)
        private val executor = Executors.newSingleThreadExecutor()
        private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        private var audioRecord: AudioRecord? = null
        private var payload: Payload? = null
        private var previousMode: Int? = null
        private var previousSpeakerphoneState: Boolean? = null
        private var previousMicrophoneMuteState: Boolean? = null
        private var noiseSuppressor: NoiseSuppressor? = null
        private var acousticEchoCanceler: AcousticEchoCanceler? = null
        private var automaticGainControl: AutomaticGainControl? = null

        fun start() {
            if (!isRunning.compareAndSet(false, true)) {
                return
            }

            previousMode = audioManager.mode
            previousSpeakerphoneState = audioManager.isSpeakerphoneOn
            previousMicrophoneMuteState = audioManager.isMicrophoneMute
            audioFocusController.acquire()
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            audioManager.isSpeakerphoneOn = true
            audioManager.isMicrophoneMute = false

            val minBufferSize = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )

            val record = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBufferSize.coerceAtLeast(SAMPLE_BUFFER_BYTES),
            )
            audioRecord = record
            attachVoiceEffects(record.audioSessionId)

            val pipe = android.os.ParcelFileDescriptor.createPipe()
            val input = android.os.ParcelFileDescriptor.AutoCloseInputStream(pipe[0])
            val output = android.os.ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
            payload = Payload.fromStream(input)
            connectionsClient.sendPayload(endpointId, payload!!)

            executor.execute {
                val bufferedOutput = BufferedOutputStream(output)
                val buffer = ByteArray(SAMPLE_BUFFER_BYTES)

                try {
                    record.startRecording()
                    while (isRunning.get()) {
                        val readCount = record.read(buffer, 0, buffer.size)
                        if (readCount > 0) {
                            bufferedOutput.write(buffer, 0, readCount)
                            bufferedOutput.flush()
                        }
                    }
                } finally {
                    try {
                        bufferedOutput.close()
                    } catch (_: Exception) {
                    }
                    stop()
                }
            }
        }

        fun stop() {
            if (!isRunning.compareAndSet(true, false)) {
                return
            }

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
            payload = null
            previousMode?.let { audioManager.mode = it }
            previousSpeakerphoneState?.let { audioManager.isSpeakerphoneOn = it }
            previousMicrophoneMuteState?.let { audioManager.isMicrophoneMute = it }
            previousMode = null
            previousSpeakerphoneState = null
            previousMicrophoneMuteState = null
            audioFocusController.release()
            executor.shutdownNow()
            onEnded()
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
    }

    private class AudioFocusController(
        context: Context,
    ) {
        private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { }
        private val lock = Any()
        private var activeUsers = 0
        private var audioFocusRequest: AudioFocusRequest? = null

        fun acquire() {
            synchronized(lock) {
                activeUsers += 1
                if (activeUsers > 1) {
                    return
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val request = AudioFocusRequest.Builder(
                        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
                    )
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
                        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
                    )
                }
            }
        }

        fun release() {
            synchronized(lock) {
                if (activeUsers == 0) {
                    return
                }

                activeUsers -= 1
                if (activeUsers > 0) {
                    return
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    audioFocusRequest?.let(audioManager::abandonAudioFocusRequest)
                    audioFocusRequest = null
                } else {
                    @Suppress("DEPRECATION")
                    audioManager.abandonAudioFocus(focusChangeListener)
                }
            }
        }
    }

    companion object {
        private const val REQUEST_PERMISSIONS_CODE = 3_101
        private const val SAMPLE_RATE = 16_000
        private const val SAMPLE_BUFFER_BYTES = 2_048
        private const val DISCOVERY_WINDOW_MILLIS = 15_000L
        private const val CONNECTION_REQUEST_DELAY_MILLIS = 1_200L
        private const val CONNECTION_RETRY_DELAY_MILLIS = 2_000L
    }
}
