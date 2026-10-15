const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "static/training/playback.js"), "utf8");

function playback(responseFor, custom = false, options = {}) {
  const calls = [];
  const listeners = new Map();
  const videoListeners = new Map();
  function emit(name, event = {}) {
    for (const entry of [...(videoListeners.get(name) || [])]) {
      if (entry.once) videoListeners.get(name).delete(entry);
      entry.listener(event);
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
      durationSeconds: options.storedDuration || "100",
    },
    duration: 100,
    currentTime: 0,
    paused: true,
    seeking: false,
    ended: false,
    controls: false,
    dispatchEvent(event) { emit(event.type, event); return !event.defaultPrevented; },
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
      this.duration = options.actualDuration || 100;
      this.currentTime = 0;
      this.ended = false;
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
  if (options.replayUrl) {
    video.dataset = { replayUrl: options.replayUrl };
  }
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
    window, fetch, Event,
  });
  return {
    calls, video,
    start: () => listeners.get("click")(),
    heartbeat: () => heartbeat(),
    hasHeartbeat: () => Boolean(heartbeat),
    pagehide: () => listeners.get("pagehide")(),
    element: (id) => elements.get(id),
    controls,
    event: emit,
    seek: (position) => emit("video-seek-request", { detail: { position }, preventDefault() {} }),
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

test("read-only replay starts at zero and pause, seek, ended, replay never write progress", async () => {
  const url = "/assignments/1/lessons/6/replay/media/";
  const player = playback(() => { throw new Error("Replay must not call progress or session APIs"); }, true, { replayUrl: url });
  player.element("lesson-completion").textContent = "Completed";
  player.element("lesson-progress-label").textContent = "95%";
  await settle();
  await player.start();
  assert.equal(player.video.src, url);
  assert.equal(player.video.currentTime, 0);
  assert.equal(player.video.paused, false);
  assert.equal(player.hasHeartbeat(), false);
  player.video.currentTime = 12;
  player.video.pause();
  assert.match(player.element("playback-status").textContent, /Paused read-only replay/);
  await player.start();
  assert.equal(player.video.currentTime, 12);
  player.seek(4);
  assert.equal(player.video.currentTime, 4);
  player.seek(999);
  assert.equal(player.video.currentTime, 4);
  player.video.currentTime = 100;
  player.video.ended = true;
  player.event("ended");
  await player.start();
  assert.equal(player.video.currentTime, 0);
  player.pagehide();
  assert.equal(player.calls.length, 0);
  assert.equal(player.element("lesson-completion").textContent, "Completed");
  assert.equal(player.element("lesson-progress-label").textContent, "95%");
});

test("read-only replay media errors are visible and permit a safe retry without session writes", async () => {
  const player = playback(() => { throw new Error("No API writes permitted"); }, true,
    { replayUrl: "/assignments/1/lessons/6/replay/media/" });
  await player.start();
  player.event("error");
  assert.equal(player.video.paused, true);
  assert.match(player.element("playback-status").textContent, /Replay is unavailable/);
  assert.equal(player.element("start-video").hidden, false);
  await player.start();
  assert.equal(player.video.paused, false);
  assert.equal(player.calls.length, 0);
});

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
  await settle();
  assert.match(player.element("playback-status").textContent, /Video is unavailable/);
  assert.equal(player.calls.filter((call) => call.url.includes("/end/")).length, 1);
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

test("End/rapid unwatched range requests never reach the native media clock and remain playable", async () => {
  const player = playback(async (url, options) => {
    const body = options.body ? JSON.parse(options.body) : {};
    return { ok: true, json: async () => ({ ...progress(url.includes("/start/") ? 19 : null),
      resume_position: body.position ?? 12.89, watched_ranges: [[0, 20]], progress_percent: 20 }) };
  }, true);
  await settle(); await player.start(); player.event("seeked");
  player.video.currentTime = 20; player.event("timeupdate");
  player.seek(100); player.seek(99); player.seek(80);
  await settle();
  assert.equal(player.video.currentTime, 20);
  assert.equal(player.video.paused, false);
  assert.equal(player.calls.filter((call) => call.url.includes("/end/")).length, 0);
  assert.match(player.element("playback-status").textContent, /unwatched video/);
  assert.equal(player.element("lesson-completion").textContent, "Incomplete");
  assert.equal(player.element("lesson-progress").value, 20);
  assert(player.calls.filter((call) => call.options.method === "POST" && call.url.includes("/progress/"))
    .every((call) => JSON.parse(call.options.body).position <= 20));
  player.video.currentTime = 23; player.event("timeupdate"); player.heartbeat(); await settle();
  assert.match(player.calls.at(-1).url, /progress\/$/);
  assert.equal(player.video.paused, false);
});

test("Home and watched mouse/touch seek intents use server observations and retain unique coverage", async () => {
  const player = playback(async (url, options) => {
    const body = options.body ? JSON.parse(options.body) : {};
    return { ok: true, json: async () => ({ ...progress(url.includes("/start/") ? 19 : null),
      resume_position: body.position ?? 12.89, watched_ranges: [[0, 30]], progress_percent: 30 }) };
  }, true);
  await settle(); await player.start(); player.event("seeked");
  player.video.currentTime = 20; player.event("timeupdate");
  for (const position of [0, 7, 25]) {
    player.seek(position); await settle(); player.event("seeked");
    assert.equal(player.video.currentTime, position);
    assert.equal(player.video.paused, false);
    assert.equal(player.element("lesson-progress").value, 30);
  }
  assert.equal(player.calls.filter((call) => call.url.includes("/end/")).length, 0);
});

test("authorization failure during seek fails closed and closes at the approved position", async () => {
  const player = playback(async (url, options) => {
    if (url.includes("/progress/") && options.method === "POST") return { ok: false, status: 403 };
    return { ok: true, json: async () => progress(url.includes("/start/") ? 19 : null) };
  }, true);
  await settle(); await player.start(); player.event("seeked");
  player.seek(100); await settle();
  assert.equal(player.video.paused, true);
  assert(player.controls.every((control) => control.disabled));
  const close = player.calls.find((call) => call.url.includes("/end/"));
  assert.equal(JSON.parse(close.options.body).position, 12.89);
  assert.match(player.element("playback-status").textContent, /Reload the lesson/);
});

test("completed endpoint replay starts a server session at zero and metadata cannot restore the end", async () => {
  const player = playback(async (url, options) => {
    const body = options.body ? JSON.parse(options.body) : {};
    return { ok: true, json: async () => ({ ...progress(url.includes("/start/") ? 19 : null, 99.45),
      resume_position: body.position ?? 68.45, completed: true, watched_ranges: [[0, 68.45]] }) };
  }, true, { storedDuration: "69", actualDuration: 68.625 });
  // There is no media metadata before the first load.
  player.video.duration = NaN;
  await settle(); await player.start(); player.event("seeked");
  const start = player.calls.find((call) => call.url.includes("/start/"));
  assert.equal(JSON.parse(start.options.body).position, 0);
  assert.equal(player.video.currentTime, 0);
  assert.equal(player.video.paused, false);
  player.event("loadedmetadata");
  assert.equal(player.video.currentTime, 0);
  assert.equal(player.element("lesson-completion").textContent, "Completed");
  assert.equal(player.element("lesson-progress").value, 99.45);
});

test("a shorter actual endpoint closes the original session and reopens replay with a zero baseline", async () => {
  let session = 18;
  const player = playback(async (url, options) => {
    const body = options.body ? JSON.parse(options.body) : {};
    return { ok: true, json: async () => ({ ...progress(url.includes("/start/") ? ++session : null, 99.45),
      resume_position: body.position ?? 68.45, completed: true, watched_ranges: [[0, 68.45]] }) };
  }, true, { storedDuration: "100", actualDuration: 68.625 });
  player.video.duration = NaN;
  await settle(); await player.start(); player.event("seeked");
  assert.equal(player.calls.filter((call) => call.url.includes("/start/")).length, 2);
  const close = player.calls.find((call) => call.url.includes("/end/"));
  assert.equal(JSON.parse(close.options.body).position, 68.45);
  assert.equal(JSON.parse(close.options.body).completed_normally, false);
  assert.equal(player.video.currentTime, 0);
  player.video.currentTime = 10; player.heartbeat(); await settle();
  assert.equal(JSON.parse(player.calls.at(-1).options.body).position, 9.9);
  assert.equal(player.element("lesson-progress").value, 99.45);
  assert.equal(player.element("lesson-completion").textContent, "Completed");
});

test("replay cannot open a second session when the original close fails", async () => {
  const player = playback(async (url) => {
    if (url.includes("/end/")) return { ok: false, status: 403 };
    return { ok: true, json: async () => ({ ...progress(url.includes("/start/") ? 19 : null, 99.45),
      resume_position: 68.45, completed: true, watched_ranges: [[0, 68.45]] }) };
  }, true, { storedDuration: "100", actualDuration: 68.625 });
  player.video.duration = NaN;
  await settle(); await player.start();
  assert.equal(player.calls.filter((call) => call.url.includes("/start/")).length, 1);
  assert.equal(player.element("start-video").disabled, true);
  assert.equal(player.video.paused, true);
  const closes = player.calls.filter((call) => call.url.includes("/end/")).length;
  player.pagehide(); await settle();
  assert.equal(player.calls.filter((call) => call.url.includes("/end/")).length, closes + 1);
});
