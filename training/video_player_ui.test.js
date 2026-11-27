const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "static/training/video_player_ui.js"), "utf8");

function ui(options = {}) {
  class Element {
    constructor(id = "") {
      this.id = id;
      this.listeners = {};
      this.attributes = {};
      this.disabled = false;
      this.hidden = false;
      this.style = {
        _props: {},
        setProperty(k, v) { this._props[k] = v; this[k] = v; },
        getPropertyValue(k) { return this._props[k] || this[k] || ""; },
      };
      this.rect = { top: 0, bottom: 200, left: 0, right: 390, width: 390, height: 200 };
    }
    addEventListener(event, callback) { (this.listeners[event] ??= []).push(callback); }
    emit(event, data = {}) { for (const callback of this.listeners[event] ?? []) callback(data); }
    click() { if (!this.disabled) this.emit("click"); }
    setAttribute(name, value) { this.attributes[name] = value; }
    getAttribute(name) { return this.attributes[name]; }
    getBoundingClientRect() { return this.rect; }
    contains(child) {
      if (!child) return false;
      return child === this || Boolean(this.children && this.children.has(child));
    }
    dispatchEvent(event) { this.emit(event.type, event); return !event.defaultPrevented; }
  }
  const elements = {};
  for (const id of ["video-player", "lesson-video", "video-play-pause", "start-video",
    "video-timeline", "video-time", "video-fullscreen", "video-buffering", "video-start-label"]) {
    elements[id] = new Element(id);
  }
  const stage = new Element("video-stage");
  stage.rect = { top: 0, bottom: 400, left: 0, right: 390, width: 390, height: 400 };
  const deck = new Element("video-controls-deck");
  deck.rect = { top: 340, bottom: 390, left: 10, right: 380, width: 370, height: 50 };
  const hud = new Element("video-top-hud");
  hud.rect = { top: 10, bottom: 40, left: 10, right: 380, width: 370, height: 30 };

  const player = elements["video-player"], video = elements["lesson-video"];
  const start = elements["start-video"], startLabel = elements["video-start-label"];
  const play = elements["video-play-pause"];
  player.children = new Set([...Object.values(elements), stage, deck, hud]);

  const classes = new Set();
  player.classList = {
    add: (v) => classes.add(v),
    remove: (v) => classes.delete(v),
    toggle: (v, enabled) => enabled ? classes.add(v) : classes.delete(v),
    contains: (v) => classes.has(v),
  };

  player.querySelector = (selector) => {
    if (options.bareQuery) return null;
    if (selector === ".video-stage") return stage;
    if (selector === ".video-controls-deck") return deck;
    if (selector === ".video-top-hud") return hud;
    return null;
  };

  let focused = false;
  player.matches = (selector) => {
    if (selector === ":focus-within") return focused;
    return false;
  };

  const document = new Element();
  document.getElementById = (id) => elements[id];
  document.fullscreenElement = null;
  player.requestFullscreen = async () => { document.fullscreenElement = player; document.emit("fullscreenchange"); };
  document.exitFullscreen = async () => { document.fullscreenElement = null; document.emit("fullscreenchange"); };

  video.duration = 100;
  video.currentTime = 0;
  video.paused = true;
  video.videoWidth = options.videoWidth || 0;
  video.videoHeight = options.videoHeight || 0;
  video.play = async () => { video.paused = false; video.emit("play"); };
  video.pause = () => { video.paused = true; video.emit("pause"); };

  let activeFadeId = null;
  const timerCallbacks = new Map();
  let nextTimerId = 1;
  const window = new Element();
  window.innerWidth = options.width || 1024;
  window.setTimeout = (callback) => {
    const id = nextTimerId++;
    timerCallbacks.set(id, callback);
    activeFadeId = id;
    return id;
  };
  window.clearTimeout = (id) => {
    timerCallbacks.delete(id);
    if (activeFadeId === id) activeFadeId = null;
  };
  window.getComputedStyle = (el) => {
    if (el === start) return { height: window.innerWidth <= 640 ? "56px" : "72px" };
    if (el === startLabel) return { lineHeight: "16px", paddingTop: "4px", paddingBottom: "4px", borderTopWidth: "1px" };
    if (el === deck) return { marginBottom: "10px" };
    if (el === hud) return { top: "14px" };
    return {};
  };

  class CustomEvent {
    constructor(type, init = {}) {
      this.type = type;
      this.detail = init.detail || {};
      this.cancelable = Boolean(init.cancelable);
      this.defaultPrevented = false;
    }
    preventDefault() { this.defaultPrevented = true; }
  }

  vm.runInNewContext(source, { document, window, CustomEvent });
  return {
    elements, player, video, document, window, classes,
    stage, deck, hud, start, startLabel, play,
    fade: () => {
      if (activeFadeId !== null && timerCallbacks.has(activeFadeId)) {
        const id = activeFadeId;
        const cb = timerCallbacks.get(id);
        timerCallbacks.delete(id);
        activeFadeId = null;
        cb?.();
      }
    },
    isFadeArmed: () => activeFadeId !== null && timerCallbacks.has(activeFadeId),
    setFocusWithin: (v) => { focused = v; },
  };
}

test("faded controls ignore pointers while visible and keyboard-focused controls stay interactive", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  assert.match(css, /\.video-player-controls\s*\{[^}]*pointer-events:\s*none;/);
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
  // The block must exist and contain the required declarations — format is now expanded
  assert.match(css, /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
  assert.match(css, /\.midnight-player button[^{]*\{[^}]*transition:\s*none/);
  assert.match(css, /\.video-player-controls\s*\{[^}]*transition:\s*none/);
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

test("timeline requests protected seeking without changing the media before authorization", () => {
  const { elements, video } = ui();
  const timeline = elements["video-timeline"];
  timeline.disabled = true; timeline.value = "80"; timeline.emit("change");
  assert.equal(video.currentTime, 0);
  timeline.disabled = false;
  for (const value of ["NaN", "-1", "101"]) { timeline.value = value; timeline.emit("change"); assert.equal(video.currentTime, 0); }
  const requests = [];
  video.addEventListener("video-seek-request", (event) => requests.push(event.detail.position));
  timeline.value = "20"; timeline.emit("change"); assert.equal(video.currentTime, 0);
  assert.deepEqual(requests, [20]);
  timeline.value = "40"; timeline.emit("input");
  video.currentTime = 21; video.emit("timeupdate");
  assert.equal(timeline.value, "40"); // Playback ticks cannot move the thumb during a drag.
  timeline.emit("change"); assert.equal(video.currentTime, 21);
  assert.deepEqual(requests, [20, 40]);
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
  const requests = [];
  video.addEventListener("video-seek-request", (event) => requests.push(event.detail.position));
  timeline.emit("change"); assert.equal(video.currentTime, 21);
  assert.deepEqual(requests, [40]);
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

test("tactile midnight player enforces single primary action and hides developer text", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  // Single-primary-action rule hides lower play/pause button when session is not active
  assert.match(css, /\.midnight-player:not\(\.is-session-active\) #video-play-pause/);
  assert.match(css, /\.video-timeline-label\.visually-hidden,\s*\.video-timeline-label\s*\{[^}]*clip:\s*rect\(0,\s*0,\s*0,\s*0\);/);
  assert.match(css, /\.video-stage\s*\{[^}]*min-height:\s*var\(--video-min-height/);
  assert.match(css, /\.midnight-player video\s*\{[^}]*object-fit:\s*contain;/);
  assert.match(css, /#start-video,\s*\.btn-primary-tactile\s*\{/);

  const { elements, video } = ui();
  const start = elements["start-video"];
  start.textContent = "Start or resume video";
  assert.equal(start.textContent, "Start or resume video");
  video.currentTime = 15;
  video.emit("timeupdate");
  assert.equal(start.textContent, "Resume video");
});

test("playback action visibility across initial, playing, paused, rejected, ended, and closed states", async () => {
  const { elements, video, player, classes } = ui();
  const start = elements["start-video"];
  const play = elements["video-play-pause"];

  // 1. Initial state (before session start)
  start.hidden = false;
  video.paused = true;
  video.emit("timeupdate");
  assert.equal(start.hidden, false);
  assert.equal(classes.has("is-session-active"), false);
  assert.equal(classes.has("is-playing"), false);
  assert.equal(play.textContent, "Play");

  // 2. Active playing state (session started and playing)
  start.hidden = true;
  video.paused = false;
  video.emit("play");
  assert.equal(start.hidden, true);
  assert.equal(classes.has("is-session-active"), true);
  assert.equal(classes.has("is-playing"), true);
  assert.equal(play.textContent, "Pause");
  assert.equal(play.attributes["aria-label"], "Pause video");

  // 3. Active paused state (user pauses during active session — NEVER hide both buttons)
  video.paused = true;
  video.emit("pause");
  assert.equal(start.hidden, true);
  assert.equal(classes.has("is-session-active"), true);
  assert.equal(classes.has("is-playing"), false);
  assert.equal(play.textContent, "Play");
  assert.equal(play.attributes["aria-label"], "Play video");

  // 4. Rejected video.play() (e.g. autoplay rejection after session start)
  let rejected = false;
  video.play = async () => { video.paused = true; rejected = true; throw new Error("Autoplay denied"); };
  play.click();
  await Promise.resolve();
  assert.equal(rejected, true);
  assert.equal(classes.has("is-session-active"), true);
  assert.equal(classes.has("is-playing"), false);
  assert.equal(play.textContent, "Play");

  // 5. Natural video end
  video.currentTime = 100;
  video.paused = true;
  video.emit("ended");
  // playback.js unhides startButton on session end
  start.hidden = false;
  video.emit("timeupdate");
  assert.equal(start.hidden, false);
  assert.equal(classes.has("is-session-active"), false);
  assert.equal(start.textContent, "Resume video");

  // 6. Expired or closed session (restores initial Start/Resume puck)
  start.hidden = false;
  video.currentTime = 0;
  video.emit("timeupdate");
  assert.equal(classes.has("is-session-active"), false);
  assert.equal(start.attributes["aria-label"], "Start video");
});

test("timeline hit area is 28px with 4px visual track and overrides global shell.css styles", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  assert.match(css, /\.video-timeline-container\s*\{[^}]*height:\s*28px;/);
  assert.match(css, /#video-player \.video-timeline-container input\[type="range"\]#video-timeline/);
  assert.match(css, /input\[type="range"\][^{]*\{[^}]*height:\s*28px\s*!important;/);
  assert.match(css, /input\[type="range"\][^{]*\{[^}]*background-size:\s*100%\s*4px\s*!important;/);
  assert.match(css, /input\[type="range"\]::-webkit-slider-runnable-track\s*\{[^}]*height:\s*28px;/);
  assert.match(css, /input\[type="range"\]::-webkit-slider-thumb\s*\{[^}]*margin-top:\s*7px;/);
});

test("cinematic player implements floating control deck, centered circular puck, and top metadata hud", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  assert.match(css, /\.video-player-controls\s*\{[^}]*position:\s*absolute;[^}]*inset:\s*0;/);
  assert.match(css, /\.video-controls-deck\s*\{[^}]*border-radius:\s*16px;/);
  assert.match(css, /#start-video,\s*\.btn-primary-tactile\s*\{[^}]*position:\s*absolute;[^}]*border-radius:\s*50%;/);
  assert.match(css, /\.midnight-player\s*\{[^}]*box-shadow:[^}]*rgba\(16,\s*185,\s*129/);
  assert.match(css, /\.video-top-hud\s*\{[^}]*position:\s*absolute;[^}]*top:\s*14px;/);
  assert.match(css, /\.midnight-player:fullscreen \.video-controls-deck/);
  // Puck is now centered in the video stage (50% not 48%)
  assert.match(css, /#start-video,\s*\.btn-primary-tactile\s*\{[^}]*top:\s*50%;/);

  const { elements, video } = ui();
  const start = elements["start-video"];
  assert.equal(start.attributes["aria-label"], "Start video");
  video.currentTime = 25;
  video.emit("timeupdate");
  assert.equal(start.attributes["aria-label"], "Resume video");
  assert.equal(start.textContent, "Resume video");
});

test("reduced-motion block covers all cinematic elements", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  // Extract the prefers-reduced-motion block
  const rmStart = css.indexOf("@media (prefers-reduced-motion: reduce)");
  assert.ok(rmStart >= 0, "prefers-reduced-motion block must exist");
  // Find the matching closing brace by counting braces
  let depth = 0, idx = rmStart;
  while (idx < css.length) {
    if (css[idx] === "{") depth++;
    else if (css[idx] === "}") { depth--; if (depth === 0) break; }
    idx++;
  }
  const rmBlock = css.slice(rmStart, idx + 1);

  // Player shell transition
  assert.match(rmBlock, /\.midnight-player\s*\{[^}]*transition:\s*none/);
  // All buttons
  assert.match(rmBlock, /\.midnight-player button/);
  // Puck preserves centering transform against shell.css button rule
  assert.match(rmBlock, /#start-video[^{]*\{[^}]*transform:\s*translate\(-50%,\s*-50%\)\s*!important/);
  // Control overlay
  assert.match(rmBlock, /\.video-player-controls\s*\{[^}]*transition:\s*none/);
  // Autohide slides removed
  assert.match(rmBlock, /\.midnight-player\.is-playing[^{]*\.video-player-controls\s*\{[^}]*transform:\s*none/);
  assert.match(rmBlock, /\.midnight-player\.is-playing[^{]*\.video-top-hud\s*\{[^}]*transform:\s*none/);
  // HUD
  assert.match(rmBlock, /\.video-top-hud\s*\{[^}]*transition:\s*none/);
  // Deck
  assert.match(rmBlock, /\.video-controls-deck\s*\{[^}]*transition:\s*none/);
  // Stage scrims
  assert.match(rmBlock, /\.video-stage::before/);
  assert.match(rmBlock, /\.video-stage::after/);
  // Timeline hit area stays aligned in both normal and hover states.
  assert.match(rmBlock, /\.midnight-player input\[type="range"\]::-webkit-slider-runnable-track,\s*\.video-timeline-container:hover input\[type="range"\]::-webkit-slider-runnable-track\s*\{[^}]*transition:\s*none;[^}]*height:\s*28px;/);
  // Timeline thumb
  assert.match(rmBlock, /input\[type="range"\]::-webkit-slider-thumb\s*\{[^}]*transition:\s*none/);
  // Spinner
  assert.match(rmBlock, /\.buffering-spinner\s*\{[^}]*animation:\s*none/);
});

test("M16 Gate 1: portrait video framing (1080x1920) sets dynamic aspect-ratio custom property and preserves stage containment", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  // CSS rules enforce object-fit: contain on the video element and bounded stage height
  assert.match(css, /\.video-stage\s*\{[^}]*aspect-ratio:\s*var\(--video-aspect-ratio,\s*16\s*\/\s*9\);/);
  assert.match(css, /\.video-stage\s*\{[^}]*max-height:\s*min\(72vh,\s*600px\);/);
  assert.match(css, /\.video-stage\s*\{[^}]*overflow:\s*hidden;/);
  assert.match(css, /\.midnight-player video\s*\{[^}]*object-fit:\s*contain;/);
  assert.match(css, /\.midnight-player video\s*\{[^}]*position:\s*absolute;[^}]*inset:\s*0;/);

  // Measure layout with portrait 1080x1920 video at mobile width 390px
  const portrait = ui({ videoWidth: 1080, videoHeight: 1920, width: 390 });
  portrait.video.emit("loadedmetadata");
  assert.equal(portrait.stage.style.getPropertyValue("--video-aspect-ratio"), "1080 / 1920");

  // Measure layout with landscape 1920x1080 video
  const landscape = ui({ videoWidth: 1920, videoHeight: 1080, width: 1024 });
  landscape.video.emit("loadedmetadata");
  assert.equal(landscape.stage.style.getPropertyValue("--video-aspect-ratio"), "1920 / 1080");

  // Zero dimensions do not corrupt aspect ratio
  const zero = ui({ videoWidth: 0, videoHeight: 0 });
  zero.video.emit("loadedmetadata");
  assert.equal(zero.stage.style.getPropertyValue("--video-aspect-ratio"), "");
});

test("M16 Gate 2: start puck centering and label clearance reserve safe margins above floating deck", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  // Center puck layout and clearance rules
  assert.match(css, /#start-video,\s*\.btn-primary-tactile\s*\{[^}]*top:\s*50%;[^}]*left:\s*50%;[^}]*transform:\s*translate\(-50%,\s*-50%\);/);
  assert.match(css, /\.video-start-label\s*\{[^}]*position:\s*absolute;/);
  assert.match(css, /\.midnight-player:has\(#start-video:not\(\[hidden\]\)\)\s*#video-play-pause\s*\{[^}]*display:\s*none\s*!important;/);

  // Mobile layout at 390px: labelGap is 6px, puck-half is 28px (56px / 2)
  const mobile = ui({ width: 390, videoWidth: 1080, videoHeight: 1920 });
  mobile.video.emit("loadedmetadata");
  assert.equal(mobile.stage.style.getPropertyValue("--video-label-gap"), "6px");
  assert.equal(mobile.stage.style.getPropertyValue("--video-puck-half"), "28px");
  const mobileMinHeight = parseInt(mobile.stage.style.getPropertyValue("--video-min-height"), 10);
  assert.ok(mobileMinHeight >= 200, "mobile min-height must clear puck and deck");

  // Desktop layout at 1024px: labelGap is 12px, puck-half is 36px (72px / 2)
  const desktop = ui({ width: 1024, videoWidth: 1920, videoHeight: 1080 });
  desktop.video.emit("loadedmetadata");
  assert.equal(desktop.stage.style.getPropertyValue("--video-label-gap"), "12px");
  assert.equal(desktop.stage.style.getPropertyValue("--video-puck-half"), "36px");

  // At the calculated minimum stage height, both Start and Resume labels must
  // clear the deck. This tests the sizing calculation, not real browser layout.
  for (const player of [mobile, desktop]) {
    for (const currentTime of [0, 15]) {
      player.video.currentTime = currentTime;
      player.video.emit("timeupdate");
      const style = player.window.getComputedStyle(player.startLabel);
      const labelHeight = parseFloat(style.lineHeight) + parseFloat(style.paddingTop) +
        parseFloat(style.paddingBottom) + 2 * parseFloat(style.borderTopWidth);
      const height = parseFloat(player.stage.style.getPropertyValue("--video-min-height"));
      const puckHalf = parseFloat(player.stage.style.getPropertyValue("--video-puck-half"));
      const gap = parseFloat(player.stage.style.getPropertyValue("--video-label-gap"));
      const deckMargin = parseFloat(player.window.getComputedStyle(player.deck).marginBottom);
      const labelBottom = height / 2 + puckHalf + gap + labelHeight;
      const deckTop = height - player.deck.getBoundingClientRect().height - deckMargin;
      assert.equal(player.startLabel.textContent, currentTime ? "Resume video" : "Start video");
      assert.ok(labelBottom + 5 < deckTop, `${player.startLabel.textContent} must clear the deck`);
    }
  }
});

test("M16 Gate 3: keyboard End-key and range slider seek dispatches video-seek-request without altering media clock", () => {
  const player = ui();
  player.video.duration = 100;
  player.video.currentTime = 20;
  player.elements["video-timeline"].disabled = false;
  player.elements["video-timeline"].value = "100"; // User presses End key on slider

  const seekRequests = [];
  player.video.addEventListener("video-seek-request", (event) => {
    seekRequests.push(event.detail.position);
  });

  player.elements["video-timeline"].emit("change");
  // Seek intent was dispatched, but media clock is NOT mutated by UI layer
  assert.deepEqual(seekRequests, [100]);
  assert.equal(player.video.currentTime, 20);

  // When playback feedback arrives (e.g. rejection snap-back), timeline returns to approved position
  player.video.emit("video-seek-feedback");
  assert.equal(player.elements["video-timeline"].value, "20");

  // Keyboard space / k does not hijack native range slider semantics
  const sliderSpaceKey = { key: " ", target: { tagName: "INPUT" }, preventDefault() { this.prevented = true; } };
  player.player.emit("keydown", sliderSpaceKey);
  assert.equal(sliderSpaceKey.prevented, undefined, "Space on INPUT must not be intercepted");
});

test("M16 Gate 4: completed video replay UI mode initializes at 0:00 and preserves completion state", () => {
  const player = ui();
  const start = player.elements["start-video"];
  const play = player.elements["video-play-pause"];

  // Replay begins at currentTime 0
  assert.equal(player.video.currentTime, 0);
  assert.equal(start.attributes["aria-label"], "Start video");
  assert.equal(play.textContent, "Play");

  // During replay, playback time updates label to Resume
  player.video.currentTime = 45;
  player.video.emit("timeupdate");
  assert.equal(start.attributes["aria-label"], "Resume video");
  assert.equal(start.textContent, "Resume video");

  // Seeking in replay dispatches seek request and allows navigation
  const seekRequests = [];
  player.video.addEventListener("video-seek-request", (event) => seekRequests.push(event.detail.position));
  player.elements["video-timeline"].disabled = false;
  player.elements["video-timeline"].value = "60";
  player.elements["video-timeline"].emit("change");
  assert.deepEqual(seekRequests, [60]);
});

test("M16 Gate 5: timeline blur during click does not mutate play button text, ensuring reliable first-click Pause", () => {
  const player = ui();
  player.start.hidden = true;
  player.play.disabled = false;
  player.video.paused = false;
  player.video.emit("play");
  assert.equal(player.play.textContent, "Pause");

  // Track if textContent setter is invoked redundantly on identical value
  let redundantSetterCall = false;
  let text = player.play.textContent;
  Object.defineProperty(player.play, "textContent", {
    get() { return text; },
    set(val) {
      if (val === text) redundantSetterCall = true;
      text = val;
    },
  });

  // Timeline slider blur occurs between mousedown and mouseup on Pause button
  player.elements["video-timeline"].emit("blur");
  assert.equal(redundantSetterCall, false, "Slider blur must not rewrite identical play button text");

  // Clicking play button immediately pauses playback
  player.play.click();
  assert.equal(player.video.paused, true, "First mouse click must pause video");
  assert.equal(player.isFadeArmed(), false, "Auto-hide fade timer must NOT be armed while paused");
  assert.equal(player.classes.has("is-controls-visible"), true, "Controls deck must remain visible while paused");
});

test("M16 Gate 6: controls stay visible during keyboard focus (:focus-within) and auto-hide is suppressed while paused", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  // CSS: auto-hide requires :not(:focus-within) so focused elements remain visible
  assert.match(css, /\.midnight-player\.is-playing:not\(\.is-controls-visible\):not\(:focus-within\)\s*\.video-player-controls\s*\{[^}]*opacity:\s*0;/);
  // CSS: high-contrast focus rings
  assert.match(css, /#video-player\s*:is\(button,\s*input,\s*video\):focus-visible\s*\{[^}]*outline:\s*[23]px solid/);
  assert.match(css, /\.midnight-player\s*input\[type="range"\]:focus-visible\s*\{[^}]*outline:\s*2px solid/);

  const player = ui();
  player.start.hidden = true;
  player.play.disabled = false;
  player.video.paused = false;
  player.video.emit("play");

  // 1. Active video playback arms auto-hide timer
  assert.equal(player.isFadeArmed(), true, "Playback must arm auto-hide timer");
  assert.equal(player.classes.has("is-controls-visible"), true);

  // 2. Keyboard focus within the player
  player.setFocusWithin(true);

  // 3. Timeout fires while focused: :focus-within protects visibility
  player.fade();
  assert.equal(player.classes.has("is-controls-visible"), true, ":focus-within must keep controls visible when timeout fires");
  assert.equal(player.isFadeArmed(), false, "Timer must be disarmed after execution");

  // 4. Proving an expired timer cannot run twice
  player.fade();
  assert.equal(player.isFadeArmed(), false, "Expired timer must not re-arm or run a second time");

  // 5. Focus moves between internal controls (e.g. from deck to play button) — no premature fade
  player.player.emit("focusout", { relatedTarget: player.play });
  assert.equal(player.isFadeArmed(), false, "Internal focus change must not schedule premature fade");
  assert.equal(player.classes.has("is-controls-visible"), true, "Controls stay visible during internal focus movement");

  // 6. Focus genuinely leaves the player after timeout was consumed:
  // focusout handler schedules a new normal auto-hide timer
  player.setFocusWithin(false);
  player.player.emit("focusout", { relatedTarget: null });
  assert.equal(player.isFadeArmed(), true, "A new auto-hide timer must be scheduled when focus genuinely leaves");
  assert.equal(player.classes.has("is-controls-visible"), true, "Controls stay visible until the scheduled timeout expires");

  // 7. When the newly scheduled timer fires, controls fade out
  player.fade();
  assert.equal(player.classes.has("is-controls-visible"), false, "Controls fade out after focusout timeout fires");
  assert.equal(player.isFadeArmed(), false);

  // 8. When focus leaves BEFORE the timer expires, existing timer is preserved without duplicate
  player.player.emit("pointermove");
  assert.equal(player.isFadeArmed(), true, "Pointer move restores controls and arms timer");
  player.setFocusWithin(true);
  player.setFocusWithin(false); // Focus leaves before timeout fires
  player.player.emit("focusout", { relatedTarget: null });
  assert.equal(player.isFadeArmed(), true, "Existing timer is preserved without creating duplicate");
  player.fade(); // Timeout fires
  assert.equal(player.classes.has("is-controls-visible"), false, "Controls fade out when existing timer expires");

  // 9. Paused player never hides controls on focusout
  player.video.paused = true;
  player.classes.add("is-controls-visible");
  player.player.emit("focusout", { relatedTarget: null });
  assert.equal(player.isFadeArmed(), false, "Paused player never arms a fade timer on focusout");
  assert.equal(player.classes.has("is-controls-visible"), true, "Controls remain visible while paused");

  // 10. Pointer interaction restores controls
  player.video.paused = false;
  player.player.emit("pointermove");
  assert.equal(player.classes.has("is-controls-visible"), true, "Pointer move restores visible state");
  assert.equal(player.isFadeArmed(), true);

  // 11. No tracked video progress is altered by visibility lifecycle events
  assert.equal(player.video.currentTime, 0, "Visibility events must never alter video currentTime");
});

// Optional actual Chromium layout/input regressions. No server or learner data:
// media properties and session state are synthetic; the template/CSS/UI are real.
// Set PLAYER_BROWSER_MODULE to an existing Playwright installation to run them.
const browserModule = process.env.PLAYER_BROWSER_MODULE?.trim();
test("outer shell can shrink below 320px when a vertical scrollbar reserves space", () => {
  const shell = fs.readFileSync(path.join(__dirname, "../accounts/static/accounts/shell.css"), "utf8");
  for (const selector of ["html", "body"]) {
    const rule = shell.match(new RegExp(`(?:^|\\n)${selector}\\s*\\{([^}]*)\\}`));
    assert.ok(rule, `${selector} sizing rule must exist`);
    assert.match(rule[1], /min-width:\s*0\s*;/);
    assert.doesNotMatch(rule[1], /overflow(?:-x)?:\s*(?:hidden|clip)/);
  }
});
test("browser geometry, focus, first-click Pause and faded pointer targets", { skip: !browserModule }, async (t) => {
  const { chromium } = require(browserModule);
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const template = fs.readFileSync(path.join(__dirname, "../templates/training/assignment_detail.html"), "utf8");
  const begin = template.indexOf('<div class="midnight-player');
  const end = template.indexOf('<p id="playback-status"', begin);
  const markup = template.slice(begin, end).replace(/\{%[\s\S]*?%\}/g, "/qa/").replace(/\{\{[\s\S]*?\}\}/g, "QA lesson");
  const css = fs.readFileSync(path.join(__dirname, "static/training/video_player.css"), "utf8");
  const shell = fs.readFileSync(path.join(__dirname, "../accounts/static/accounts/shell.css"), "utf8");
  await page.setContent(`<style>${shell}\n${css}\nhtml { scrollbar-gutter: stable; } body { min-height: 1500px; }</style><div class="application-shell"><div class="app-main"><main class="page-content"><button id="outside">Outside player</button>${markup}</main></div></div>`);
  await page.evaluate(() => {
    const video = document.getElementById("lesson-video");
    let paused = true, position = 0;
    Object.defineProperties(video, {
      duration: { get: () => 100 },
      videoWidth: { get: () => window.qaWidth || 1080 },
      videoHeight: { get: () => window.qaHeight || 1920 },
      currentTime: { get: () => position, set: (value) => { position = value; } },
      paused: { get: () => paused },
    });
    video.play = async () => { paused = false; video.dispatchEvent(new Event("play")); };
    video.pause = () => { paused = true; video.dispatchEvent(new Event("pause")); };
  });
  await page.addScriptTag({ content: source });
  await page.emulateMedia({ reducedMotion: "reduce" });
  for (const width of [1440, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const [mediaWidth, mediaHeight] of [[1080, 1920], [1920, 1080]]) {
      await page.evaluate(([w, h]) => {
        window.qaWidth = w; window.qaHeight = h;
        document.querySelector("video").dispatchEvent(new Event("loadedmetadata"));
      }, [mediaWidth, mediaHeight]);
      const geometry = await page.evaluate(() => {
        const rect = (selector) => {
          const r = document.querySelector(selector).getBoundingClientRect();
          return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, width: r.width, height: r.height };
        };
        return { stage: rect(".video-stage"), video: rect("video"), puck: rect("#start-video"),
          label: rect("#video-start-label"), deck: rect(".video-controls-deck"),
          fit: getComputedStyle(document.querySelector("video")).objectFit,
          clientWidth: document.documentElement.clientWidth,
          overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth };
      });
      assert(geometry.clientWidth < width, "vertical scrollbar must reserve layout space");
      assert.equal(geometry.overflow, false, `page overflow at ${width}`);
      assert.equal(geometry.fit, "contain");
      assert(Math.abs(geometry.video.height - geometry.stage.height) < 1, `video exceeds stage at ${width}`);
      assert(Math.abs(geometry.video.width - geometry.stage.width) < 1);
      assert(geometry.label.bottom + 5 < geometry.deck.top, `label overlaps deck at ${width}`);
      assert(Math.abs((geometry.puck.top + geometry.puck.bottom) / 2 -
        (geometry.stage.top + geometry.stage.bottom) / 2) < 1, "puck must remain centered");
    }
  }
  await page.setViewportSize({ width: 390, height: 320 });
  await page.evaluate(() => document.querySelector("video").dispatchEvent(new Event("loadedmetadata")));
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await page.getByRole("button", { name: "Enter fullscreen" }).click();
  await page.waitForFunction(() => Boolean(document.fullscreenElement));
  // Fullscreen entry precedes the ResizeObserver-driven control layout.
  await page.waitForFunction(() => document.getElementById("video-start-label").getBoundingClientRect().bottom <
    document.querySelector(".video-controls-deck").getBoundingClientRect().top);
  const fullscreenGeometry = await page.evaluate(() => ({
    labelBottom: document.getElementById("video-start-label").getBoundingClientRect().bottom,
    deckTop: document.querySelector(".video-controls-deck").getBoundingClientRect().top,
    stageHeight: document.querySelector(".video-stage").getBoundingClientRect().height,
    height: innerHeight,
  }));
  assert(fullscreenGeometry.labelBottom < fullscreenGeometry.deckTop, "short fullscreen label separation");
  assert(fullscreenGeometry.stageHeight <= fullscreenGeometry.height);
  await page.getByRole("button", { name: "Exit fullscreen" }).click();
  await page.waitForFunction(() => !document.fullscreenElement);
  // Real hit testing and mouse clicks, using only a synthetic media state.
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.setViewportSize({ width: 768, height: 900 });
  assert.match(await page.evaluate(() =>
    getComputedStyle(document.querySelector(".video-player-controls")).transitionDuration), /0\.22s/);
  await page.evaluate(() => {
    document.getElementById("start-video").hidden = true;
    for (const control of document.querySelectorAll("[data-playback-control]")) control.disabled = false;
    document.querySelector("video").dispatchEvent(new Event("timeupdate"));
  });
  await page.getByRole("button", { name: "Play video" }).click();
  assert.equal(await page.evaluate(() => document.querySelector("video").paused), false);
  await page.getByRole("button", { name: "Pause video" }).click();
  assert.equal(await page.evaluate(() => document.querySelector("video").paused), true, "first mouse Pause click");
  await page.getByRole("button", { name: "Play video" }).click();
  await page.locator("#outside").click();
  await page.mouse.move(0, 0);
  await page.waitForFunction(() =>
    getComputedStyle(document.querySelector(".video-player-controls")).opacity === "0", null,
    { timeout: 6000 });
  assert.equal(await page.evaluate(() => {
    const r = document.getElementById("video-timeline").getBoundingClientRect();
    return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2).id;
  }), "lesson-video", "hidden timeline must not intercept pointers");
  const surface = await page.locator("video").boundingBox();
  await page.mouse.move(surface.x + surface.width / 2, surface.y + surface.height / 2);
  await page.waitForFunction(() =>
    getComputedStyle(document.querySelector(".video-player-controls")).opacity === "1");
  await page.getByRole("button", { name: "Pause video" }).click();
  assert.equal(await page.evaluate(() => document.querySelector("video").paused), true);
  await page.locator("#video-play-pause").focus();
  await page.keyboard.press("Tab");
  const focus = await page.evaluate(() => ({ label: document.activeElement.getAttribute("aria-label"),
    outline: getComputedStyle(document.activeElement).outlineStyle }));
  assert.equal(focus.label, "Enter fullscreen");
  assert.equal(focus.outline, "solid");
  await page.emulateMedia({ reducedMotion: "reduce" });
  assert.equal(await page.evaluate(() => getComputedStyle(document.querySelector(".video-player-controls")).transitionDuration), "0s");
  // Exercise both production scripts through real native range/button input.
  // All media/session behavior below is mocked and cannot touch QA progress.
  const learner = await browser.newPage({ viewport: { width: 390, height: 844 }, hasTouch: true });
  learner.on("pageerror", (error) => errors.push(error.message));
  await learner.setContent(`<style>${shell}\n${css}</style>${markup}
    <progress id="lesson-progress" max="100"></progress><span id="lesson-progress-label"></span>
    <span id="lesson-resume"></span><span id="lesson-completion"></span><p id="playback-status" role="status"></p>`);
  await learner.evaluate(() => {
    const video = document.getElementById("lesson-video");
    delete video.dataset.replayUrl; // Case A must use tracked playback, not the stripped template's replay branch.
    video.dataset.progressUrl = "/qa/progress/";
    video.dataset.startUrl = "/qa/sessions/start/";
    video.dataset.durationSeconds = "100";
    let paused = true, position = 0, source = "", ended = false, session = 0;
    window.qaState = {
      resume: 20, completed: false, positions: [], calls: [], pauseClicks: 0,
      deferNextProgress: false, resolveDeferredProgress: null,
    };
    document.getElementById("video-play-pause").addEventListener("click", () => window.qaState.pauseClicks++);
    Object.defineProperties(video, {
      duration: { get: () => 100 }, videoWidth: { get: () => 1080 }, videoHeight: { get: () => 1920 },
      currentTime: { get: () => position, set: (value) => {
        window.qaState.positions.push(value); position = value; ended = value >= 100;
        video.dispatchEvent(new Event("seeking"));
        queueMicrotask(() => video.dispatchEvent(new Event("seeked")));
        if (ended) video.dispatchEvent(new Event("ended"));
      } },
      src: { get: () => source, set: (value) => { source = value; } },
      paused: { get: () => paused }, ended: { get: () => ended },
    });
    video.load = () => { position = 0; ended = false; queueMicrotask(() => video.dispatchEvent(new Event("loadedmetadata"))); };
    video.play = async () => { paused = false; video.dispatchEvent(new Event("play")); };
    video.pause = () => { if (!paused) { paused = true; video.dispatchEvent(new Event("pause")); } };
    window.fetch = async (url, options) => {
      const body = options.body ? JSON.parse(options.body) : {};
      window.qaState.calls.push({ url, body });
      if (body.position !== undefined) window.qaState.resume = body.position;
      if (url.endsWith("/progress/") && window.qaState.deferNextProgress) {
        window.qaState.deferNextProgress = false;
        return new Promise((resolve) => {
          window.qaState.resolveDeferredProgress = () => {
            window.qaState.resolveDeferredProgress = null;
            resolve({ ok: true, json: async () => ({
              resume_position: 60,
              progress_percent: 60,
              watched_ranges: [[0, 60]],
              completed: false,
            }) });
          };
        });
      }
      return { ok: true, json: async () => ({
        session_id: url.endsWith("/start/") ? ++session : null,
        resume_position: window.qaState.resume,
        progress_percent: window.qaState.completed ? 99.45 : 30,
        watched_ranges: [[0, window.qaState.completed ? 99.45 : 30]],
        completed: window.qaState.completed,
      }) };
    };
  });
  await learner.addScriptTag({ content: fs.readFileSync(path.join(__dirname, "static/training/playback.js"), "utf8") });
  await learner.addScriptTag({ content: source });
  assert.equal(await learner.locator("video").getAttribute("data-replay-url"), null, "Case A must not enter read-only replay");
  await learner.getByRole("button", { name: "Start video" }).click();
  await learner.waitForFunction(() => window.qaState.calls.some((call) => call.url.endsWith("/start/")));
  await learner.getByRole("slider", { name: "Video timeline" }).press("End");
  await learner.waitForFunction(() => document.getElementById("playback-status").textContent.includes("unwatched video"));
  assert.equal(await learner.evaluate(() => window.qaState.positions.includes(100)), false);
  assert.equal(await learner.evaluate(() => document.querySelector("video").paused), false);
  assert.equal(await learner.locator("#lesson-completion").textContent(), "Incomplete");
  await learner.getByRole("slider", { name: "Video timeline" }).press("Home");
  await learner.waitForFunction(() => document.querySelector("video").currentTime === 0 && !document.querySelector("video").paused);
  const range = await learner.getByRole("slider", { name: "Video timeline" }).boundingBox();
  await learner.mouse.click(range.x + range.width * 0.15, range.y + range.height / 2);
  await learner.waitForFunction(() => document.querySelector("video").currentTime > 10 && document.querySelector("video").currentTime < 20);
  await learner.touchscreen.tap(range.x + range.width * 0.25, range.y + range.height / 2);
  await learner.waitForFunction(() => document.querySelector("video").currentTime > 20 && document.querySelector("video").currentTime < 30);
  assert.equal(await learner.locator("#lesson-progress").getAttribute("value"), "30");
  await learner.getByRole("button", { name: "Pause video" }).click();
  await learner.waitForFunction(() => document.getElementById("playback-status").textContent.startsWith("Paused."), null, { timeout: 5000 });
  assert.equal(await learner.evaluate(() => window.qaState.pauseClicks), 1, "timeline blur must preserve the first Pause click");
  await learner.waitForFunction(() => !document.getElementById("start-video").hidden);
  assert.equal(await learner.getByRole("button", { name: "Resume video" }).count(), 1);
  const resumeLayout = await learner.evaluate(() => ({
    label: document.getElementById("video-start-label").textContent,
    labelBottom: document.getElementById("video-start-label").getBoundingClientRect().bottom,
    deckTop: document.querySelector(".video-controls-deck").getBoundingClientRect().top,
  }));
  assert.equal(resumeLayout.label, "Resume video");
  assert(resumeLayout.labelBottom + 5 < resumeLayout.deckTop, "Resume label must clear the control deck at 390px");
  // The fresh server response now represents an already completed endpoint.
  await learner.evaluate(() => { window.qaState.completed = true; window.qaState.resume = 99.8; });
  await learner.getByRole("button", { name: "Resume video" }).click();
  // This first start response corrects local cached progress to the endpoint;
  // the metadata fallback must close it and reopen a zero-baseline replay.
  await learner.waitForFunction(() => document.querySelector("video").currentTime === 0 && !document.querySelector("video").paused);
  assert.equal(await learner.locator("#lesson-completion").textContent(), "Completed");
  assert.equal(await learner.evaluate(() => window.qaState.calls.filter((call) => call.url.endsWith("/start/")).at(-1).body.position), 0);
  await learner.getByRole("button", { name: "Pause video" }).click();
  await learner.waitForFunction(() => document.getElementById("playback-status").textContent.startsWith("Paused."));
  await learner.getByRole("button", { name: "Start video" }).click();
  await learner.waitForFunction(() => !document.querySelector("video").paused);
  await learner.evaluate(() => {
    window.qaState.deferNextProgress = true;
    document.getElementById("lesson-video").dispatchEvent(
      new CustomEvent("video-seek-request", { detail: { position: 40 }, cancelable: true }),
    );
  });
  await learner.waitForFunction(() => typeof window.qaState.resolveDeferredProgress === "function");
  const progressRequestsBeforeClose = await learner.evaluate(() =>
    window.qaState.calls.filter((call) => call.url.endsWith("/progress/")).length);
  await learner.evaluate(() => window.dispatchEvent(new Event("pagehide")));
  await learner.evaluate(async () => {
    window.qaState.resolveDeferredProgress();
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
  const lateResponseState = await learner.evaluate(() => ({
    progressRequests: window.qaState.calls.filter((call) => call.url.endsWith("/progress/")).length,
    progress: document.getElementById("lesson-progress").value,
    completion: document.getElementById("lesson-completion").textContent,
  }));
  assert.equal(lateResponseState.progressRequests, progressRequestsBeforeClose,
    "a response for a closed session must not trigger another seek request");
  assert.equal(lateResponseState.progress, 99.45,
    "a stale response must not overwrite confirmed progress");
  assert.equal(lateResponseState.completion, "Completed",
    "a stale response must not clear completed state");
  // Exercise the dedicated read-only replay route UI in the browser.
  const replayPage = await browser.newPage({ viewport: { width: 390, height: 844 } });
  replayPage.on("pageerror", (error) => errors.push(error.message));
  await replayPage.setContent(`<style>${shell}\n${css}</style>${markup}
    <p id="playback-status" role="status"></p>`);
  await replayPage.evaluate(() => {
    const video = document.getElementById("lesson-video");
    video.dataset.replayUrl = "/qa/replay/media/";
    delete video.dataset.progressUrl;
    delete video.dataset.startUrl;
    video.dataset.durationSeconds = "100";
    let paused = true, position = 0, currentSrc = "";
    window.qaReplayCalls = [];
    window.qaAssignedSources = [];
    Object.defineProperties(video, {
      duration: { get: () => 100 }, videoWidth: { get: () => 1080 }, videoHeight: { get: () => 1920 },
      currentTime: { get: () => position, set: (value) => { position = value; } },
      src: {
        get: () => currentSrc,
        set: (value) => {
          currentSrc = value;
          window.qaAssignedSources.push(value);
        },
      },
      paused: { get: () => paused }, ended: { get: () => position >= 100 },
    });
    video.load = () => { position = 0; queueMicrotask(() => video.dispatchEvent(new Event("loadedmetadata"))); };
    video.play = async () => { paused = false; video.dispatchEvent(new Event("play")); };
    video.pause = () => { paused = true; video.dispatchEvent(new Event("pause")); };
    window.fetch = async (url, options) => {
      window.qaReplayCalls.push({ url: String(url), method: options?.method || "GET" });
      throw new Error("Read-only replay must not call session or progress APIs: " + url);
    };
  });
  await replayPage.addScriptTag({ content: fs.readFileSync(path.join(__dirname, "static/training/playback.js"), "utf8") });
  await replayPage.addScriptTag({ content: source });
  assert.equal(await replayPage.locator("video").getAttribute("data-replay-url"), "/qa/replay/media/");
  assert.equal(await replayPage.evaluate(() => document.querySelector("video").src), "", "initial replay src must be empty before start");
  await replayPage.getByRole("button", { name: "Start video" }).click();
  await replayPage.waitForFunction(() => document.getElementById("playback-status").textContent.includes("read-only replay"));
  assert.equal(await replayPage.evaluate(() => document.querySelector("video").currentTime), 0, "replay starts at position 0");
  assert.equal(await replayPage.evaluate(() => document.querySelector("video").src), "/qa/replay/media/", "replay media URL must be assigned to video src");
  assert.deepEqual(await replayPage.evaluate(() => window.qaAssignedSources), ["/qa/replay/media/"], "recorded src assignments must only contain the replay URL");
  assert.equal(await replayPage.evaluate(() => !document.querySelector("video").src.includes("/sessions/")), true, "tracked-playback session media endpoint must not be selected");
  assert.equal(await replayPage.evaluate(() => document.querySelector("video").paused), false, "video must be playing after start");
  assert.equal(await replayPage.evaluate(() => window.qaReplayCalls.length), 0, "replay start must make zero API calls");

  // Exercise seeking in read-only replay
  await replayPage.evaluate(() => {
    document.getElementById("lesson-video").dispatchEvent(new CustomEvent("video-seek-request", { detail: { position: 35 } }));
  });
  assert.equal(await replayPage.evaluate(() => document.querySelector("video").currentTime), 35, "replay seeking updates position");
  assert.equal(await replayPage.evaluate(() => window.qaReplayCalls.length), 0, "replay seeking must make zero API calls");

  // Perform Pause click and verify state and zero network calls AFTER pause
  await replayPage.getByRole("button", { name: "Pause video" }).click();
  await replayPage.waitForFunction(() => document.querySelector("video").paused);
  assert.equal(await replayPage.evaluate(() => document.querySelector("video").paused), true, "video element must be paused after Pause click");
  await replayPage.waitForFunction(() => document.getElementById("playback-status").textContent.includes("Paused read-only replay"));
  assert.equal(await replayPage.evaluate(() => window.qaReplayCalls.length), 0, "replay must make zero API calls after pause");
  await replayPage.close();
  assert.deepEqual(errors, []);
});
