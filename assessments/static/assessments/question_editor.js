/* Progressive enhancement for Django's existing draft-option formset. */
(() => {
  const editors = new WeakMap();

  function initQuestionEditor(form) {
    if (editors.has(form)) return editors.get(form);
    const type = form.querySelector('[name="question_type"]');
    const list = form.querySelector("[data-option-list]");
    const template = form.querySelector("[data-option-template]");
    const total = form.querySelector('[name$="-TOTAL_FORMS"]');
    const maximum = form.querySelector('[name$="-MAX_NUM_FORMS"]');
    const add = form.querySelector("[data-add-option]");
    const status = form.querySelector("[data-option-status]");
    if (!type || !list || !template || !total || !add || !status) return null;
    const view = form.ownerDocument.defaultView;
    const rows = () => Array.from(list.querySelectorAll("[data-option-form]"));
    const field = (row, name) => row.querySelector(`[name$="-${name}"]`);
    const activeRows = () => rows().filter(row => !field(row, "DELETE").checked);
    let previousType = type.value;
    let singleChoice = null;

    function sync() {
      const active = activeRows();
      const binary = type.value === "TRUE_FALSE";
      add.hidden = binary;
      add.disabled = Number(total.value) >= Number(maximum?.value || 1000);
      rows().forEach(row => {
        row.hidden = field(row, "DELETE").checked;
        const remove = row.querySelector("[data-remove-option]");
        remove.hidden = binary;
        remove.disabled = active.length <= 2;
        if (!row.hidden) {
          const number = active.indexOf(row) + 1;
          row.querySelector("legend").textContent = `Option ${number}`;
          remove.setAttribute("aria-label", `Remove option ${number}`);
        }
      });
    }

    function enhance(row) {
      field(row, "DELETE").closest("p").hidden = true;
      field(row, "is_correct").addEventListener("change", event => {
        if (event.target.checked) {
          activeRows().filter(other => other !== row).forEach(other => {
            field(other, "is_correct").checked = false;
          });
        }
      });
      row.querySelector("[data-remove-option]").addEventListener("click", () => removeOption(row));
    }

    function appendOption() {
      const index = Number(total.value);
      if (!Number.isSafeInteger(index) || index < 0 || index >= Number(maximum?.value || 1000)) {
        status.textContent = "The option form limit has been reached. Save this draft before continuing.";
        return null;
      }
      const position = Math.max(0, ...activeRows().map(row => Number(field(row, "position").value) || 0)) + 1;
      list.insertAdjacentHTML("beforeend", template.innerHTML.replace(/__prefix__/g, String(index)));
      total.value = String(index + 1);
      const row = rows().at(-1);
      field(row, "position").value = String(position);
      enhance(row);
      return row;
    }

    function addOption() {
      if (type.value !== "SINGLE_CHOICE") return null;
      const row = appendOption();
      if (row) {
        sync();
        field(row, "text").focus();
        status.textContent = `${activeRows().length} answer options. Select exactly one correct answer.`;
      }
      return row;
    }

    function removeOption(row) {
      if (type.value !== "SINGLE_CHOICE" || activeRows().length <= 2) return false;
      field(row, "DELETE").checked = true;
      sync();
      add.focus();
      status.textContent = "Option marked for removal when you save this draft.";
      return true;
    }

    function snapshot() {
      return rows().map(row => ({
        row, text: field(row, "text").value, position: field(row, "position").value,
        correct: field(row, "is_correct").checked, deleted: field(row, "DELETE").checked,
      }));
    }

    function restore(saved) {
      rows().forEach(row => {
        const item = saved.find(value => value.row === row);
        field(row, "DELETE").checked = item ? item.deleted : true;
        field(row, "text").readOnly = false;
        if (item) {
          field(row, "text").value = item.text;
          field(row, "position").value = item.position;
          field(row, "is_correct").checked = item.correct;
        }
      });
    }

    function changeType() {
      if (type.value === previousType) return;
      if (type.value === "TRUE_FALSE") {
        const current = activeRows();
        const replacing = current.length > 2 || current.some((row, index) => {
          const text = field(row, "text").value.trim();
          return text && text.toLowerCase() !== ["true", "false"][index];
        });
        if (replacing && !view.confirm(
          "Use True and False instead of these answers? Extra options will be removed only when you save. " +
          "Switching back before saving restores your Single Choice answers. Cancel keeps all current answers."
        )) {
          type.value = previousType;
          return;
        }
        singleChoice = snapshot();
        while (activeRows().length < 2) {
          if (!appendOption()) {
            restore(singleChoice);
            type.value = previousType;
            sync();
            return;
          }
        }
        const choices = activeRows();
        const selected = choices.slice(0, 2).filter(row => field(row, "is_correct").checked);
        choices.forEach((row, index) => {
          field(row, "DELETE").checked = index >= 2;
          if (index < 2) {
            field(row, "text").value = ["True", "False"][index];
            field(row, "text").readOnly = true;
            field(row, "is_correct").checked = selected.length === 1 && selected[0] === row;
          }
        });
        status.textContent = "True/False has two options. Select exactly one correct answer before saving.";
      } else {
        if (singleChoice) restore(singleChoice);
        else rows().forEach(row => { field(row, "text").readOnly = false; });
        singleChoice = null;
        status.textContent = "Single Choice answers restored. You can add more options.";
      }
      previousType = type.value;
      sync();
    }

    rows().forEach(enhance);
    if (type.value === "TRUE_FALSE") {
      const choices = activeRows();
      const labels = choices.map(row => field(row, "text").value.trim().toLowerCase());
      if (choices.length === 2 && labels.every(value => !value || value === "true" || value === "false") &&
          (!labels[0] || !labels[1] || labels[0] !== labels[1])) {
        choices.forEach((row, index) => {
          if (!labels[index]) field(row, "text").value = labels[1 - index] === "true" ? "False" :
            labels[1 - index] === "false" ? "True" : ["True", "False"][index];
          field(row, "text").readOnly = true;
        });
      } else {
        status.textContent = "Saved answers were preserved. Switch to Single Choice and back to True/False to convert them with confirmation.";
      }
    }
    add.addEventListener("click", addOption);
    type.addEventListener("change", changeType);
    sync();
    const editor = { addOption, removeOption, changeType, activeRows };
    editors.set(form, editor);
    return editor;
  }

  if (typeof document !== "undefined") {
    const start = () => document.querySelectorAll("[data-question-editor]").forEach(initQuestionEditor);
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
    else start();
  }
  if (typeof module !== "undefined" && module.exports) module.exports = { initQuestionEditor };
})();
