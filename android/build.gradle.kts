allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Some plugins (mp_audio_stream) still build against an old Android SDK and NDK, which the
// AndroidX libraries refuse; build them with the app's SDK and NDK instead.
subprojects {
    if (name != "app") {
        afterEvaluate {
            val lib = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            val app = rootProject.project(":app").extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            if (lib != null && app != null) {
                app.compileSdkVersion?.let { lib.compileSdkVersion(it) }
                app.ndkVersion?.let { lib.ndkVersion = it }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
