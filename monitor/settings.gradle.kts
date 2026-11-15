pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        // libsu (root shell) is published on JitPack
        maven("https://jitpack.io")
    }
}

rootProject.name = "k3s-node-monitor"
include(":app")
