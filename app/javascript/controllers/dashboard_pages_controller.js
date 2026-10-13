import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "error",
    "pageRow",
    "catalogItem",
    "draftInput",
    "draftPreview",
    "draftValidated",
    "draftAccountSelection",
    "draftSecuritySelection",
  ];
  static values = {
    returnUrl: String,
    homeUrl: String,
    currentPageUrl: String,
  };

  async selectPage(event) {
    event.preventDefault();
    const link = event.currentTarget;
    const visit = () => this._visit(link.href);

    await this._request(this.currentPageUrlValue, {
      method: "PATCH",
      body: { page_id: link.dataset.dashboardPageKey },
      success: visit,
      failure: visit,
    });
  }

  async addWidget(event) {
    const button = event.currentTarget;
    const duplicateType = button.dataset.duplicateType === "true";
    if (duplicateType && !window.confirm(button.dataset.duplicateConfirm))
      return;
    const form = button.closest("[data-dashboard-widget-add-form]");
    const settings = form ? this._settingsFromForm(form) : {};

    await this._request(button.dataset.url, {
      method: "POST",
      body: {
        widget: {
          key: button.dataset.widgetKey,
          settings,
          allow_duplicate: duplicateType,
        },
      },
      button,
      success: () => this._visit(this.returnUrlValue),
    });
  }

  async removeWidget(event) {
    const button = event.currentTarget;
    await this._request(button.dataset.url, {
      method: "DELETE",
      button,
      success: () => this._visit(this.returnUrlValue),
    });
  }

  async createPage(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    const name = data.get("name");
    const template = data.get("template");
    const accountId = data.get("account_id") || null;
    await this._request(form.dataset.url, {
      method: "POST",
      body: { page: { name, template, account_id: accountId } },
      success: (payload) => this._visit(this._pageUrl(payload.page.id)),
    });
  }

  filterCatalog(event) {
    const query = event.currentTarget.value.trim().toLowerCase();
    this.catalogItemTargets.forEach((item) => {
      item.classList.toggle("hidden", !item.dataset.searchText.includes(query));
    });
  }

  stopPropagation(event) {
    event.stopPropagation();
  }

  async saveWidgetSettings(event) {
    event.preventDefault();
    const form = event.currentTarget;
    await this._persistWidgetSettings(form);
  }

  async resetWidgetSettings(event) {
    event.preventDefault();
    const form = event.currentTarget;
    form.querySelectorAll("[data-default-value]").forEach((field) => {
      field.value = field.dataset.defaultValue || "";
    });
    await this._persistWidgetSettings(form);
  }

  async _persistWidgetSettings(form) {
    const settings = this._settingsFromForm(form);

    await this._request(form.dataset.url, {
      method: "PATCH",
      body: { widget: { settings } },
      success: () => this._visit(this.returnUrlValue),
    });
  }

  _settingsFromForm(form) {
    const settings = {};
    new FormData(form).forEach((value, key) => {
      const field = form.elements.namedItem(key);
      if (field?.dataset.settingType === "integer") {
        settings[key] = Number.parseInt(value, 10);
      } else if (field?.dataset.settingType === "identifier") {
        settings[key] = value || null;
      } else {
        settings[key] = value;
      }
    });

    if (settings.scope === "overall") {
      if (Object.hasOwn(settings, "account_id")) settings.account_id = null;
      if (Object.hasOwn(settings, "security_id")) settings.security_id = null;
    } else if (
      settings.scope === "account" &&
      Object.hasOwn(settings, "security_id")
    ) {
      settings.security_id = null;
    } else if (
      settings.scope === "security" &&
      Object.hasOwn(settings, "account_id")
    ) {
      settings.account_id = null;
    }

    return settings;
  }

  async previewDraft(event) {
    event.preventDefault();
    const form = event.currentTarget;
    let draft;
    try {
      draft = JSON.parse(this.draftInputTarget.value);
    } catch (_error) {
      this._showError(this.draftInputTarget.dataset.invalidMessage);
      return;
    }

    await this._request(form.dataset.url, {
      method: "POST",
      body: {
        draft,
        selections: {
          account_id: this.hasDraftAccountSelectionTarget
            ? this.draftAccountSelectionTarget.value || null
            : null,
          security_id: this.hasDraftSecuritySelectionTarget
            ? this.draftSecuritySelectionTarget.value || null
            : null,
        },
      },
      success: (payload) => {
        this.draftValidatedTarget.value = JSON.stringify(
          payload.draft,
          null,
          2,
        );
        this.draftPreviewTarget.classList.remove("hidden");
      },
    });
  }

  async createFromDraft(event) {
    const button = event.currentTarget;
    const draft = this._validatedDraft();
    if (!draft || !window.confirm(button.dataset.confirm)) return;

    await this._request(button.dataset.url, {
      method: "POST",
      body: {
        page: {
          name: draft.name,
          draft,
          provenance: "ai_draft",
        },
      },
      button,
      success: (payload) => this._visit(this._pageUrl(payload.page.id)),
    });
  }

  async applyDraft(event) {
    const button = event.currentTarget;
    const draft = this._validatedDraft();
    if (!draft || !window.confirm(button.dataset.confirm)) return;

    await this._request(button.dataset.url, {
      method: "PATCH",
      body: { draft },
      button,
      success: () => this._visit(this.returnUrlValue),
    });
  }

  _validatedDraft() {
    try {
      return JSON.parse(this.draftValidatedTarget.value);
    } catch (_error) {
      this._showError(this.draftValidatedTarget.dataset.invalidMessage);
      return null;
    }
  }

  async restoreInvestments(event) {
    const button = event.currentTarget;
    await this._request(button.dataset.url, {
      method: "POST",
      body: { page: { id: "investments" } },
      button,
      success: () => this._visit(this._pageUrl("investments")),
    });
  }

  async renamePage(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const name = new FormData(form).get("name");
    await this._request(form.dataset.url, {
      method: "PATCH",
      body: { page: { name } },
      success: () => this._visit(this.returnUrlValue),
    });
  }

  async deletePage(event) {
    const button = event.currentTarget;
    if (!window.confirm(button.dataset.confirm)) return;

    await this._request(button.dataset.url, {
      method: "DELETE",
      button,
      success: () => this._visit(this.homeUrlValue),
    });
  }

  movePageUp(event) {
    const row = event.currentTarget.closest(
      "[data-dashboard-pages-target='pageRow']",
    );
    const previous = row?.previousElementSibling;
    if (!row || !previous || previous.dataset.pageId === "home") return;

    row.parentElement.insertBefore(row, previous);
    this._persistPageOrder(row);
  }

  movePageDown(event) {
    const row = event.currentTarget.closest(
      "[data-dashboard-pages-target='pageRow']",
    );
    const next = row?.nextElementSibling;
    if (!row || !next || row.dataset.pageId === "home") return;

    row.parentElement.insertBefore(next, row);
    this._persistPageOrder(row);
  }

  async _persistPageOrder(row) {
    const container = row.closest("[data-order-url]");
    const ids = this.pageRowTargets.map((item) => item.dataset.pageId);
    await this._request(container.dataset.orderUrl, {
      method: "PATCH",
      body: { page_ids: ids },
      success: () => this._visit(this.returnUrlValue),
      failure: () => this._visit(this.returnUrlValue),
    });
  }

  _pageUrl(pageId) {
    const url = new URL(this.homeUrlValue, window.location.origin);
    url.searchParams.set("page", pageId);
    return url.toString();
  }

  _visit(url) {
    window.Turbo.visit(url);
  }

  async _request(url, { method, body, button, success, failure }) {
    this._clearError();
    if (button) button.disabled = true;

    try {
      const response = await fetch(url, {
        method,
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrfToken(),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
      const payload = response.status === 204 ? {} : await response.json();
      if (!response.ok)
        throw new Error(
          payload.message || `Request failed (${response.status})`,
        );

      success?.(payload);
    } catch (error) {
      this._showError(error.message);
      failure?.();
    } finally {
      if (button) button.disabled = false;
    }
  }

  _csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || "";
  }

  _clearError() {
    if (!this.hasErrorTarget) return;
    this.errorTarget.textContent = "";
    this.errorTarget.classList.add("hidden");
  }

  _showError(message) {
    if (!this.hasErrorTarget) {
      console.error("[Dashboard Pages]", message);
      return;
    }
    this.errorTarget.textContent = message;
    this.errorTarget.classList.remove("hidden");
  }
}
