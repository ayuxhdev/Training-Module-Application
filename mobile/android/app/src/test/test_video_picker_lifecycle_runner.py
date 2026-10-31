"""Offline Gradle-cache lookup regressions using temporary fixture files only."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "video_picker_runner", Path(__file__).with_name("run_video_picker_lifecycle_tests.py"),
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class CachedJarTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="picker-jar-test-")
        self.addCleanup(directory.cleanup)
        self.cache = Path(directory.name)
        self.version_dir = self.cache / "org.example" / "sample" / "1.0"

    def fixture(self, bucket, name="sample-1.0.jar", content=b"binary"):
        path = self.version_dir / bucket / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def resolve(self):
        return runner.jar(self.cache, "org.example", "sample", "1.0")

    def test_binary_only(self):
        binary = self.fixture("binary")
        self.assertEqual(self.resolve(), str(binary))

    def test_binary_with_sources_javadoc_and_other_classifiers(self):
        binary = self.fixture("binary")
        for classifier in ("sources", "javadoc", "linux-x64"):
            self.fixture(classifier, f"sample-1.0-{classifier}.jar", b"classifier")
        self.assertEqual(self.resolve(), str(binary))

    def test_sources_and_javadoc_without_binary_fail_clearly(self):
        self.fixture("sources", "sample-1.0-sources.jar")
        self.fixture("javadoc", "sample-1.0-javadoc.jar")
        with self.assertRaisesRegex(RuntimeError, r"Missing cached binary org\.example:sample:1\.0 .*sample-1\.0\.jar.*no downloads attempted"):
            self.resolve()

    def test_identical_duplicate_binaries_choose_sorted_path(self):
        self.fixture("zzz")
        first = self.fixture("aaa")
        self.assertEqual(self.resolve(), str(first))

    def test_conflicting_duplicate_binaries_are_rejected(self):
        self.fixture("aaa", content=b"first binary")
        self.fixture("zzz", content=b"different binary")
        with self.assertRaisesRegex(RuntimeError, "Conflicting cached binary copies.*no downloads attempted"):
            self.resolve()

    def test_directory_with_binary_filename_is_not_a_jar(self):
        (self.version_dir / "not-a-file" / "sample-1.0.jar").mkdir(parents=True)
        with self.assertRaisesRegex(RuntimeError, "Missing cached binary"):
            self.resolve()


if __name__ == "__main__":
    unittest.main()
