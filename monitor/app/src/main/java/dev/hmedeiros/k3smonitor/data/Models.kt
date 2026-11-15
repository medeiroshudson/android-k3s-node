package dev.hmedeiros.k3smonitor.data

import org.json.JSONObject
import kotlin.math.roundToInt

data class HostMetrics(
    val cpuPct: Int? = null,
    val cpuCores: Int? = null,
    val load1: Double? = null,
    val memTotalKb: Long? = null,
    val memAvailKb: Long? = null,
    val swapTotalKb: Long? = null,
    val swapFreeKb: Long? = null,
    val psiFull10: Double? = null,
    val tempC: Double? = null,
    val batteryPct: Int? = null,
    val batteryStatus: String? = null,
    val batteryTempC: Double? = null,
    val dataTotalKb: Long? = null,
    val dataFreeKb: Long? = null,
) {
    val memUsedKb: Long?
        get() {
            val total = memTotalKb ?: return null
            val avail = memAvailKb ?: return null
            return total - avail
        }

    val memUsedPct: Int?
        get() {
            val total = memTotalKb ?: return null
            val used = memUsedKb ?: return null
            if (total <= 0) return null
            return ((used * 100) / total).toInt()
        }

    val diskUsedPct: Int?
        get() {
            val total = dataTotalKb ?: return null
            val free = dataFreeKb ?: return null
            if (total <= 0) return null
            return (((total - free) * 100) / total).toInt()
        }

    companion object {
        fun parse(json: String): HostMetrics? = runCatching {
            val h = JSONObject(json).getJSONObject("host")
            HostMetrics(
                cpuPct = h.optIntOrNull("cpu_pct"),
                cpuCores = h.optIntOrNull("cpu_cores"),
                load1 = h.optDoubleOrNull("load1"),
                memTotalKb = h.optLongOrNull("mem_total_kb"),
                memAvailKb = h.optLongOrNull("mem_avail_kb"),
                swapTotalKb = h.optLongOrNull("swap_total_kb"),
                swapFreeKb = h.optLongOrNull("swap_free_kb"),
                psiFull10 = h.optDoubleOrNull("psi_full10"),
                tempC = h.optDoubleOrNull("temp_c"),
                batteryPct = h.optIntOrNull("battery_pct"),
                batteryStatus = h.optStringIfPresent("battery_status"),
                batteryTempC = h.optDoubleOrNull("battery_temp_c"),
                dataTotalKb = h.optLongOrNull("data_total_kb"),
                dataFreeKb = h.optLongOrNull("data_free_kb"),
            )
        }.getOrNull()
    }
}

data class ContainerMetrics(
    val state: String = "unknown",
    val pid: Int? = null,
    val uptimeSec: Long? = null,
    val cpuPermill: Int? = null,
    val cpuLimitPermill: Int? = null,
    val cpuCores: Int? = null,
    val ramUsedKb: Long? = null,
    val ramLimitKb: Long? = null,
    val diskTotalKb: Long? = null,
    val diskFreeKb: Long? = null,
    val services: Map<String, String> = emptyMap(),
) {
    /**
     * `cpu_permill` is permille of the *whole* container capacity, measured:
     * one saturated busy loop reports ~127 with 8 cores visible (1000/8 = 125)
     * and three report 383, so divide by 10 for a percentage comparable to the
     * host and cluster cards.
     */
    val cpuPct: Int?
        get() = cpuPermill?.div(10)

    /** Cores actually consumed, from the same permille. */
    val cpuCoresUsed: Double?
        get() = cpuPermill?.let { it / 1000.0 }

    val ramUsedPct: Int?
        get() {
            val used = ramUsedKb ?: return null
            val limit = ramLimitKb ?: return null
            if (limit <= 0) return null
            return ((used * 100) / limit).toInt()
        }

    val diskUsedPct: Int?
        get() {
            val total = diskTotalKb ?: return null
            val free = diskFreeKb ?: return null
            if (total <= 0) return null
            return (((total - free) * 100) / total).toInt()
        }

    companion object {
        fun parse(json: String): ContainerMetrics? = runCatching {
            val c = JSONObject(json).getJSONObject("container")
            val services = c.optString("services", "")
                .split(' ')
                .filter { it.contains('=') }
                .associate { it.substringBefore('=') to it.substringAfter('=') }
            ContainerMetrics(
                state = c.optString("state", "unknown"),
                pid = c.optIntOrNull("pid"),
                uptimeSec = c.optLongOrNull("uptime_sec"),
                cpuPermill = c.optIntOrNull("cpu_permill"),
                cpuLimitPermill = c.optIntOrNull("cpu_limit_permill"),
                cpuCores = c.optIntOrNull("cpu_cores"),
                ramUsedKb = c.optLongOrNull("ram_used_kb"),
                ramLimitKb = c.optLongOrNull("ram_limit_kb"),
                diskTotalKb = c.optLongOrNull("disk_total_kb"),
                diskFreeKb = c.optLongOrNull("disk_free_kb"),
                services = services,
            )
        }.getOrNull()
    }
}

/**
 * Cluster-wide numbers. Capacity is aggregated twice by the collector: over all
 * nodes, and over the nodes metrics-server actually answers for, because it
 * cannot scrape every kubelet here. The percentage is always computed against
 * the measured capacity, and [measured] tells the UI how much of the cluster
 * the number really covers.
 */
data class ClusterMetrics(
    val node: String? = null,
    val ready: Boolean = false,
    val podsTotal: Int? = null,
    val podsRunning: Int? = null,
    val k3sVersion: String? = null,
    val nodesTotal: Int? = null,
    val nodesReady: Int? = null,
    val nodesReporting: Int? = null,
    val cpuCapacityCores: Double? = null,
    val memCapacityKb: Long? = null,
    val cpuMeasuredCores: Double? = null,
    val memMeasuredKb: Long? = null,
    val cpuUsedCores: Double? = null,
    val memUsedKb: Long? = null,
) {
    val cpuPct: Int? get() = percent(cpuUsedCores, cpuMeasuredCores?.toDouble())
    val memPct: Int? get() = percent(memUsedKb?.toDouble(), memMeasuredKb?.toDouble())

    /** True when part of the cluster is missing from the usage numbers. */
    val partiallyMeasured: Boolean
        get() {
            val reporting = nodesReporting ?: return false
            val total = nodesTotal ?: return false
            return reporting < total
        }

    private fun percent(used: Double?, capacity: Double?): Int? {
        if (used == null || capacity == null || capacity <= 0) return null
        return ((used * 100) / capacity).roundToInt()
    }

    companion object {
        fun parse(json: String): ClusterMetrics? = runCatching {
            val c = JSONObject(json).getJSONObject("cluster")
            ClusterMetrics(
                node = c.optStringIfPresent("node"),
                ready = c.optBoolean("ready", false),
                podsTotal = c.optIntOrNull("pods_total"),
                podsRunning = c.optIntOrNull("pods_running"),
                k3sVersion = c.optStringIfPresent("k3s_version"),
                nodesTotal = c.optIntOrNull("nodes_total"),
                nodesReady = c.optIntOrNull("nodes_ready"),
                nodesReporting = c.optIntOrNull("nodes_reporting"),
                cpuCapacityCores = c.optDoubleOrNull("cpu_capacity_cores"),
                memCapacityKb = c.optLongOrNull("mem_capacity_kb"),
                cpuMeasuredCores = c.optDoubleOrNull("cpu_measured_cores"),
                memMeasuredKb = c.optLongOrNull("mem_measured_kb"),
                cpuUsedCores = c.optDoubleOrNull("cpu_used_cores"),
                memUsedKb = c.optLongOrNull("mem_used_kb"),
            )
        }.getOrNull()
    }
}

private fun JSONObject.optIntOrNull(key: String): Int? =
    if (has(key) && !isNull(key)) optInt(key) else null

private fun JSONObject.optLongOrNull(key: String): Long? =
    if (has(key) && !isNull(key)) optLong(key) else null

private fun JSONObject.optDoubleOrNull(key: String): Double? =
    if (has(key) && !isNull(key)) optDouble(key) else null

private fun JSONObject.optStringIfPresent(key: String): String? =
    if (has(key) && !isNull(key)) optString(key).ifEmpty { null } else null
