package dev.hmedeiros.k3smonitor.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.hmedeiros.k3smonitor.data.ClusterMetrics
import dev.hmedeiros.k3smonitor.data.ContainerMetrics
import dev.hmedeiros.k3smonitor.data.HostMetrics

object Palette {
    val bg = Color(0xFF0A0F12)
    val card = Color(0xFF121A1F)
    val cardSoft = Color(0xFF1A242B)
    val accent = Color(0xFF7FD1C8)
    val text = Color(0xFFE7EEF0)
    val muted = Color(0xFF7E8F96)
    val ok = Color(0xFF7FD1C8)
    val warn = Color(0xFFE0B25A)
    val bad = Color(0xFFE06C6C)
}

@Composable
fun MonitorScreen(
    host: HostMetrics?,
    container: ContainerMetrics?,
    cluster: ClusterMetrics?,
    hostAgeSec: Int,
    error: String?,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.bg)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Header(cluster, container, hostAgeSec)
        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth().weight(1f),
        ) {
            StatCard(
                title = "CPU",
                value = host?.cpuPct?.let { "$it%" } ?: "—",
                percent = host?.cpuPct,
                detail = buildString {
                    host?.cpuCores?.let { append("$it núcleos") }
                    host?.load1?.let { append(" · load ${"%.2f".format(it)}") }
                },
                modifier = Modifier.weight(1f),
            )
            StatCard(
                title = "MEMÓRIA",
                value = host?.memUsedPct?.let { "$it%" } ?: "—",
                percent = host?.memUsedPct,
                detail = buildString {
                    val used = host?.memTotalKb?.let { it - (host.memAvailKb ?: it) }
                    if (used != null && host.memTotalKb != null) {
                        append("${gb(used)} de ${gb(host.memTotalKb)}")
                    }
                    host?.psiFull10?.let { if (it > 0) append(" · PSI ${"%.1f".format(it)}") }
                },
                modifier = Modifier.weight(1f),
            )
            StatCard(
                title = "CONTAINER",
                value = container?.ramUsedPct?.let { "$it%" } ?: "—",
                percent = container?.ramUsedPct,
                detail = buildString {
                    if (container?.ramUsedKb != null && container.ramLimitKb != null) {
                        append("${mb(container.ramUsedKb)} de ${gb(container.ramLimitKb)}")
                    }
                    container?.cpuPermill?.takeIf { it > 0 }?.let { append(" · CPU ${"%.0f".format(it / 10.0)}%") }
                },
                modifier = Modifier.weight(1f),
            )
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth().weight(0.75f),
        ) {
            InfoCard(
                title = "TEMPERATURA",
                value = host?.tempC?.let { "${"%.1f".format(it)} °C" } ?: "—",
                detail = host?.batteryTempC?.let { "bateria ${"%.1f".format(it)} °C" } ?: "",
                modifier = Modifier.weight(1f),
            )
            InfoCard(
                title = "BATERIA",
                value = host?.batteryPct?.let { "$it%" } ?: "—",
                detail = host?.batteryStatus?.lowercase()?.replace('_', ' ') ?: "",
                modifier = Modifier.weight(1f),
            )
            InfoCard(
                title = "DISCO",
                value = container?.diskUsedPct?.let { "$it%" } ?: host?.diskUsedPct?.let { "$it%" } ?: "—",
                detail = container?.let {
                    if (it.diskTotalKb != null && it.diskFreeKb != null) {
                        "${gb(it.diskTotalKb - it.diskFreeKb)} de ${gb(it.diskTotalKb)}"
                    } else ""
                } ?: "",
                modifier = Modifier.weight(1f),
            )
        }
        ServicesRow(container)
        Footer(error, hostAgeSec)
    }
}

@Composable
private fun Header(cluster: ClusterMetrics?, container: ContainerMetrics?, hostAgeSec: Int) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column {
            Text(
                text = cluster?.node ?: "k3s node",
                color = Palette.text,
                fontSize = 24.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = buildString {
                    append(container?.uptimeSec?.let { "container ${duration(it)}" } ?: "container —")
                    cluster?.k3sVersion?.let { append(" · $it") }
                },
                color = Palette.muted,
                fontSize = 14.sp,
            )
        }
        Spacer(Modifier.weight(1f))
        StatusPill(ready = cluster?.ready == true)
        Spacer(Modifier.width(12.dp))
        Text(
            text = "atualizado ${hostAgeSec}s",
            color = Palette.muted,
            fontSize = 13.sp,
        )
    }
}

@Composable
private fun StatusPill(ready: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (ready) Palette.cardSoft else Palette.cardSoft)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(9.dp)
                .clip(RoundedCornerShape(50))
                .background(if (ready) Palette.ok else Palette.bad),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = if (ready) "Ready" else "NotReady",
            color = if (ready) Palette.ok else Palette.bad,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
private fun StatCard(
    title: String,
    value: String,
    percent: Int?,
    detail: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxHeight()
            .clip(RoundedCornerShape(14.dp))
            .background(Palette.card)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Text(title, color = Palette.muted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(4.dp))
        Text(
            value,
            color = Palette.text,
            fontSize = 30.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
        )
        Spacer(Modifier.height(6.dp))
        Bar(percent)
        Spacer(Modifier.height(5.dp))
        Text(detail, color = Palette.muted, fontSize = 12.sp, maxLines = 1)
    }
}

@Composable
private fun InfoCard(title: String, value: String, detail: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxHeight()
            .clip(RoundedCornerShape(14.dp))
            .background(Palette.card)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Text(title, color = Palette.muted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(3.dp))
        Text(value, color = Palette.text, fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
        if (detail.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            Text(detail, color = Palette.muted, fontSize = 12.sp, maxLines = 1)
        }
    }
}

@Composable
private fun Bar(percent: Int?) {
    val value = (percent ?: 0).coerceIn(0, 100)
    val color = when {
        value >= 90 -> Palette.bad
        value >= 70 -> Palette.warn
        else -> Palette.accent
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(6.dp)
            .clip(RoundedCornerShape(50))
            .background(Palette.cardSoft),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(value / 100f)
                .height(6.dp)
                .clip(RoundedCornerShape(50))
                .background(color),
        )
    }
}

@Composable
private fun ServicesRow(container: ContainerMetrics?) {
    val services = container?.services.orEmpty()
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Palette.card)
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Text("SERVIÇOS", color = Palette.muted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.width(6.dp))
        if (services.isEmpty()) {
            Text("—", color = Palette.muted, fontSize = 14.sp)
        } else {
            services.forEach { (name, state) ->
                val up = state == "active"
                Text(
                    text = name,
                    color = if (up) Palette.text else Palette.bad,
                    fontSize = 13.sp,
                )
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .clip(RoundedCornerShape(50))
                        .background(if (up) Palette.ok else Palette.bad),
                )
            }
        }
    }
}

@Composable
private fun Footer(error: String?, hostAgeSec: Int) {
    if (error == null && hostAgeSec < 10) return
    Text(
        text = error ?: "dados de ${hostAgeSec}s atrás",
        color = if (error != null) Palette.bad else Palette.muted,
        fontSize = 12.sp,
        maxLines = 1,
    )
}

private fun gb(kb: Long): String = "%.1f GB".format(kb / 1_048_576.0)
private fun mb(kb: Long): String = "%.0f MB".format(kb / 1024.0)

private fun duration(seconds: Long): String {
    val d = seconds / 86_400
    val h = (seconds % 86_400) / 3_600
    val m = (seconds % 3_600) / 60
    return when {
        d > 0 -> "${d}d ${h}h"
        h > 0 -> "${h}h ${m}m"
        else -> "${m}m"
    }
}
