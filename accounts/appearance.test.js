const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "static/accounts/appearance.js"), "utf8");
const key = "gardens-need.appearance";

function element(extra = {}) {
  const listeners = new Map();
  return {
    ...extra,
    addEventListener(name, callback) { listeners.set(name, callback); },
    emit(name, event) { listeners.get(name)?.(event); },
  };
}

function appearance({ saved = null, dark = false, readFails = false, writeFails = false, hasControl = true } = {}) {
  const inputs = ["system", "light", "dark"].map(value => element({ value }));
  const label = {}, status = {}, summary = { setAttribute(name, value) { this[name] = value; }, focus() { this.focused = true; } };
  const control = {
    hidden: true,
    open: false,
    querySelectorAll: () => inputs,
    querySelector: name => ({ ".appearance-status": status, ".appearance-current": label, summary })[name],
    contains: target => target === summary || inputs.includes(target),
  };
  const document = element({ documentElement: { dataset: {} }, querySelector: () => hasControl ? control : null });
  const system = element({ matches: dark });
  const writes = [];
  let reads = 0;
  const window = element({
    matchMedia: () => system,
    localStorage: {
      getItem(name) { reads++; assert.equal(name, key); if (readFails) throw Error("storage denied"); return saved; },
      setItem(name, value) { if (writeFails) throw Error("storage denied"); writes.push([name, value]); },
    },
  });
  vm.runInNewContext(source, { window, document });
  return {
    document, window, control, label, status, summary, writes,
    reads: () => reads,
    theme: () => document.documentElement.dataset.theme,
    ready: () => document.emit("DOMContentLoaded"),
    choose: value => inputs.find(input => input.value === value).emit("change"),
    system: value => { system.matches = value; system.emit("change"); },
    checked: () => inputs.find(input => input.checked)?.value,
  };
}

for (const dark of [false, true]) {
  test(`System is the default, applied before DOM readiness (${dark ? "dark" : "light"})`, () => {
    const app = appearance({ dark });
    assert.equal(app.theme(), dark ? "dark" : "light");
    assert.equal(app.control.hidden, true);
    app.ready();
    assert.equal(app.control.hidden, false);
    assert.equal(app.checked(), "system");
    assert.equal(app.label.textContent, "System");
    app.system(!dark);
    assert.equal(app.theme(), dark ? "light" : "dark");
    assert.equal(app.reads(), 1);
    assert.deepEqual(app.writes, []);
  });
}

for (const saved of ["light", "dark"]) {
  test(`saved ${saved} wins before the first paint and ignores device changes`, () => {
    const app = appearance({ saved, dark: saved === "light" });
    assert.equal(app.theme(), saved);
    app.ready();
    app.system(saved === "dark");
    assert.equal(app.theme(), saved);
    assert.equal(app.checked(), saved);
    assert.equal(app.reads(), 1);
  });
}

test("only whitelisted preferences are applied", () => {
  for (const saved of ["DARK", "", "__proto__", '<script>alert(1)</script>']) {
    const app = appearance({ saved });
    app.ready();
    assert.equal(app.theme(), "light");
    assert.equal(app.checked(), "system");
  }
});

test("choices apply immediately, persist only the cosmetic key, and restore on the next page", () => {
  const app = appearance();
  app.ready();
  app.choose("dark");
  assert.equal(app.theme(), "dark");
  assert.equal(app.summary["aria-label"], "Appearance settings: Dark");
  assert.deepEqual(app.writes, [[key, "dark"]]);
  assert.equal(appearance({ saved: app.writes.at(-1)[1] }).theme(), "dark");
  app.choose("system");
  app.system(true);
  assert.equal(app.theme(), "dark");
  assert.equal(app.checked(), "system");
});

test("storage failures preserve usable in-page selection and accessible feedback", () => {
  const app = appearance({ readFails: true, writeFails: true });
  app.ready();
  assert.equal(app.theme(), "light");
  assert.match(app.status.textContent, /could not save or restore/);
  app.choose("dark");
  assert.equal(app.theme(), "dark");
  assert.equal(app.checked(), "dark");
  assert.match(app.status.textContent, /choice still applies/);
});

test("cross-tab appearance changes synchronize without reacting to authentication storage", () => {
  const app = appearance();
  app.ready();
  app.window.emit("storage", { key: "access_token", newValue: "dark" });
  assert.equal(app.checked(), "system");
  app.window.emit("storage", { key, newValue: "dark" });
  assert.equal(app.theme(), "dark");
  assert.equal(app.checked(), "dark");
  app.window.emit("storage", { key: null, newValue: null });
  assert.equal(app.checked(), "system");
  assert.deepEqual(app.writes, []);
});

test("Escape closes appearance and returns focus; outside clicks dismiss it", () => {
  const app = appearance(); app.ready();
  app.control.open = true;
  app.document.emit("click", { target: app.summary });
  assert.equal(app.control.open, true);
  app.document.emit("keydown", { key: "Escape" });
  assert.equal(app.control.open, false);
  assert.equal(app.summary.focused, true);
  app.control.open = true;
  app.document.emit("click", { target: {} });
  assert.equal(app.control.open, false);
});

test("bootstrap remains safe without a selector", () => {
  const app = appearance({ saved: "dark", hasControl: false });
  app.ready();
  assert.equal(app.theme(), "dark");
});

test("both shared palettes retain readable foreground/background token pairs", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/accounts/shell.css"), "utf8");
  const luminance = hex => {
    const channels = [1, 3, 5].map(offset => parseInt(hex.slice(offset, offset + 2), 16) / 255)
      .map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
    return channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
  };
  for (const selector of [":root", 'html[data-theme="dark"]']) {
    const block = css.slice(css.indexOf(`${selector} {`)).split("}", 1)[0];
    const tokens = Object.fromEntries([...block.matchAll(/--([\w-]+):\s*(#[0-9a-f]{6});/g)].map(match => [match[1], match[2]]));
    for (const [foreground, background] of [
      ["color-text", "color-surface"], ["color-text-muted", "color-surface"],
      ["color-on-primary", "color-brand-primary"],
      ...["success", "warning", "danger", "info"].map(state => [`color-${state}-foreground`, `color-${state}-background`]),
    ]) {
      const values = [luminance(tokens[foreground]), luminance(tokens[background])].sort((a, b) => b - a);
      assert.ok((values[0] + .05) / (values[1] + .05) >= 4.5, `${selector}: ${foreground}`);
    }
  }
});
