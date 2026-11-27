package io.github.chialecode.blink_client

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * BLINK Android host activity exposing a zero-extra-plugin platform bridge on
 * `io.github.chialecode.blink/platform`:
 * - Private sandbox storage directories (`filesDir`, `noBackupFilesDir`, `cacheDir`)
 * - Storage Access Framework (SAF) document open/save and content URI writing
 * - Wi-Fi multicast lock management for M4 LAN mDNS discovery
 *
 * Kept modular so Android Keystore methods can be added cleanly in subsequent M4 work.
 */
class MainActivity : FlutterActivity() {
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var pendingPickerResult: MethodChannel.Result? = null
    private var pendingPickerRequestCode: Int = 0
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLATFORM_CHANNEL_NAME)
            .setMethodCallHandler(::handlePlatformCall)
    }

    private fun handlePlatformCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStorageDirs" -> handleGetStorageDirs(result)
            "pickFileToOpen" -> handlePickFileToOpen(call, result)
            "pickFileToSave" -> handlePickFileToSave(call, result)
            "writeBytesToContentUri" -> handleWriteBytesToContentUri(call, result)
            "acquireMulticastLock" -> handleAcquireMulticastLock(result)
            "releaseMulticastLock" -> handleReleaseMulticastLock(result)
            else -> result.notImplemented()
        }
    }

    private fun handleGetStorageDirs(result: MethodChannel.Result) {
        result.success(
            mapOf(
                "filesDir" to filesDir.absolutePath,
                "noBackupFilesDir" to noBackupFilesDir.absolutePath,
                "cacheDir" to cacheDir.absolutePath,
            ),
        )
    }

    @Suppress("DEPRECATION")
    private fun handlePickFileToOpen(call: MethodCall, result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("picker_busy", "Another file picker operation is already in progress.", null)
            return
        }
        val mimeType = (call.argument<String>("mimeType") ?: "*/*").ifBlank { "*/*" }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pendingPickerResult = result
        pendingPickerRequestCode = REQUEST_OPEN_DOCUMENT
        try {
            startActivityForResult(intent, REQUEST_OPEN_DOCUMENT)
        } catch (error: Exception) {
            clearPendingPicker()
            result.error("picker_unavailable", error.message ?: "Unable to open document picker.", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun handlePickFileToSave(call: MethodCall, result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("picker_busy", "Another file picker operation is already in progress.", null)
            return
        }
        val mimeType = (call.argument<String>("mimeType") ?: "*/*").ifBlank { "*/*" }
        val suggestedName =
            (call.argument<String>("suggestedFileName") ?: "blink-export")
                .trim()
                .ifEmpty { "blink-export" }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, suggestedName)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pendingPickerResult = result
        pendingPickerRequestCode = REQUEST_CREATE_DOCUMENT
        try {
            startActivityForResult(intent, REQUEST_CREATE_DOCUMENT)
        } catch (error: Exception) {
            clearPendingPicker()
            result.error("picker_unavailable", error.message ?: "Unable to open save document picker.", null)
        }
    }

    private fun handleWriteBytesToContentUri(call: MethodCall, result: MethodChannel.Result) {
        val rawUri = call.argument<String>("uri")?.trim().orEmpty()
        val bytes = call.argument<ByteArray>("bytes")
        if (rawUri.isEmpty() || !rawUri.startsWith("content://") || bytes == null) {
            result.error("invalid_args", "Expected a content:// URI and non-null byte payload.", null)
            return
        }
        ioExecutor.execute {
            try {
                val uri = Uri.parse(rawUri)
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("ContentResolver returned null OutputStream.")
                stream.use { output ->
                    output.write(bytes)
                    output.flush()
                }
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("io_error", error.message ?: "Failed to write document URI.", null)
                }
            }
        }
    }

    private fun handleAcquireMulticastLock(result: MethodChannel.Result) {
        try {
            val wifiManager =
                applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiManager == null) {
                result.success(false)
                return
            }
            val lock = multicastLock ?: wifiManager.createMulticastLock(MULTICAST_LOCK_TAG).apply {
                setReferenceCounted(false)
                multicastLock = this
            }
            if (!lock.isHeld) {
                lock.acquire()
            }
            result.success(lock.isHeld)
        } catch (_: SecurityException) {
            result.success(false)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun handleReleaseMulticastLock(result: MethodChannel.Result) {
        releaseMulticastLockInternal()
        result.success(true)
    }

    private fun releaseMulticastLockInternal() {
        val lock = multicastLock ?: return
        try {
            if (lock.isHeld) {
                lock.release()
            }
        } catch (_: Exception) {
            // Best-effort release during lifecycle teardown.
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val pending = pendingPickerResult
        if (pending == null || requestCode != pendingPickerRequestCode) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        clearPendingPicker()

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }

        when (requestCode) {
            REQUEST_OPEN_DOCUMENT -> copyPickedDocumentToCache(uri, pending)
            REQUEST_CREATE_DOCUMENT -> pending.success(uri.toString())
            else -> pending.success(null)
        }
    }

    private fun copyPickedDocumentToCache(uri: Uri, result: MethodChannel.Result) {
        ioExecutor.execute {
            var tmpFile: File? = null
            try {
                val stagingDir = File(cacheDir, "picked_imports").apply { mkdirs() }
                val safeName = sanitizePickedFileName(queryDisplayName(uri))
                val uniquePrefix = UUID.randomUUID().toString().replace("-", "").take(12)
                val targetFile = File(stagingDir, "${uniquePrefix}_$safeName")
                tmpFile = File(stagingDir, "${targetFile.name}.part")

                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("Unable to open selected document stream.")
                input.use { source ->
                    FileOutputStream(tmpFile).use { output ->
                        val buffer = ByteArray(COPY_BUFFER_BYTES)
                        while (true) {
                            val read = source.read(buffer)
                            if (read <= 0) {
                                break
                            }
                            output.write(buffer, 0, read)
                        }
                        output.flush()
                        output.fd.sync()
                    }
                }

                if (!tmpFile.renameTo(targetFile)) {
                    tmpFile.copyTo(targetFile, overwrite = true)
                    tmpFile.delete()
                }
                tmpFile = null
                runOnUiThread { result.success(targetFile.absolutePath) }
            } catch (error: Exception) {
                tmpFile?.delete()
                runOnUiThread {
                    result.error("io_error", error.message ?: "Failed to stage selected file.", null)
                }
            }
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) cursor.getString(idx) else null
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun sanitizePickedFileName(rawName: String?): String {
        val base = rawName
            ?.substringAfterLast('/')
            ?.substringAfterLast('\\')
            ?.replace("..", "_")
            ?.trim()
            .orEmpty()
        if (base.isEmpty()) {
            return "imported-file"
        }
        val cleaned = buildString(base.length) {
            for (ch in base) {
                if (ch.isLetterOrDigit() || ch == '.' || ch == '_' || ch == '-' || ch == ' ') {
                    append(ch)
                } else {
                    append('_')
                }
            }
        }.trim().trimStart('.')
        return cleaned.ifEmpty { "imported-file" }.take(120)
    }

    private fun clearPendingPicker() {
        pendingPickerResult = null
        pendingPickerRequestCode = 0
    }

    override fun onDestroy() {
        pendingPickerResult?.success(null)
        clearPendingPicker()
        releaseMulticastLockInternal()
        ioExecutor.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val PLATFORM_CHANNEL_NAME = "io.github.chialecode.blink/platform"
        private const val MULTICAST_LOCK_TAG = "blink-lan-discovery"
        private const val REQUEST_OPEN_DOCUMENT = 4801
        private const val REQUEST_CREATE_DOCUMENT = 4802
        private const val COPY_BUFFER_BYTES = 32 * 1024
    }
}
