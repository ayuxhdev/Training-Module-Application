const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "static/accounts/password_toggle.js"), "utf8");

function setup({ hasToggle = true, hasPassword = true, type = "password" } = {}) {
  const listeners = new Map();
  const password = { type, value: "entered value", name: "password", autocomplete: "current-password" };
  const attrs = { "aria-controls": "id_password" };
  const toggle = {
    hidden: true, textContent: "Show password",
    getAttribute: name => attrs[name],
    setAttribute: (name, value) => { attrs[name] = value; },
    addEventListener: (name, callback) => listeners.set(name, callback),
  };
  const document = {
    querySelector(selector) { assert.equal(selector, "[data-password-toggle]"); return hasToggle ? toggle : null; },
    getElementById(id) { assert.equal(id, "id_password"); return hasPassword ? password : null; },
  };
  vm.runInNewContext(source, { document });
  return { password, toggle, attrs, listeners, click: () => listeners.get("click")() };
}

test("password stays masked until the native button is activated", () => {
  const app = setup();
  assert.equal(app.password.type, "password");
  assert.equal(app.toggle.hidden, false);
  assert.equal(app.toggle.textContent, "Show password");
  assert.equal(Object.hasOwn(app.attrs, "aria-pressed"), false);
  assert.equal(app.listeners.size, 1);
});

test("activation reveals and hides the same field with changing labels and no pressed state", () => {
  const app = setup();
  for (let i = 0; i < 4; i++) {
    app.click();
    const visible = i % 2 === 0;
    assert.equal(app.password.type, visible ? "text" : "password");
    assert.equal(app.toggle.textContent, visible ? "Hide password" : "Show password");
    assert.equal(Object.hasOwn(app.attrs, "aria-pressed"), false);
    assert.equal(app.password.value, "entered value");
    assert.equal(app.password.name, "password");
    assert.equal(app.password.autocomplete, "current-password");
  }
});

test("unrelated pages and missing or incorrect target fields are left alone", () => {
  for (const options of [{ hasToggle: false }, { hasPassword: false }, { type: "text" }]) {
    const app = setup(options);
    assert.equal(app.toggle.hidden, true);
    assert.equal(app.listeners.size, 0);
  }
});
