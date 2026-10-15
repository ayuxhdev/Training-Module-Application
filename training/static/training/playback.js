(function () {
  "use strict";

  const video = document.getElementById("lesson-video");
  if (!video) return;

  const startButton = document.getElementById("start-video");
  const customControls = document.getElementById("video-player-controls");
  const progress = document.getElementById("lesson-progress");
  const progressLabel = document.getElementById("lesson-progress-label");
  const resumeLabel = document.getElementById("lesson-resume");
  const completionLabel = document.getElementById("lesson-completion");
  const status = document.getElementById("playback-status");
  const progressUrl = video.dataset.progressUrl;
  const startUrl = video.dataset.startUrl;
  const endBaseUrl = startUrl ? startUrl.replace(/start\/$/, "") : "";
  const csrfToken = video.dataset.csrfToken;
  const heartbeatIntervalMs = 10000; // Below the server's 30-second continuity limit.

  let sessionId = null;
  let starting = false;
  let ending = false;
  let seeking = false;
  let ignoreSeek = false;
  let timer = null;
  let pendingRequest = Promise.resolve();
  let approvedPosition = 0;
  let sessionOrigin = 0;
  let lastPlayedPosition = 0;
  let watchedRanges = [];
  let seekInFlight = false;
  function feedback() {
    video.dispatchEvent(new Event("video-seek-feedback"));
  }
  function nearEnd(position, duration) {
    return Number.isFinite(duration) && duration > 0 && position > 0 && position >= duration - 1;
  }
  function setControls(enabled) {
    video.controls = enabled && !customControls;
    if (customControls) {
      for (const control of customControls.querySelectorAll("[data-playback-control]")) {
        control.disabled = !enabled;
      }
      startButton.hidden = enabled;
    }
  }
  setControls(false);
  startButton.disabled = true;

  function showStatus(message) {
    status.textContent = message;
  }

  const replayUrl = video.dataset.replayUrl;
  if (replayUrl) {
    // The server authorizes this completed lesson on every media request.
    // Replay never calls session/progress endpoints or changes recorded credit.
    let loaded = false;
    startButton.disabled = false;
    showStatus("Read-only replay. Your recorded completion and coverage will not change.");
    startButton.addEventListener("click", async () => {
      if (starting) return;
      starting = true;
      startButton.disabled = true;
      try {
        if (!loaded) {
          const metadataReady = new Promise((resolve, reject) => {
            function ready() {
              video.removeEventListener("error", failed);
              resolve();
            }
            function failed() {
              video.removeEventListener("loadedmetadata", ready);
              reject(new Error("Replay is unavailable. Reload the lesson or contact your training coordinator."));
            }
            video.addEventListener("loadedmetadata", ready, { once: true });
            video.addEventListener("error", failed, { once: true });
          });
          video.src = replayUrl;
          video.load();
          await metadataReady;
          video.currentTime = 0;
          loaded = true;
        } else if (video.ended || nearEnd(video.currentTime, video.duration)) {
          video.currentTime = 0;
        }
        setControls(true);
        await video.play().catch(() => {
          showStatus("Replay ready. Press Play to continue. Recorded progress will not change.");
        });
      } catch (error) {
        loaded = false;
        setControls(false);
        showStatus(error.message);
      } finally {
        starting = false;
        startButton.disabled = false;
      }
    });
    video.addEventListener("play", () => showStatus("Playing read-only replay. Recorded progress will not change."));
    video.addEventListener("pause", () => {
      if (!starting && !video.ended) {
        setControls(false);
        showStatus("Paused read-only replay. Recorded progress is unchanged.");
      }
    });
    video.addEventListener("ended", () => {
      setControls(false);
      showStatus("Replay ended. Your recorded completion and coverage are unchanged.");
    });
    video.addEventListener("error", () => {
      loaded = false;
      video.pause();
      setControls(false);
      showStatus("Replay is unavailable. Reload the lesson or contact your training coordinator.");
    });
    video.addEventListener("video-seek-request", (event) => {
      event.preventDefault();
      const position = event.detail.position;
      if (loaded && Number.isFinite(position) && position >= 0 && position <= video.duration) {
        video.currentTime = position;
      }
      feedback();
    });
    window.addEventListener("pagehide", () => video.pause());
    return;
  }

  async function request(url, method, payload) {
    const response = await fetch(url, {
      method,
      credentials: "same-origin",
      headers: method === "POST" ? {
        "Content-Type": "application/json",
        "X-CSRFToken": csrfToken,
      } : {},
      body: method === "POST" ? JSON.stringify(payload) : undefined,
    });
    if (!response.ok) throw new Error("Playback progress is unavailable. Reload the lesson to try again.");
    let data;
    try {
      data = await response.json();
    } catch (_) {
      throw new Error("Playback response was invalid. Reload the lesson to try again.");
    }
    if (!data || !Number.isFinite(data.resume_position) ||
        !Number.isFinite(data.progress_percent) || typeof data.completed !== "boolean" ||
        !Array.isArray(data.watched_ranges)) {
      throw new Error("Playback response was invalid. Reload the lesson to try again.");
    }
    return data;
  }

  function post(url, payload) {
    const result = pendingRequest.then(() => request(url, "POST", payload));
    pendingRequest = result.catch(() => {});
    return result;
  }

  function updateProgress(data) {
    approvedPosition = Math.max(0, Math.min(data.resume_position, video.duration || data.resume_position));
    watchedRanges = data.watched_ranges;
    const percent = Math.max(0, Math.min(100, data.progress_percent));
    progress.value = percent;
    progressLabel.textContent = `${Math.round(percent)}%`;
    resumeLabel.textContent = `Resume position: ${Math.round(approvedPosition)} seconds`;
    completionLabel.textContent = data.completed ? "Completed" : "Incomplete";
  }

  function reportedPosition() {
    // Stay slightly behind the media clock so request and save time cannot
    // turn normal playback into an apparent forward seek.
    const playedInSession = Math.max(0, video.currentTime - sessionOrigin);
    return Math.max(0, video.currentTime - playedInSession * 0.01);
  }

  function setPosition(position) {
    if (!Number.isFinite(video.duration)) return;
    const boundedPosition = Math.max(0, Math.min(position, video.duration));
    if (Math.abs(video.currentTime - boundedPosition) < 0.05) return;
    ignoreSeek = true;
    lastPlayedPosition = boundedPosition;
    video.currentTime = boundedPosition;
  }

  function stopTimer() {
    if (timer !== null) window.clearInterval(timer);
    timer = null;
  }

  function startTimer() {
    stopTimer();
    timer = window.setInterval(() => {
      if (sessionId !== null && !video.paused && !video.seeking) heartbeat();
    }, heartbeatIntervalMs);
  }

  async function heartbeat() {
    const id = sessionId;
    if (id === null) return;
    try {
      const data = await post(progressUrl, { session_id: id, position: reportedPosition() });
      if (sessionId === id) updateProgress(data);
    } catch (error) {
      if (sessionId !== id) return;
      stopTimer();
      await endSession(false, approvedPosition);
      video.pause();
      setControls(false);
      startButton.disabled = sessionId !== null;
      showStatus(error.message);
    }
  }

  async function endSession(completedNormally, position = reportedPosition()) {
    if (sessionId === null || ending) return;
    ending = true;
    stopTimer();
    const id = sessionId;
    sessionId = null;
    showStatus("Saving playback progress. Please wait.");
    video.pause();
    try {
      const data = await post(`${endBaseUrl}${id}/end/`, {
        position,
        completed_normally: completedNormally,
      });
      updateProgress(data);
      showStatus(completedNormally
        ? "Video ended. Your recorded progress is shown above."
        : "Paused. Your progress is saved. Press Start or Resume to continue.");
    } catch (error) {
      sessionId = id; // Keep the ID so pagehide can retry a failed close.
      showStatus(error.message);
    } finally {
      ending = false;
      setControls(false);
      startButton.disabled = sessionId !== null;
    }
  }

  video.addEventListener("error", async () => {
    stopTimer();
    const message = "Video is unavailable. Please contact your training coordinator.";
    showStatus(message);
    // Startup's metadata promise owns its failed session cleanup.
    if (!starting && sessionId !== null) {
      await endSession(false, approvedPosition);
      showStatus(message);
    }
  });

  request(progressUrl, "GET").then((data) => {
    updateProgress(data);
    startButton.disabled = false;
  }).catch((error) => showStatus(error.message));

  startButton.addEventListener("click", async () => {
    if (starting || ending || sessionId !== null) return;
    starting = true;
    startButton.disabled = true;
    try {
      // Request replay from the server as well as rewinding the media clock.
      // Otherwise a later session response/metadata restore reinstates the endpoint.
      const knownDuration = Number.isFinite(video.duration) && video.duration > 0
        ? video.duration : Number(video.dataset.durationSeconds);
      const replay = video.ended || nearEnd(approvedPosition, knownDuration);
      let data = await post(startUrl, replay ? { position: 0 } : {});
      if (!Number.isInteger(data.session_id) || data.session_id <= 0) {
        throw new Error("Playback response was invalid. Reload the lesson to try again.");
      }
      sessionId = data.session_id;
      updateProgress(data);
      async function loadMedia() {
        const metadataReady = new Promise((resolve, reject) => {
          function loaded() {
            video.removeEventListener("error", failed);
            resolve();
          }
          function failed() {
            video.removeEventListener("loadedmetadata", loaded);
            reject(new Error("Video is unavailable."));
          }
          video.addEventListener("loadedmetadata", loaded, { once: true });
          video.addEventListener("error", failed, { once: true });
        });
        video.src = `${endBaseUrl}${sessionId}/media/`;
        video.load();
        await metadataReady;
      }
      await loadMedia();
      // Actual media duration may differ from rounded stored metadata.
      if (!replay && nearEnd(approvedPosition, video.duration)) {
        await endSession(false, approvedPosition);
        if (sessionId !== null) throw new Error("Playback progress is unavailable. Reload the lesson to try again.");
        data = await post(startUrl, { position: 0 });
        if (!Number.isInteger(data.session_id) || data.session_id <= 0) {
          throw new Error("Playback response was invalid. Reload the lesson to try again.");
        }
        sessionId = data.session_id;
        updateProgress(data);
        await loadMedia();
      }
      sessionOrigin = approvedPosition;
      setPosition(approvedPosition);
      setControls(true);
      showStatus("Video ready. Press play if playback does not start automatically.");
      try {
        await video.play();
      } catch (_) {
        // The browser may require a second gesture after loading media.
      }
    } catch (error) {
      if (sessionId !== null) await endSession(false, approvedPosition);
      showStatus(error.message);
      video.pause();
      startButton.disabled = sessionId !== null;
    } finally {
      starting = false;
    }
  });

  video.addEventListener("play", () => {
    if (sessionId === null || ending) {
      video.pause();
      if (!ending) showStatus("Playback is not active. Press Start or Resume to continue.");
      return;
    }
    showStatus("Playing. Progress is saved during playback.");
    startTimer();
  });

  video.addEventListener("pause", () => {
    if (sessionId !== null && (starting || seeking) && !video.ended) {
      showStatus("Paused. Playback will resume when ready.");
    }
    if (!starting && !seeking && !video.ended) endSession(false);
  });
  video.addEventListener("ended", () => endSession(true));

  video.addEventListener("timeupdate", () => {
    if (!video.seeking && !seeking) lastPlayedPosition = video.currentTime;
  });

  video.addEventListener("video-seek-request", async (event) => {
    event.preventDefault();
    const position = event.detail.position;
    const id = sessionId;
    if (id === null || starting || ending || seekInFlight || !Number.isFinite(position) ||
        position < 0 || position > video.duration) {
      feedback();
      return;
    }
    seekInFlight = true;
    seeking = true;
    const wasPlaying = !video.paused;
    stopTimer();
    video.pause();
    try {
      // Save legitimate playback first. Never assign an unapproved timeline
      // position to the video, where it can trigger a range fetch/ended event.
      const data = await post(progressUrl, { session_id: id, position: reportedPosition() });
      if (sessionId !== id) return;
      updateProgress(data);
      const alreadyWatched = watchedRanges.some((range) => position >= range[0] && position <= range[1]);
      if (position > lastPlayedPosition + 0.05 && !alreadyWatched) {
        showStatus("Move through unwatched video by playing it. Your playback position has been kept.");
      } else {
        const observed = await post(progressUrl, { session_id: id, position });
        if (sessionId !== id) return;
        updateProgress(observed);
        sessionOrigin = approvedPosition;
        setPosition(approvedPosition);
      }
    } catch (error) {
      if (sessionId === id) {
        await endSession(false, approvedPosition);
        showStatus(error.message);
      }
    } finally {
      seeking = false;
      seekInFlight = false;
      feedback();
      if (wasPlaying && sessionId === id) {
        await video.play().catch(() => {});
        // Preserve accessible rejection feedback after the play event.
        if (position > lastPlayedPosition + 0.05 &&
            !watchedRanges.some((range) => position >= range[0] && position <= range[1])) {
          showStatus("Move through unwatched video by playing it. Your playback position has been kept.");
        }
      }
    }
  });

  video.addEventListener("seeking", () => {
    if (ignoreSeek) return;
    seeking = true;
    stopTimer();
  });
  video.addEventListener("seeked", async () => {
    if (ignoreSeek) {
      ignoreSeek = false;
      return;
    }
    if (!seeking) return;
    const wasPlaying = !video.paused;
    video.pause();
    const furthestWatched = watchedRanges.reduce((furthest, range) => Math.max(furthest, range[1] || 0), 0);
    const movingBackward = video.currentTime < lastPlayedPosition - 0.05;
    if (!movingBackward && video.currentTime > Math.max(approvedPosition, furthestWatched) + 2) {
      setPosition(approvedPosition);
      sessionOrigin = approvedPosition;
      showStatus("Move through unwatched video by playing it. Your saved position has been restored.");
    } else if (sessionId !== null) {
      await heartbeat(); // A backward seek resets the server's position baseline.
      if (sessionId !== null) sessionOrigin = video.currentTime;
    }
    seeking = false;
    if (wasPlaying && sessionId !== null) video.play().catch(() => {});
  });

  window.addEventListener("pagehide", () => {
    stopTimer();
    if (sessionId === null) return;
    const id = sessionId;
    sessionId = null;
    fetch(`${endBaseUrl}${id}/end/`, {
      method: "POST",
      credentials: "same-origin",
      keepalive: true,
      headers: { "Content-Type": "application/json", "X-CSRFToken": csrfToken },
      body: JSON.stringify({ position: reportedPosition(), completed_normally: false }),
    }).catch(() => {});
  });
})();
