const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "static/training/playback.js"), "utf8");

function playback(responseFor, custom = false) {
  const calls = [];
  const listeners = new Map();
  const videoListeners = new Map();
  function emit(name) {
    for (const entry of [...(videoListeners.get(name) || [])]) {
      if (entry.once) videoListeners.get(name).delete(entry);
      entry.listener();
    }
  }
  let heartbeat;
  const elements = new Map();
  const controls = [{ disabled: true }, { disabled: true }];
  if (custom) elements.set("video-player-controls", { querySelectorAll: () => controls });
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
    addEventListener(name, listener, options = {}) {
      if (!videoListeners.has(name)) videoListeners.set(name, new Set());
      videoListeners.get(name).add({ listener, once: options.once });
    },
    removeEventListener(name, listener) {
      for (const entry of videoListeners.get(name) || []) {
        if (entry.listener === listener) videoListeners.get(name).delete(entry);
      }
    },
    load() {
      emit("loadedmetadata");
    },
    async play() {
      this.paused = false;
      emit("play");
    },
    pause() {
      const wasPlaying = !this.paused;
      this.paused = true;
      if (wasPlaying) emit("pause");
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
    controls,
    event: emit,
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

test("custom controls follow the existing session lifecycle without native controls", async () => {
  const player = playback(async (url) => ({
    ok: true,
    json: async () => url.includes("/start/") ? progress(19) : progress(),
  }), true);
  await settle();
  assert(player.controls.every((control) => control.disabled));
  player.start();
  await settle();
  assert.equal(player.video.controls, false);
  assert(player.controls.every((control) => !control.disabled));
  assert.equal(player.element("start-video").hidden, true);
  player.video.pause();
  player.event("pause");
  await settle();
  assert(player.controls.every((control) => control.disabled));
  assert.equal(player.element("start-video").hidden, false);
  assert.equal(player.element("start-video").disabled, false);
  assert.equal(player.calls.filter((call) => call.url.includes("/end/")).length, 1);
  assert.match(player.element("playback-status").textContent, /^Paused\./);
});

test("pause status updates while closing, then resume and ended reflect the session lifecycle", async () => {
  let finishClose;
  const player = playback(async (url) => {
    if (url.includes("/end/")) await new Promise((resolve) => { finishClose = resolve; });
    return { ok: true, json: async () => url.includes("/start/") ? progress(19) : progress() };
  });
  await settle(); await player.start();
  assert.match(player.element("playback-status").textContent, /^Playing\./);
  player.video.pause(); await settle();
  assert.match(player.element("playback-status").textContent, /^Saving playback progress/);
  finishClose(); await settle();
  assert.match(player.element("playback-status").textContent, /^Paused\./);
  await player.start();
  assert.match(player.element("playback-status").textContent, /^Playing\./);
  player.video.ended = true; player.video.pause(); player.event("ended"); await settle();
  assert.doesNotMatch(player.element("playback-status").textContent, /^Playing\./);
  finishClose(); await settle();
  assert.match(player.element("playback-status").textContent, /^Video ended\./);
});

test("play without a session is paused and cannot display Playing", async () => {
  const player = playback(async () => ({ ok: true, json: async () => progress() }));
  await settle(); await player.video.play();
  assert.equal(player.video.paused, true);
  assert.match(player.element("playback-status").textContent, /not active/);
});

test("paused seeking and media errors never retain the Playing status", async () => {
  const player = playback(async (url) => ({
    ok: true, json: async () => url.includes("/start/") ? progress(19) : progress(),
  }));
  await settle(); await player.start();
  player.event("seeked"); // Finish the backend-selected initial resume seek.
  player.event("seeking"); player.video.pause();
  assert.match(player.element("playback-status").textContent, /^Paused\./);
  assert.equal(player.calls.filter((call) => call.url.includes("/end/")).length, 0);
  player.event("error");
  assert.match(player.element("playback-status").textContent, /Video is unavailable/);
});

test("expired session errors replace Playing and leave playback stopped", async () => {
  const player = playback(async (url, options) => {
    if (url.includes("/progress/") && options.method === "POST") return { ok: false, status: 409 };
    return { ok: true, json: async () => url.includes("/start/") ? progress(19) : progress() };
  });
  await settle(); await player.start(); player.heartbeat(); await settle();
  assert.equal(player.video.paused, true);
  assert.match(player.element("playback-status").textContent, /Reload the lesson/);
  assert.equal(player.calls.filter((call) => call.url.includes("/end/")).length, 1);
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
