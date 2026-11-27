package io.github.chialecode.blink_client

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * BLINK Android host activity exposing a zero-extra-plugin platform bridge on
 * `io.github.chialecode.blink/platform`:
 * - Private sandbox storage directories (`filesDir`, `noBackupFilesDir`, `cacheDir`)
 * - Storage Access Framework (SAF) document open/save and content URI writing
 * - Wi-Fi multicast lock management for M4 LAN mDNS discovery
 * - Hardware-backed Android Keystore AES-256-GCM secret storage (`INV-08`)
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
            "secretRead" -> handleSecretRead(call, result)
            "secretWrite" -> handleSecretWrite(call, result)
            "secretDelete" -> handleSecretDelete(call, result)
            "secretDeleteAllForChannel" -> handleSecretDeleteAllForChannel(call, result)
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

    private fun handleSecretRead(call: MethodCall, result: MethodChannel.Result) {
        val channel = validateSecretChannel(call.argument<String>("channel"))
        val key = validateSecretKey(call.argument<String>("key"))
        if (channel == null || key == null) {
            result.error("invalid_args", "Invalid channel or secret key.", null)
            return
        }
        ioExecutor.execute {
            try {
                val file = secretFileFor(channel, key)
                if (!file.exists()) {
                    runOnUiThread { result.success(null) }
                    return@execute
                }
                val raw = file.readBytes()
                if (raw.size < 2 + GCM_IV_BYTES + 16 || raw[0] != SECRET_ENVELOPE_VERSION) {
                    throw IllegalStateException("Corrupt encrypted secret envelope.")
                }
                val ivLen = raw[1].toInt() and 0xFF
                if (ivLen != GCM_IV_BYTES || raw.size <= 2 + ivLen) {
                    throw IllegalStateException("Invalid AES-GCM IV length.")
                }
                val iv = raw.copyOfRange(2, 2 + ivLen)
                val ciphertext = raw.copyOfRange(2 + ivLen, raw.size)
                val secretKey = getExistingKeystoreKey(channel)
                    ?: throw IllegalStateException("Android Keystore key missing for channel.")
                val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
                cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
                cipher.updateAAD("$channel:$key".toByteArray(StandardCharsets.UTF_8))
                val plaintext = cipher.doFinal(ciphertext)
                val decoded = String(plaintext, StandardCharsets.UTF_8)
                plaintext.fill(0)
                runOnUiThread { result.success(decoded) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "secret_decrypt_failed",
                        "Failed to decrypt Android Keystore secret.",
                        null,
                    )
                }
            }
        }
    }

    private fun handleSecretWrite(call: MethodCall, result: MethodChannel.Result) {
        val channel = validateSecretChannel(call.argument<String>("channel"))
        val key = validateSecretKey(call.argument<String>("key"))
        val value = call.argument<String>("value")
        if (channel == null || key == null || value == null) {
            result.error("invalid_args", "Invalid channel, secret key, or value.", null)
            return
        }
        ioExecutor.execute {
            var tmpFile: File? = null
            try {
                val dir = secretDirFor(channel).apply { mkdirs() }
                val targetFile = File(dir, "$key.enc")
                tmpFile = File(dir, "$key.enc.${System.nanoTime()}.blink-tmp")
                val secretKey = getOrCreateKeystoreKey(channel)
                val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
                cipher.init(Cipher.ENCRYPT_MODE, secretKey)
                cipher.updateAAD("$channel:$key".toByteArray(StandardCharsets.UTF_8))
                val plaintext = value.toByteArray(StandardCharsets.UTF_8)
                val ciphertext = try {
                    cipher.doFinal(plaintext)
                } finally {
                    plaintext.fill(0)
                }
                val iv = cipher.iv
                val envelope = ByteArrayOutputStream(2 + iv.size + ciphertext.size).apply {
                    write(SECRET_ENVELOPE_VERSION.toInt())
                    write(iv.size)
                    write(iv)
                    write(ciphertext)
                }.toByteArray()

                FileOutputStream(tmpFile).use { output ->
                    output.write(envelope)
                    output.flush()
                    output.fd.sync()
                }
                if (!tmpFile.renameTo(targetFile)) {
                    tmpFile.copyTo(targetFile, overwrite = true)
                    tmpFile.delete()
                }
                tmpFile = null
                runOnUiThread { result.success(true) }
            } catch (_: Exception) {
                tmpFile?.delete()
                runOnUiThread {
                    result.error(
                        "secret_write_failed",
                        "Failed to encrypt and persist Android Keystore secret.",
                        null,
                    )
                }
            }
        }
    }

    private fun handleSecretDelete(call: MethodCall, result: MethodChannel.Result) {
        val channel = validateSecretChannel(call.argument<String>("channel"))
        val key = validateSecretKey(call.argument<String>("key"))
        if (channel == null || key == null) {
            result.error("invalid_args", "Invalid channel or secret key.", null)
            return
        }
        ioExecutor.execute {
            try {
                val file = secretFileFor(channel, key)
                if (file.exists()) {
                    file.delete()
                }
                runOnUiThread { result.success(true) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error("secret_delete_failed", "Failed to delete secret.", null)
                }
            }
        }
    }

    private fun handleSecretDeleteAllForChannel(call: MethodCall, result: MethodChannel.Result) {
        val channel = validateSecretChannel(call.argument<String>("channel"))
        if (channel == null) {
            result.error("invalid_args", "Invalid channel.", null)
            return
        }
        ioExecutor.execute {
            try {
                val dir = secretDirFor(channel)
                if (dir.exists()) {
                    dir.listFiles()?.forEach { child ->
                        if (child.isFile && child.name.endsWith(".enc")) {
                            child.delete()
                        }
                    }
                }
                val alias = keystoreAliasFor(channel)
                val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE_PROVIDER).apply { load(null) }
                if (keyStore.containsAlias(alias)) {
                    keyStore.deleteEntry(alias)
                }
                runOnUiThread { result.success(true) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error("secret_clear_failed", "Failed to clear channel secrets.", null)
                }
            }
        }
    }

    private fun validateSecretChannel(raw: String?): String? {
        val trimmed = raw?.trim().orEmpty()
        return if (trimmed == "blink" || trimmed == "blink-dev") trimmed else null
    }

    private fun validateSecretKey(raw: String?): String? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty() || trimmed.length > 96 || trimmed.contains("..") || trimmed.startsWith(".")) {
            return null
        }
        return if (SECRET_KEY_REGEX.matches(trimmed)) trimmed else null
    }

    private fun secretDirFor(channel: String): File =
        File(File(noBackupFilesDir, channel), "credentials")

    private fun secretFileFor(channel: String, key: String): File =
        File(secretDirFor(channel), "$key.enc")

    private fun keystoreAliasFor(channel: String): String = "blink_secret_key_$channel"

    private fun getExistingKeystoreKey(channel: String): SecretKey? {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE_PROVIDER).apply { load(null) }
        val alias = keystoreAliasFor(channel)
        if (!keyStore.containsAlias(alias)) {
            return null
        }
        return keyStore.getKey(alias, null) as? SecretKey
    }

    private fun getOrCreateKeystoreKey(channel: String): SecretKey {
        getExistingKeystoreKey(channel)?.let { return it }
        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE_PROVIDER,
        )
        val spec = KeyGenParameterSpec.Builder(
            keystoreAliasFor(channel),
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
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
        private const val ANDROID_KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val AES_GCM_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val SECRET_ENVELOPE_VERSION: Byte = 1
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
        private val SECRET_KEY_REGEX = Regex("^[A-Za-z0-9._-]{1,96}$")
    }
}
