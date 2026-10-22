/**
 * Accessible assessment timer based on authoritative server deadline.
 * Preserves server-authoritative submission and expiration.
 */
(() => {
  const activeTimers = new WeakMap();

  function formatRemainingTime(ms) {
    if (ms <= 0) {
      return {
        text: "Time expired",
        totalSeconds: 0,
        minutes: 0,
        seconds: 0,
        expired: true,
      };
    }
    const totalSeconds = Math.ceil(ms / 1000);
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    const formattedSeconds = seconds < 10 ? "0" + seconds : String(seconds);

    let text;
    if (hours > 0) {
      const formattedMinutes = minutes < 10 ? "0" + minutes : String(minutes);
      text = `${hours}:${formattedMinutes}:${formattedSeconds}`;
    } else {
      text = `${minutes}:${formattedSeconds}`;
    }

    return {
      text,
      totalSeconds,
      hours,
      minutes,
      seconds,
      expired: false,
    };
  }

  function initAssessmentTimer(banner, options = {}) {
    if (!banner) return null;
    if (activeTimers.has(banner)) return activeTimers.get(banner);
    const deadlineStr = banner.dataset.deadline;
    if (!deadlineStr) return null;
    const deadlineTime = new Date(deadlineStr).getTime();
    if (Number.isNaN(deadlineTime)) return null;

    const serverNowStr = banner.dataset.serverNow;
    const serverNowTime = serverNowStr ? new Date(serverNowStr).getTime() : null;

    // Use options if provided for testing, otherwise standard globals
    const nowFn = options.now || (() => Date.now());
    const perfFn = options.performanceNow !== undefined
      ? options.performanceNow
      : ((typeof performance !== "undefined" && typeof performance.now === "function")
          ? () => performance.now()
          : null);

    const clientStartTime = nowFn();
    const hasValidServerNow = serverNowTime !== null && !Number.isNaN(serverNowTime);

    // Initial remaining time computed from server reference to eliminate client clock skew
    const initialRemainingMs = hasValidServerNow
      ? (deadlineTime - serverNowTime)
      : (deadlineTime - clientStartTime);

    // The server timestamp belongs to rendering, not script initialization. Navigation
    // response timing accounts for deferred scripts without comparing device/server dates.
    let monotonicAnchor = perfFn ? perfFn() : null;
    const responseStart = options.navigationResponseStart !== undefined
      ? options.navigationResponseStart
      : (options.performanceNow === undefined && typeof performance !== "undefined"
          ? performance.getEntriesByType?.("navigation")[0]?.responseStart : null);
    let elapsedBase = hasValidServerNow && monotonicAnchor !== null
      && Number.isFinite(responseStart) && responseStart >= 0 && responseStart <= monotonicAnchor
      ? monotonicAnchor - responseStart : 0;
    let wallAnchor = clientStartTime;
    let elapsedFloor = elapsedBase;
    let suspended = false;
    let stopped = false;
    let intervalId = null;
    const doc = banner.ownerDocument;
    const view = doc?.defaultView;

    function elapsed() {
      const delta = perfFn ? perfFn() - monotonicAnchor : nowFn() - wallAnchor;
      elapsedFloor = Math.max(elapsedFloor, elapsedBase + Math.max(0, delta));
      return elapsedFloor;
    }

    function suspend() {
      if (stopped || suspended) return;
      elapsedBase = elapsed();
      monotonicAnchor = perfFn ? perfFn() : null;
      wallAnchor = nowFn();
      suspended = true;
    }

    function resume() {
      if (stopped || doc?.visibilityState === "hidden") return;
      if (suspended) {
        // Relative wall time includes sleep on platforms whose monotonic clock stalls.
        // Device/server clock offsets cancel. A wall-clock edit DURING suspension is
        // indistinguishable from sleep without fresh server-time synchronization.
        const monotonicDelta = perfFn ? perfFn() - monotonicAnchor : 0;
        elapsedBase += Math.max(0, monotonicDelta, nowFn() - wallAnchor);
        monotonicAnchor = perfFn ? perfFn() : null;
        wallAnchor = nowFn();
        suspended = false;
      }
      tick();
    }

    function visibilityChanged() {
      if (doc.visibilityState === "hidden") suspend();
      else resume();
    }

    const listeners = [
      [doc, "visibilitychange", visibilityChanged],
      [doc, "freeze", suspend], [doc, "resume", resume],
      [view, "blur", suspend], [view, "focus", resume],
      [view, "pagehide", suspend], [view, "pageshow", resume],
    ];

    function cleanup() {
      stopped = true;
      if (intervalId !== null) clearInterval(intervalId);
      intervalId = null;
      listeners.forEach(([target, event, handler]) => target?.removeEventListener(event, handler));
    }

    const timerEl = banner.querySelector("#assessment-timer");
    const alertEl = banner.querySelector("#assessment-timer-alert");

    function tick() {
      if (stopped) return true;
      const remainingMs = initialRemainingMs - elapsed();

      const formatted = formatRemainingTime(remainingMs);

      if (timerEl) {
        timerEl.textContent = formatted.text;
      }

      if (formatted.expired) {
        cleanup();
        banner.classList.remove("is-warning", "is-critical");
        banner.classList.add("is-expired");
        if (alertEl) {
          const msg = "The deadline for this assessment has passed. Answers submitted now will be recorded as expired.";
          if (alertEl.textContent !== msg) {
            alertEl.textContent = msg;
          }
          alertEl.hidden = false;
        }
        return true; // Reached end
      } else if (formatted.totalSeconds <= 60) {
        banner.classList.remove("is-warning");
        banner.classList.add("is-critical");
        if (alertEl) {
          const msg = "Less than 1 minute remaining. Prepare to submit your answers.";
          if (alertEl.textContent !== msg) {
            alertEl.textContent = msg;
          }
          alertEl.hidden = false;
        }
      } else if (formatted.totalSeconds <= 120) {
        banner.classList.add("is-warning");
        banner.classList.remove("is-critical");
        if (alertEl) {
          const msg = "Less than 2 minutes remaining.";
          if (alertEl.textContent !== msg) {
            alertEl.textContent = msg;
          }
          alertEl.hidden = false;
        }
      } else {
        banner.classList.remove("is-warning", "is-critical", "is-expired");
        if (alertEl) {
          alertEl.hidden = true;
          alertEl.textContent = "";
        }
      }
      return false;
    }

    const timer = {
      stop() {
        cleanup();
        if (activeTimers.get(banner) === timer) activeTimers.delete(banner);
      },
      tick,
    };
    activeTimers.set(banner, timer);
    if (!tick()) {
      listeners.forEach(([target, event, handler]) => target?.addEventListener(event, handler));
      if (doc?.visibilityState === "hidden") suspend();
      intervalId = setInterval(tick, 1000);
    }
    return timer;
  }

  if (typeof document !== "undefined") {
    document.addEventListener("DOMContentLoaded", () => {
      const banner = document.getElementById("assessment-timer-banner");
      if (banner) {
        initAssessmentTimer(banner);
      }
    });
  }

  if (typeof module !== "undefined" && module.exports) {
    module.exports = { formatRemainingTime, initAssessmentTimer };
  }
})();
