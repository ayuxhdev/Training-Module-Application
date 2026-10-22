"""Bounded metadata extraction for new administrator video uploads."""
import hashlib
import json
import subprocess
import tempfile
from decimal import Decimal, InvalidOperation, ROUND_CEILING
from pathlib import Path

from django.conf import settings
from django.core.exceptions import ValidationError

MAX_VIDEO_BYTES = 2 * 1024 * 1024 * 1024
VIDEO_EXTENSIONS = ("mp4", "webm", "mov")


def has_video_signature(header):
    return header.startswith(b"\x1a\x45\xdf\xa3") or (
        len(header) >= 8 and header[4:8] in (b"ftyp", b"moov", b"mdat", b"free", b"skip", b"wide")
    )


def _probe_video_duration(path):
    command = [settings.VIDEO_FFPROBE_PATH, "-v", "error", "-max_alloc", "67108864",
        "-protocol_whitelist", "file", "-format_whitelist", "mov,matroska,webm",
        "-probesize", "5000000", "-analyzeduration", "5000000", "-select_streams", "v:0",
        "-show_entries", "format=duration:stream=codec_type", "-of", "json"]
    if path.suffix.lower() in (".mp4", ".mov"):
        command.extend(["-enable_drefs", "0", "-use_absolute_path", "0"])
    command.extend(["-i", str(path)])
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, check=True, timeout=15, shell=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except OSError:
        raise ValidationError("Automatic video processing is unavailable. Contact your administrator and try again.") from None
    except subprocess.TimeoutExpired:
        raise ValidationError("Video inspection took too long. Try a different video export or contact your administrator.") from None
    except subprocess.CalledProcessError:
        raise ValidationError("This video could not be read. Export a new MP4, WebM or MOV file and try again.") from None
    try:
        metadata = json.loads(result.stdout)
        if not isinstance(metadata, dict):
            raise ValueError
        streams = metadata.get("streams", [])
        if not streams or not isinstance(streams[0], dict) or streams[0].get("codec_type") != "video":
            raise ValueError
        duration = Decimal(str(metadata["format"]["duration"]))
        if not duration.is_finite() or not 0 < duration <= 4294967295:
            raise ValueError
        # The existing model stores whole seconds; rounding up never overstates coverage.
        return int(duration.to_integral_value(rounding=ROUND_CEILING))
    except (KeyError, TypeError, ValueError, InvalidOperation):
        raise ValidationError("We could not determine this video's length. Export a new MP4, WebM or MOV file and try again.") from None


def video_upload_metadata(uploaded):
    """Hash and stage bytes in one pass; never close the request-owned stream."""
    extension = uploaded.name.rsplit(".", 1)[-1].lower()
    if extension not in VIDEO_EXTENSIONS:
        raise ValidationError("Choose an MP4, WebM or MOV video file.")
    try:
        size = uploaded.size
        if size is None:
            raise ValidationError("The upload size could not be read. Choose the file again.")
        if size <= 0:
            raise ValidationError("The selected file is empty. Choose a video file.")
        if size > MAX_VIDEO_BYTES:
            raise ValidationError("Choose a video no larger than 2 GB.")
        with tempfile.TemporaryDirectory(prefix="training-video-") as directory:
            path = Path(directory) / ("video." + extension)
            position = uploaded.tell()
            try:
                uploaded.seek(0)
                header = uploaded.read(12)
                if not has_video_signature(header):
                    raise ValidationError("The file does not contain a supported video. Choose an MP4, WebM or MOV video.")
                digest = hashlib.sha256()
                total = 0
                with path.open("xb") as staged:
                    chunk = header
                    while chunk:
                        total += len(chunk)
                        if total > MAX_VIDEO_BYTES:
                            raise ValidationError("Choose a video no larger than 2 GB.")
                        digest.update(chunk)
                        staged.write(chunk)
                        chunk = uploaded.read(64 * 1024)
                if total != size:
                    raise ValidationError("The upload could not be read completely. Choose the file again.")
            finally:
                uploaded.seek(position)
            duration = _probe_video_duration(path)
            return digest.hexdigest(), duration
    except (OSError, ValueError, AttributeError, TypeError):
        raise ValidationError("The upload could not be read or processed. Choose the file again or contact your administrator.") from None
