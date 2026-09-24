// :core — application state, actions, ports, fixtures and scenarios as plain Kotlin on the
// JVM. No Android dependency, so its tests and the headless CLI run on the Mac in seconds
// with no emulator (Part 0; build plan §3.1 loop L1).
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

// No toolchain download: compile with the JDK Gradle runs on and emit Java 17 bytecode,
// which is what the Android app consumes.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies {
    api(libs.kotlinx.serialization.json)
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}

// `randroid test core --tests <X>` filters both JVM modules; the one without a match is not a failure.
tasks.test {
    filter.isFailOnNoMatchingTests = false
    // The phone protocol conformance corpus, read from the repository at test time, never a copy
    // (richos/mobile/conformance/README.md "Consuming it from Swift and Kotlin"). An input, so a
    // changed vector reruns the tests instead of reusing a cached pass.
    val vectors = rootProject.file("../conformance/vectors")
    inputs.dir(vectors).withPropertyName("conformanceVectors").withPathSensitivity(PathSensitivity.RELATIVE)
    systemProperty("richos.conformance", vectors.absolutePath)
}
