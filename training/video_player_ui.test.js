const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "static/training/video_player_ui.js"), "utf8");

function ui() {
  class Element {
    constructor() { this.listeners = {}; this.attributes = {}; this.disabled = false; this.hidden = false; }
    addEventListener(event, callback) { (this.listeners[event] ??= []).push(callback); }
    emit(event, data = {}) { for (const callback of this.listeners[event] ?? []) callback(data); }
    click() { if (!this.disabled) this.emit("click"); }
    setAttribute(name, value) { this.attributes[name] = value; }
  }
  const elements = {};
  for (const id of ["video-player", "lesson-video", "video-play-pause", "start-video",
    "video-timeline", "video-time", "video-fullscreen", "video-buffering"]) elements[id] = new Element();
  const player = elements["video-player"], video = elements["lesson-video"];
  const classes = new Set();
  player.classList = { add: (v) => classes.add(v), remove: (v) => classes.delete(v),
    toggle: (v, enabled) => enabled ? classes.add(v) : classes.delete(v) };
  const document = new Element();
  document.getElementById = (id) => elements[id];
  player.requestFullscreen = async () => { document.fullscreenElement = player; document.emit("fullscreenchange"); };
  document.exitFullscreen = async () => { document.fullscreenElement = null; document.emit("fullscreenchange"); };
  video.duration = 100; video.currentTime = 0; video.paused = true;
  video.play = async () => { video.paused = false; video.emit("play"); };
  video.pause = () => { video.paused = true; video.emit("pause"); };
  let fade;
  const window = new Element();
  window.setTimeout = (callback) => { fade = callback; return 1; };
  window.clearTimeout = () => { fade = null; };
  vm.runInNewContext(source, { document, window });
  return { elements, player, video, document, window, classes, fade: () => fade?.() };
}

test("faded controls ignore pointers while visible and keyboard-focused controls stay interactive", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  assert.match(css, /\.video-player-controls\s*\{[^}]*pointer-events:\s*auto;/);
  assert.match(css, /\.midnight-player\.is-playing:not\(\.is-controls-visible\):not\(:focus-within\) \.video-player-controls\s*\{[^}]*opacity:\s*0;[^}]*pointer-events:\s*none;/);
  const { player, elements, video, classes, fade } = ui();
  elements["start-video"].hidden = true;
  elements["video-play-pause"].click();
  fade(); assert.equal(classes.has("is-controls-visible"), false);
  player.emit("pointermove"); assert.equal(classes.has("is-controls-visible"), true);
  fade(); player.emit("focusin"); assert.equal(classes.has("is-controls-visible"), true);
  assert.equal(video.paused, false);
});

test("reduced-motion styles disable button and controls transitions", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  assert.match(css, /@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{\s*\.midnight-player button,\s*\.video-player-controls\s*\{\s*transition:\s*none;/);
});

test("visual controls cannot start disabled media or manufacture recorded coverage", async () => {
  const { elements, video } = ui();
  const play = elements["video-play-pause"], start = elements["start-video"];
  play.disabled = true; start.disabled = true;
  play.click(); assert.equal(video.paused, true);
  let starts = 0; start.disabled = false; start.addEventListener("click", () => starts++);
  play.disabled = false; play.click(); assert.equal(starts, 1); assert.equal(video.paused, true);
  start.hidden = true; play.click(); assert.equal(video.paused, false);
  play.click(); assert.equal(video.paused, true);
  video.currentTime = 72; video.emit("timeupdate");
  assert.equal(elements["video-time"].textContent, "1:12 / 1:40");
  assert.equal(elements["video-timeline"].attributes["aria-valuetext"], "1:12 of 1:40");
  assert.equal(elements["lesson-progress"], undefined); // UI never accesses credit/completion controls.
});

test("timeline uses native seeking and rejects disabled or malformed input", () => {
  const { elements, video } = ui();
  const timeline = elements["video-timeline"];
  timeline.disabled = true; timeline.value = "80"; timeline.emit("change");
  assert.equal(video.currentTime, 0);
  timeline.disabled = false;
  for (const value of ["NaN", "-1", "101"]) { timeline.value = value; timeline.emit("change"); assert.equal(video.currentTime, 0); }
  timeline.value = "20"; timeline.emit("change"); assert.equal(video.currentTime, 20);
  timeline.value = "40"; timeline.emit("input");
  video.currentTime = 21; video.emit("timeupdate");
  assert.equal(timeline.value, "40"); // Playback ticks cannot move the thumb during a drag.
  timeline.emit("change"); assert.equal(video.currentTime, 40);
});

test("pointer release without change restores timeline updates and preserves pending seeks", () => {
  const { elements, video } = ui();
  const timeline = elements["video-timeline"];
  video.currentTime = 20; video.emit("timeupdate");
  timeline.emit("input"); timeline.emit("pointerup");
  assert.equal(video.currentTime, 20);
  video.currentTime = 21; video.emit("timeupdate");
  assert.equal(timeline.value, "21");
  timeline.value = "40"; timeline.emit("input"); timeline.emit("pointerup");
  assert.equal(timeline.value, "40");
  assert.equal(video.currentTime, 21);
  timeline.emit("change"); assert.equal(video.currentTime, 40);
});

test("pointer cancellation restores timeline updates without seeking", () => {
  const { elements, video } = ui();
  const timeline = elements["video-timeline"];
  video.currentTime = 20; video.emit("timeupdate");
  timeline.value = "40"; timeline.emit("input"); timeline.emit("pointercancel");
  assert.equal(video.currentTime, 20);
  video.currentTime = 21; video.emit("timeupdate");
  assert.equal(timeline.value, "21");
});

test("keyboard preserves range/button semantics and reveals faded controls", () => {
  const { player, elements, video, classes, fade } = ui();
  elements["start-video"].hidden = true;
  const key = (tag) => ({ key: " ", target: { tagName: tag }, preventDefault() { this.prevented = true; } });
  const rangeKey = key("INPUT"); player.emit("keydown", rangeKey);
  assert.equal(rangeKey.prevented, undefined); assert.equal(video.paused, true);
  const videoKey = key("VIDEO"); player.emit("keydown", videoKey);
  assert.equal(videoKey.prevented, true); assert.equal(video.paused, false);
  fade(); assert.equal(classes.has("is-controls-visible"), false);
  player.emit("focusin"); assert.equal(classes.has("is-controls-visible"), true);
});

test("buffering/fullscreen states are accessible and exit clears fade timer", async () => {
  const { elements, video, document, window, classes, fade } = ui();
  video.emit("waiting"); assert.equal(elements["video-buffering"].hidden, false);
  video.emit("playing"); assert.equal(elements["video-buffering"].hidden, true);
  const fullscreen = elements["video-fullscreen"];
  fullscreen.click(); await Promise.resolve();
  assert.equal(fullscreen.attributes["aria-pressed"], "true");
  assert.equal(fullscreen.attributes["aria-label"], "Exit fullscreen");
  fullscreen.click(); await Promise.resolve(); assert.equal(document.fullscreenElement, null);
  elements["start-video"].hidden = true; elements["video-play-pause"].click();
  window.emit("pagehide"); fade(); assert.equal(classes.has("is-controls-visible"), true);
});
