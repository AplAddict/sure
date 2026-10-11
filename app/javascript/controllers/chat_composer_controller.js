import { Controller } from "@hotwired/stimulus";

// Composer menus for the AI chat: quick prompts (⌘), @mentions, and time ranges (+).
// Everything inserted is plain text the user can edit; nothing is sent until they submit.
export default class extends Controller {
  static targets = ["input", "menu", "filter", "mentionList", "mentionStatus", "chips", "chipTemplate", "filePicker", "fileStatus"];
  static values = { url: String, removeLabel: { type: String, default: "Remove" } };

  connect() {
    this.loaded = false;
    this.options = null;
    this.outsideClick = (event) => {
      if (!this.element.contains(event.target)) this.#closeAll();
    };
    document.addEventListener("click", this.outsideClick);
  }

  disconnect() {
    document.removeEventListener("click", this.outsideClick);
  }

  toggle(event) {
    event.preventDefault();
    const name = event.params.menu;
    const menu = this.menuTargets.find((el) => el.dataset.menu === name);
    if (!menu) return;

    const willOpen = menu.classList.contains("hidden");
    this.#closeAll();
    if (!willOpen) return;

    menu.classList.remove("hidden");
    event.currentTarget.setAttribute("aria-expanded", "true");
    if (name === "mentions") this.#loadMentions();
  }

  // Menu items become bubbles. Nothing reaches the message until the form is sent.
  insert(event) {
    event.preventDefault();
    const { text, kind } = event.params;
    if (!text) return;
    this.#addChip(kind || "prompt", text);
    this.#closeAll();
  }

  removeChip(event) {
    event.preventDefault();
    const chip = event.currentTarget.closest("[data-composer-chip]");
    if (!chip) return;
    chip.remove();
    this.#chipsChanged();
    this.inputTarget.focus();
  }

  // Joins the bubbles and the typed text into the one message the server receives:
  // quick questions first, then what was typed, then mentions and time ranges.
  serialize() {
    const chips = this.#chips();
    if (chips.length === 0) return;

    const textChips = chips.filter((c) => c.dataset.kind !== "file");
    if (textChips.length === 0) return;

    const byKind = (kind) => textChips.filter((c) => c.dataset.kind === kind).map((c) => c.dataset.text);
    const typed = this.inputTarget.value.trim();
    const parts = [...byKind("prompt"), typed, ...byKind("mention"), ...byKind("range")].filter(Boolean);

    this.inputTarget.value = parts.join(" ");
    textChips.forEach((chip) => chip.remove());
  }

  pickFile(event) {
    event.preventDefault();
    this.#closeAll();
    if (this.hasFilePickerTarget) this.filePickerTarget.click();
  }

  // The chosen <input> itself moves into its bubble (and a fresh picker takes its place), so a
  // bubble always owns exactly one file and removing it removes the file from the upload.
  fileChosen(event) {
    const picker = event.currentTarget;
    const file = picker.files && picker.files[0];
    if (!file) return;

    const data = picker.dataset;
    const maxFiles = Number(data.maxFiles || 3);
    const maxBytes = Number(data.maxBytes || 10 * 1024 * 1024);
    const attached = this.#chips().filter((c) => c.dataset.kind === "file").length;

    const reject = (message) => {
      this.#setFileStatus(message);
      picker.value = "";
    };

    if (!/\.(pdf|csv|txt)$/i.test(file.name)) return reject(data.errorUnsupported);
    if (attached >= maxFiles) return reject(data.errorTooMany);
    if (file.size > maxBytes) return reject(data.errorTooLarge);

    this.#setFileStatus("");
    const fresh = picker.cloneNode(false);
    fresh.value = "";
    picker.after(fresh);

    const chip = this.#addChip("file", file.name, { unique: false });
    if (chip) {
      picker.removeAttribute("data-chat-composer-target");
      picker.removeAttribute("data-action");
      chip.appendChild(picker);
    }
  }

  #setFileStatus(message) {
    if (this.hasFileStatusTarget) this.fileStatusTarget.textContent = message || "";
  }

  // Backspace in an empty box removes the last bubble, like a tag input.
  backspace(event) {
    if (event.key !== "Backspace" || this.inputTarget.value !== "") return;
    const last = this.#chips().at(-1);
    if (!last) return;
    event.preventDefault();
    last.remove();
    this.#chipsChanged();
  }

  filterMentions() {
    this.#renderMentions();
  }

  escape(event) {
    if (event.key === "Escape") this.#closeAll();
  }

  #closeAll() {
    this.menuTargets.forEach((el) => el.classList.add("hidden"));
    this.element
      .querySelectorAll("[aria-expanded='true']")
      .forEach((el) => el.setAttribute("aria-expanded", "false"));
  }

  #chips() {
    return this.hasChipsTarget ? Array.from(this.chipsTarget.querySelectorAll("[data-composer-chip]")) : [];
  }

  #addChip(kind, text, { unique = true } = {}) {
    if (unique && this.#chips().some((c) => c.dataset.kind === kind && c.dataset.text === text)) {
      this.inputTarget.focus();
      return null;
    }

    const template = this.chipTemplateTargets.find((t) => t.dataset.kind === kind);
    if (!template) return null;

    const chip = template.content.firstElementChild.cloneNode(true);
    chip.dataset.kind = kind;
    chip.dataset.text = text;
    chip.querySelector("[data-chip-label]").textContent = text; // data, never markup
    chip.title = text;
    const remove = chip.querySelector("[data-chip-remove]");
    remove.setAttribute("aria-label", `${this.removeLabelValue} ${text}`);
    this.chipsTarget.appendChild(chip);

    this.#chipsChanged();
    this.inputTarget.focus();
    return chip;
  }

  #chipsChanged() {
    // The chat controller listens for input to resize the box and enable Send.
    this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }));
  }

  async #loadMentions() {
    if (this.loaded) return this.#renderMentions();

    this.mentionStatusTarget.textContent = this.mentionStatusTarget.dataset.loading;
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });
      if (!response.ok) throw new Error(String(response.status));
      this.options = await response.json();
      this.loaded = true;
      this.#renderMentions();
    } catch (_error) {
      this.mentionStatusTarget.textContent = this.mentionStatusTarget.dataset.failed;
    }
  }

  #renderMentions() {
    if (!this.options) return;
    const query = this.hasFilterTarget ? this.filterTarget.value.trim().toLowerCase() : "";
    const list = this.mentionListTarget;
    const data = list.dataset;
    list.replaceChildren();

    const match = (names) => (names || []).filter((name) => !query || name.toLowerCase().includes(query));

    // Each section: a titled block with its own divider and a count; accounts split by type.
    const sections = [];
    const groups = this.options.account_groups || {};
    const groupKeys = Object.keys(groups);
    if (groupKeys.length > 0) {
      for (const key of groupKeys) {
        sections.push({ title: data[`label${this.#camel(key)}`] || key, group: data.accountsLabel, names: match(groups[key]) });
      }
    } else {
      sections.push({ title: data.accountsLabel, group: data.accountsLabel, names: match(this.options.accounts) });
    }
    sections.push({ title: data.categoriesLabel, group: data.categoriesLabel, names: match(this.options.categories) });
    sections.push({ title: data.merchantsLabel, group: data.merchantsLabel, names: match(this.options.merchants) });

    let shown = 0;
    let lastGroup = null;
    for (const section of sections) {
      if (section.names.length === 0) continue;

      // A top-level heading when the family of sections changes (Accounts / Categories / Merchants).
      if (section.group !== lastGroup) {
        const top = document.createElement("p");
        top.className = `${lastGroup ? "mt-2 border-t border-secondary pt-2 " : ""}px-3 pb-1 text-xs font-semibold uppercase tracking-wide text-primary`;
        top.textContent = section.group;
        top.setAttribute("role", "presentation");
        list.appendChild(top);
        lastGroup = section.group;
      }

      if (section.title !== section.group) {
        const sub = document.createElement("p");
        sub.className = "px-3 pt-1 pb-0.5 text-xs font-medium text-secondary";
        sub.textContent = `${section.title} (${section.names.length})`;
        sub.setAttribute("role", "presentation");
        list.appendChild(sub);
      }

      for (const name of section.names) {
        const button = document.createElement("button");
        button.type = "button";
        button.setAttribute("role", "option");
        button.className = "block w-full text-left px-3 py-1.5 text-sm text-primary hover:bg-surface-hover rounded-md truncate";
        button.textContent = name; // textContent: names are data, never markup
        button.title = name;
        button.addEventListener("click", () => {
          this.#addChip("mention", name);
          this.#closeAll();
        });
        list.appendChild(button);
        shown += 1;
      }
    }

    this.mentionStatusTarget.textContent = shown === 0 ? this.mentionStatusTarget.dataset.empty : "";
  }

  #camel(key) {
    return key.replace(/(^|_)([a-z])/g, (_m, _s, c) => c.toUpperCase());
  }
}
