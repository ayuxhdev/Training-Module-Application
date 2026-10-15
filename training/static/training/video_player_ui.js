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
  const startLabel = document.getElementById("video-start-label");
  const stage = player.querySelector(".video-stage");
  const deck = player.querySelector(".video-controls-deck");
  const hud = player.querySelector(".video-top-hud");
  let fade;
  let scrubbing = false;
  function measureLayout() {
    if (!stage || !deck || !startLabel) return;
    if (video.videoWidth > 0 && video.videoHeight > 0) {
      stage.style.setProperty("--video-aspect-ratio", `${video.videoWidth} / ${video.videoHeight}`);
    }
    const puckHeight = parseFloat(window.getComputedStyle(start).height);
    const labelStyle = window.getComputedStyle(startLabel);
    const labelHeight = parseFloat(labelStyle.lineHeight) + parseFloat(labelStyle.paddingTop) +
      parseFloat(labelStyle.paddingBottom) + 2 * parseFloat(labelStyle.borderTopWidth);
    const deckStyle = window.getComputedStyle(deck);
    const deckSpace = deck.getBoundingClientRect().height + parseFloat(deckStyle.marginBottom || 0);
    const hudSpace = hud ? hud.getBoundingClientRect().height + parseFloat(window.getComputedStyle(hud).top || 0) : 0;
    const labelGap = window.innerWidth <= 640 ? 6 : 12;
    const lowerClearance = deckSpace + puckHeight / 2 + labelGap + labelHeight + 12;
    const upperClearance = hudSpace + puckHeight / 2 + 12;
    // Reserve actual control dimensions on both sides of the centered puck.
    stage.style.setProperty("--video-min-height", `${Math.ceil(2 * Math.max(lowerClearance, upperClearance))}px`);
    stage.style.setProperty("--video-puck-half", `${puckHeight / 2}px`);
    stage.style.setProperty("--video-label-gap", `${labelGap}px`);
    const height = stage.getBoundingClientRect().height;
    if (document.fullscreenElement === player) {
      const center = Math.max(puckHeight / 2, (upperClearance + height - lowerClearance) / 2);
      stage.style.setProperty("--video-puck-top", `${center}px`);
    }
  }
  function reveal() {
    player.classList.add("is-controls-visible");
    window.clearTimeout(fade);
    if (!video.paused) fade = window.setTimeout(() => {
      if (!scrubbing && !player.matches(":focus-within")) player.classList.remove("is-controls-visible");
    }, 4000);
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
    const playText = video.paused ? "Play" : "Pause";
    // A timeline blur occurs between mouse-down and mouse-up on Pause.
    // Replacing even identical button content there can cancel native click.
    if (play.textContent !== playText) play.textContent = playText;
    play.setAttribute("aria-label", video.paused ? "Play video" : "Pause video");
    if (start && Number(video.currentTime || 0) > 0) {
      if (start.textContent !== "Resume video") start.textContent = "Resume video";
      start.setAttribute("aria-label", "Resume video");
    } else if (start) {
      if (start.textContent !== "Start video") start.textContent = "Start video";
      start.setAttribute("aria-label", "Start video");
    }
    if (startLabel) {
      startLabel.textContent = start.getAttribute("aria-label");
      startLabel.hidden = start.hidden;
    }
    player.classList.toggle("is-playing", !video.paused);
    if (start) {
      const isSessionActive = Boolean(start.hidden);
      player.classList.toggle("is-session-active", isSessionActive);
    }
    if (timeline.style) {
      const dur = duration > 0 ? duration : 1;
      const current = Number(timeline.value) || 0;
      const pct = Math.min(100, Math.max(0, (current / dur) * 100));
      const grad = `linear-gradient(to right, #ffffff 0%, #ffffff ${pct}%, rgba(255, 255, 255, 0.16) ${pct}%, rgba(255, 255, 255, 0.16) 100%)`;
      timeline.style.backgroundImage = grad;
    }
  }
  function toggle() {
    if (!start.hidden && !start.disabled) start.click();
    else if (!play.disabled) {
      if (video.paused) {
        video.play().catch(() => reveal());
      } else {
        video.pause();
      }
    }
    reveal();
  }
  play.addEventListener("click", toggle);
  video.addEventListener("click", reveal);
  // playback.js validates intent before a native seek can request media bytes.
  timeline.addEventListener("input", () => {
    scrubbing = true;
    if (timeline.style) {
      const dur = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : 1;
      const current = Number(timeline.value) || 0;
      const pct = Math.min(100, Math.max(0, (current / dur) * 100));
      const grad = `linear-gradient(to right, #ffffff 0%, #ffffff ${pct}%, rgba(255, 255, 255, 0.16) ${pct}%, rgba(255, 255, 255, 0.16) 100%)`;
      timeline.style.backgroundImage = grad;
    }
    reveal();
  });
  timeline.addEventListener("pointerup", () => { scrubbing = false; });
  timeline.addEventListener("pointercancel", () => { scrubbing = false; render(); });
  timeline.addEventListener("blur", () => { scrubbing = false; render(); });
  timeline.addEventListener("change", () => {
    const position = Number(timeline.value);
    scrubbing = false;
    if (!timeline.disabled && Number.isFinite(position) && position >= 0 && position <= video.duration) {
      video.dispatchEvent(new CustomEvent("video-seek-request", { detail: { position }, cancelable: true }));
    }
    render();
    reveal();
  });
  video.addEventListener("video-seek-feedback", render);
  for (const event of ["timeupdate", "loadedmetadata", "durationchange"]) video.addEventListener(event, render);
  for (const event of ["play", "pause", "ended"]) video.addEventListener(event, () => { render(); reveal(); });
  for (const event of ["waiting", "stalled", "loadstart"]) video.addEventListener(event, () => { buffering.hidden = false; reveal(); });
  for (const event of ["playing", "canplay", "pause", "ended", "error"]) video.addEventListener(event, () => { buffering.hidden = true; });
  for (const event of ["pointermove", "pointerdown", "focusin"]) player.addEventListener(event, reveal);
  player.addEventListener("keydown", (event) => {
    reveal();
    measureLayout();
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
  if (start && typeof MutationObserver !== "undefined") {
    try {
      const observer = new MutationObserver(() => render());
      observer.observe(start, { attributes: true, attributeFilter: ["hidden", "disabled"] });
    } catch (_) {}
  }
  window.addEventListener("pagehide", () => window.clearTimeout(fade));
  video.addEventListener("loadedmetadata", measureLayout);
  window.addEventListener("resize", measureLayout);
  if (typeof ResizeObserver !== "undefined" && stage && deck && startLabel) {
    const observer = new ResizeObserver(measureLayout);
    for (const element of [stage, deck, hud, startLabel]) if (element) observer.observe(element);
  }
  render();
  measureLayout();
})();
