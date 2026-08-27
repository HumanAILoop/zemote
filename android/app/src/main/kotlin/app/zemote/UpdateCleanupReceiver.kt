package app.zemote

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.io.File

class UpdateCleanupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val prefs = context.getSharedPreferences("update", Context.MODE_PRIVATE)
        val path = prefs.getString("cleanupApkPath", null)
        if (path != null) {
            runCatching { File(path).delete() }
            prefs.edit().remove("cleanupApkPath").apply()
        }
        runCatching { File(context.filesDir, "update").listFiles()?.forEach(File::delete) }
    }
}
