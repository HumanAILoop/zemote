package app.zemote

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64

class MainActivity : FlutterActivity() {
    private val channelName = "zemote/update"
    private val notifyChannelName = "zemote/notifications"
    private val navChannelName = "zemote/nav"
    private val cryptoChannelName = "zemote/crypto"

    private val notificationPermissionRequestCode = 4096

    /** Payload (JSON) of a tapped notification, consumed by the Dart side. */
    private var pendingNotificationPayload: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getApkDir" -> result.success(apkDir().absolutePath)
                "getSupportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "canInstall" -> result.success(canRequestPackageInstalls())
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(true)
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    val deleteAfterInstall =
                        call.argument<Boolean>("deleteAfterInstall") == true
                    result.success(installApk(path, deleteAfterInstall))
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, notifyChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForeground" -> {
                    ZemoteNotificationService.start(
                        this,
                        call.argument<String>("title") ?: "任务运行中",
                        call.argument<String>("text") ?: ""
                    )
                    result.success(true)
                }
                "updateForeground" -> {
                    val title = call.argument<String>("title") ?: "任务运行中"
                    val text = call.argument<String>("text") ?: ""
                    val service = ZemoteNotificationService.instance
                    if (service != null) {
                        service.update(title, text)
                        result.success(true)
                    } else {
                        ZemoteNotificationService.start(this, title, text)
                        result.success(true)
                    }
                }
                "stopForeground" -> {
                    stopService(Intent(this, ZemoteNotificationService::class.java))
                    result.success(true)
                }
                "notifyTaskCompleted" -> {
                    TaskNotifications.notify(
                        this,
                        call.argument<String>("title") ?: "任务完成",
                        call.argument<String>("text") ?: "",
                        call.argument<String>("payload")
                    )
                    result.success(true)
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermission()
                    result.success(true)
                }
                "hasNotificationPermission" -> {
                    result.success(hasNotificationPermission())
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, navChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchPayload" -> {
                    result.success(pendingNotificationPayload)
                    pendingNotificationPayload = null
                }
                "setTapHandler" -> {
                    // Handler registration is implicit (method channel callbacks);
                    // just acknowledge and deliver any pending payload.
                    result.success(pendingNotificationPayload)
                    pendingNotificationPayload = null
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, cryptoChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "encrypt" -> {
                    try {
                        result.success(cryptoEncrypt(call.argument<String>("value") ?: ""))
                    } catch (e: Exception) {
                        result.error("crypto", e.message, null)
                    }
                }
                "decrypt" -> {
                    try {
                        result.success(cryptoDecrypt(call.argument<String>("value") ?: ""))
                    } catch (e: Exception) {
                        result.error("crypto", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingNotificationPayload = intent?.getStringExtra("notificationTask")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = intent.getStringExtra("notificationTask")
        if (payload != null) {
            pendingNotificationPayload = payload
            pushPayloadToDart(payload)
        }
    }

    private fun pushPayloadToDart(payload: String) {
        val engine = flutterEngine
        if (engine != null) {
            MethodChannel(engine.dartExecutor.binaryMessenger, navChannelName)
                .invokeMethod("onNotificationTap", payload, null)
        }
    }

    private fun hasNotificationPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasNotificationPermission()
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequestCode
            )
        }
    }

    private fun apkDir(): File = File(filesDir, "update").apply { mkdirs() }

    private fun canRequestPackageInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            )
            startActivity(intent)
        }
    }

    private fun installApk(path: String?, deleteAfterInstall: Boolean): Boolean {
        if (path == null) return false
        val file = File(path)
        if (!file.exists()) return false
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            if (deleteAfterInstall) {
                getSharedPreferences("update", MODE_PRIVATE)
                    .edit()
                    .putString("cleanupApkPath", file.absolutePath)
                    .apply()
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    // --------------------------------------------------------- keystore AES

    private val keyAlias = "zemote_credentials"

    private fun getOrCreateKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(keyAlias)) {
            val kg = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            kg.init(
                KeyGenParameterSpec.Builder(
                    keyAlias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
            return kg.generateKey()
        }
        return (ks.getEntry(keyAlias, null) as KeyStore.SecretKeyEntry).secretKey
    }

    /** AES/GCM: [12-byte IV][ciphertext+tag] -> base64. */
    private fun cryptoEncrypt(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        val cipherBytes = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val out = ByteArray(iv.size + cipherBytes.size)
        System.arraycopy(iv, 0, out, 0, iv.size)
        System.arraycopy(cipherBytes, 0, out, iv.size, cipherBytes.size)
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    private fun cryptoDecrypt(base64: String): String {
        val data = Base64.decode(base64, Base64.NO_WRAP)
        val iv = data.copyOfRange(0, 12)
        val cipherBytes = data.copyOfRange(12, data.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(cipherBytes), Charsets.UTF_8)
    }
}
