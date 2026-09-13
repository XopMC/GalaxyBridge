plugins {
    id("com.android.library")
}

android {
    namespace = "com.xopmc.galaxybridge.protocol"
    compileSdk = 37

    defaultConfig {
        minSdk = 31
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("test") {
            resources.directories.add(
                rootProject.projectDir.resolve("../protocol/fixtures").absolutePath
            )
        }
    }
}

dependencies {
    api("com.google.protobuf:protobuf-javalite:4.36.0")
    testImplementation("junit:junit:4.13.2")
}
