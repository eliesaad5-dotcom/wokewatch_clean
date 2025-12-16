plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load signing credentials from an untracked key.properties file
// key.properties (DO NOT COMMIT) should contain:
// storeFile=C:\\path\\to\\wokewatch-release.jks
// storePassword=your-store-password
// keyAlias=wokewatch
// keyPassword=your-key-password
import java.util.Properties
import java.io.FileInputStream

val keystoreProps = Properties()
val keystorePropsFile = rootProject.file("key.properties")
if (keystorePropsFile.exists()) {
    FileInputStream(keystorePropsFile).use { keystoreProps.load(it) }
}

// Load local.properties to allow specifying ADMOB_APP_ID there
val localProps = Properties()
val localPropsFile = rootProject.file("local.properties")
if (localPropsFile.exists()) {
    FileInputStream(localPropsFile).use { localProps.load(it) }
}

android {
    namespace = "com.wokewatch.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // Application ID used by Play Store and on-device package manager
        applicationId = "com.wokewatch.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Allow setting AdMob App ID via project property ADMOB_APP_ID or local.properties ADMOB_APP_ID; default to Google's test ID
        val admobId = (project.findProperty("ADMOB_APP_ID") as String?)
            ?: (localProps.getProperty("ADMOB_APP_ID"))
            ?: "ca-app-pub-3940256099942544~3347511713"
        manifestPlaceholders["ADMOB_APP_ID"] = admobId
    }

    signingConfigs {
        create("release") {
            val storeFilePath = keystoreProps.getProperty("storeFile")
            if (!storeFilePath.isNullOrBlank()) {
                storeFile = file(storeFilePath)
            }
            storePassword = keystoreProps.getProperty("storePassword")
            keyAlias = keystoreProps.getProperty("keyAlias")
            keyPassword = keystoreProps.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            // Use release signing config when key.properties is provided
            if (keystoreProps.isNotEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Fallback to debug signing to allow local runs if not configured
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
