package com.xopmc.galaxybridge.catalog

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.util.Base64
import java.io.ByteArrayOutputStream
import org.json.JSONArray
import org.json.JSONObject

/** Normal Helper UID only. One renderer supplies both the existing ADB export and paired TLS catalog. */
internal object ApplicationCatalogExporter {
    class Application(val packageName: String, val component: String, val label: String, val system: Boolean, val iconPNG: ByteArray?) {
        fun json(icon: Any = JSONObject.NULL) = JSONObject().put("package", packageName).put("component", component)
            .put("label", label).put("system", system).put("icon", icon)
    }
    fun collect(context: Context): List<Application> {
        val manager = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = if (Build.VERSION.SDK_INT >= 33) manager.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_ALL.toLong()))
            else { @Suppress("DEPRECATION") manager.queryIntentActivities(intent, PackageManager.MATCH_ALL) }
        val seen = hashSetOf<String>()
        val entries = mutableListOf<Application>()
        val deadline = SystemClock.elapsedRealtime() + 8_000
        for (info in resolved.sortedBy { it.activityInfo?.packageName.orEmpty() }) {
            if (entries.size >= 512 || SystemClock.elapsedRealtime() > deadline) break
            val activity = info.activityInfo ?: continue
            val name = activity.packageName
            val component = "$name/${activity.name}"
            if (!seen.add(name) || name.length > 256 || component.length > 1024) continue
            val icon = runCatching {
                val drawable = info.loadIcon(manager)
                val bounds = Rect(drawable.bounds)
                val bitmap = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
                try {
                    drawable.setBounds(0, 0, 128, 128)
                    drawable.draw(Canvas(bitmap))
                    ByteArrayOutputStream().use { output ->
                        check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                        output.toByteArray().takeIf { it.size <= 65_536 }
                    }
                } finally { drawable.bounds = bounds; bitmap.recycle() }
            }.getOrNull()
            entries += Application(name, component, info.loadLabel(manager).toString().take(256),
                activity.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0, icon)
        }
        return entries.sortedBy { it.label.lowercase() }
    }
    fun inlineJSON(context: Context): ByteArray {
        val entries = collect(context)
        val rows = JSONArray()
        entries.forEach { rows.put(it.json()) }
        val root = JSONObject().put("version", 1).put("applications", rows)
        var size = root.toString().toByteArray(Charsets.UTF_8).size + 64
        require(size < MAX_JSON)
        var omitted = 0
        entries.forEachIndexed { index, entry ->
            val icon = entry.iconPNG
            if (icon != null) {
                val encoded = Base64.encodeToString(icon, Base64.NO_WRAP)
                val cost = encoded.length + 24
                if (size + cost < MAX_JSON) { rows.getJSONObject(index).put("icon_png_base64", encoded); size += cost }
                else omitted++
            }
        }
        root.put("icons_omitted", omitted)
        val bytes = root.toString().toByteArray(Charsets.UTF_8)
        check(bytes.size <= MAX_JSON)
        return bytes
    }
    private const val MAX_JSON = 2 * 1024 * 1024
}
