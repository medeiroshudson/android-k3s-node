package dev.hmedeiros.k3smonitor.data

import org.json.JSONObject

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
    val memUsedPct: Int?
        get() {
            val total = memTotalKb ?: return null
            val avail = memAvailKb ?: return null
            if (total <= 0) return null
            return (((total - avail) * 100) / total).toInt()
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
                batteryStatus = h.optString("battery_status", null),
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
    val ramUsedKb: Long? = null,
    val ramLimitKb: Long? = null,
    val diskTotalKb: Long? = null,
    val diskFreeKb: Long? = null,
    val services: Map<String, String> = emptyMap(),
) {
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
                ramUsedKb = c.optLongOrNull("ram_used_kb"),
                ramLimitKb = c.optLongOrNull("ram_limit_kb"),
                diskTotalKb = c.optLongOrNull("disk_total_kb"),
                diskFreeKb = c.optLongOrNull("disk_free_kb"),
                services = services,
            )
        }.getOrNull()
    }
}

data class ClusterMetrics(
    val node: String? = null,
    val ready: Boolean = false,
    val podsTotal: Int? = null,
    val podsRunning: Int? = null,
    val k3sVersion: String? = null,
) {
    companion object {
        fun parse(json: String): ClusterMetrics? = runCatching {
            val c = JSONObject(json).getJSONObject("cluster")
            ClusterMetrics(
                node = c.optString("node", null),
                ready = c.optBoolean("ready", false),
                podsTotal = c.optIntOrNull("pods_total"),
                podsRunning = c.optIntOrNull("pods_running"),
                k3sVersion = c.optString("k3s_version", null),
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
