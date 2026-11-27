const assert = require("node:assert/strict");
const test = require("node:test");
const { initQuestionEditor } = require("./static/assessments/question_editor.js");

class Control extends EventTarget {
  constructor(value = "") {
    super();
    this.value = String(value);
    this.checked = false;
    this.hidden = false;
    this.attributes = {};
  }
  focus() { this.focused = true; }
  setAttribute(name, value) { this.attributes[name] = value; }
}

function fixture({ labels = ["", ""], positions, ids = [], correct = [], kind = "SINGLE_CHOICE", confirm = true, max = 1000 } = {}) {
  const rows = [];
  function row(index, text, position, id = "") {
    const controls = Object.fromEntries(["text", "position", "is_correct", "DELETE", "id"].map(name => {
      const input = new Control({ text, position, id }[name] || "");
      input.name = `options-${index}-${name}`;
      input.id = `id_${input.name}`;
      input.closest = () => input.paragraph || (input.paragraph = {});
      return [name, input];
    }));
    controls.is_correct.checked = correct.includes(index);
    const remove = new Control();
    const legend = {};
    return {
      controls, remove, legend,
      querySelector(selector) {
        if (selector === "[data-remove-option]") return remove;
        if (selector === "legend") return legend;
        return Object.entries(controls).find(([name]) => selector === `[name$="-${name}"]`)?.[1];
      },
    };
  }
  labels.forEach((label, i) => rows.push(row(i, label, positions?.[i] ?? i + 1, ids[i])));
  const type = new Control(kind);
  const total = new Control(rows.length);
  const maximum = new Control(max);
  const add = new Control();
  const status = new Control();
  const confirmations = [];
  const list = {
    querySelectorAll: () => rows,
    insertAdjacentHTML(where, html) {
      assert.equal(where, "beforeend");
      assert.doesNotMatch(html, /__prefix__/);
      const index = Number(html.match(/name="options-(\d+)-text"/)[1]);
      rows.push(row(index, "", ""));
    },
  };
  const template = { innerHTML: '<textarea name="options-__prefix__-text" id="id_options-__prefix__-text"></textarea>' };
  const elements = {
    '[name="question_type"]': type, "[data-option-list]": list, "[data-option-template]": template,
    '[name$="-TOTAL_FORMS"]': total, '[name$="-MAX_NUM_FORMS"]': maximum,
    "[data-add-option]": add, "[data-option-status]": status,
  };
  const form = {
    querySelector: selector => elements[selector],
    ownerDocument: { defaultView: { confirm(message) { confirmations.push(message); return confirm; } } },
  };
  const editor = initQuestionEditor(form);
  return {
    form, editor, rows, type, total, add, status, confirmations,
    switchTo(value) { type.value = value; type.dispatchEvent(new Event("change")); },
    texts() { return editor.activeRows().map(r => r.controls.text.value); },
  };
}

test("two initial options can grow to three and four with unique form indices and positions", () => {
  const f = fixture();
  f.add.dispatchEvent(new Event("click"));
  f.add.dispatchEvent(new Event("click"));
  assert.equal(f.total.value, "4");
  assert.deepEqual(f.rows.map(r => r.controls.position.value), ["1", "2", "3", "4"]);
  assert.equal(new Set(f.rows.map(r => r.controls.text.name)).size, 4);
  assert.equal(f.rows[3].controls.text.focused, true);
  assert.equal(f.rows[3].remove.attributes["aria-label"], "Remove option 4");
});

test("selecting another correct answer clears the previous selection", () => {
  const f = fixture({ labels: ["A", "B", "C"], correct: [0] });
  f.rows[2].controls.is_correct.checked = true;
  f.rows[2].controls.is_correct.dispatchEvent(new Event("change"));
  assert.deepEqual(f.rows.map(r => r.controls.is_correct.checked), [false, false, true]);
});

test("blank Single Choice converts to automatic True/False without choosing a correct answer", () => {
  const f = fixture();
  f.switchTo("TRUE_FALSE");
  assert.deepEqual(f.texts(), ["True", "False"]);
  assert.equal(f.add.hidden, true);
  assert.ok(f.rows.every(r => r.controls.text.readOnly && !r.controls.is_correct.checked));
  assert.equal(f.confirmations.length, 0);
  assert.equal(f.editor.addOption(), null);
});

test("conversion requires confirmation and switching back restores all entered answers and IDs", () => {
  const f = fixture({ labels: ["A", "B", "C", "D"], ids: [11, 12, 13, 14], correct: [2] });
  f.switchTo("TRUE_FALSE");
  assert.equal(f.confirmations.length, 1);
  assert.deepEqual(f.texts(), ["True", "False"]);
  assert.deepEqual(f.rows.map(r => r.controls.DELETE.checked), [false, false, true, true]);
  f.switchTo("SINGLE_CHOICE");
  assert.deepEqual(f.texts(), ["A", "B", "C", "D"]);
  assert.deepEqual(f.rows.map(r => r.controls.id.value), ["11", "12", "13", "14"]);
  assert.deepEqual(f.rows.map(r => r.controls.is_correct.checked), [false, false, true, false]);
  assert.ok(f.rows.every(r => !r.controls.text.readOnly && !r.hidden));
});

test("cancelling a type conversion preserves selection, values and deletion flags", () => {
  const f = fixture({ labels: ["A", "B", "C"], correct: [1], confirm: false });
  f.switchTo("TRUE_FALSE");
  assert.equal(f.type.value, "SINGLE_CHOICE");
  assert.deepEqual(f.texts(), ["A", "B", "C"]);
  assert.ok(f.rows.every(r => !r.controls.DELETE.checked));
  assert.equal(f.rows[1].controls.is_correct.checked, true);
});

test("a saved valid True/False draft keeps its text, order and correct answer", () => {
  const f = fixture({ labels: ["False", "True"], kind: "TRUE_FALSE", correct: [1], ids: [21, 22] });
  assert.deepEqual(f.texts(), ["False", "True"]);
  assert.equal(f.rows[1].controls.is_correct.checked, true);
  assert.equal(f.confirmations.length, 0);
  f.switchTo("SINGLE_CHOICE");
  f.editor.addOption();
  assert.deepEqual(f.texts(), ["False", "True", ""]);
});

test("an incomplete True/False draft gets only missing canonical labels", () => {
  const f = fixture({ labels: ["False", ""], kind: "TRUE_FALSE", correct: [0] });
  assert.deepEqual(f.texts(), ["False", "True"]);
  assert.equal(f.rows[0].controls.is_correct.checked, true);
});

test("an old invalid True/False draft is preserved with guidance instead of silent overwriting", () => {
  const f = fixture({ labels: ["Yes", "No", "Maybe"], kind: "TRUE_FALSE" });
  assert.deepEqual(f.texts(), ["Yes", "No", "Maybe"]);
  assert.match(f.status.textContent, /preserved.*confirmation/);
});

test("removal keeps Django IDs and total form indices while marking only the chosen row", () => {
  const f = fixture({ labels: ["A", "B", "C"], ids: [31, 32, 33] });
  f.rows[1].remove.dispatchEvent(new Event("click"));
  assert.deepEqual(f.texts(), ["A", "C"]);
  assert.equal(f.rows[1].controls.DELETE.checked, true);
  assert.equal(f.rows[1].controls.id.value, "32");
  assert.equal(f.total.value, "3");
  assert.equal(f.editor.removeOption(f.rows[0]), false);
  f.editor.addOption();
  assert.equal(f.rows[3].controls.position.value, "4");
});

test("the existing form limit is respected and repeated initialization adds no handlers", () => {
  const f = fixture({ max: 3 });
  assert.equal(initQuestionEditor(f.form), f.editor);
  f.add.dispatchEvent(new Event("click"));
  assert.equal(f.total.value, "3");
  assert.equal(f.add.disabled, true);
  assert.equal(f.editor.addOption(), null);
  assert.equal(f.total.value, "3");
});
