import { Controller } from "@hotwired/stimulus";

// Links whose saved-page PATCH failed in this document. Kept in memory (not in a
// data attribute) so a Turbo snapshot restore cannot freeze a transient failure.
const failedPageLinks = new WeakSet();

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
    orderError: String,
  };

  async selectPage(event) {
    const link = event.currentTarget;
    if (failedPageLinks.has(link)) return;

    event.preventDefault();
    await this._request(this.currentPageUrlValue, {
      method: "PATCH",
      body: { page_id: link.dataset.dashboardPageKey },
      errorTarget: this._errorTargetFor(link),
      success: () => this._visit(link.href),
      failure: () => {
        failedPageLinks.add(link);
      },
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
      errorTarget: this._errorTargetFor(button),
      success: () => this._visit(this.returnUrlValue),
    });
  }

  async duplicateWidget(event) {
    const button = event.currentTarget;
    let settings = {};
    try {
      settings = JSON.parse(button.dataset.widgetSettings || "{}");
    } catch (_error) {
      this._showError(
        button.dataset.invalidSettingsMessage,
        this._errorTargetFor(button),
      );
      return;
    }

    await this._request(button.dataset.url, {
      method: "POST",
      body: {
        widget: {
          key: button.dataset.widgetKey,
          settings,
          allow_duplicate: true,
        },
      },
      button,
      errorTarget: this._errorTargetFor(button),
      success: () => this._visit(this.returnUrlValue),
    });
  }

  async removeWidget(event) {
    const button = event.currentTarget;
    if (!window.confirm(button.dataset.confirm)) return;

    await this._request(button.dataset.url, {
      method: "DELETE",
      button,
      errorTarget: this._errorTargetFor(button),
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
    await this._manageRequest(form, form.dataset.url, {
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
    const scope = form.elements.namedItem("scope");
    if (scope) {
      scope.value = scope.dataset.defaultValue || "";
      scope.dispatchEvent(new Event("change", { bubbles: true }));
    }
    form.querySelectorAll("[data-default-value]").forEach((field) => {
      if (field !== scope) field.value = field.dataset.defaultValue || "";
    });
    await this._persistWidgetSettings(form);
  }

  async _persistWidgetSettings(form) {
    const settings = this._settingsFromForm(form);

    await this._request(form.dataset.url, {
      method: "PATCH",
      body: { widget: { settings } },
      errorTarget: form.querySelector("[data-dashboard-pages-target='error']"),
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

    const excludedIdentifiers =
      settings.scope === "overall"
        ? ["account_id", "security_id"]
        : settings.scope === "account"
          ? ["security_id"]
          : settings.scope === "security"
            ? ["account_id"]
            : [];

    return Object.fromEntries(
      Object.entries(settings).filter(
        ([key]) => !excludedIdentifiers.includes(key),
      ),
    );
  }

  async previewDraft(event) {
    event.preventDefault();
    const form = event.currentTarget;
    let draft;
    try {
      draft = JSON.parse(this.draftInputTarget.value);
    } catch (_error) {
      this._showError(
        this.draftInputTarget.dataset.invalidMessage,
        this._errorTargetFor(form),
      );
      return;
    }

    await this._manageRequest(form, form.dataset.url, {
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
    const draft = this._validatedDraft(button);
    if (!draft || !window.confirm(button.dataset.confirm)) return;

    await this._manageRequest(button, button.dataset.url, {
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
    const draft = this._validatedDraft(button);
    if (!draft || !window.confirm(button.dataset.confirm)) return;

    await this._manageRequest(button, button.dataset.url, {
      method: "PATCH",
      body: { draft },
      button,
      success: () => this._visit(this.returnUrlValue),
    });
  }

  _validatedDraft(source) {
    try {
      return JSON.parse(this.draftValidatedTarget.value);
    } catch (_error) {
      this._showError(
        this.draftValidatedTarget.dataset.invalidMessage,
        this._errorTargetFor(source),
      );
      return null;
    }
  }

  async restoreInvestments(event) {
    const button = event.currentTarget;
    await this._manageRequest(button, button.dataset.url, {
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
    await this._manageRequest(form, form.dataset.url, {
      method: "PATCH",
      body: { page: { name } },
      success: () => this._visit(this.returnUrlValue),
    });
  }

  async deletePage(event) {
    const button = event.currentTarget;
    if (!window.confirm(button.dataset.confirm)) return;

    await this._manageRequest(button, button.dataset.url, {
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

    const container = row.closest("[data-order-url]");
    if (!container) {
      this._showError(
        this.orderErrorValue,
        this._errorTargetFor(event.currentTarget),
      );
      return;
    }
    if (this._pageOrderRequests?.has(container)) return;

    const confirmedIds = this._pageOrderIds(container);
    row.parentElement.insertBefore(row, previous);
    this._persistPageOrder(container, confirmedIds);
  }

  movePageDown(event) {
    const row = event.currentTarget.closest(
      "[data-dashboard-pages-target='pageRow']",
    );
    const next = row?.nextElementSibling;
    if (!row || !next || row.dataset.pageId === "home") return;

    const container = row.closest("[data-order-url]");
    if (!container) {
      this._showError(
        this.orderErrorValue,
        this._errorTargetFor(event.currentTarget),
      );
      return;
    }
    if (this._pageOrderRequests?.has(container)) return;

    const confirmedIds = this._pageOrderIds(container);
    row.parentElement.insertBefore(next, row);
    this._persistPageOrder(container, confirmedIds);
  }

  async _persistPageOrder(container, confirmedIds) {
    this._pageOrderRequests ||= new WeakSet();
    if (this._pageOrderRequests.has(container)) return;

    const ids = this._pageOrderIds(container);
    const previousIds = confirmedIds || ids;
    this._pageOrderRequests.add(container);
    this._setPageMoveButtonsDisabled(container, true);

    try {
      await this._manageRequest(container, container.dataset.orderUrl, {
        method: "PATCH",
        body: { page_ids: ids },
        success: () => this._visit(this.returnUrlValue),
        failure: () => this._restorePageOrder(container, previousIds),
      });
    } finally {
      this._pageOrderRequests.delete(container);
      this._setPageMoveButtonsDisabled(container, false);
    }
  }

  _pageOrderIds(container) {
    return Array.from(
      container.querySelectorAll("[data-dashboard-pages-target='pageRow']"),
    ).map((item) => item.dataset.pageId);
  }

  _restorePageOrder(container, ids) {
    const rowsById = new Map(
      Array.from(
        container.querySelectorAll("[data-dashboard-pages-target='pageRow']"),
      ).map((row) => [row.dataset.pageId, row]),
    );
    ids.forEach((id) => {
      const row = rowsById.get(id);
      if (row) row.parentElement.appendChild(row);
    });
  }

  _setPageMoveButtonsDisabled(container, disabled) {
    container
      .querySelectorAll(
        "[data-action~='click->dashboard-pages#movePageUp'], [data-action~='click->dashboard-pages#movePageDown']",
      )
      .forEach((button) => {
        button.disabled = disabled;
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

  _manageRequest(source, url, options) {
    return this._request(url, {
      ...options,
      errorTarget: this._errorTargetFor(source),
    });
  }

  async _request(url, { method, body, button, errorTarget, success, failure }) {
    this._clearError(errorTarget);
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
      this._showError(error.message, errorTarget);
      failure?.();
    } finally {
      if (button) button.disabled = false;
    }
  }

  _csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || "";
  }

  _clearError(errorTarget) {
    const target = this._errorTargets(errorTarget)[0];
    if (!target) return;

    target.textContent = "";
    target.classList.add("hidden");
  }

  _showError(message, errorTarget) {
    const target = this._errorTargets(errorTarget)[0];
    if (!target) return;

    target.textContent = message;
    target.classList.remove("hidden");

    const dialog = target.closest?.("dialog[open]");
    const wasInView = this._isInView(target, dialog);
    target.scrollIntoView?.({ block: "nearest" });
    if (dialog && !wasInView) target.focus?.({ preventScroll: true });
  }

  _isInView(target, dialog) {
    if (!target.getBoundingClientRect) return true;

    const targetRect = target.getBoundingClientRect();
    const boundary = dialog?.getBoundingClientRect?.() || {
      top: 0,
      bottom: window.innerHeight,
    };
    return (
      targetRect.top >= boundary.top && targetRect.bottom <= boundary.bottom
    );
  }

  _errorTargetFor(element) {
    const owner = element?.closest("[data-error-target-id]");
    const targetId = owner?.dataset.errorTargetId;
    const explicitTarget = targetId ? document.getElementById(targetId) : null;
    return this._errorTargets(explicitTarget, element)[0] || null;
  }

  _errorTargets(errorTarget, element) {
    if (errorTarget) return [errorTarget];

    const dialog = element?.closest("dialog");
    const dialogTarget = dialog?.querySelector("[role='alert']");
    if (dialogTarget) return [dialogTarget];

    const localTarget = this.errorTargets.find(
      (target) => target.dataset.errorScope === "local",
    );
    if (localTarget) return [localTarget];

    const pageTarget = this.errorTargets.find(
      (target) => target.dataset.errorScope === "page",
    );
    return pageTarget ? [pageTarget] : [];
  }
}
