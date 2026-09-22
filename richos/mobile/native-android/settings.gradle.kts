// The native RichOS Android app (build plan richos-hq docs/plans/2026-09-22-native-apps-build-plan.md §3.3).
//   :core  plain Kotlin/JVM, no Android dependency: state, actions, ports, fixtures, scenarios.
//   :cli   the headless command line over the real :core (bin/randroid headless …).
//   :app   the Compose app; bin/randroid emu … builds, installs and drives it.
// The Part 0 rule: logic is proven on the Mac in seconds, with no emulator. See README.md.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "richos-native-android"

include(":core", ":cli", ":app")
