import { Controller } from "@hotwired/stimulus";

// Composer menus for the AI chat: quick prompts (⌘), @mentions, and time ranges (+).
// Everything inserted is plain text the user can edit; nothing is sent until they submit.
export default class extends Controller {
  static targets = ["input", "menu", "filter", "mentionList", "mentionStatus", "chips", "chipTemplate"];
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

    const byKind = (kind) => chips.filter((c) => c.dataset.kind === kind).map((c) => c.dataset.text);
    const typed = this.inputTarget.value.trim();
    const parts = [...byKind("prompt"), typed, ...byKind("mention"), ...byKind("range")].filter(Boolean);

    this.inputTarget.value = parts.join(" ");
    this.chipsTarget.replaceChildren();
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

  #addChip(kind, text) {
    if (this.#chips().some((c) => c.dataset.kind === kind && c.dataset.text === text)) {
      this.inputTarget.focus();
      return;
    }

    const template = this.chipTemplateTargets.find((t) => t.dataset.kind === kind);
    if (!template) return;

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
    list.replaceChildren();

    let shown = 0;
    for (const [kind, label] of [
      ["accounts", this.mentionListTarget.dataset.accountsLabel],
      ["categories", this.mentionListTarget.dataset.categoriesLabel],
      ["merchants", this.mentionListTarget.dataset.merchantsLabel],
    ]) {
      const names = (this.options[kind] || []).filter((name) => !query || name.toLowerCase().includes(query)).slice(0, 25);
      if (names.length === 0) continue;

      const heading = document.createElement("p");
      heading.className = "px-3 pt-2 pb-1 text-xs font-medium text-secondary";
      heading.textContent = label;
      list.appendChild(heading);

      for (const name of names) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "block w-full text-left px-3 py-1.5 text-sm text-primary hover:bg-surface-hover rounded-md truncate";
        button.textContent = name; // textContent: names are data, never markup
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
}
