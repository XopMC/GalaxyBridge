package com.xopmc.galaxybridge.catalog

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Shell-only export used by the direct ADB transport. The receiver is compiled
 * only into shell-enabled flavors and is protected by Android's DUMP permission,
 * which the adb shell owns but ordinary third-party apps do not.
 */
class ApplicationCatalogExportReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_EXPORT) return
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID)
        if (requestId == null || !REQUEST_ID.matches(requestId)) {
            resultCode = RESULT_INVALID_REQUEST
            return
        }

        val pendingResult = goAsync()
        EXECUTOR.execute {
            runCatching { export(context, requestId) }
                .onSuccess { directory ->
                    pendingResult.resultCode = RESULT_OK
                    pendingResult.resultData = directory.absolutePath
                }
                .onFailure { failure ->
                    pendingResult.resultCode = RESULT_EXPORT_FAILED
                    pendingResult.resultData = failure.javaClass.simpleName
                }
            pendingResult.finish()
        }
    }

    private fun export(context: Context, requestId: String): File {
        val externalRoot = requireNotNull(context.getExternalFilesDir(null))
        val catalogRoot = File(externalRoot, "application-catalog").apply { mkdirs() }
        removeExpiredExports(catalogRoot)
        val output = File(catalogRoot, requestId).apply {
            deleteRecursively()
            check(mkdirs()) { "Unable to create catalog export" }
        }
        val iconDirectory = File(output, "icons").apply {
            check(mkdirs()) { "Unable to create icon export" }
        }

        val packageManager = context.packageManager
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = if (Build.VERSION.SDK_INT >= 33) {
            packageManager.queryIntentActivities(
                launcherIntent,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_ALL.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(launcherIntent, PackageManager.MATCH_ALL)
        }
        val seen = HashSet<String>()
        val applications = JSONArray()
        resolved.sortedWith(
            compareBy<android.content.pm.ResolveInfo> {
                it.loadLabel(packageManager).toString().lowercase()
            }.thenBy { it.activityInfo.packageName },
        ).forEach { resolveInfo ->
            val activity = resolveInfo.activityInfo ?: return@forEach
            val packageName = activity.packageName
            if (!seen.add(packageName)) return@forEach
            val iconName = "${applications.length()}.png"
            val iconFile = File(iconDirectory, iconName)
            val hasIcon = runCatching {
                val drawable = resolveInfo.loadIcon(packageManager)
                val bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
                drawable.draw(canvas)
                FileOutputStream(iconFile).use { stream ->
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
                    stream.fd.sync()
                }
                bitmap.recycle()
                true
            }.getOrElse {
                iconFile.delete()
                false
            }
            applications.put(
                JSONObject()
                    .put("package", packageName)
                    .put("component", "${activity.packageName}/${activity.name}")
                    .put("label", resolveInfo.loadLabel(packageManager).toString())
                    .put(
                        "system",
                        activity.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0,
                    )
                    .put("icon", if (hasIcon) "icons/$iconName" else JSONObject.NULL),
            )
        }

        val temporaryManifest = File(output, "manifest.json.part")
        temporaryManifest.writeText(
            JSONObject()
                .put("version", 1)
                .put("applications", applications)
                .toString(),
            Charsets.UTF_8,
        )
        check(temporaryManifest.renameTo(File(output, "manifest.json"))) {
            "Unable to publish catalog manifest"
        }
        return output
    }

    private fun removeExpiredExports(root: File) {
        val cutoff = System.currentTimeMillis() - EXPORT_RETENTION_MILLIS
        root.listFiles()?.filter { it.isDirectory && it.lastModified() < cutoff }
            ?.forEach(File::deleteRecursively)
    }

    companion object {
        const val ACTION_EXPORT = "com.xopmc.galaxybridge.EXPORT_APPLICATION_CATALOG"
        const val EXTRA_REQUEST_ID = "request_id"
        private const val RESULT_OK = 0
        private const val RESULT_INVALID_REQUEST = 2
        private const val RESULT_EXPORT_FAILED = 3
        private const val ICON_SIZE = 128
        private const val EXPORT_RETENTION_MILLIS = 7L * 24L * 60L * 60L * 1_000L
        private val REQUEST_ID = Regex("^[0-9a-f]{32}$")
        private val EXECUTOR = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "GalaxyBridge-AppCatalog").apply { isDaemon = true }
        }
    }
}
