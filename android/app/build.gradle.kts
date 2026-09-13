plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val directSigningEnvironment = linkedMapOf(
    "GB_ANDROID_DIRECT_KEYSTORE" to System.getenv("GB_ANDROID_DIRECT_KEYSTORE"),
    "GB_ANDROID_DIRECT_KEYSTORE_PASSWORD" to System.getenv("GB_ANDROID_DIRECT_KEYSTORE_PASSWORD"),
    "GB_ANDROID_DIRECT_KEY_ALIAS" to System.getenv("GB_ANDROID_DIRECT_KEY_ALIAS"),
    "GB_ANDROID_DIRECT_KEY_PASSWORD" to System.getenv("GB_ANDROID_DIRECT_KEY_PASSWORD"),
)
val allowUnsignedDirect = System.getenv("GB_ANDROID_ALLOW_UNSIGNED") == "1"
val directSigningInputsComplete = directSigningEnvironment.values.all { !it.isNullOrBlank() }

android {
    namespace = "com.xopmc.galaxybridge"
    compileSdk = 37
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "com.xopmc.galaxybridge"
        minSdk = 31
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
    }


    signingConfigs {
        if (directSigningInputsComplete) {
            create("directRelease") {
                storeFile = file(directSigningEnvironment.getValue("GB_ANDROID_DIRECT_KEYSTORE")!!)
                storePassword = directSigningEnvironment.getValue("GB_ANDROID_DIRECT_KEYSTORE_PASSWORD")
                keyAlias = directSigningEnvironment.getValue("GB_ANDROID_DIRECT_KEY_ALIAS")
                keyPassword = directSigningEnvironment.getValue("GB_ANDROID_DIRECT_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        getByName("release") {
            isDebuggable = false
        }
    }

    flavorDimensions += "distribution"
    productFlavors {
        create("internal") {
            dimension = "distribution"
            applicationIdSuffix = ".internal"
            versionNameSuffix = "-internal"
            buildConfigField("String", "DISTRIBUTION", "\"internal\"")
        }
        create("direct") {
            dimension = "distribution"
            versionNameSuffix = "-direct"
            buildConfigField("String", "DISTRIBUTION", "\"direct\"")
            if (directSigningInputsComplete) {
                signingConfig = signingConfigs.getByName("directRelease")
            }
        }
        create("play") {
            dimension = "distribution"
            buildConfigField("String", "DISTRIBUTION", "\"play\"")
        }
    }

    sourceSets.named("direct") {
        manifest.srcFile("src/direct/AndroidManifest.xml")
        java.directories.add("src/internal/java")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}")
    }
}

val validateDirectReleaseSigning by tasks.registering {
    group = "verification"
    description = "Fails unless all externally supplied direct-release signing inputs are present."
    // Resolve only non-secret validation values during configuration. The task
    // action must not capture this Gradle script or Project for cache storage.
    val missing = directSigningEnvironment.filterValues { it.isNullOrBlank() }.keys.toList()
    val unsignedBuild = allowUnsignedDirect && directSigningEnvironment.values.all { it.isNullOrBlank() }
    val keystorePath = directSigningEnvironment["GB_ANDROID_DIRECT_KEYSTORE"]
        ?.takeIf { it.isNotBlank() }?.let { file(it) }
    doLast {
        if (unsignedBuild) return@doLast
        check(missing.isEmpty()) {
            "Direct release signing is not configured. Set ${missing.joinToString()} in the environment; " +
                "release builds never fall back to the debug key."
        }
        check(keystorePath?.isFile == true) {
            "GB_ANDROID_DIRECT_KEYSTORE must name an existing keystore file: $keystorePath"
        }
    }
}

tasks.configureEach {
    if (name.matches(Regex("^(assembleDirectRelease|bundleDirectRelease|packageDirectRelease(?:Bundle|UniversalApk)?)$"))) {
        dependsOn(validateDirectReleaseSigning)
    }
}

dependencies {
    implementation(project(":companion-core"))
    implementation(project(":companion-protocol"))

    val composeBom = platform("androidx.compose:compose-bom:2026.08.00")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.camera:camera-core:1.6.2")
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-view:1.6.2")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    // ZXing core runs entirely in this process. Do not use ML Kit here: its
    // runtime brings Google DataTransport/diagnostic collection into a product
    // whose privacy contract explicitly forbids telemetry.
    implementation("com.google.zxing:core:3.5.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation("junit:junit:4.13.2")
}
