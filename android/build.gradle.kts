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
    // Fix: AGP 8.0+ requires namespace; ffmpeg_kit plugins don't declare one.
    // Register before evaluationDependsOn triggers evaluation below.
    project.afterEvaluate {
        extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.run {
            if (namespace == null) namespace = group.toString()
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
