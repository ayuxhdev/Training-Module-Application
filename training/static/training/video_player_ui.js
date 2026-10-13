(function () {
  "use strict";
  const player = document.getElementById("video-player");
  if (!player) return;
  const video = document.getElementById("lesson-video");
  const play = document.getElementById("video-play-pause");
  const start = document.getElementById("start-video");
  const timeline = document.getElementById("video-timeline");
  const time = document.getElementById("video-time");
  const fullscreen = document.getElementById("video-fullscreen");
  const buffering = document.getElementById("video-buffering");
  let fade;
  let scrubbing = false;
  function reveal() {
    player.classList.add("is-controls-visible");
    window.clearTimeout(fade);
    if (!video.paused) fade = window.setTimeout(() => player.classList.remove("is-controls-visible"), 4000);
  }
  function format(seconds) {
    const total = Math.max(0, Math.floor(seconds || 0));
    return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
  }
  function render() {
    const duration = Number.isFinite(video.duration) ? video.duration : 0;
    timeline.max = String(duration || 1);
    if (!scrubbing) timeline.value = String(video.currentTime || 0);
    timeline.setAttribute("aria-valuetext", `${format(video.currentTime)} of ${format(duration)}`);
    time.textContent = `${format(video.currentTime)} / ${format(duration)}`;
    play.textContent = video.paused ? "Play" : "Pause";
    play.setAttribute("aria-label", video.paused ? "Play video" : "Pause video");
    if (start && Number(video.currentTime || 0) > 0) {
      start.textContent = "Resume video";
    }
    player.classList.toggle("is-playing", !video.paused);
  }
  function toggle() {
    if (!start.hidden && !start.disabled) start.click();
    else if (!play.disabled) {
      if (video.paused) video.play().catch(() => reveal());
      else video.pause();
    }
    reveal();
  }
  play.addEventListener("click", toggle);
  video.addEventListener("click", reveal);
  // Seeking still passes through playback.js's existing seek events and backend.
  timeline.addEventListener("input", () => { scrubbing = true; reveal(); });
  for (const event of ["pointerup", "pointercancel"]) {
    timeline.addEventListener(event, () => { scrubbing = false; });
  }
  timeline.addEventListener("blur", () => { scrubbing = false; render(); });
  timeline.addEventListener("change", () => {
    const position = Number(timeline.value);
    scrubbing = false;
    if (!timeline.disabled && Number.isFinite(position) && position >= 0 && position <= video.duration) {
      video.currentTime = position;
    }
    reveal();
  });
  for (const event of ["timeupdate", "loadedmetadata", "durationchange"]) video.addEventListener(event, render);
  for (const event of ["play", "pause", "ended"]) video.addEventListener(event, () => { render(); reveal(); });
  for (const event of ["waiting", "stalled", "loadstart"]) video.addEventListener(event, () => { buffering.hidden = false; reveal(); });
  for (const event of ["playing", "canplay", "pause", "ended", "error"]) video.addEventListener(event, () => { buffering.hidden = true; });
  for (const event of ["pointermove", "focusin"]) player.addEventListener(event, reveal);
  player.addEventListener("keydown", (event) => {
    reveal();
    // Leave native button activation and range keyboard semantics intact.
    if ((event.key === " " || event.key.toLowerCase() === "k") &&
        !["INPUT", "BUTTON", "A"].includes(event.target.tagName)) {
      event.preventDefault(); toggle();
    }
  });
  fullscreen.disabled = !player.requestFullscreen;
  fullscreen.addEventListener("click", async () => {
    try {
      if (document.fullscreenElement === player) await document.exitFullscreen();
      else await player.requestFullscreen();
    } catch (_) { reveal(); }
  });
  document.addEventListener("fullscreenchange", () => {
    const active = document.fullscreenElement === player;
    fullscreen.textContent = active ? "Exit fullscreen" : "Fullscreen";
    fullscreen.setAttribute("aria-label", active ? "Exit fullscreen" : "Enter fullscreen");
    fullscreen.setAttribute("aria-pressed", String(active));
    reveal();
  });
  window.addEventListener("pagehide", () => window.clearTimeout(fade));
  render();
})();
