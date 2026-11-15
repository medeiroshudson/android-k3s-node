package dev.hmedeiros.k3smonitor.data

import android.content.Context
import com.topjohnwu.superuser.Shell
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/**
 * Thin wrapper around libsu.
 *
 * The app runs one command per poll cycle: the collector script prints a single
 * JSON object, so there is no fork-per-metric and no parsing on the root side.
 */
object RootShell {

    // Three pollers share one libsu shell. Without this lock their writes and
    // reads interleave and a section comes back empty, which the UI shows as "—".
    private val shellLock = Mutex()

    private const val TARGET_DIR = "/data/local/Droidspaces/monitor"
    private const val SCRIPT = "$TARGET_DIR/monitor.sh"

    /**
     * Installs the collector from the APK's assets on first run, so the app is
     * self-contained: no adb push needed after installing the APK.
     */
    fun installCollector(context: Context) {
        val staged = File(context.cacheDir, "monitor.sh")
        context.assets.open("monitor.sh").use { input ->
            staged.outputStream().use { output -> input.copyTo(output) }
        }
        Shell.cmd(
            "mkdir -p $TARGET_DIR",
            "cp ${staged.absolutePath} $SCRIPT",
            "chmod 755 $SCRIPT",
            "rm -f ${staged.absolutePath}",
        ).exec()
    }

    /** True once Magisk granted root to this app. */
    fun isAvailable(): Boolean = Shell.getShell().isRoot

    /** Runs the collector for one section and returns its JSON line, or null. */
    suspend fun collect(section: String): String? = shellLock.withLock {
        val result = Shell.cmd("/system/bin/sh $SCRIPT $section").exec()
        val line = result.out.firstOrNull { it.trim().startsWith("{") }?.trim()
        if (line == null || !result.isSuccess) {
            android.util.Log.w(
                "k3smonitor",
                "collect($section) code=${result.code} out=${result.out.size} " +
                    "err=${result.err.take(3)} json=${line != null}",
            )
        }
        line
    }
}
