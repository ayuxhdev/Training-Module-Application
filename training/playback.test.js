const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "static/training/playback.js"), "utf8");

function playback(responseFor) {
  const calls = [];
  const listeners = new Map();
  const videoListeners = new Map();
  let heartbeat;
  const elements = new Map();
  for (const id of ["start-video", "lesson-progress", "lesson-progress-label",
    "lesson-resume", "lesson-completion", "playback-status"]) {
    elements.set(id, { disabled: false, textContent: "", addEventListener(name, listener) {
      listeners.set(name, listener);
    } });
  }
  const video = {
    dataset: {
      progressUrl: "/assignments/4/lessons/8/progress/",
      startUrl: "/assignments/4/lessons/8/sessions/start/",
      csrfToken: "test-token",
    },
    duration: 100,
    currentTime: 0,
    paused: true,
    seeking: false,
    ended: false,
    controls: false,
    addEventListener(name, listener) {
      videoListeners.set(name, listener);
    },
    removeEventListener(name, listener) {
      if (videoListeners.get(name) === listener) videoListeners.delete(name);
    },
    load() {
      videoListeners.get("loadedmetadata")?.();
    },
    async play() {
      this.paused = false;
      videoListeners.get("play")?.();
    },
    pause() {
      this.paused = true;
    },
  };
  elements.set("lesson-video", video);
  const window = {
    setInterval(callback) { heartbeat = callback; return 1; },
    clearInterval() { heartbeat = undefined; },
    addEventListener(name, listener) { listeners.set(name, listener); },
  };
  const fetch = async (url, options) => {
    calls.push({ url, options });
    return responseFor(url, options);
  };
  vm.runInNewContext(source, {
    document: { getElementById: (id) => elements.get(id) },
    window, fetch,
  });
  return {
    calls, video,
    start: () => listeners.get("click")(),
    heartbeat: () => heartbeat(),
    pagehide: () => listeners.get("pagehide")(),
    element: (id) => elements.get(id),
  };
}

async function settle() {
  for (let i = 0; i < 5; i += 1) await new Promise(setImmediate);
}

function progress(sessionId = null, watched = 50.442) {
  return {
    session_id: sessionId,
    resume_position: 12.89,
    progress_percent: watched,
    watched_ranges: [[0, watched]],
    completed: false,
  };
}

test("a protected forward observation keeps the session playable", async () => {
  const player = playback(async (url) => ({
    ok: true,
    json: async () => url.includes("/start/") ? progress(19) : progress(),
  }));
  await settle();
  player.start();
  await settle();
  player.video.currentTime = 99;
  player.heartbeat();
  await settle();
  assert.equal(player.calls.filter((call) => call.url.includes("/end/")).length, 0);
  assert.equal(player.video.paused, false);
  assert.equal(player.element("start-video").disabled, true);
  assert.equal(player.element("lesson-progress-label").textContent, "50%");
});

test("failed heartbeat closes its session using the last approved position", async () => {
  const player = playback(async (url, options) => {
    if (url.includes("/start/")) return { ok: true, json: async () => progress(19) };
    if (url.includes("/end/")) return { ok: true, json: async () => progress() };
    if (url.includes("/progress/") && options.method === "POST") return { ok: false };
    return { ok: true, json: async () => progress() };
  });
  await settle();
  player.start();
  await settle();
  player.video.currentTime = 13;
  player.heartbeat();
  await settle();
  const close = player.calls.find((call) => call.url.includes("/end/"));
  assert.ok(close);
  assert.equal(JSON.parse(close.options.body).position, 12.89);
  assert.equal(JSON.parse(close.options.body).completed_normally, false);
  assert.equal(player.video.paused, true);
  assert.equal(player.element("start-video").disabled, false);
  assert.match(player.element("playback-status").textContent, /Reload the lesson/);
});

test("a failed close retains the session for a pagehide retry", async () => {
  const player = playback(async (url, options) => {
    if (url.includes("/start/")) return { ok: true, json: async () => progress(19) };
    if (url.includes("/end/")) return { ok: false };
    if (url.includes("/progress/") && options.method === "POST") return { ok: false };
    return { ok: true, json: async () => progress() };
  });
  await settle();
  player.start();
  await settle();
  player.heartbeat();
  await settle();
  assert.equal(player.element("start-video").disabled, true);
  player.pagehide();
  await settle();
  assert.equal(player.calls.filter((call) => call.url.includes("/end/")).length, 2);
});
