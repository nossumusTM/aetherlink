package com.example.sputni

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONException
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class GeoBackgroundRelayService : Service() {
    companion object {
        const val ACTION_ACTIVATE = "sputni.geo.ACTIVATE"
        const val ACTION_DEACTIVATE = "sputni.geo.DEACTIVATE"
        const val ACTION_STOP = "sputni.geo.STOP"

        const val PREFS_NAME = "sputni.geo.background_relay"
        const val KEY_ACTIVE = "active"
        const val KEY_ROOM_ID = "room_id"
        const val KEY_SIGNALING_URL = "signaling_url"
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_KEY_MATERIAL = "key_material"
        const val KEY_UPDATE_INTERVAL_SECONDS = "update_interval_seconds"
        const val KEY_DISTANCE_FILTER_METERS = "distance_filter_meters"
        const val KEY_HIGH_ACCURACY = "high_accuracy"
        const val KEY_SHARE_HEADING = "share_heading"
        const val KEY_SHARE_SPEED = "share_speed"
        const val KEY_KEEP_AWAKE = "keep_awake"

        private const val NOTIFICATION_CHANNEL_ID = "sputni_geo_background"
        private const val NOTIFICATION_ID = 4812
        private const val RECONNECT_DELAY_MS = 2_000L
        private const val GCM_NONCE_SIZE = 12
        private val HKDF_SALT = byteArrayOf(115, 112, 117, 116, 110, 105)
        private val HKDF_INFO = "sputni-secure-channel-v1".toByteArray(StandardCharsets.UTF_8)

        fun start(
            context: Context,
            action: String,
            arguments: Map<*, *>? = null,
        ) {
            val intent = Intent(context, GeoBackgroundRelayService::class.java).apply {
                this.action = action
                if (arguments != null) {
                    for ((key, value) in arguments) {
                        val name = key as? String ?: continue
                        when (value) {
                            is String -> putExtra(name, value)
                            is Int -> putExtra(name, value)
                            is Boolean -> putExtra(name, value)
                        }
                    }
                }
            }

            if (action == ACTION_ACTIVATE) {
                ContextCompat.startForegroundService(context, intent)
                return
            }

            context.startService(intent)
        }
    }

    private val mainHandler by lazy { android.os.Handler(Looper.getMainLooper()) }
    private val random = SecureRandom()
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private var locationCallback: LocationCallback? = null
    private var webSocketClient: OkHttpClient? = null
    private var webSocket: WebSocket? = null
    private var reconnectRunnable: Runnable? = null
    private var publishHeartbeatRunnable: Runnable? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastPointEnvelope: String? = null
    private var currentConfig: RelayConfig? = null
    private var isRelayActive = false

    override fun onCreate() {
        super.onCreate()
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ACTIVATE -> {
                val config = RelayConfig.fromIntent(intent) ?: RelayConfig.fromPreferences(this)
                if (config == null) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                persistConfig(config, active = true)
                activateRelay(config)
            }

            ACTION_DEACTIVATE -> {
                persistActive(false)
                deactivateRelay(stopService = true)
            }

            ACTION_STOP -> {
                currentConfig?.let { config ->
                    webSocket?.let {
                        sendControl(
                            webSocket = it,
                            config = config,
                            action = "geo-position-stopped",
                        )
                    }
                }
                deactivateRelay(stopService = true)
                clearConfig()
            }

            else -> {
                val config = RelayConfig.fromPreferences(this)
                if (config != null && preferences().getBoolean(KEY_ACTIVE, false)) {
                    activateRelay(config)
                } else {
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
        }

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val config = RelayConfig.fromPreferences(this)
        if (config != null && preferences().getBoolean(KEY_ACTIVE, false)) {
            webSocket?.let {
                sendControl(
                    webSocket = it,
                    config = config,
                    action = "geo-position-app-swiped",
                )
            }
            DeviceAlertNotifier.show(
                context = this,
                id = 3103,
                title = "Position sharing moved to background",
                body = "App was removed from recents. Background relay is keeping location sharing alive.",
            )
            activateRelay(config)
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        deactivateRelay(stopService = false)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun activateRelay(config: RelayConfig) {
        try {
            currentConfig = config
            isRelayActive = true
            startForeground(NOTIFICATION_ID, buildNotification())
            syncWakeLock(config.keepAwake)
            startLocationUpdates(config)
            connectWebSocket(config)
            schedulePublishHeartbeat(config)
        } catch (_: Exception) {
            persistActive(false)
            deactivateRelay(stopService = true)
        }
    }

    private fun deactivateRelay(stopService: Boolean) {
        isRelayActive = false
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = null
        publishHeartbeatRunnable?.let(mainHandler::removeCallbacks)
        publishHeartbeatRunnable = null

        locationCallback?.let { callback ->
            fusedLocationClient.removeLocationUpdates(callback)
        }
        locationCallback = null

        webSocket?.close(1000, "Relay stopped")
        webSocket = null
        webSocketClient?.dispatcher?.executorService?.shutdown()
        webSocketClient = null
        syncWakeLock(false)

        if (stopService) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
        }
    }

    private fun connectWebSocket(config: RelayConfig) {
        if (!isRelayActive) {
            return
        }

        webSocket?.cancel()
        webSocketClient?.dispatcher?.executorService?.shutdown()
        webSocketClient = OkHttpClient.Builder()
            .retryOnConnectionFailure(true)
            .build()
        val request = Request.Builder()
            .url(config.signalingUrl)
            .build()
        webSocket = webSocketClient?.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    sendJoin(webSocket, config)
                    lastPointEnvelope?.let { sendEnvelope(webSocket, config, it) }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    handleIncomingMessage(webSocket, config, text)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    scheduleReconnect(config)
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(code, reason)
                }

                override fun onFailure(
                    webSocket: WebSocket,
                    t: Throwable,
                    response: Response?,
                ) {
                    scheduleReconnect(config)
                }
            },
        )
    }

    private fun scheduleReconnect(config: RelayConfig) {
        if (!isRelayActive) {
            return
        }
        reconnectRunnable?.let(mainHandler::removeCallbacks)
        reconnectRunnable = Runnable { connectWebSocket(config) }.also {
            mainHandler.postDelayed(it, RECONNECT_DELAY_MS)
        }
    }

    private fun schedulePublishHeartbeat(config: RelayConfig) {
        publishHeartbeatRunnable?.let(mainHandler::removeCallbacks)
        val intervalMs = maxOf(config.updateIntervalSeconds * 3, 15) * 1_000L
        publishHeartbeatRunnable = object : Runnable {
            override fun run() {
                if (!isRelayActive) {
                    return
                }

                val envelope = lastPointEnvelope
                val socket = webSocket
                if (envelope != null && socket != null) {
                    sendEnvelope(socket, config, envelope)
                } else if (socket == null) {
                    connectWebSocket(config)
                }

                mainHandler.postDelayed(this, intervalMs)
            }
        }.also { mainHandler.postDelayed(it, intervalMs) }
    }

    private fun startLocationUpdates(config: RelayConfig) {
        if (!hasLocationPermission()) {
            persistActive(false)
            stopSelf()
            return
        }

        locationCallback?.let { callback ->
            fusedLocationClient.removeLocationUpdates(callback)
        }

        val priority = if (config.highAccuracy) {
            Priority.PRIORITY_HIGH_ACCURACY
        } else {
            Priority.PRIORITY_BALANCED_POWER_ACCURACY
        }
        val intervalMs = config.updateIntervalSeconds.coerceAtLeast(2) * 1_000L
        val request = LocationRequest.Builder(priority, intervalMs)
            .setMinUpdateDistanceMeters(config.distanceFilterMeters.toFloat())
            .setMinUpdateIntervalMillis((intervalMs / 2).coerceAtLeast(1_000L))
            .build()

        locationCallback = object : LocationCallback() {
            override fun onLocationResult(locationResult: LocationResult) {
                val location = locationResult.lastLocation ?: return
                handleLocation(config, location)
            }
        }

        try {
            fusedLocationClient.requestLocationUpdates(
                request,
                locationCallback ?: return,
                Looper.getMainLooper(),
            )

            fusedLocationClient.lastLocation.addOnSuccessListener { location ->
                if (location != null) {
                    handleLocation(config, location)
                }
            }
        } catch (_: SecurityException) {
            persistActive(false)
            deactivateRelay(stopService = true)
        }
    }

    private fun handleLocation(config: RelayConfig, location: Location) {
        if (!isRelayActive) {
            return
        }

        val point = JSONObject().apply {
            put("latitude", location.latitude)
            put("longitude", location.longitude)
            put("timestampMillis", location.time)
            put("accuracy", location.accuracy.toDouble())
            put("altitude", location.altitude)
            if (config.shareSpeed) {
                put("speed", location.speed.toDouble())
            } else {
                put("speed", JSONObject.NULL)
            }
            if (config.shareHeading) {
                put("heading", location.bearing.toDouble())
            } else {
                put("heading", JSONObject.NULL)
            }
        }
        val envelope = JSONObject().apply {
            put("type", "position-update")
            put("payload", JSONObject().put("point", point))
        }.toString()

        lastPointEnvelope = envelope
        webSocket?.let { sendEnvelope(it, config, envelope) }
    }

    private fun handleIncomingMessage(
        webSocket: WebSocket,
        config: RelayConfig,
        rawMessage: String,
    ) {
        val message = decodeIncomingMessage(rawMessage) ?: return
        val type = message.optString("type")
        if (type == "join") {
            val role = message.optJSONObject("payload")?.optString("role")
            if (role == "geo-monitor") {
                sendLatestPointIfAvailable(webSocket, config)
            }
            return
        }

        if (type == "control") {
            val action = message.optJSONObject("payload")?.optString("action")
            if (action == "geo-monitor-ready") {
                sendLatestPointIfAvailable(webSocket, config)
            }
        }
    }

    private fun sendLatestPointIfAvailable(
        webSocket: WebSocket,
        config: RelayConfig,
    ) {
        lastPointEnvelope?.let { sendEnvelope(webSocket, config, it) }
    }

    private fun decodeIncomingMessage(rawMessage: String): JSONObject? {
        return try {
            val message = JSONObject(rawMessage)
            if (message.optString("type") != "secure-signal") {
                message
            } else {
                val keyMaterial = currentConfig?.keyMaterial
                if (keyMaterial.isNullOrBlank()) {
                    null
                } else {
                    decryptJsonPayload(message.getJSONObject("payload"), keyMaterial)
                }
            }
        } catch (_: JSONException) {
            null
        }
    }

    private fun sendJoin(webSocket: WebSocket, config: RelayConfig) {
        val payload = JSONObject().apply {
            put("roomId", config.roomId)
            put("role", "geo-position")
            if (!config.deviceId.isNullOrBlank()) {
                put("deviceId", config.deviceId)
            }
        }
        val message = JSONObject()
            .put("type", "join")
            .put("payload", payload)
        sendSignalingMessage(webSocket, config, message)
    }

    private fun sendEnvelope(
        webSocket: WebSocket,
        config: RelayConfig,
        envelope: String,
    ) {
        val dataPayload = JSONObject().apply {
            put("channel", "geo-position")
            put("envelope", envelope)
        }
        val clearMessage = JSONObject().apply {
            put("type", "data")
            put("payload", dataPayload)
        }
        sendSignalingMessage(webSocket, config, clearMessage)
    }

    private fun sendControl(
        webSocket: WebSocket,
        config: RelayConfig,
        action: String,
    ) {
        val clearMessage = JSONObject().apply {
            put("type", "control")
            put(
                "payload",
                JSONObject().apply {
                    put("action", action)
                },
            )
        }
        sendSignalingMessage(webSocket, config, clearMessage)
    }

    private fun sendSignalingMessage(
        webSocket: WebSocket,
        config: RelayConfig,
        clearMessage: JSONObject,
    ) {
        val outgoing = if (config.keyMaterial.isNullOrBlank()) {
            clearMessage
        } else {
            val encrypted = encryptJsonPayload(clearMessage, config.keyMaterial)
            JSONObject().apply {
                put("type", "secure-signal")
                put("payload", encrypted)
            }
        }

        webSocket.send(outgoing.toString())
    }

    private fun encryptJsonPayload(
        clearMessage: JSONObject,
        keyMaterial: String,
    ): JSONObject {
        val aesKey = deriveAesKey(keyMaterial)
        val nonce = ByteArray(GCM_NONCE_SIZE).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(aesKey, "AES"),
            GCMParameterSpec(128, nonce),
        )
        val ciphertextWithTag = cipher.doFinal(
            clearMessage.toString().toByteArray(StandardCharsets.UTF_8),
        )
        val ciphertext = ciphertextWithTag.copyOfRange(0, ciphertextWithTag.size - 16)
        val mac = ciphertextWithTag.copyOfRange(ciphertextWithTag.size - 16, ciphertextWithTag.size)

        return JSONObject().apply {
            put("nonce", base64Url(nonce))
            put("ciphertext", base64Url(ciphertext))
            put("mac", base64Url(mac))
        }
    }

    private fun decryptJsonPayload(
        encryptedPayload: JSONObject,
        keyMaterial: String,
    ): JSONObject? {
        return try {
            val aesKey = deriveAesKey(keyMaterial)
            val nonce = base64UrlDecode(encryptedPayload.getString("nonce"))
            val ciphertext = base64UrlDecode(encryptedPayload.getString("ciphertext"))
            val mac = base64UrlDecode(encryptedPayload.getString("mac"))
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(aesKey, "AES"),
                GCMParameterSpec(128, nonce),
            )
            val clearBytes = cipher.doFinal(ciphertext + mac)
            JSONObject(String(clearBytes, StandardCharsets.UTF_8))
        } catch (_: Exception) {
            null
        }
    }

    private fun deriveAesKey(keyMaterial: String): ByteArray {
        val ikm = keyMaterial.trim().toByteArray(StandardCharsets.UTF_8)
        val prkMac = Mac.getInstance("HmacSHA256")
        prkMac.init(SecretKeySpec(HKDF_SALT, "HmacSHA256"))
        val prk = prkMac.doFinal(ikm)

        val expandMac = Mac.getInstance("HmacSHA256")
        expandMac.init(SecretKeySpec(prk, "HmacSHA256"))
        expandMac.update(HKDF_INFO)
        expandMac.update(byteArrayOf(1))
        return expandMac.doFinal().copyOf(32)
    }

    private fun base64Url(bytes: ByteArray): String {
        return Base64.encodeToString(
            bytes,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
    }

    private fun base64UrlDecode(value: String): ByteArray {
        return Base64.decode(
            value,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Sputni Geo background relay active")
            .setContentText("Sharing your position while the app is closed.")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Sputni Geo background relay",
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    private fun syncWakeLock(enabled: Boolean) {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (enabled) {
            if (wakeLock?.isHeld == true) {
                return
            }
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "sputni:geo_background_relay",
            ).apply { acquire() }
            return
        }

        wakeLock?.let { lock ->
            if (lock.isHeld) {
                lock.release()
            }
        }
        wakeLock = null
    }

    private fun persistConfig(config: RelayConfig, active: Boolean) {
        preferences().edit()
            .putBoolean(KEY_ACTIVE, active)
            .putString(KEY_ROOM_ID, config.roomId)
            .putString(KEY_SIGNALING_URL, config.signalingUrl)
            .putString(KEY_DEVICE_ID, config.deviceId)
            .putString(KEY_KEY_MATERIAL, config.keyMaterial)
            .putInt(KEY_UPDATE_INTERVAL_SECONDS, config.updateIntervalSeconds)
            .putInt(KEY_DISTANCE_FILTER_METERS, config.distanceFilterMeters)
            .putBoolean(KEY_HIGH_ACCURACY, config.highAccuracy)
            .putBoolean(KEY_SHARE_HEADING, config.shareHeading)
            .putBoolean(KEY_SHARE_SPEED, config.shareSpeed)
            .putBoolean(KEY_KEEP_AWAKE, config.keepAwake)
            .apply()
    }

    private fun persistActive(active: Boolean) {
        preferences().edit()
            .putBoolean(KEY_ACTIVE, active)
            .apply()
    }

    private fun clearConfig() {
        preferences().edit().clear().apply()
        lastPointEnvelope = null
        currentConfig = null
    }

    private fun preferences() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun hasLocationPermission(): Boolean {
        val fineGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val coarseGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        return fineGranted || coarseGranted
    }
}

private data class RelayConfig(
    val roomId: String,
    val signalingUrl: String,
    val deviceId: String?,
    val keyMaterial: String?,
    val updateIntervalSeconds: Int,
    val distanceFilterMeters: Int,
    val highAccuracy: Boolean,
    val shareHeading: Boolean,
    val shareSpeed: Boolean,
    val keepAwake: Boolean,
) {
    companion object {
        fun fromIntent(intent: Intent): RelayConfig? {
            val roomId = intent.getStringExtra("roomId")?.trim().orEmpty()
            val signalingUrl = intent.getStringExtra("signalingUrl")?.trim().orEmpty()
            if (roomId.isEmpty() || signalingUrl.isEmpty()) {
                return null
            }

            return RelayConfig(
                roomId = roomId,
                signalingUrl = signalingUrl,
                deviceId = intent.getStringExtra("deviceId")?.trim(),
                keyMaterial = intent.getStringExtra("keyMaterial")?.trim(),
                updateIntervalSeconds = intent.getIntExtra("updateIntervalSeconds", 5),
                distanceFilterMeters = intent.getIntExtra("distanceFilterMeters", 10),
                highAccuracy = intent.getBooleanExtra("highAccuracy", true),
                shareHeading = intent.getBooleanExtra("shareHeading", true),
                shareSpeed = intent.getBooleanExtra("shareSpeed", true),
                keepAwake = intent.getBooleanExtra("keepAwake", true),
            )
        }

        fun fromPreferences(context: Context): RelayConfig? {
            val prefs = context.getSharedPreferences(
                GeoBackgroundRelayService.PREFS_NAME,
                Context.MODE_PRIVATE,
            )
            val roomId = prefs.getString(GeoBackgroundRelayService.KEY_ROOM_ID, null)?.trim().orEmpty()
            val signalingUrl =
                prefs.getString(GeoBackgroundRelayService.KEY_SIGNALING_URL, null)?.trim().orEmpty()
            if (roomId.isEmpty() || signalingUrl.isEmpty()) {
                return null
            }

            return RelayConfig(
                roomId = roomId,
                signalingUrl = signalingUrl,
                deviceId = prefs.getString(GeoBackgroundRelayService.KEY_DEVICE_ID, null)?.trim(),
                keyMaterial = prefs.getString(GeoBackgroundRelayService.KEY_KEY_MATERIAL, null)?.trim(),
                updateIntervalSeconds =
                    prefs.getInt(GeoBackgroundRelayService.KEY_UPDATE_INTERVAL_SECONDS, 5),
                distanceFilterMeters =
                    prefs.getInt(GeoBackgroundRelayService.KEY_DISTANCE_FILTER_METERS, 10),
                highAccuracy = prefs.getBoolean(GeoBackgroundRelayService.KEY_HIGH_ACCURACY, true),
                shareHeading = prefs.getBoolean(GeoBackgroundRelayService.KEY_SHARE_HEADING, true),
                shareSpeed = prefs.getBoolean(GeoBackgroundRelayService.KEY_SHARE_SPEED, true),
                keepAwake = prefs.getBoolean(GeoBackgroundRelayService.KEY_KEEP_AWAKE, true),
            )
        }
    }
}
