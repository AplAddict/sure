import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["content", "chevron", "container", "button"];
  static values = {
    sectionKey: String,
    collapsed: Boolean,
    url: String,
  };

  connect() {
    if (this.collapsedValue) {
      this.collapse(false);
    }
  }

  toggle(event) {
    event.preventDefault();
    if (this.collapsedValue) {
      this.expand();
    } else {
      this.collapse();
    }
  }

  handleToggleKeydown(event) {
    // Handle Enter and Space keys for keyboard accessibility
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      event.stopPropagation(); // Prevent section's keyboard handler from firing
      this.toggle(event);
    }
  }

  collapse(persist = true) {
    this.contentTarget.classList.add("hidden");
    this.chevronTarget.classList.add("-rotate-90");
    this.collapsedValue = true;
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", "false");
    }
    if (persist) {
      this.savePreference(true);
    }
  }

  expand() {
    this.contentTarget.classList.remove("hidden");
    this.chevronTarget.classList.remove("-rotate-90");
    this.collapsedValue = false;
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", "true");
    }
    this.savePreference(false);
  }

  async savePreference(collapsed) {
    // Safely obtain CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]');
    if (!csrfToken) {
      console.error(
        "[Dashboard Section] CSRF token not found. Cannot save preferences.",
      );
      return;
    }

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken.content,
        },
        body: JSON.stringify({ widget: { collapsed } }),
      });

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        console.error(
          "[Dashboard Section] Failed to save preferences:",
          response.status,
          errorData,
        );
        window.location.reload();
      }
    } catch (error) {
      console.error(
        "[Dashboard Section] Network error saving preferences:",
        error,
      );
      window.location.reload();
    }
  }
}
