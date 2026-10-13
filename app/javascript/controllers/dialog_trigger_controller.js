import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="dialog-trigger"
//
// Opens a native modal <dialog> (DS::Dialog) from a button that lives next to
// it, such as the phone bottom bar's "More" and the dashboard page switcher.
// The DS dialog already owns Escape, outside click and the focus trap; this
// controller adds what a trigger needs: aria-expanded state and returning focus
// to the trigger on every close, including a handoff to a different dialog.
export default class extends Controller {
  static targets = ["trigger", "dialog", "message"];

  connect() {
    this._restoreFocus = this.restoreFocus.bind(this);
    if (this.hasDialogTarget) {
      this.dialogTarget.addEventListener("close", this._restoreFocus);
    }
  }

  disconnect() {
    if (this.hasDialogTarget) {
      this.dialogTarget.removeEventListener("close", this._restoreFocus);
    }
  }

  open() {
    if (!this.hasDialogTarget || this.dialogTarget.open) return;

    this.dialogTarget.showModal();
    if (this.hasTriggerTarget) {
      this.triggerTarget.setAttribute("aria-expanded", "true");
    }
    const focusTarget = this.dialogTarget.querySelector(
      "[aria-current], button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])",
    );
    focusTarget?.focus();
  }

  // Closes this dialog and opens another one by id (for example "Manage pages").
  // When the second dialog closes, focus returns to this controller's trigger.
  handoff(event) {
    this._handoff(event);
  }

  // Opens the handoff dialog at a named control instead of its default first
  // focusable element. The mobile Create action uses this to land directly in
  // the existing create form without introducing a second creation workflow.
  handoffToFocus(event) {
    this._handoff(event, event.currentTarget.dataset.dialogTriggerFocusId);
  }

  _handoff(event, focusId = null) {
    const target = document.getElementById(
      event.currentTarget.dataset.dialogTriggerHandoffId,
    );
    if (!target) {
      if (this.hasMessageTarget) {
        this.messageTarget.textContent =
          event.currentTarget.dataset.missingTargetMessage;
        this.messageTarget.classList.remove("hidden");
      }
      return;
    }
    if (target.open) return;

    if (this.hasMessageTarget) this.messageTarget.classList.add("hidden");
    this.close({ restore: false });
    target.addEventListener("close", this._restoreFocus, { once: true });
    target.showModal();

    const focusTarget = focusId ? document.getElementById(focusId) : null;
    if (focusTarget && target.contains(focusTarget)) {
      focusTarget.focus({ preventScroll: true });
      focusTarget.scrollIntoView({ block: "center" });
    }
  }

  close({ restore = true } = {}) {
    if (!restore) this.skipRestoreFocusOnce = true;
    if (this.dialogTarget.open) this.dialogTarget.close();
    if (restore) this.restoreFocus();
  }

  restoreFocus() {
    if (this.skipRestoreFocusOnce) {
      this.skipRestoreFocusOnce = false;
      return;
    }
    if (!this.hasTriggerTarget) return;

    this.triggerTarget.setAttribute("aria-expanded", "false");
    if (!document.querySelector("dialog:modal")) this.triggerTarget.focus();
  }
}
