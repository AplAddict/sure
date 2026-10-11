import { Controller } from "@hotwired/stimulus";

// Composer menus for the AI chat: quick prompts (⌘), @mentions, and time ranges (+).
// Everything inserted is plain text the user can edit; nothing is sent until they submit.
export default class extends Controller {
  static targets = ["input", "menu", "filter", "mentionList", "mentionStatus"];
  static values = { url: String };

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

  insert(event) {
    event.preventDefault();
    const text = event.params.text;
    if (!text) return;
    this.#insertAtCursor(event.params.mode === "replace" ? text : `${text} `, event.params.mode === "replace");
    this.#closeAll();
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

  #insertAtCursor(text, replace) {
    const input = this.inputTarget;
    if (replace) {
      input.value = text;
    } else {
      const start = input.selectionStart ?? input.value.length;
      const end = input.selectionEnd ?? input.value.length;
      const before = input.value.slice(0, start);
      const needsSpace = before.length > 0 && !/\s$/.test(before);
      input.value = `${before}${needsSpace ? " " : ""}${text}${input.value.slice(end)}`;
      const caret = (before + (needsSpace ? " " : "") + text).length;
      input.setSelectionRange(caret, caret);
    }
    input.focus();
    // Let the chat controller resize the box and enable the send button.
    input.dispatchEvent(new Event("input", { bubbles: true }));
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
          this.#insertAtCursor(`${name} `, false);
          this.#closeAll();
        });
        list.appendChild(button);
        shown += 1;
      }
    }

    this.mentionStatusTarget.textContent = shown === 0 ? this.mentionStatusTarget.dataset.empty : "";
  }
}
