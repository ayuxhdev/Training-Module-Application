const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(
  path.join(__dirname, "static/accounts/shell.js"),
  "utf8",
);

function createClassList() {
  const values = new Set();
  return {
    toggle(name, force) {
      const shouldAdd = force === undefined ? !values.has(name) : force;
      if (shouldAdd) {
        values.add(name);
      } else {
        values.delete(name);
      }
      return shouldAdd;
    },
    contains(name) {
      return values.has(name);
    },
  };
}

function createElement(document, attributes = {}) {
  const values = new Map(Object.entries(attributes));
  const listeners = new Map();
  return {
    attributes: values,
    classList: createClassList(),
    disabled: false,
    hidden: false,
    tabIndex: 0,
    addEventListener(name, listener) {
      const registered = listeners.get(name) || [];
      registered.push(listener);
      listeners.set(name, registered);
    },
    emit(name, event = {}) {
      for (const listener of listeners.get(name) || []) {
        listener(event);
      }
    },
    focus() {
      document.activeElement = this;
    },
    getAttribute(name) {
      return values.has(name) ? values.get(name) : null;
    },
    setAttribute(name, value) {
      values.set(name, value);
    },
  };
}

function createShell() {
  const documentListeners = new Map();
  const document = {
    activeElement: null,
    body: { classList: createClassList() },
    addEventListener(name, listener) {
      const registered = documentListeners.get(name) || [];
      registered.push(listener);
      documentListeners.set(name, registered);
    },
    emit(name, event) {
      for (const listener of documentListeners.get(name) || []) {
        listener(event);
      }
    },
  };
  const firstLink = createElement(document);
  const secondLink = createElement(document);
  const links = [firstLink, secondLink];
  const sidebar = createElement(document);
  sidebar.querySelector = () => firstLink;
  sidebar.querySelectorAll = () => links;
  sidebar.contains = (element) => links.includes(element);

  const toggle = createElement(document, {
    "aria-controls": "app-sidebar",
    "aria-expanded": "false",
  });
  const backdrop = createElement(document);
  const mainContent = createElement(document);
  const skipLink = createElement(document);
  const elements = new Map([
    ["app-sidebar", sidebar],
    ["sidebar-toggle", toggle],
    ["sidebar-backdrop", backdrop],
  ]);
  const mediaListeners = [];
  const media = {
    matches: true,
    addEventListener(name, listener) {
      if (name === "change") {
        mediaListeners.push(listener);
      }
    },
    setMatches(matches) {
      this.matches = matches;
      for (const listener of mediaListeners) {
        listener({ matches });
      }
    },
  };

  document.getElementById = (id) => elements.get(id);
  document.querySelector = (selector) => {
    if (selector === ".app-main") return mainContent;
    if (selector === ".skip-link") return skipLink;
    return null;
  };
  vm.runInNewContext(source, {
    document,
    window: { matchMedia: () => media },
  });

  return { backdrop, document, firstLink, links, mainContent, media, secondLink, sidebar, skipLink, toggle };
}

function tabEvent(shiftKey = false) {
  return {
    key: "Tab",
    shiftKey,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
}

test("Tab and Shift+Tab stay inside the open drawer and wrap at both ends", () => {
  const shell = createShell();
  shell.toggle.emit("click");
  assert.equal(shell.document.activeElement, shell.firstLink);

  shell.secondLink.focus();
  const forward = tabEvent();
  shell.document.emit("keydown", forward);
  assert.equal(forward.prevented, true);
  assert.equal(shell.document.activeElement, shell.firstLink);

  const backward = tabEvent(true);
  shell.document.emit("keydown", backward);
  assert.equal(backward.prevented, true);
  assert.equal(shell.document.activeElement, shell.secondLink);

  shell.toggle.focus();
  const escapedForward = tabEvent();
  shell.document.emit("keydown", escapedForward);
  assert.equal(escapedForward.prevented, true);
  assert.equal(shell.document.activeElement, shell.firstLink);

  shell.toggle.focus();
  const escapedBackward = tabEvent(true);
  shell.document.emit("keydown", escapedBackward);
  assert.equal(escapedBackward.prevented, true);
  assert.equal(shell.document.activeElement, shell.secondLink);
});

test("opening makes covered content inert and Escape or backdrop restores focus", () => {
  const shell = createShell();
  shell.toggle.emit("click");

  assert.equal(shell.mainContent.inert, true);
  assert.equal(shell.skipLink.inert, true);
  assert.equal(shell.toggle.getAttribute("aria-expanded"), "true");
  assert.equal(shell.toggle.getAttribute("aria-controls"), "app-sidebar");

  shell.document.emit("keydown", { key: "Escape" });
  assert.equal(shell.toggle.getAttribute("aria-expanded"), "false");
  assert.equal(shell.mainContent.inert, false);
  assert.equal(shell.skipLink.inert, false);
  assert.equal(shell.document.activeElement, shell.toggle);

  shell.toggle.emit("click");
  shell.backdrop.emit("click");
  assert.equal(shell.toggle.getAttribute("aria-expanded"), "false");
  assert.equal(shell.document.activeElement, shell.toggle);
});

test("navigation and desktop resize still close the drawer", () => {
  const shell = createShell();
  shell.toggle.emit("click");
  shell.sidebar.emit("click", {
    target: { closest: () => shell.firstLink },
  });
  assert.equal(shell.toggle.getAttribute("aria-expanded"), "false");
  assert.equal(shell.mainContent.inert, false);

  shell.toggle.emit("click");
  shell.media.setMatches(false);
  assert.equal(shell.toggle.getAttribute("aria-expanded"), "false");
  assert.equal(shell.mainContent.inert, false);
});
