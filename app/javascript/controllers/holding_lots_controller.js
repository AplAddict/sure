import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="holding-lots"
//
// A position row opens the tax lots beneath it. Lot rows are rendered hidden and
// carry data-lots-for="<position key>"; the button carries the same key. Plain
// attributes keep it working without JavaScript state to lose on a Turbo visit.
export default class extends Controller {
  static targets = ["toggle", "lot"];

  toggle(event) {
    const button = event.currentTarget;
    this.#set(button, button.getAttribute("aria-expanded") !== "true");
  }

  expandAll() {
    this.toggleTargets.forEach((button) => this.#set(button, true));
  }

  collapseAll() {
    this.toggleTargets.forEach((button) => this.#set(button, false));
  }

  #set(button, open) {
    const key = button.dataset.lotsKey;
    button.setAttribute("aria-expanded", open ? "true" : "false");
    const chevron = button.querySelector("[data-chevron]");
    if (chevron) chevron.style.transform = open ? "rotate(90deg)" : "";
    this.lotTargets.filter((row) => row.dataset.lotsFor === key).forEach((row) => { row.hidden = !open; });
  }
}
