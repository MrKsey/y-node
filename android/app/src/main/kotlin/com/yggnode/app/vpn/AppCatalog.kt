package com.yggnode.app.vpn

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import java.io.ByteArrayOutputStream

/**
 * The launchable apps, used by the split-tunnelling screen.
 *
 * Only apps with a launcher entry are listed: that is what the manifest queries
 * declaration allows without the broad QUERY_ALL_PACKAGES permission, and an app
 * the user cannot launch is not one they would route into the tunnel.
 */
object AppCatalog {

    data class AppInfo(
        val packageName: String,
        val label: String,
        val isSystem: Boolean,
    )

    fun list(context: Context): List<AppInfo> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = try {
            pm.queryIntentActivities(intent, PackageManager.MATCH_ALL)
        } catch (_: Exception) {
            emptyList()
        }

        val seen = HashSet<String>()
        val apps = ArrayList<AppInfo>(resolved.size)
        for (info in resolved) {
            val pkg = info.activityInfo?.packageName ?: continue
            // The app itself must never be routed into its own tunnel.
            if (pkg == context.packageName) continue
            if (!seen.add(pkg)) continue
            val appInfo = try {
                pm.getApplicationInfo(pkg, 0)
            } catch (_: Exception) {
                null
            }
            val label = try {
                pm.getApplicationLabel(info.activityInfo.applicationInfo).toString()
            } catch (_: Exception) {
                pkg
            }
            val system = appInfo != null &&
                (appInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
            apps.add(AppInfo(pkg, label, system))
        }
        return apps.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.label })
    }

    fun icon(context: Context, packageName: String): ByteArray? {
        val pm = context.packageManager
        val drawable = try {
            pm.getApplicationIcon(packageName)
        } catch (_: Exception) {
            return null
        }
        val bitmap = drawableToBitmap(drawable) ?: return null
        return try {
            ByteArrayOutputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                out.toByteArray()
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap? {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            val source = drawable.bitmap
            val size = ICON_SIZE
            return Bitmap.createScaledBitmap(source, size, size, true)
        }
        val size = ICON_SIZE
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        return bitmap
    }

    private const val ICON_SIZE = 96
}
