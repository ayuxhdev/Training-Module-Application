const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "static/training/video_player_ui.js"), "utf8");

function ui() {
  class Element {
    constructor() { this.listeners = {}; this.attributes = {}; this.disabled = false; this.hidden = false; this.style = {}; }
    addEventListener(event, callback) { (this.listeners[event] ??= []).push(callback); }
    emit(event, data = {}) { for (const callback of this.listeners[event] ?? []) callback(data); }
    click() { if (!this.disabled) this.emit("click"); }
    setAttribute(name, value) { this.attributes[name] = value; }
    getAttribute(name) { return this.attributes[name]; }
    dispatchEvent(event) { this.emit(event.type, event); return !event.defaultPrevented; }
  }
  const elements = {};
  for (const id of ["video-player", "lesson-video", "video-play-pause", "start-video",
    "video-timeline", "video-time", "video-fullscreen", "video-buffering"]) elements[id] = new Element();
  const player = elements["video-player"], video = elements["lesson-video"];
  const classes = new Set();
  player.classList = { add: (v) => classes.add(v), remove: (v) => classes.delete(v),
    toggle: (v, enabled) => enabled ? classes.add(v) : classes.delete(v) };
  player.querySelector = () => null;
  player.matches = () => false;
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
  vm.runInNewContext(source, { document, window, CustomEvent });
  return { elements, player, video, document, window, classes, fade: () => fade?.() };
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
  // Puck
  assert.match(rmBlock, /#start-video/);
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

// Optional actual Chromium layout/input regressions. No server or learner data:
// media properties and session state are synthetic; the template/CSS/UI are real.
// Set PLAYER_BROWSER_MODULE to an existing Playwright installation to run them.
const browserModule = process.env.PLAYER_BROWSER_MODULE;
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
  const browser = await chromium.launch({ channel: "chrome", headless: true });
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
  await page.setViewportSize({ width: 768, height: 900 });
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
  await page.waitForTimeout(4100);
  assert.equal(await page.evaluate(() => getComputedStyle(document.querySelector(".video-player-controls")).opacity), "0");
  assert.equal(await page.evaluate(() => {
    const r = document.getElementById("video-timeline").getBoundingClientRect();
    return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2).id;
  }), "lesson-video", "hidden timeline must not intercept pointers");
  const surface = await page.locator("video").boundingBox();
  await page.mouse.move(surface.x + surface.width / 2, surface.y + surface.height / 2);
  await page.getByRole("button", { name: "Pause video" }).click();
  assert.equal(await page.evaluate(() => document.querySelector("video").paused), true);
  await page.locator("#video-play-pause").focus();
  await page.keyboard.press("Tab");
  const focus = await page.evaluate(() => ({ label: document.activeElement.getAttribute("aria-label"),
    outline: getComputedStyle(document.activeElement).outlineStyle }));
  assert.equal(focus.label, "Enter fullscreen");
  assert.equal(focus.outline, "solid");
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
    window.qaState = { resume: 20, completed: false, positions: [], calls: [], pauseClicks: 0 };
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
  // The fresh server response now represents an already completed endpoint.
  await learner.evaluate(() => { window.qaState.completed = true; window.qaState.resume = 99.8; });
  await learner.getByRole("button", { name: "Resume video" }).click();
  // This first start response corrects local cached progress to the endpoint;
  // the metadata fallback must close it and reopen a zero-baseline replay.
  await learner.waitForFunction(() => document.querySelector("video").currentTime === 0 && !document.querySelector("video").paused);
  assert.equal(await learner.locator("#lesson-completion").textContent(), "Completed");
  assert.equal(await learner.evaluate(() => window.qaState.calls.filter((call) => call.url.endsWith("/start/")).at(-1).body.position), 0);
  await learner.getByRole("button", { name: "Pause video" }).click();
  assert.deepEqual(errors, []);
});
