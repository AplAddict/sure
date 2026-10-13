import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "scope",
    "accountField",
    "securityField",
    "popover",
    "trigger",
  ];

  connect() {
    this.syncScope();
    this.syncExpanded();
  }

  scopeChanged() {
    this.syncScope();
  }

  toggle() {
    this.syncExpanded();
  }

  close(event) {
    if (!this.hasPopoverTarget || !this.popoverTarget.open) return;

    event.preventDefault();
    event.stopPropagation();
    this.popoverTarget.open = false;
    this.syncExpanded();
    this.triggerTarget.focus();
  }

  syncExpanded() {
    if (!this.hasPopoverTarget || !this.hasTriggerTarget) return;

    this.triggerTarget.setAttribute(
      "aria-expanded",
      this.popoverTarget.open.toString(),
    );
  }

  syncScope() {
    if (!this.hasScopeTarget) return;

    this.syncIdentifier(
      this.accountFieldTargets,
      this.scopeTarget.value === "account",
    );
    this.syncIdentifier(
      this.securityFieldTargets,
      this.scopeTarget.value === "security",
    );
  }

  syncIdentifier(wrappers, relevant) {
    wrappers.forEach((wrapper) => {
      wrapper.classList.toggle("hidden", !relevant);
      const field = wrapper.querySelector("select, input");
      if (!field) return;

      field.disabled = !relevant;
      if (!relevant) field.value = "";
    });
  }
}
