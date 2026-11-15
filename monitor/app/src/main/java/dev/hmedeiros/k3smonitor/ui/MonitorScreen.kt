package dev.hmedeiros.k3smonitor.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
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

/**
 * Tuned for an OLED panel left on all day: the background is pure black, so
 * those pixels are simply off, and the surfaces above it are as dark as they can
 * be while still reading as a card. Text is dimmed to the least brightness that
 * keeps the panel legible from a distance — every lit pixel costs power here.
 */
object Palette {
    val bg = Color(0xFF000000)
    val card = Color(0xFF0B1013)
    val cardSoft = Color(0xFF141D20)
    val accent = Color(0xFF6FC5BC)
    val text = Color(0xFFD8E2E4)
    val muted = Color(0xFF75858C)
    val ok = Color(0xFF7FD1C8)
    val warn = Color(0xFFE0B25A)
    val bad = Color(0xFFE06C6C)
}

/**
 * Three cards side by side, each one carrying the same pair of gauges — CPU and
 * memory — for a different scope: the phone (host), the container that runs the
 * kubelet (node) and the cluster as a whole. Keeping the shape identical is the
 * point: the eye compares at the same place in each card.
 */
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
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Header(cluster, container, hostAgeSec)

        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth().weight(1f),
        ) {
            HostCard(host, Modifier.weight(1f))
            NodeCard(container, Modifier.weight(1f))
            ClusterCard(cluster, Modifier.weight(1f))
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth().height(74.dp),
        ) {
            InfoCard(
                title = "TEMPERATURA",
                value = host?.tempC?.let { "%.1f °C".format(it) } ?: "—",
                detail = host?.batteryTempC?.let { "bateria %.1f °C".format(it) }.orEmpty(),
                modifier = Modifier.weight(1f),
            )
            InfoCard(
                title = "BATERIA",
                value = host?.batteryPct?.let { "$it%" } ?: "—",
                detail = batteryLabel(host?.batteryStatus),
                modifier = Modifier.weight(1f),
            )
            InfoCard(
                title = "DISCO",
                value = container?.diskUsedPct?.let { "$it%" }
                    ?: host?.diskUsedPct?.let { "$it%" } ?: "—",
                detail = container?.let { c ->
                    val total = c.diskTotalKb
                    val free = c.diskFreeKb
                    if (total != null && free != null) "${gb(total - free)} de ${gb(total)}" else ""
                }.orEmpty(),
                modifier = Modifier.weight(1f),
            )
        }

        ServicesRow(container)
        Footer(error)
    }
}

@Composable
private fun HostCard(host: HostMetrics?, modifier: Modifier = Modifier) {
    val rejectNote = host?.psiFull10?.takeIf { it > 0 }
    MetricCard(
        title = "HOST",
        cpuPercent = host?.cpuPct,
        cpuValue = pct(host?.cpuPct),
        cpuDetail = buildString {
            host?.cpuCores?.let { append("$it núcleos") }
            host?.load1?.let {
                if (isNotEmpty()) append(" · ")
                append("load %.2f".format(it))
            }
        }.ifEmpty { "—" },
        ramPercent = host?.memUsedPct,
        ramValue = pct(host?.memUsedPct),
        ramDetail = host?.let { h -> h.memUsedKb?.let { "${gb(it)} de ${gb(h.memTotalKb ?: 0)}" } }
            ?: "—",
        footnote = buildString {
            host?.swapTotalKb?.let { total ->
                val free = host.swapFreeKb ?: total
                append("swap ${amount(total - free)} de ${amount(total)}")
            }
            rejectNote?.let {
                if (isNotEmpty()) append(" · ")
                append("PSI %.1f".format(it))
            }
        }.ifEmpty { null },
        modifier = modifier,
    )
}

@Composable
private fun NodeCard(container: ContainerMetrics?, modifier: Modifier = Modifier) {
    val running = container?.state == "running"
    MetricCard(
        title = "NODE",
        cpuPercent = if (running) container?.cpuPct else null,
        cpuValue = if (running) pct(container?.cpuPct) else "parado",
        cpuDetail = if (running) {
            val used = container?.cpuCoresUsed
            val cores = container?.cpuCores
            when {
                used == null || cores == null -> "—"
                // 1% and "0,0 of 8 cores" contradict each other; below a tenth
                // of a core the honest statement is that it is under one tenth.
                used < 0.05 -> "<0,1 de $cores núcleos"
                else -> "%.1f de %d núcleos".format(used, cores)
            }
        } else "container não iniciado",
        ramPercent = if (running) container?.ramUsedPct else null,
        ramValue = if (running) pct(container?.ramUsedPct) else "—",
        ramDetail = if (running) {
            container?.let { c ->
                val used = c.ramUsedKb
                val limit = c.ramLimitKb
                if (used != null && limit != null) "${mb(used)} de ${gb(limit)}" else "—"
            } ?: "—"
        } else "—",
        footnote = container?.uptimeSec?.let {
            if (running) "container ativo há ${duration(it)}" else "container ativo há ${duration(it)}"
        },
        modifier = modifier,
    )
}

@Composable
private fun ClusterCard(cluster: ClusterMetrics?, modifier: Modifier = Modifier) {
    val measured = cluster?.partiallyMeasured == true
    MetricCard(
        title = "CLUSTER",
        cpuPercent = cluster?.cpuPct,
        cpuValue = pct(cluster?.cpuPct),
        cpuDetail = cluster?.let { c ->
            val used = c.cpuUsedCores
            val cap = c.cpuMeasuredCores
            if (used != null && cap != null) "%.1f de %.0f núcleos".format(used, cap) else "—"
        } ?: "—",
        ramPercent = cluster?.memPct,
        ramValue = pct(cluster?.memPct),
        ramDetail = cluster?.let { c ->
            val used = c.memUsedKb
            val cap = c.memMeasuredKb
            if (used != null && cap != null) "${gb(used)} de ${gb(cap)}" else "—"
        } ?: "—",
        footnote = cluster?.let { c ->
            val total = c.nodesTotal
            val reporting = c.nodesReporting
            val named = c.measuredNodes
            val coverage = when {
                // Naming the node is the difference between "the cluster uses 22%"
                // and "the one node that reports uses 22% of its own capacity".
                named.isNotEmpty() && total != null && reporting != null ->
                    "medido em ${named.joinToString(", ")} · $reporting de $total nós"
                reporting != null && total != null -> "$reporting de $total nós medidos"
                else -> null
            }
            val pods = c.podsRunning
            val podsTotal = c.podsTotal
            listOfNotNull(
                coverage,
                if (pods != null && podsTotal != null) "$pods/$podsTotal pods" else null,
            ).joinToString(" · ").ifEmpty { null }
        },
        footnoteTone = if (measured) Palette.warn else Palette.muted,
        modifier = modifier,
    )
}

@Composable
private fun MetricCard(
    title: String,
    cpuPercent: Int?,
    cpuValue: String,
    cpuDetail: String,
    ramPercent: Int?,
    ramValue: String,
    ramDetail: String,
    footnote: String?,
    footnoteTone: Color = Palette.muted,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxHeight()
            .clip(RoundedCornerShape(14.dp))
            .background(Palette.card)
            .padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        Text(
            title,
            color = Palette.muted,
            fontSize = 10.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 1.4.sp,
        )
        Spacer(Modifier.weight(1f))
        Gauge("CPU", cpuValue, cpuPercent, cpuDetail)
        Spacer(Modifier.height(14.dp))
        Gauge("RAM", ramValue, ramPercent, ramDetail)
        Spacer(Modifier.weight(1f))
        if (footnote != null) {
            Text(footnote, color = footnoteTone, fontSize = 10.sp, maxLines = 2)
        }
    }
}

@Composable
private fun Gauge(label: String, value: String, percent: Int?, detail: String) {
    Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.fillMaxWidth()) {
        Text(
            label,
            color = Palette.muted,
            fontSize = 10.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 1.2.sp,
        )
        Spacer(Modifier.weight(1f))
        Text(
            value,
            color = valueTone(percent, value),
            fontSize = 22.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
        )
    }
    Spacer(Modifier.height(4.dp))
    Bar(percent)
    Spacer(Modifier.height(4.dp))
    Text(detail, color = Palette.muted, fontSize = 11.sp, maxLines = 1)
}

@Composable
private fun Header(cluster: ClusterMetrics?, container: ContainerMetrics?, hostAgeSec: Int) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column {
            Text(
                text = cluster?.node ?: "k3s node",
                color = Palette.text,
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = buildString {
                    cluster?.k3sVersion?.let { append(it) }
                    cluster?.nodesReady?.let { ready ->
                        cluster.nodesTotal?.let { total ->
                            if (isNotEmpty()) append(" · ")
                            append("$ready/$total nós Ready")
                        }
                    }
                }.ifEmpty { "aguardando o cluster" },
                color = Palette.muted,
                fontSize = 12.sp,
            )
        }
        Spacer(Modifier.weight(1f))
        StatusPill(ready = cluster?.ready)
        Spacer(Modifier.width(12.dp))
        Text(
            text = "atualizado ${hostAgeSec}s",
            color = Palette.muted,
            fontSize = 12.sp,
        )
    }
}

/** null means the cluster has not answered yet, which is not the same as NotReady. */
@Composable
private fun StatusPill(ready: Boolean?) {
    val (dot, label) = when (ready) {
        true -> Palette.ok to "Ready"
        false -> Palette.bad to "NotReady"
        null -> Palette.muted to "aguardando"
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Palette.cardSoft)
            .padding(horizontal = 14.dp, vertical = 7.dp),
    ) {
        Box(
            modifier = Modifier
                .size(9.dp)
                .clip(RoundedCornerShape(50))
                .background(dot),
        )
        Spacer(Modifier.width(8.dp))
        Text(text = label, color = dot, fontSize = 13.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun InfoCard(title: String, value: String, detail: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxHeight()
            .clip(RoundedCornerShape(14.dp))
            .background(Palette.card)
            .padding(horizontal = 14.dp, vertical = 9.dp),
    ) {
        Text(
            title,
            color = Palette.muted,
            fontSize = 10.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 1.2.sp,
        )
        Spacer(Modifier.height(3.dp))
        Text(value, color = Palette.text, fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
        if (detail.isNotEmpty()) {
            Spacer(Modifier.height(2.dp))
            Text(detail, color = Palette.muted, fontSize = 10.sp, maxLines = 1)
        }
    }
}

@Composable
private fun Bar(percent: Int?) {
    val value = (percent ?: 0).coerceIn(0, 100)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(5.dp)
            .clip(RoundedCornerShape(50))
            .background(Palette.cardSoft),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(value / 100f)
                .height(5.dp)
                .clip(RoundedCornerShape(50))
                .background(barTone(value)),
        )
    }
}

@Composable
private fun ServicesRow(container: ContainerMetrics?) {
    val services = container?.services.orEmpty()
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Palette.card)
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 7.dp),
    ) {
        Text(
            "SERVIÇOS",
            color = Palette.muted,
            fontSize = 10.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 1.2.sp,
        )
        Spacer(Modifier.width(4.dp))
        if (services.isEmpty()) {
            Text("—", color = Palette.muted, fontSize = 12.sp)
        } else {
            services.forEach { (name, state) ->
                val up = state == "active"
                Text(name, color = if (up) Palette.text else Palette.bad, fontSize = 12.sp)
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
private fun Footer(error: String?) {
    if (error == null) return
    Text(text = error, color = Palette.bad, fontSize = 11.sp, maxLines = 1)
}

private fun pct(value: Int?): String = value?.let { "$it%" } ?: "—"

private fun valueTone(percent: Int?, value: String): Color = when {
    value == "—" || value == "parado" -> Palette.muted
    (percent ?: 0) >= 90 -> Palette.bad
    (percent ?: 0) >= 70 -> Palette.warn
    else -> Palette.text
}

private fun barTone(percent: Int): Color = when {
    percent >= 90 -> Palette.bad
    percent >= 70 -> Palette.warn
    else -> Palette.accent
}

private fun batteryLabel(status: String?): String = when (status) {
    "Charging" -> "carregando"
    "Full" -> "cheia"
    "Discharging" -> "descarregando"
    "Not charging" -> "sem carga"
    null, "" -> ""
    else -> status.lowercase()
}

private fun gb(kb: Long): String = "%.1f GB".format(kb / 1_048_576.0)
private fun mb(kb: Long): String = "%.0f MB".format(kb / 1024.0)

/** Picks the unit that keeps the number short: 108 MB, 2,0 GB. */
private fun amount(kb: Long): String = if (kb >= 1_048_576) gb(kb) else mb(kb)

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
