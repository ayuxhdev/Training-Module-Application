// Keep drawer behavior isolated from the server-rendered navigation and its permissions.
(() => {
  const sidebar = document.getElementById("app-sidebar");
  const toggle = document.getElementById("sidebar-toggle");
  const backdrop = document.getElementById("sidebar-backdrop");
  const mainContent = document.querySelector(".app-main");
  const skipLink = document.querySelector(".skip-link");

  if (!sidebar || !toggle || !backdrop) {
    return;
  }

  const mobileNavigation = window.matchMedia("(max-width: 56rem)");

  function setDrawerOpen(open, restoreFocus = false) {
    const shouldOpen = open && mobileNavigation.matches;
    sidebar.classList.toggle("is-open", shouldOpen);
    backdrop.hidden = !shouldOpen;
    toggle.setAttribute("aria-expanded", String(shouldOpen));
    document.body.classList.toggle("nav-open", shouldOpen);
    if (mainContent) {
      mainContent.inert = shouldOpen;
    }
    if (skipLink) {
      skipLink.inert = shouldOpen;
    }

    if (shouldOpen) {
      const firstLink = sidebar.querySelector(".nav-link");
      if (firstLink) {
        firstLink.focus();
      }
    } else if (restoreFocus && mobileNavigation.matches) {
      toggle.focus();
    }
  }

  toggle.addEventListener("click", () => {
    const isOpen = toggle.getAttribute("aria-expanded") === "true";
    setDrawerOpen(!isOpen);
  });

  backdrop.addEventListener("click", () => setDrawerOpen(false, true));

  sidebar.addEventListener("click", (event) => {
    const clickedLink = event.target && typeof event.target.closest === "function"
      ? event.target.closest("a")
      : null;
    if (clickedLink && mobileNavigation.matches) {
      setDrawerOpen(false);
    }
  });

  document.addEventListener("keydown", (event) => {
    const isOpen = toggle.getAttribute("aria-expanded") === "true";
    if (!isOpen) {
      return;
    }

    if (event.key === "Escape") {
      setDrawerOpen(false, true);
      return;
    }

    if (event.key !== "Tab") {
      return;
    }

    const focusableElements = Array.from(sidebar.querySelectorAll(
      'a[href], button, input, select, textarea, [tabindex]',
    )).filter((element) => (
      element.tabIndex >= 0
      && !element.disabled
      && !element.hidden
      && element.getAttribute("aria-hidden") !== "true"
    ));
    if (!focusableElements.length) {
      return;
    }

    const activeIndex = focusableElements.indexOf(document.activeElement);
    const firstElement = focusableElements[0];
    const lastElement = focusableElements[focusableElements.length - 1];
    if (activeIndex === -1) {
      event.preventDefault();
      (event.shiftKey ? lastElement : firstElement).focus();
    } else if (event.shiftKey && activeIndex === 0) {
      event.preventDefault();
      lastElement.focus();
    } else if (!event.shiftKey && activeIndex === focusableElements.length - 1) {
      event.preventDefault();
      firstElement.focus();
    }
  });

  mobileNavigation.addEventListener("change", (event) => {
    if (!event.matches) {
      setDrawerOpen(false);
    }
  });
})();
