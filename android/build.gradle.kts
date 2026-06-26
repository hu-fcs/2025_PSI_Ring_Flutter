allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    // project.evaluationDependsOn(":app")
    afterEvaluate {
        if (hasProperty("android")) {
            extensions.configure<com.android.build.gradle.BaseExtension> {
                // compileSdkVersion が android-34 未満なら、強制的に android-34 に引き上げる
                val currentSdk = compileSdkVersion
                if (currentSdk != null && currentSdk.contains("android-")) {
                    val version = currentSdk.substringAfter("-").toIntOrNull()
                    if (version != null && version < 34) {
                        compileSdkVersion("android-34")
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
