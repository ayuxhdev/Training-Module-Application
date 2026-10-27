// Progressively enhance the existing password field without changing submission.
(() => {
  const toggle = document.querySelector("[data-password-toggle]");
  if (!toggle) return;

  const password = document.getElementById(toggle.getAttribute("aria-controls"));
  if (!password || password.type !== "password") return;

  toggle.addEventListener("click", () => {
    const reveal = password.type === "password";
    password.type = reveal ? "text" : "password";
    toggle.textContent = reveal ? "Hide password" : "Show password";
  });
  toggle.hidden = false;
})();
