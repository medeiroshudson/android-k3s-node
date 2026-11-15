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
 *
 * The collector is installed from the APK's assets before the first run, under
 * its own lock. Copying it on every launch raced the pollers, which executed a
 * half-written script and reported syntax errors at random lines.
 */
object RootShell {

    private const val TARGET_DIR = "/data/local/Droidspaces/monitor"
    private const val SCRIPT = "$TARGET_DIR/monitor.sh"

    private val fastLock = Mutex()
    private val slowLock = Mutex()
    private val installLock = Mutex()
    private var installed = false
    private var appContext: Context? = null

    /** Second root shell, used only by the cluster section. */
    private val slowShell: Shell by lazy { Shell.Builder.create().build() }

    /** Call once, before any polling starts. */
    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /**
     * Puts the collector on the device the first time it is needed, and only
     * rewrites it when this build ships a different one. Every lane goes through
     * this gate, so no poller can read a partially written file.
     */
    private suspend fun ensureInstalled() = installLock.withLock {
        if (installed) return@withLock
        val context = appContext ?: return@withLock

        val staged = File(context.cacheDir, "monitor.sh")
        context.assets.open("monitor.sh").use { input ->
            staged.outputStream().use { output -> input.copyTo(output) }
        }
        val target = File(SCRIPT)
        val unchanged = target.exists() &&
            target.length() == staged.length() &&
            runCatching { target.readText() == staged.readText() }.getOrDefault(false)

        if (!unchanged) {
            Shell.cmd(
                "mkdir -p $TARGET_DIR",
                "cp ${staged.absolutePath} $SCRIPT",
                "chmod 755 $SCRIPT",
            ).exec()
        }
        staged.delete()
        installed = true
    }

    /** True once Magisk granted root to this app. */
    fun isAvailable(): Boolean = Shell.getShell().isRoot

    /** Runs the collector for one section and returns its JSON line, or null. */
    suspend fun collect(section: String): String? {
        ensureInstalled()
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
