package dev.hmedeiros.k3smonitor.data

import android.content.Context
import android.util.Log
import com.topjohnwu.superuser.Shell
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/**
 * Thin wrapper around libsu.
 *
 * The app runs one command per poll cycle: the collector script prints a single
 * JSON object, so there is no fork-per-metric and no parsing on the root side.
 *
 * Two lanes, one shell each. Concurrency on a single shell interleaves writes and
 * reads and makes a section come back empty, so each lane takes a lock; but a
 * single lock would also stall the 2 s host poll behind a `kubectl` call that can
 * take four seconds, which showed up as a panel updating every 15 s.
 */
object RootShell {

    private const val TARGET_DIR = "/data/local/Droidspaces/monitor"
    private const val SCRIPT = "$TARGET_DIR/monitor.sh"

    private val fastLock = Mutex()
    private val slowLock = Mutex()

    /** Second root shell, used only by the cluster section. */
    private val slowShell: Shell by lazy { Shell.Builder.create().build() }

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
    suspend fun collect(section: String): String? {
        val slow = section == "cluster"
        val lock = if (slow) slowLock else fastLock
        return lock.withLock {
            val shell = if (slow) slowShell else Shell.getShell()
            // Capture lists are passed explicitly: a Job without them returns an
            // empty output even when the command ran and exited 0.
            val out = mutableListOf<String>()
            val err = mutableListOf<String>()
            val result = shell.newJob()
                .add("/system/bin/sh $SCRIPT $section")
                .to(out, err)
                .exec()
            val line = out.firstOrNull { it.trim().startsWith("{") }?.trim()
            if (line == null || !result.isSuccess) {
                Log.w(
                    "k3smonitor",
                    "collect($section) code=${result.code} out=${out.size} " +
                        "err=${err.take(3)} json=${line != null}",
                )
            }
            line
        }
    }
}
