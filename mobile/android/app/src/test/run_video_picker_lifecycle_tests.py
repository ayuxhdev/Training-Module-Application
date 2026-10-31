"""Run actual picker lifecycle code on the JVM using cached Kotlin tooling.

No Android device, Gradle daemon, dependency download or project changes needed.
The Android-free class is extracted verbatim from MainActivity.kt into a temporary
compilation directory. Assertions run against that production implementation.
"""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def jar(cache, group, artifact, version):
    """Resolve only binary JARs; identical cache duplicates are safe to reuse."""
    filename = f"{artifact}-{version}.jar"
    matches = sorted(
        path for path in (cache / group / artifact / version).glob(f"*/{filename}")
        if path.is_file()
    )
    if not matches:
        raise RuntimeError(f"Missing cached binary {group}:{artifact}:{version} ({filename}); no downloads attempted")
    if len(matches) > 1:
        digests = set()
        for path in matches:
            with path.open("rb") as stream:
                digests.add(hashlib.file_digest(stream, "sha256").digest())
        if len(digests) != 1:
            raise RuntimeError(f"Conflicting cached binary copies for {group}:{artifact}:{version}; no downloads attempted")
    return str(matches[0])


def main():
    test_root = Path(__file__).resolve().parent
    kotlin_path = Path("kotlin/com/gardensneed/training")
    source = (test_root.parent / "main" / kotlin_path / "MainActivity.kt").read_text()
    lifecycle = source[source.index("internal class VideoPickerCopyLifecycle"):]
    imports = "\n".join(line for line in source.splitlines() if line.startswith("import java."))
    production = "package com.gardensneed.training\n" + imports + "\n" + lifecycle
    cache = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle")) / "caches/modules-2/files-2.1"

    dependencies = [
        jar(cache, "org.jetbrains.kotlin", artifact, version)
        for artifact, version in (
            ("kotlin-compiler-embeddable", "2.4.0"),
            ("kotlin-build-tools-api", "2.4.0"),
            ("kotlin-stdlib", "2.4.0"),
            ("kotlin-script-runtime", "2.4.0"),
            ("kotlin-reflect", "1.6.10"),
            ("kotlin-daemon-embeddable", "2.4.0"),
        )
    ]
    dependencies += [jar(cache, "org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.8.0")]
    dependencies += [jar(cache, "org.jetbrains", "annotations", "13.0")]
    java = shutil.which("java")
    if not java and os.environ.get("JAVA_HOME"):
        candidate = Path(os.environ["JAVA_HOME"]) / "bin" / ("java.exe" if os.name == "nt" else "java")
        if candidate.is_file():
            java = str(candidate)
    if not java:
        raise RuntimeError("Java is unavailable")
    classpath = os.pathsep.join(dependencies)
    with tempfile.TemporaryDirectory(prefix="video-picker-jvm-") as directory:
        work = Path(directory)
        implementation = work / "VideoPickerCopyLifecycle.kt"
        implementation.write_text(production, encoding="utf-8")
        classes = work / "classes"
        subprocess.run([
            java, "-Xmx512m", "-cp", classpath, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
            "-no-stdlib", "-no-reflect", "-classpath", classpath, "-jvm-target", "17",
            "-d", str(classes), str(implementation), str(test_root / kotlin_path / "VideoPickerCopyLifecycleTest.kt"),
        ], check=True, timeout=120)
        subprocess.run([
            java, "-Xmx256m", "-cp", str(classes) + os.pathsep + classpath,
            "com.gardensneed.training.VideoPickerCopyLifecycleTestKt",
        ], check=True, timeout=30)


if __name__ == "__main__":
    main()
