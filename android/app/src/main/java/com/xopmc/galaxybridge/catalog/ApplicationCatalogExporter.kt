package com.xopmc.galaxybridge.catalog

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
    fun inlineJSON(context: Context): ByteArray = inlineJSON(collect(context))
    fun inlineJSON(entries: List<Application>): ByteArray {
        val rows = JSONArray()
        entries.forEach { rows.put(it.json()) }
        val root = JSONObject().put("version", 1).put("applications", rows)
        val metadataBytes = root.toString().toByteArray(Charsets.UTF_8).size + 64
        require(metadataBytes < MAX_JSON)
        val iconCount = entries.count { it.iconPNG != null }
        val fieldBudget = if (iconCount == 0) 0 else (MAX_JSON - metadataBytes) / iconCount
        var omitted = 0
        entries.forEachIndexed { index, entry ->
            val icon = entry.iconPNG
            if (icon != null) {
                val encoded = inlineIcon(icon, fieldBudget)
                if (encoded != null) rows.getJSONObject(index).put("icon_png_base64", encoded)
                else omitted++
            }
        }
        root.put("icons_omitted", omitted)
        val bytes = root.toString().toByteArray(Charsets.UTF_8)
        check(bytes.size <= MAX_JSON)
        return bytes
    }

    private fun inlineIcon(png: ByteArray, fieldBudget: Int): String? {
        fun fitting(bytes: ByteArray): String? {
            val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
            // Android escapes '/' in Base64; count actual JSON bytes, replacing
            // the field object's braces with its comma in the existing row.
            val cost = JSONObject().put("icon_png_base64", encoded)
                .toString().toByteArray(Charsets.UTF_8).size - 1
            return encoded.takeIf { cost <= fieldBudget }
        }
        fitting(png)?.let { return it }
        return runCatching {
            val original = BitmapFactory.decodeByteArray(png, 0, png.size) ?: return@runCatching null
            try {
                for (edge in intArrayOf(96, 64, 48, 32, 24, 16)) {
                    if (edge >= original.width || edge >= original.height) continue
                    val resized = Bitmap.createScaledBitmap(original, edge, edge, true)
                    try {
                        val candidate = ByteArrayOutputStream().use { output ->
                            check(resized.compress(Bitmap.CompressFormat.PNG, 100, output))
                            fitting(output.toByteArray())
                        }
                        if (candidate != null) return@runCatching candidate
                    } finally { resized.recycle() }
                }
                null
            } finally { original.recycle() }
        }.getOrNull()
    }
    private const val MAX_JSON = 2 * 1024 * 1024
}
