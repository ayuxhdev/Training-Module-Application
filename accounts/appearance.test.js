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

function extractMediaBlock(source, query) {
  const queryIndex = source.indexOf(query);
  if (queryIndex === -1) return null;
  const openBrace = source.indexOf("{", queryIndex);
  if (openBrace === -1) return null;

  let depth = 0;
  for (let i = openBrace; i < source.length; i++) {
    const char = source[i];
    if (char === "{") {
      depth++;
    } else if (char === "}") {
      depth--;
      if (depth === 0) {
        return source.slice(openBrace + 1, i);
      }
    }
  }
  return null;
}

function parseRules(block) {
  if (!block) return [];
  const rules = [];
  const regex = /([^{]+)\{([^}]*)\}/g;
  let match;
  while ((match = regex.exec(block)) !== null) {
    const rawHeader = match[1].trim();
    const declarations = match[2];
    const selectors = rawHeader
      .split(",")
      .map(s => s.trim())
      .filter(Boolean);
    rules.push({ header: rawHeader, selectors, declarations });
  }
  return rules;
}

function findRuleWithExactSelector(block, targetSelector) {
  const rules = parseRules(block);
  return rules.find(rule => rule.selectors.includes(targetSelector)) || null;
}

function extractRuleDeclarations(block, exactSelector) {
  const rule = findRuleWithExactSelector(block, exactSelector);
  return rule ? rule.declarations : null;
}

test("primary action-link buttons retain readable on-primary text color at rest and hover", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/accounts/shell.css"), "utf8");

  // Extract declaration block for .action-link.btn-primary at rest (not :hover, :focus, etc.)
  const atRestMatch = css.match(/\.action-link\.btn-primary(?![a-zA-Z0-9_:.-])[^{]*\{([^}]*)\}/);
  assert.ok(atRestMatch, "at-rest .action-link.btn-primary rule must exist");
  assert.match(
    atRestMatch[1],
    /color:\s*var\(--color-on-primary\)/,
    "at-rest .action-link.btn-primary must declare color: var(--color-on-primary)",
  );

  // Extract declaration block for .action-link.btn-primary:hover
  const hoverMatch = css.match(/\.action-link\.btn-primary:hover(?![a-zA-Z0-9_:.-])[^{]*\{([^}]*)\}/);
  assert.ok(hoverMatch, ":hover .action-link.btn-primary rule must exist");
  assert.match(
    hoverMatch[1],
    /color:\s*var\(--color-on-primary\)/,
    ":hover .action-link.btn-primary must declare color: var(--color-on-primary)",
  );

  assert.match(css, /\.action-link:not\(\.btn-primary\)/);
});

test("brace-aware reduced-motion extraction verifies transitions and preserves sidebar positioning", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/accounts/shell.css"), "utf8");
  const rmBlock = extractMediaBlock(css, "@media (prefers-reduced-motion: reduce)");
  assert.ok(rmBlock, "prefers-reduced-motion block must be extracted in full");

  // 1. Sidebar in reduced motion: transitions disabled, but positioning transforms preserved
  const sidebarRule = findRuleWithExactSelector(rmBlock, ".app-sidebar");
  assert.ok(sidebarRule, ".app-sidebar rule must exist inside prefers-reduced-motion");
  assert.match(sidebarRule.declarations, /transition:\s*none\s*!important/);
  assert.doesNotMatch(sidebarRule.declarations, /transform:\s*none/);

  // 2. Buttons and inputs in reduced motion: transitions AND active transforms disabled
  const buttonRule = findRuleWithExactSelector(rmBlock, 'input[type="submit"]');
  assert.ok(buttonRule, "input[type='submit'] rule must exist inside prefers-reduced-motion");
  assert.match(buttonRule.declarations, /transition:\s*none\s*!important/);
  assert.match(buttonRule.declarations, /transform:\s*none\s*!important/);

  // Check all required selectors are present as exact selectors in the button/input rule
  const requiredSelectors = [
    "button",
    'input[type="submit"]',
    'input[type="button"]',
    'input[type="reset"]',
    ".btn",
    ".action-link",
    ".primary-nav .nav-link",
  ];
  for (const selector of requiredSelectors) {
    assert.ok(
      buttonRule.selectors.includes(selector),
      `Reduced motion must cover exact selector "${selector}"`,
    );
  }

  // 3. Mobile sidebar positioning transforms remain intact in mobile media query
  const mobileBlock = extractMediaBlock(css, "@media (max-width: 56rem)");
  assert.ok(mobileBlock, "Mobile media query block must be extracted");
  const closedSidebarRule = findRuleWithExactSelector(mobileBlock, ".app-sidebar");
  assert.ok(closedSidebarRule, "Closed mobile sidebar rule must exist");
  assert.match(closedSidebarRule.declarations, /transform:\s*translateX\(-105%\)/);

  const openSidebarRule = findRuleWithExactSelector(mobileBlock, ".app-sidebar.is-open");
  assert.ok(openSidebarRule, "Open mobile sidebar rule must exist");
  assert.match(openSidebarRule.declarations, /transform:\s*translateX\(0\)/);
});

test("reduced-motion regression checks prove assertions fail if declarations are removed or broken", () => {
  function validateReducedMotion(cssText) {
    const block = extractMediaBlock(cssText, "@media (prefers-reduced-motion: reduce)");
    if (!block) throw new Error("Missing media block");

    const sidebarRule = findRuleWithExactSelector(block, ".app-sidebar");
    if (!sidebarRule) {
      throw new Error("Base .app-sidebar selector missing from reduced motion");
    }
    if (!/transition:\s*none\s*!important/.test(sidebarRule.declarations)) {
      throw new Error("Sidebar transition not disabled");
    }
    if (/transform:\s*none/.test(sidebarRule.declarations)) {
      throw new Error("Sidebar positioning transform broken by transform: none");
    }

    const buttonRule = findRuleWithExactSelector(block, ".btn");
    if (!buttonRule) {
      throw new Error("Button/input rule missing from reduced motion");
    }
    for (const selector of [
      "button",
      'input[type="submit"]',
      'input[type="button"]',
      'input[type="reset"]',
      ".btn",
      ".action-link",
      ".primary-nav .nav-link",
    ]) {
      if (!buttonRule.selectors.includes(selector)) {
        throw new Error(`Missing exact selector in reduced motion: ${selector}`);
      }
    }
    if (!/transition:\s*none\s*!important/.test(buttonRule.declarations)) {
      throw new Error("Input transitions not disabled");
    }
    if (!/transform:\s*none\s*!important/.test(buttonRule.declarations)) {
      throw new Error("Input transforms not disabled");
    }
    return true;
  }

  const validCss = fs.readFileSync(path.join(__dirname, "static/accounts/shell.css"), "utf8");
  assert.ok(validateReducedMotion(validCss));

  // Removing standalone button while keeping input[type="button"] causes failure
  assert.throws(
    () => validateReducedMotion(validCss.replace("  button,\n", "")),
    /Missing exact selector in reduced motion: button/,
  );

  // Removing base .app-sidebar while keeping .app-sidebar.is-open causes failure
  assert.throws(
    () => validateReducedMotion(validCss.replace("  .app-sidebar,\n", "")),
    /Base \.app-sidebar selector missing from reduced motion/,
  );

  // Removing sidebar transition: none causes failure
  assert.throws(
    () => validateReducedMotion(validCss.replace("  .app-sidebar,\n  .app-sidebar.is-open {\n    transition: none !important;", "  .app-sidebar,\n  .app-sidebar.is-open {\n    /* removed */")),
    /Sidebar transition not disabled/,
  );

  // Adding transform: none to sidebar causes failure
  assert.throws(
    () => validateReducedMotion(validCss.replace("  .app-sidebar,\n  .app-sidebar.is-open {\n    transition: none !important;", "  .app-sidebar,\n  .app-sidebar.is-open {\n    transition: none !important;\n    transform: none !important;")),
    /Sidebar positioning transform broken/,
  );

  // Removing input[type="submit"] from reduced motion causes failure
  assert.throws(
    () => validateReducedMotion(validCss.replace("  button,\n  input[type=\"submit\"],\n", "  button,\n")),
    /Missing exact selector in reduced motion: input\[type="submit"\]/,
  );

  // Removing transform: none !important from inputs causes failure
  assert.throws(
    () => validateReducedMotion(validCss.replace("    transition: none !important;\n    transform: none !important;", "    transition: none !important;")),
    /Input transforms not disabled/,
  );
});

test("reduced-motion covers Batch 3 dashboard and curriculum elements", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/accounts/shell.css"), "utf8");
  const rmBlock = extractMediaBlock(css, "@media (prefers-reduced-motion: reduce)");
  assert.ok(rmBlock, "prefers-reduced-motion block must exist");

  const dashboardRule = findRuleWithExactSelector(rmBlock, ".dashboard-task");
  assert.ok(dashboardRule, ".dashboard-task rule must exist inside prefers-reduced-motion");
  assert.match(dashboardRule.declarations, /transition:\s*none\s*!important/);
  assert.match(dashboardRule.declarations, /transform:\s*none\s*!important/);

  for (const selector of [
    ".dashboard-task",
    ".dashboard-record-card",
    ".dashboard-progress-fill",
    ".learning-curriculum li",
    ".assessment-question",
    ".assessment-option",
    ".assessment-timer-banner",
  ]) {
    assert.ok(
      dashboardRule.selectors.includes(selector),
      `Reduced motion must cover exact selector "${selector}"`,
    );
  }
});

test("visually-hidden helper provides accessible clip and dimensions", () => {
  const css = fs.readFileSync(path.join(__dirname, "static/accounts/shell.css"), "utf8");
  const vhMatch = css.match(/\.visually-hidden\s*\{([^}]*)\}/);
  assert.ok(vhMatch, ".visually-hidden class must exist in shell.css");
  assert.match(vhMatch[1], /position:\s*absolute\s*!important/);
  assert.match(vhMatch[1], /width:\s*1px\s*!important/);
  assert.match(vhMatch[1], /height:\s*1px\s*!important/);
  assert.match(vhMatch[1], /overflow:\s*hidden\s*!important/);
  assert.match(vhMatch[1], /clip:\s*rect\(0,\s*0,\s*0,\s*0\)\s*!important/);
  assert.match(vhMatch[1], /white-space:\s*nowrap\s*!important/);
  assert.match(vhMatch[1], /border:\s*0\s*!important/);
});
