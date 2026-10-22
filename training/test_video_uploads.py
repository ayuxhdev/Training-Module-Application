import hashlib
import json
import subprocess
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from django.core.exceptions import ValidationError
from django.core.files.uploadedfile import SimpleUploadedFile, TemporaryUploadedFile
from django.test import SimpleTestCase, override_settings

from .video_uploads import _probe_video_duration, video_upload_metadata


class VideoMetadataTests(SimpleTestCase):
    payload = b"\x00\x00\x00\x18ftypisom" + b"\x00" * 12 + b"test bytes" * 10000

    def upload(self, temporary=False, name="upload.mp4", content=None):
        content = self.payload if content is None else content
        if temporary:
            upload = TemporaryUploadedFile(name, "video/mp4", len(content), None)
            upload.write(content)
            upload.seek(0)
        else:
            upload = SimpleUploadedFile(name, content, "video/mp4")
        self.addCleanup(upload.close)
        return upload

    @override_settings(VIDEO_FFPROBE_PATH="trusted-ffprobe")
    def test_hash_duration_staging_command_and_cleanup_for_both_upload_types(self):
        for temporary in (False, True):
            with self.subTest(temporary=temporary):
                upload = self.upload(temporary, "user filename & command.mp4")
                upload.seek(7)
                paths = []
                def inspect(command, **kwargs):
                    path = Path(command[-1])
                    paths.append(path)
                    self.assertEqual(path.name, "video.mp4")
                    self.assertEqual(path.read_bytes(), self.payload)
                    self.assertEqual(command[0], "trusted-ffprobe")
                    self.assertEqual(command[command.index("-protocol_whitelist") + 1], "file")
                    self.assertEqual(command[command.index("-format_whitelist") + 1], "mov,matroska,webm")
                    self.assertEqual(command[command.index("-enable_drefs") + 1], "0")
                    self.assertEqual(command[command.index("-use_absolute_path") + 1], "0")
                    self.assertFalse(kwargs["shell"])
                    self.assertEqual(kwargs["timeout"], 15)
                    self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
                    return SimpleNamespace(stdout=json.dumps({"format": {"duration": "68.650667"}, "streams": [{"codec_type": "video"}]}))
                with patch("training.video_uploads.subprocess.run", side_effect=inspect):
                    checksum, duration = video_upload_metadata(upload)
                self.assertEqual(checksum, hashlib.sha256(self.payload).hexdigest())
                self.assertEqual(duration, 69)
                self.assertFalse(upload.closed)
                self.assertEqual(upload.tell(), 7)
                self.assertFalse(paths[0].parent.exists())

    def test_missing_empty_oversized_wrong_extension_and_bad_header_fail_before_probe(self):
        cases = [("empty.mp4", b"", 0), ("bad.exe", self.payload, len(self.payload)),
                 ("bad.mp4", b"not video", 9), ("large.mp4", self.payload, 2 * 1024**3 + 1),
                 ("unknown.mp4", self.payload, None)]
        with patch("training.video_uploads.subprocess.run") as probe:
            for name, content, size in cases:
                with self.subTest(name=name):
                    upload = self.upload(name=name, content=content)
                    upload.size = size
                    with self.assertRaises(ValidationError):
                        video_upload_metadata(upload)
                    self.assertFalse(upload.closed)
            probe.assert_not_called()

    def test_unreadable_and_incomplete_uploads_restore_stream_and_fail_closed(self):
        upload = self.upload()
        upload.seek(4)
        with patch.object(upload.file, "read", side_effect=OSError("private storage details")):
            with self.assertRaisesMessage(ValidationError, "could not be read or processed"):
                video_upload_metadata(upload)
        self.assertEqual(upload.tell(), 4)
        self.assertFalse(upload.closed)
        upload.size += 1
        with self.assertRaisesMessage(ValidationError, "could not be read completely"):
            video_upload_metadata(upload)
        self.assertEqual(upload.tell(), 4)

    def test_real_bytes_cannot_exceed_limit_using_false_size_metadata(self):
        upload = self.upload()
        upload.size = 24
        with patch("training.video_uploads.MAX_VIDEO_BYTES", 32):
            with self.assertRaisesMessage(ValidationError, "no larger than 2 GB"):
                video_upload_metadata(upload)
        self.assertFalse(upload.closed)

    def test_probe_failures_are_friendly_and_temporary_copies_are_removed(self):
        errors = [(FileNotFoundError("private executable path"), "processing is unavailable"),
                  (subprocess.TimeoutExpired("probe", 15), "took too long"),
                  (subprocess.CalledProcessError(1, "probe"), "could not be read")]
        for error, message in errors:
            with self.subTest(error=type(error).__name__):
                paths = []
                def fail(command, **kwargs):
                    paths.append(Path(command[-1]))
                    raise error
                upload = self.upload()
                with patch("training.video_uploads.subprocess.run", side_effect=fail):
                    with self.assertRaisesMessage(ValidationError, message):
                        video_upload_metadata(upload)
                self.assertFalse(paths[0].parent.exists())
                self.assertFalse(upload.closed)
                self.assertEqual(upload.tell(), 0)

    def test_unknown_invalid_and_non_video_probe_results_are_rejected(self):
        results = ["invalid JSON", "[]", '{"format": {}, "streams": []}']
        for duration in ("N/A", "NaN", "Infinity", "0", "-1", "4294967296"):
            results.append(json.dumps({"format": {"duration": duration}, "streams": [{"codec_type": "video"}]}))
        results.append(json.dumps({"format": {"duration": "10"}, "streams": [{"codec_type": "audio"}]}))
        for output in results:
            with self.subTest(output=output), patch("training.video_uploads.subprocess.run", return_value=SimpleNamespace(stdout=output)):
                with self.assertRaisesMessage(ValidationError, "could not determine"):
                    _probe_video_duration(Path("video.mp4"))

    def test_webm_does_not_receive_mov_only_options(self):
        with patch("training.video_uploads.subprocess.run", return_value=SimpleNamespace(stdout='{"format":{"duration":"1"},"streams":[{"codec_type":"video"}]}')) as probe:
            self.assertEqual(_probe_video_duration(Path("video.webm")), 1)
            self.assertNotIn("-enable_drefs", probe.call_args.args[0])
