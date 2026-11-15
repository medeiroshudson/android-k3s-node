package dev.hmedeiros.k3smonitor

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.runtime.LaunchedEffect
import dev.hmedeiros.k3smonitor.data.ClusterMetrics
import dev.hmedeiros.k3smonitor.data.ContainerMetrics
import dev.hmedeiros.k3smonitor.data.HostMetrics
import dev.hmedeiros.k3smonitor.data.RootShell
import dev.hmedeiros.k3smonitor.ui.MonitorScreen
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // This activity is the home screen: keep the panel lit while charging.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        setContent {
            var host by remember { mutableStateOf<HostMetrics?>(null) }
            var container by remember { mutableStateOf<ContainerMetrics?>(null) }
            var cluster by remember { mutableStateOf<ClusterMetrics?>(null) }
            var hostTick by remember { mutableIntStateOf(0) }
            var error by remember { mutableStateOf<String?>(null) }

            // Three cadences: /proc is cheap, droidspaces costs a fork, kubectl
            // costs a round trip and its data only refreshes every 15 s.
            LaunchedEffect(Unit) {
                withContext(Dispatchers.IO) { RootShell.installCollector(applicationContext) }
                while (true) {
                    val json = withContext(Dispatchers.IO) { RootShell.collect("host") }
                    if (json != null) {
                        HostMetrics.parse(json)?.let { host = it; hostTick = 0 }
                        error = null
                    } else {
                        error = "sem leitura do coletor (root?)"
                    }
                    delay(2_000)
                }
            }

            LaunchedEffect(Unit) {
                while (true) {
                    withContext(Dispatchers.IO) { RootShell.collect("container") }
                        ?.let { ContainerMetrics.parse(it)?.let { c -> container = c } }
                    delay(5_000)
                }
            }

            LaunchedEffect(Unit) {
                while (true) {
                    withContext(Dispatchers.IO) { RootShell.collect("cluster") }
                        ?.let { ClusterMetrics.parse(it)?.let { c -> cluster = c } }
                    delay(15_000)
                }
            }

            LaunchedEffect(hostTick) {
                while (true) {
                    delay(1_000)
                    hostTick++
                }
            }

            MonitorScreen(
                host = host,
                container = container,
                cluster = cluster,
                hostAgeSec = hostTick,
                error = error,
            )
        }
    }
}
