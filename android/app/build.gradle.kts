import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key lives in android/key.properties, which is not in the repo.
// Without it the build falls back to the debug key so a fresh checkout still
// produces an installable APK.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.yggnode.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.yggnode.app"
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    // One version code per ABI so the two APKs can be told apart and updated
    // independently: versionCode * 10 + slot.
    applicationVariants.all {
        val variantVersionName = versionName
        val variantVersionCode = versionCode
        outputs.all {
            val output = this as ApkVariantOutputImpl
            val abi = output.getFilter("ABI") ?: "universal"
            val abiSlot = when (abi) {
                "armeabi-v7a" -> 1
                "arm64-v8a" -> 2
                "x86_64" -> 3
                else -> 0
            }
            if (abiSlot > 0) {
                output.versionCodeOverride = variantVersionCode * 10 + abiSlot
            }
            output.outputFileName = "Y-Node-$variantVersionName-$abi.apk"
        }
    }
}

dependencies {
    implementation(files("libs/yggnode.aar"))
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.annotation:annotation:1.9.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
