package com.example.sputni

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.Settings
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val permissionsChannelName = "sputni/permissions"
    private val storageChannelName = "sputni/storage"
    private val geoBackgroundChannelName = "sputni/geo_background"
    private val alertsChannelName = "sputni/alerts"
    private val permissionRequestCode = 4101
    private val directoryPickerRequestCode = 4102
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissions: Array<String>? = null
    private var pendingDirectoryPickerResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            permissionsChannelName,
        ).setMethodCallHandler(::handlePermissionCall)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            storageChannelName,
        ).setMethodCallHandler(::handleStorageCall)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            geoBackgroundChannelName,
        ).setMethodCallHandler(::handleGeoBackgroundCall)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            alertsChannelName,
        ).setMethodCallHandler(::handleAlertsCall)
        DeviceAlertNotifier.ensureChannel(this)
    }

    private fun handlePermissionCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestCameraAccess" -> requestPermissions(
                arrayOf(Manifest.permission.CAMERA),
                result,
            )

            "requestMicrophoneAccess" -> requestPermissions(
                arrayOf(Manifest.permission.RECORD_AUDIO),
                result,
            )

            "requestBackgroundLocationAccess" -> requestBackgroundLocationAccess(result)
            "requestNotificationAccess" -> requestNotificationAccess(result)

            "openAppSettings" -> openAppSettings(result)
            else -> result.notImplemented()
        }
    }

    private fun handleStorageCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickRecordingDirectory" -> pickRecordingDirectory(result)
            "copyRecordingToDirectory" -> copyRecordingToDirectory(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleGeoBackgroundCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "activate" -> {
                    GeoBackgroundRelayService.start(
                        context = this,
                        action = GeoBackgroundRelayService.ACTION_ACTIVATE,
                        arguments = call.arguments as? Map<*, *>,
                    )
                    result.success(null)
                }

                "deactivate" -> {
                    GeoBackgroundRelayService.start(
                        context = this,
                        action = GeoBackgroundRelayService.ACTION_DEACTIVATE,
                    )
                    result.success(null)
                }

                "stop" -> {
                    GeoBackgroundRelayService.start(
                        context = this,
                        action = GeoBackgroundRelayService.ACTION_STOP,
                    )
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error(
                "geo_background_failed",
                error.message ?: "Unable to control the geo background relay.",
                null,
            )
        }
    }

    private fun handleAlertsCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "showAlert" -> {
                val arguments = call.arguments as? Map<*, *>
                val id = (arguments?.get("id") as? Number)?.toInt()
                val title = arguments?.get("title") as? String
                val body = arguments?.get("body") as? String

                if (id == null || title.isNullOrBlank() || body.isNullOrBlank()) {
                    result.error(
                        "invalid_alert_arguments",
                        "Alert id, title, and body are required.",
                        null,
                    )
                    return
                }

                DeviceAlertNotifier.show(
                    context = this,
                    id = id,
                    title = title,
                    body = body,
                )
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun requestPermissions(
        permissions: Array<String>,
        result: MethodChannel.Result,
    ) {
        if (pendingPermissionResult != null) {
            result.error(
                "permission_request_in_progress",
                "Another permission request is already active.",
                null,
            )
            return
        }

        if (permissions.all(::isPermissionGranted)) {
            result.success(true)
            return
        }

        pendingPermissionResult = result
        pendingPermissions = permissions
        ActivityCompat.requestPermissions(this, permissions, permissionRequestCode)
    }

    private fun requestBackgroundLocationAccess(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(true)
            return
        }

        requestPermissions(
            arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
            result,
        )
    }

    private fun requestNotificationAccess(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }

        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            result,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != permissionRequestCode) {
            return
        }

        val callback = pendingPermissionResult ?: return
        val requestedPermissions = pendingPermissions
        pendingPermissionResult = null
        pendingPermissions = null

        val granted = requestedPermissions?.all(::isPermissionGranted)
            ?: grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        callback.success(granted)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != directoryPickerRequestCode) {
            return
        }

        val callback = pendingDirectoryPickerResult ?: return
        pendingDirectoryPickerResult = null

        if (resultCode != RESULT_OK || data?.data == null) {
            callback.success(null)
            return
        }

        val treeUri = data.data ?: run {
            callback.success(null)
            return
        }

        val flags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

        try {
            contentResolver.takePersistableUriPermission(treeUri, flags)
        } catch (_: SecurityException) {
            // Continue with the returned URI when the picker doesn't expose
            // persistable access for the selected location.
        }

        callback.success(
            mapOf(
                "path" to describeTreeUri(treeUri),
                "uri" to treeUri.toString(),
            ),
        )
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        val opened = runCatching {
            startActivity(intent)
            true
        }.getOrDefault(false)
        result.success(opened)
    }

    private fun pickRecordingDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryPickerResult != null) {
            result.error(
                "directory_picker_in_progress",
                "Another directory picker request is already active.",
                null,
            )
            return
        }

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }

        pendingDirectoryPickerResult = result
        startActivityForResult(intent, directoryPickerRequestCode)
    }

    private fun copyRecordingToDirectory(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")?.trim().orEmpty()
        val treeUriString = call.argument<String>("treeUri")?.trim().orEmpty()
        val fileName = call.argument<String>("fileName")?.trim().orEmpty()

        if (sourcePath.isEmpty() || treeUriString.isEmpty() || fileName.isEmpty()) {
            result.error(
                "invalid_copy_request",
                "Recording copy request is missing a source path, tree URI, or file name.",
                null,
            )
            return
        }

        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
            result.error(
                "missing_recording",
                "The recording file does not exist.",
                null,
            )
            return
        }

        val treeUri = Uri.parse(treeUriString)
        val targetDirectory = DocumentFile.fromTreeUri(this, treeUri)
        if (targetDirectory == null || !targetDirectory.canWrite()) {
            result.error(
                "directory_not_writable",
                "The selected recording folder is not writable.",
                null,
            )
            return
        }

        try {
            targetDirectory.findFile(fileName)?.delete()
            val targetFile = targetDirectory.createFile("video/mp4", fileName)
            if (targetFile == null) {
                result.error(
                    "file_creation_failed",
                    "Unable to create the recording file in the selected folder.",
                    null,
                )
                return
            }

            FileInputStream(sourceFile).use { input ->
                contentResolver.openOutputStream(targetFile.uri, "w")?.use { output ->
                    input.copyTo(output)
                } ?: throw IllegalStateException("Unable to open the selected folder for writing.")
            }

            result.success(
                mapOf(
                    "path" to "${describeTreeUri(treeUri)}/$fileName",
                    "uri" to targetFile.uri.toString(),
                ),
            )
        } catch (error: Exception) {
            result.error(
                "copy_failed",
                error.message ?: "Unable to save the recording to the selected folder.",
                null,
            )
        }
    }

    private fun describeTreeUri(treeUri: Uri): String {
        return runCatching {
            val documentId = DocumentsContract.getTreeDocumentId(treeUri)
            val components = documentId.split(":", limit = 2)
            val volume = components.firstOrNull().orEmpty()
            val relativePath = components.getOrNull(1).orEmpty().trim('/')
            val rootPath = if (volume.equals("primary", ignoreCase = true)) {
                "/storage/emulated/0"
            } else {
                "/storage/$volume"
            }

            if (relativePath.isEmpty()) {
                rootPath
            } else {
                "$rootPath/$relativePath"
            }
        }.getOrDefault(treeUri.toString())
    }

    private fun isPermissionGranted(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            permission,
        ) == PackageManager.PERMISSION_GRANTED
    }
}
