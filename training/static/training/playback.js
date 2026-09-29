(function () {
  "use strict";

  const video = document.getElementById("lesson-video");
  if (!video) return;

  const startButton = document.getElementById("start-video");
  const progress = document.getElementById("lesson-progress");
  const progressLabel = document.getElementById("lesson-progress-label");
  const resumeLabel = document.getElementById("lesson-resume");
  const completionLabel = document.getElementById("lesson-completion");
  const status = document.getElementById("playback-status");
  const progressUrl = video.dataset.progressUrl;
  const startUrl = video.dataset.startUrl;
  const endBaseUrl = startUrl.replace(/start\/$/, "");
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
  video.controls = false;
  startButton.disabled = true;

  function showStatus(message) {
    status.textContent = message;
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
      sessionId = null;
      video.pause();
      video.controls = false;
      startButton.disabled = false;
      showStatus(error.message);
    }
  }

  async function endSession(completedNormally) {
    if (sessionId === null || ending) return;
    ending = true;
    stopTimer();
    const id = sessionId;
    sessionId = null;
    try {
      const data = await post(`${endBaseUrl}${id}/end/`, {
        position: reportedPosition(),
        completed_normally: completedNormally,
      });
      updateProgress(data);
      if (completedNormally) showStatus("Video ended. Your recorded progress is shown above.");
    } catch (error) {
      showStatus(error.message);
    } finally {
      ending = false;
      video.controls = false;
      startButton.disabled = false;
    }
  }

  video.addEventListener("loadedmetadata", () => setPosition(approvedPosition));
  video.addEventListener("error", () => showStatus("Video is unavailable. Please contact your training coordinator."));

  request(progressUrl, "GET").then((data) => {
    updateProgress(data);
    startButton.disabled = false;
  }).catch((error) => showStatus(error.message));

  startButton.addEventListener("click", async () => {
    if (starting || ending || sessionId !== null) return;
    starting = true;
    startButton.disabled = true;
    try {
      // Omitting position makes the backend choose the saved resume point.
      const data = await post(startUrl, {});
      if (!Number.isInteger(data.session_id) || data.session_id <= 0) {
        throw new Error("Playback response was invalid. Reload the lesson to try again.");
      }
      sessionId = data.session_id;
      updateProgress(data);
      sessionOrigin = data.resume_position;
      const mediaUrl = `${endBaseUrl}${sessionId}/media/`;
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
      video.src = mediaUrl;
      video.load();
      await metadataReady;
      setPosition(approvedPosition);
      video.controls = true;
      showStatus("Video ready. Press play if playback does not start automatically.");
      try {
        await video.play();
      } catch (_) {
        // The browser may require a second gesture after loading media.
      }
    } catch (error) {
      if (sessionId !== null) await endSession(false);
      showStatus(error.message);
      video.pause();
      startButton.disabled = false;
    } finally {
      starting = false;
    }
  });

  video.addEventListener("play", () => {
    if (sessionId === null) {
      video.pause();
      return;
    }
    showStatus("Playing. Progress is saved during playback.");
    startTimer();
  });

  video.addEventListener("pause", () => {
    if (!starting && !seeking && !video.ended) endSession(false);
  });
  video.addEventListener("ended", () => endSession(true));

  video.addEventListener("timeupdate", () => {
    if (!video.seeking && !seeking) lastPlayedPosition = video.currentTime;
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
