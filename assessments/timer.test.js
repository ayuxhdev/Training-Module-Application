const assert = require("node:assert/strict");
const test = require("node:test");
const { readFileSync } = require("node:fs");
const { runInNewContext } = require("node:vm");
const { formatRemainingTime, initAssessmentTimer } = require("./static/assessments/timer.js");

function clockFixture(t, { delay = 0, skew = 0, duration = 120000 } = {}) {
  const view = new EventTarget();
  const doc = new EventTarget();
  doc.defaultView = view;
  doc.visibilityState = "visible";
  const label = { textContent: "" };
  const alert = { textContent: "", hidden: true };
  const classes = new Set();
  const server = Date.parse("2026-10-22T12:00:00Z");
  const clock = { wall: server + skew + delay, mono: 1000 + delay };
  const banner = {
    ownerDocument: doc,
    dataset: {
      deadline: new Date(server + duration).toISOString(),
      serverNow: new Date(server).toISOString(),
    },
    classList: {
      add: (...names) => names.forEach(name => classes.add(name)),
      remove: (...names) => names.forEach(name => classes.delete(name)),
    },
    querySelector: selector => selector === "#assessment-timer" ? label : alert,
  };
  const options = {
    now: () => clock.wall,
    performanceNow: () => clock.mono,
    navigationResponseStart: 1000,
  };
  const timer = initAssessmentTimer(banner, options);
  t.after(() => timer.stop());
  return {
    clock, banner, options, timer, label, alert, classes, view,
    advance(ms, monotonic = ms) { clock.wall += ms; clock.mono += monotonic; },
    hide() { doc.visibilityState = "hidden"; doc.dispatchEvent(new Event("visibilitychange")); },
    show() { doc.visibilityState = "visible"; doc.dispatchEvent(new Event("visibilitychange")); },
  };
}

test("immediate initialization uses the server anchor despite device clock skew", t => {
  const f = clockFixture(t, { skew: 86400000 });
  assert.equal(f.label.textContent, "2:00");
});

test("persistent warning region changes only at 2m, 1m and expiry, including resume", t => {
  const f = clockFixture(t, { duration: 180000 });
  const writes = [];
  let text = f.alert.textContent;
  Object.defineProperty(f.alert, "textContent", {
    get() { return text; },
    set(value) { text = value; writes.push(value); },
  });
  f.advance(60000);
  f.timer.tick();
  assert.match(text, /2 minutes/);
  for (let tick = 0; tick < 3; tick++) {
    f.advance(1000);
    f.timer.tick();
  }
  assert.equal(writes.length, 1);
  f.hide();
  f.advance(57000, 0);
  f.show();
  assert.match(text, /1 minute/);
  f.view.dispatchEvent(new Event("focus"));
  f.timer.tick();
  assert.equal(writes.length, 2);
  f.advance(60000);
  f.timer.tick();
  assert.match(text, /expired/i);
  f.timer.tick();
  f.show();
  assert.equal(writes.length, 3);
});

test("delayed initialization displays the 100 seconds actually remaining", t => {
  const f = clockFixture(t, { delay: 20000, skew: -86400000 });
  assert.equal(f.label.textContent, "1:40");
});

test("browser bootstrap reads navigation timing and initializes only once", t => {
  const f = clockFixture(t, { delay: 20000 });
  f.timer.stop();
  const doc = f.banner.ownerDocument;
  doc.getElementById = () => f.banner;
  const schedule = t.mock.fn(() => 1);
  const context = {
    document: doc, module: { exports: {} },
    performance: {
      now: () => f.clock.mono,
      getEntriesByType: type => {
        assert.equal(type, "navigation");
        return [{ responseStart: 1000 }];
      },
    },
    setInterval: schedule, clearInterval() {},
  };
  runInNewContext(readFileSync(require.resolve("./static/assessments/timer.js"), "utf8"), context);
  doc.dispatchEvent(new Event("DOMContentLoaded"));
  assert.equal(f.label.textContent, "1:40");
  doc.dispatchEvent(new Event("DOMContentLoaded"));
  assert.equal(schedule.mock.callCount(), 1);
  context.module.exports.initAssessmentTimer(f.banner).stop();
});

test("uninterrupted countdown includes initialization delay exactly once", t => {
  const f = clockFixture(t, { delay: 20000 });
  f.advance(10000);
  f.timer.tick();
  assert.equal(f.label.textContent, "1:30");
});

test("sleep/resume counts suspended wall time when the monotonic clock pauses", t => {
  const f = clockFixture(t);
  f.hide();
  f.advance(20000, 0);
  f.show();
  assert.equal(f.label.textContent, "1:40");
  f.advance(1000);
  f.timer.tick();
  assert.equal(f.label.textContent, "1:39");
});

test("ordinary background time is not counted twice on foreground", t => {
  const f = clockFixture(t);
  f.hide();
  f.advance(20000);
  f.timer.tick();
  f.show();
  assert.equal(f.label.textContent, "1:40");
});

test("focus while still hidden does not lose the pending suspension anchor", t => {
  const f = clockFixture(t);
  f.hide();
  f.advance(10000, 1000);
  f.view.dispatchEvent(new Event("focus"));
  f.advance(10000, 0);
  f.show();
  assert.equal(f.label.textContent, "1:40");
});

test("foreground clock adjustments do not affect countdown or later resume", t => {
  const f = clockFixture(t);
  f.advance(86400000, 1000);
  f.timer.tick();
  assert.equal(f.label.textContent, "1:59");
  f.hide();
  f.advance(10000, 0);
  f.show();
  assert.equal(f.label.textContent, "1:49");
});

test("a backward wall adjustment cannot increase countdown on resume", t => {
  const f = clockFixture(t);
  f.hide();
  f.advance(-86400000, 10000);
  f.show();
  assert.equal(f.label.textContent, "1:50");
});

test("expiry during suspension is displayed and remains expired", t => {
  const f = clockFixture(t);
  f.hide();
  f.advance(180000, 0);
  f.show();
  assert.equal(f.label.textContent, "Time expired");
  assert.ok(f.classes.has("is-expired"));
  assert.equal(f.alert.hidden, false);
  f.advance(-180000, 0);
  f.timer.tick();
  assert.equal(f.label.textContent, "Time expired");
});

test("repeated initialization and resume events neither restart nor duplicate countdown", t => {
  const schedule = t.mock.method(globalThis, "setInterval", () => 1);
  const cancel = t.mock.method(globalThis, "clearInterval", () => {});
  const f = clockFixture(t);
  const repeated = initAssessmentTimer(f.banner, f.options);
  t.after(() => repeated.stop());
  assert.equal(repeated, f.timer);
  f.hide();
  f.view.dispatchEvent(new Event("blur"));
  f.advance(20000, 0);
  f.show();
  f.view.dispatchEvent(new Event("focus"));
  f.view.dispatchEvent(new Event("pageshow"));
  assert.equal(f.label.textContent, "1:40");
  assert.equal(schedule.mock.callCount(), 1);
  f.hide();
  f.advance(120000, 0);
  f.show();
  assert.equal(f.label.textContent, "Time expired");
  assert.equal(cancel.mock.callCount(), 1);
  assert.equal(initAssessmentTimer(f.banner, f.options), f.timer);
  f.view.dispatchEvent(new Event("focus"));
  assert.equal(schedule.mock.callCount(), 1);
});

test("page cache suspension resumes correctly and stop removes lifecycle listeners", t => {
  const f = clockFixture(t);
  f.view.dispatchEvent(new Event("pagehide"));
  f.advance(20000, 0);
  f.view.dispatchEvent(new Event("pageshow"));
  assert.equal(f.label.textContent, "1:40");
  f.timer.stop();
  f.hide();
  f.advance(20000, 0);
  f.show();
  f.view.dispatchEvent(new Event("focus"));
  assert.equal(f.label.textContent, "1:40");
});

test("formatRemainingTime formats standard minute and second intervals", () => {
  const result = formatRemainingTime(330 * 1000); // 5m 30s
  assert.equal(result.text, "5:30");
  assert.equal(result.totalSeconds, 330);
  assert.equal(result.minutes, 5);
  assert.equal(result.seconds, 30);
  assert.equal(result.expired, false);
});

test("formatRemainingTime pads single-digit seconds", () => {
  const result = formatRemainingTime(65 * 1000); // 1m 5s
  assert.equal(result.text, "1:05");
  assert.equal(result.totalSeconds, 65);
  assert.equal(result.minutes, 1);
  assert.equal(result.seconds, 5);
});

test("formatRemainingTime formats hours when over 60 minutes", () => {
  const result = formatRemainingTime(3725 * 1000); // 1h 2m 5s
  assert.equal(result.text, "1:02:05");
  assert.equal(result.hours, 1);
  assert.equal(result.minutes, 2);
  assert.equal(result.seconds, 5);
});

test("formatRemainingTime marks 0 or negative time as expired", () => {
  const zero = formatRemainingTime(0);
  assert.equal(zero.text, "Time expired");
  assert.equal(zero.expired, true);

  const past = formatRemainingTime(-5000);
  assert.equal(past.text, "Time expired");
  assert.equal(past.expired, true);
});

test("initAssessmentTimer updates DOM classes and alerts based on remaining time", () => {
  const now = Date.now();
  const classes = new Set();
  const banner = {
    dataset: { deadline: new Date(now + 90 * 1000).toISOString() }, // 90s remaining (warning)
    classList: {
      add: cls => classes.add(cls),
      remove: cls => classes.delete(cls),
      contains: cls => classes.has(cls),
    },
    querySelector: sel => {
      if (sel === "#assessment-timer") return { textContent: "" };
      if (sel === "#assessment-timer-alert") return { textContent: "", hidden: true };
      return null;
    },
  };

  const timer = initAssessmentTimer(banner);
  assert.ok(timer);
  assert.ok(classes.has("is-warning"));
  assert.ok(!classes.has("is-critical"));
  assert.ok(!classes.has("is-expired"));
  timer.stop();
});

test("initAssessmentTimer sets is-critical when <= 60 seconds", () => {
  const now = Date.now();
  const classes = new Set();
  let alertText = "";
  const banner = {
    dataset: { deadline: new Date(now + 45 * 1000).toISOString() }, // 45s remaining (critical)
    classList: {
      add: cls => classes.add(cls),
      remove: cls => classes.delete(cls),
      contains: cls => classes.has(cls),
    },
    querySelector: sel => {
      if (sel === "#assessment-timer") return { textContent: "" };
      if (sel === "#assessment-timer-alert") return { set textContent(val) { alertText = val; }, hidden: true };
      return null;
    },
  };

  const timer = initAssessmentTimer(banner);
  assert.ok(timer);
  assert.ok(classes.has("is-critical"));
  assert.ok(!classes.has("is-warning"));
  assert.match(alertText, /1 minute/);
  timer.stop();
});

test("initAssessmentTimer sets is-expired when past deadline", () => {
  const now = Date.now();
  const classes = new Set();
  let alertText = "";
  const banner = {
    dataset: { deadline: new Date(now - 10000).toISOString() }, // 10s past deadline
    classList: {
      add: cls => classes.add(cls),
      remove: cls => classes.delete(cls),
      contains: cls => classes.has(cls),
    },
    querySelector: sel => {
      if (sel === "#assessment-timer") return { textContent: "" };
      if (sel === "#assessment-timer-alert") return { set textContent(val) { alertText = val; }, hidden: true };
      return null;
    },
  };

  const timer = initAssessmentTimer(banner);
  assert.ok(timer);
  assert.ok(classes.has("is-expired"));
  assert.match(alertText, /deadline.*passed/);
  timer.stop();
});

test("initAssessmentTimer returns null on invalid or missing deadline", () => {
  assert.equal(initAssessmentTimer(null), null);
  assert.equal(initAssessmentTimer({ dataset: {} }), null);
  assert.equal(initAssessmentTimer({ dataset: { deadline: "invalid" } }), null);
});

test("initAssessmentTimer correctly uses serverNow when client clock is FAST (skewed into future)", () => {
  // Server time: 12:00:00, Deadline: 12:15:00 (15 min remaining = 900s)
  // Client clock: 13:00:00 (1 hour ahead)
  const serverBase = new Date("2026-10-21T12:00:00.000Z").getTime();
  const deadline = new Date("2026-10-21T12:15:00.000Z").toISOString();
  const serverNow = new Date("2026-10-21T12:00:00.000Z").toISOString();

  let displayedText = "";
  const banner = {
    dataset: { deadline, serverNow },
    classList: { add: () => {}, remove: () => {}, contains: () => false },
    querySelector: sel => {
      if (sel === "#assessment-timer") return { set textContent(v) { displayedText = v; } };
      if (sel === "#assessment-timer-alert") return { textContent: "", hidden: true };
      return null;
    },
  };

  // Client time is 1 hour fast: Date.now() returns serverBase + 3,600,000
  const clientClock = () => serverBase + 3600 * 1000;
  const monotonicClock = () => 1000; // Monotonic base

  const timer = initAssessmentTimer(banner, { now: clientClock, performanceNow: monotonicClock });
  assert.ok(timer);
  // Must show 15:00 based on server remaining time, not 0 / expired
  assert.equal(displayedText, "15:00");
  timer.stop();
});

test("initAssessmentTimer correctly uses serverNow when client clock is SLOW (skewed into past)", () => {
  // Server time: 12:00:00, Deadline: 12:05:00 (5 min remaining = 300s)
  // Client clock: 10:00:00 (2 hours behind)
  const serverBase = new Date("2026-10-21T12:00:00.000Z").getTime();
  const deadline = new Date("2026-10-21T12:05:00.000Z").toISOString();
  const serverNow = new Date("2026-10-21T12:00:00.000Z").toISOString();

  let displayedText = "";
  const banner = {
    dataset: { deadline, serverNow },
    classList: { add: () => {}, remove: () => {}, contains: () => false },
    querySelector: sel => {
      if (sel === "#assessment-timer") return { set textContent(v) { displayedText = v; } };
      if (sel === "#assessment-timer-alert") return { textContent: "", hidden: true };
      return null;
    },
  };

  // Client time is 2 hours slow: Date.now() returns serverBase - 7,200,000
  const clientClock = () => serverBase - 7200 * 1000;
  const monotonicClock = () => 5000;

  const timer = initAssessmentTimer(banner, { now: clientClock, performanceNow: monotonicClock });
  assert.ok(timer);
  // Must show 5:00 based on server remaining time, not 2h 5m
  assert.equal(displayedText, "5:00");
  timer.stop();
});

test("initAssessmentTimer uses monotonic clock so manual system clock changes during attempt do not corrupt timer", () => {
  const serverBase = new Date("2026-10-21T12:00:00.000Z").getTime();
  const deadline = new Date("2026-10-21T12:10:00.000Z").toISOString(); // 10m = 600s
  const serverNow = new Date("2026-10-21T12:00:00.000Z").toISOString();

  let displayedText = "";
  const banner = {
    dataset: { deadline, serverNow },
    classList: { add: () => {}, remove: () => {}, contains: () => false },
    querySelector: sel => {
      if (sel === "#assessment-timer") return { set textContent(v) { displayedText = v; } };
      if (sel === "#assessment-timer-alert") return { textContent: "", hidden: true };
      return null;
    },
  };

  let clientTime = serverBase;
  let monotonicTime = 1000;

  const timer = initAssessmentTimer(banner, {
    now: () => clientTime,
    performanceNow: () => monotonicTime,
  });
  assert.ok(timer);
  assert.equal(displayedText, "10:00");

  // User manually shifts their system clock back by 30 minutes!
  clientTime -= 30 * 60 * 1000;
  // But monotonic time advances normally by 30 seconds:
  monotonicTime += 30 * 1000;

  timer.tick();
  // 600s - 30s = 570s = 9m 30s
  assert.equal(displayedText, "9:30");
  timer.stop();
});

test("initAssessmentTimer handles exact server expiration boundary", () => {
  const deadline = new Date("2026-10-21T12:00:00.000Z").toISOString();
  // Server time has reached deadline
  const serverNow = new Date("2026-10-21T12:00:00.000Z").toISOString();

  let displayedText = "";
  const classes = new Set();
  const banner = {
    dataset: { deadline, serverNow },
    classList: {
      add: cls => classes.add(cls),
      remove: cls => classes.delete(cls),
      contains: cls => classes.has(cls),
    },
    querySelector: sel => {
      if (sel === "#assessment-timer") return { set textContent(v) { displayedText = v; } };
      if (sel === "#assessment-timer-alert") return { textContent: "", hidden: true };
      return null;
    },
  };

  const timer = initAssessmentTimer(banner);
  assert.ok(timer);
  assert.equal(displayedText, "Time expired");
  assert.ok(classes.has("is-expired"));
  timer.stop();
});
