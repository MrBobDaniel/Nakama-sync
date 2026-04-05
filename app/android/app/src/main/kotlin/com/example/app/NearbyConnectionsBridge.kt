package com.example.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
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
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

class NearbyConnectionsBridge(
    private val context: Context,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val strategy = Strategy.P2P_POINT_TO_POINT
    private val serviceId = "com.example.app.walkie"
    private val connectionsClient: ConnectionsClient = Nearby.getConnectionsClient(context)
    private val executor = Executors.newCachedThreadPool()
    private val activeEndpoints = linkedSetOf<String>()
    private val discoveredEndpoints = ConcurrentHashMap.newKeySet<String>()
    private val receivedStreams = ConcurrentHashMap<Long, Payload>()
    private val endpointRoomMatches = ConcurrentHashMap<String, Boolean>()

    private var eventSink: EventChannel.EventSink? = null
    private var roomId: String? = null
    private var displayName: String = "Nakama Android"
    private var currentAudioStreamer: AudioStreamer? = null

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
        executor.shutdownNow()
    }

    private fun startSession(result: MethodChannel.Result) {
        if (!isPlayServicesAvailable()) {
            emit("unsupported", "Google Play services Nearby is unavailable.")
            result.error("play_services_unavailable", "Google Play services Nearby is unavailable.", null)
            return
        }

        if (!hasRequiredPermissions()) {
            emit("unsupported", "Nearby Connections requires Bluetooth, nearby devices, location, and microphone permissions.")
            result.error("missing_permissions", "Nearby Connections permissions are missing.", null)
            return
        }

        stopSession()

        emit("session_started", "Starting Nearby Connections advertising and discovery.")

        val advertisingOptions = AdvertisingOptions.Builder()
            .setStrategy(strategy)
            .build()
        val discoveryOptions = DiscoveryOptions.Builder()
            .setStrategy(strategy)
            .build()

        connectionsClient.startAdvertising(
            displayName,
            serviceId,
            connectionLifecycleCallback,
            advertisingOptions,
        ).addOnFailureListener { error ->
            emit("error", "Failed to advertise: ${error.localizedMessage ?: "unknown error"}")
        }

        connectionsClient.startDiscovery(
            serviceId,
            endpointDiscoveryCallback,
            discoveryOptions,
        ).addOnFailureListener { error ->
            emit("error", "Failed to discover peers: ${error.localizedMessage ?: "unknown error"}")
        }

        result.success(null)
    }

    private fun setPushToTalkActive(isActive: Boolean, result: MethodChannel.Result) {
        val endpointId = activeEndpoints.firstOrNull()
        if (endpointId == null) {
            emit("error", "No active Nearby peer is connected.")
            result.error("no_endpoint", "No active Nearby peer is connected.", null)
            return
        }

        if (isActive) {
            if (currentAudioStreamer == null) {
                currentAudioStreamer = AudioStreamer(
                    connectionsClient = connectionsClient,
                    endpointId = endpointId,
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
        connectionsClient.stopAllEndpoints()
        connectionsClient.stopAdvertising()
        connectionsClient.stopDiscovery()
    }

    private fun isPlayServicesAvailable(): Boolean {
        val status = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context)
        return status == ConnectionResult.SUCCESS
    }

    private fun hasRequiredPermissions(): Boolean {
        val permissions = buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                add(Manifest.permission.BLUETOOTH_ADVERTISE)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.NEARBY_WIFI_DEVICES)
            }
        }

        return permissions.all { permission ->
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun emit(event: String, message: String, extra: Map<String, Any?> = emptyMap()) {
        val payload = linkedMapOf<String, Any?>(
            "event" to event,
            "message" to message,
            "roomId" to roomId,
            "connectedPeers" to activeEndpoints.size,
        )
        payload.putAll(extra)
        eventSink?.success(payload)
    }

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            if (!discoveredEndpoints.add(endpointId)) {
                return
            }

            emit("peer_discovered", "Found nearby peer ${info.endpointName}.")
            connectionsClient.requestConnection(
                displayName,
                endpointId,
                connectionLifecycleCallback,
            ).addOnFailureListener { error ->
                emit("error", "Failed to request connection: ${error.localizedMessage ?: "unknown error"}")
            }
        }

        override fun onEndpointLost(endpointId: String) {
            discoveredEndpoints.remove(endpointId)
            if (activeEndpoints.remove(endpointId)) {
                emit("disconnected", "Nearby peer left range. Searching again.")
            }
        }
    }

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            emit("connection_initiated", "Connection initiated with ${info.endpointName}.")
            connectionsClient.acceptConnection(endpointId, payloadCallback)
                .addOnFailureListener { error ->
                    emit("error", "Failed to accept connection: ${error.localizedMessage ?: "unknown error"}")
                }
        }

        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            when (resolution.status.statusCode) {
                com.google.android.gms.common.api.CommonStatusCodes.SUCCESS -> {
                    activeEndpoints.add(endpointId)
                    sendHandshake(endpointId)
                    emit("connected", "Connected to nearby peer over Nearby Connections.")
                }

                com.google.android.gms.common.api.CommonStatusCodes.CONNECTION_REJECTED -> {
                    emit("error", "Nearby peer rejected the connection.")
                }

                else -> {
                    emit("error", "Nearby connection failed with status ${resolution.status.statusCode}.")
                }
            }
        }

        override fun onDisconnected(endpointId: String) {
            activeEndpoints.remove(endpointId)
            emit("disconnected", "Nearby peer disconnected. Discovery continues in the background.")
        }
    }

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            when (payload.type) {
                Payload.Type.STREAM -> {
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

    private class AudioStreamer(
        private val connectionsClient: ConnectionsClient,
        private val endpointId: String,
        private val onEnded: () -> Unit,
    ) {
        private val isRunning = AtomicBoolean(false)
        private val executor = Executors.newSingleThreadExecutor()

        private var audioRecord: AudioRecord? = null
        private var payload: Payload? = null

        fun start() {
            if (!isRunning.compareAndSet(false, true)) {
                return
            }

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
            audioRecord?.release()
            audioRecord = null
            payload = null
            executor.shutdownNow()
            onEnded()
        }
    }

    companion object {
        private const val SAMPLE_RATE = 16_000
        private const val SAMPLE_BUFFER_BYTES = 2_048
    }
}
