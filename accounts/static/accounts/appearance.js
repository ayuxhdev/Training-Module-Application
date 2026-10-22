// Runs before the stylesheet: a device preference only, never account state.
(() => {
  const key = "gardens-need.appearance";
  const root = document.documentElement;
  const system = window.matchMedia("(prefers-color-scheme: dark)");
  const valid = value => ["system", "light", "dark"].includes(value) ? value : "system";
  let mode = "system";
  let storageFailed = false;
  try {
    mode = valid(window.localStorage.getItem(key));
  } catch (_) {
    storageFailed = true;
  }

  function apply() {
    root.dataset.theme = mode === "system" ? (system.matches ? "dark" : "light") : mode;
  }
  apply();
  system.addEventListener("change", () => { if (mode === "system") apply(); });

  document.addEventListener("DOMContentLoaded", () => {
    const control = document.querySelector(".appearance-control");
    if (!control) return;
    const inputs = control.querySelectorAll('input[name="appearance"]');
    const status = control.querySelector(".appearance-status");
    const label = control.querySelector(".appearance-current");
    function sync() {
      inputs.forEach(input => { input.checked = input.value === mode; });
      label.textContent = { system: "System", light: "Light", dark: "Dark" }[mode];
      control.querySelector("summary").setAttribute("aria-label", `Appearance settings: ${label.textContent}`);
      status.textContent = storageFailed
        ? "Your browser could not save or restore appearance. Your choice still applies to this page."
        : "";
    }
    control.hidden = false;
    sync();
    inputs.forEach(input => input.addEventListener("change", () => {
      mode = valid(input.value);
      apply();
      try {
        window.localStorage.setItem(key, mode);
        storageFailed = false;
      } catch (_) {
        storageFailed = true;
      }
      sync();
    }));
    window.addEventListener("storage", event => {
      if (event.key !== key && event.key !== null) return;
      mode = valid(event.newValue);
      storageFailed = false;
      apply();
      sync();
    });
    document.addEventListener("click", event => {
      if (!control.contains(event.target)) control.open = false;
    });
    document.addEventListener("keydown", event => {
      if (event.key === "Escape" && control.open) {
        control.open = false;
        control.querySelector("summary").focus();
      }
    });
  });
})();
