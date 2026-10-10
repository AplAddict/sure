import { Controller } from "@hotwired/stimulus";

// Compact global research search: show only on deliberate icon activation.
export default class extends Controller {
  static targets = ["panel", "trigger"];

  connect() {
    this.close();
  }

  toggle(event) {
    event?.preventDefault();
    const opening = this.panelTargets.some((panel) => panel.classList.contains("hidden"));
    opening ? this.open() : this.close();
  }

  open() {
    this.panelTargets.forEach((panel) => panel.classList.remove("hidden"));
    this.triggerTargets.forEach((trigger) => trigger.setAttribute("aria-expanded", "true"));
    const visible = this.panelTargets.find((panel) => panel.offsetParent !== null);
    visible?.querySelector("input[type='search']")?.focus({ preventScroll: true });
  }

  close() {
    this.panelTargets.forEach((panel) => panel.classList.add("hidden"));
    this.triggerTargets.forEach((trigger) => trigger.setAttribute("aria-expanded", "false"));
  }

  keydown(event) {
    if (event.key === "Escape") this.close();
  }
}
