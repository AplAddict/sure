import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { afterEach, test } from "node:test";

const controllerPath = new URL(
  "../../app/javascript/controllers/dashboard_pages_controller.js",
  import.meta.url,
);
const source = await readFile(controllerPath, "utf8");
const testableSource = `${source
  .replace(
    'import { Controller } from "@hotwired/stimulus";\n',
    "class Controller {}\n",
  )
  .replace(
    "export default class extends Controller",
    "class DashboardPagesController extends Controller",
  )}\nexport default DashboardPagesController;`;
const { default: DashboardPagesController } = await import(
  `data:text/javascript;base64,${Buffer.from(testableSource).toString("base64")}`
);

const originalGlobals = new Map(
  ["document", "fetch", "window"].map((name) => [name, globalThis[name]]),
);

afterEach(() => {
  for (const [name, value] of originalGlobals) {
    if (value === undefined) delete globalThis[name];
    else globalThis[name] = value;
  }
});

function errorTarget({ scope = "local", dialog = null, inView = true } = {}) {
  const classes = new Set(["hidden"]);
  const target = {
    dataset: { errorScope: scope },
    textContent: "",
    announcements: 0,
    scrollCalls: [],
    focusCalls: [],
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
      contains: (name) => classes.has(name),
    },
    closest: (selector) => (selector === "dialog[open]" ? dialog : null),
    getBoundingClientRect: () =>
      inView ? { top: 10, bottom: 20 } : { top: 200, bottom: 220 },
    scrollIntoView(options) {
      this.scrollCalls.push(options);
    },
    focus(options) {
      this.focusCalls.push(options);
    },
  };
  let text = "";
  Object.defineProperty(target, "textContent", {
    get: () => text,
    set: (value) => {
      text = value;
      if (value) target.announcements += 1;
    },
  });
  return target;
}

function controllerWith(...targets) {
  const controller = Object.create(DashboardPagesController.prototype);
  controller.errorTargets = targets;
  return controller;
}

function installRequestGlobals(targetById = {}) {
  globalThis.document = {
    getElementById: (id) => targetById[id] || null,
    querySelector: () => null,
  };
  globalThis.window = {
    confirm: () => true,
    innerHeight: 100,
    Turbo: { visit: () => {} },
  };
}

function actionButton(dataset, owner) {
  return {
    dataset,
    disabled: false,
    closest(selector) {
      if (selector === "[data-dashboard-widget-add-form]") return null;
      if (selector === "[data-error-target-id]") return owner;
      if (selector === "dialog") return null;
      return null;
    },
  };
}

test("selectPage keeps a PATCH failure visible and lets the next click use the GET href", async () => {
  const target = errorTarget();
  const controller = controllerWith(target);
  const visits = [];
  let requests = 0;
  let prevented = 0;
  const link = {
    href: "/?page=investing",
    dataset: { dashboardPageKey: "investing" },
    closest: () => null,
  };

  controller.currentPageUrlValue = "/dashboard/pages/current";
  controller._visit = (url) => visits.push(url);
  installRequestGlobals();
  globalThis.fetch = async () => {
    requests += 1;
    throw new Error("Page selection failed");
  };

  const event = {
    currentTarget: link,
    preventDefault: () => {
      prevented += 1;
    },
  };
  await controller.selectPage(event);
  await controller.selectPage(event);

  assert.equal(prevented, 1);
  assert.equal(requests, 1);
  assert.equal(target.textContent, "Page selection failed");
  assert.equal(target.classList.contains("hidden"), false);
  assert.deepEqual(visits, []);
});

test("add, duplicate, remove, and invalid settings errors use their explicit page alert", async () => {
  const target = errorTarget({ scope: "page" });
  const controller = controllerWith(target);
  const owner = { dataset: { errorTargetId: "dashboard-page-alert" } };
  installRequestGlobals({ "dashboard-page-alert": target });
  globalThis.fetch = async () => {
    throw new Error("Action failed");
  };

  await controller.addWidget({
    currentTarget: actionButton(
      {
        url: "/widgets",
        widgetKey: "home.net_worth",
        duplicateType: "false",
      },
      owner,
    ),
  });
  assert.equal(target.textContent, "Action failed");

  await controller.duplicateWidget({
    currentTarget: actionButton(
      {
        url: "/widgets",
        widgetKey: "home.net_worth",
        widgetSettings: "{}",
      },
      owner,
    ),
  });
  assert.equal(target.textContent, "Action failed");

  await controller.removeWidget({
    currentTarget: actionButton(
      { url: "/widgets/1", confirm: "Remove?" },
      owner,
    ),
  });
  assert.equal(target.textContent, "Action failed");

  const invalidButton = actionButton(
    { widgetSettings: "{", invalidSettingsMessage: "Invalid settings" },
    owner,
  );
  await controller.duplicateWidget({ currentTarget: invalidButton });
  assert.equal(target.textContent, "Invalid settings");
  assert.equal(target.announcements, 4);
});

test("one deterministic alert receives each fallback message", () => {
  const localTarget = errorTarget();
  const pageTarget = errorTarget({ scope: "page" });
  const controller = controllerWith(localTarget, pageTarget);
  installRequestGlobals();

  controller._showError("Only once");

  assert.equal(localTarget.textContent, "Only once");
  assert.equal(localTarget.announcements, 1);
  assert.equal(pageTarget.textContent, "");
  assert.equal(pageTarget.announcements, 0);
});

test("an action inside a dialog falls back to that dialog alert before controller alerts", () => {
  const localTarget = errorTarget();
  const modalTarget = errorTarget();
  const dialog = { querySelector: () => modalTarget };
  const action = {
    closest(selector) {
      if (selector === "[data-error-target-id]")
        return { dataset: { errorTargetId: "missing-alert" } };
      if (selector === "dialog") return dialog;
      return null;
    },
  };
  const controller = controllerWith(localTarget);
  installRequestGlobals();

  controller._showError("Dialog failed", controller._errorTargetFor(action));

  assert.equal(modalTarget.textContent, "Dialog failed");
  assert.equal(localTarget.textContent, "");
});

test("errors scroll without focus except for an out-of-view open-dialog alert", () => {
  const dialog = { getBoundingClientRect: () => ({ top: 0, bottom: 100 }) };
  const modalTarget = errorTarget({ dialog, inView: false });
  const pageTarget = errorTarget({ scope: "page", inView: false });
  const controller = controllerWith(pageTarget);
  installRequestGlobals();

  controller._showError("Modal failed", modalTarget);
  controller._showError("Page failed", pageTarget);

  assert.deepEqual(modalTarget.scrollCalls, [{ block: "nearest" }]);
  assert.deepEqual(modalTarget.focusCalls, [{ preventScroll: true }]);
  assert.deepEqual(pageTarget.scrollCalls, [{ block: "nearest" }]);
  assert.deepEqual(pageTarget.focusCalls, []);
});

function reorderFixture() {
  const target = errorTarget();
  const buttons = [{ disabled: false }, { disabled: false }];
  const rows = ["investments", "planning"].map((pageId) => ({
    dataset: { pageId },
  }));
  const parent = {
    appendChild(row) {
      rows.splice(rows.indexOf(row), 1);
      rows.push(row);
    },
  };
  rows.forEach((row) => {
    row.parentElement = parent;
  });
  const owner = { dataset: { errorTargetId: "reorder-error" } };
  const container = {
    dataset: { orderUrl: "/dashboard/pages/order" },
    closest: (selector) =>
      selector === "[data-error-target-id]" ? owner : null,
    querySelectorAll(selector) {
      return selector.includes("pageRow") ? rows : buttons;
    },
  };
  return { buttons, container, rows, target };
}

test("a reorder failure restores the confirmed order without navigating or wiping its message", async () => {
  const { buttons, container, rows, target } = reorderFixture();
  const controller = controllerWith(target);
  const visits = [];
  rows.reverse();
  controller.returnUrlValue = "/?page=planning";
  controller._visit = (url) => visits.push(url);
  installRequestGlobals({ "reorder-error": target });
  globalThis.fetch = async () => {
    throw new Error("Order failed");
  };

  await controller._persistPageOrder(container, ["investments", "planning"]);

  assert.deepEqual(
    rows.map((row) => row.dataset.pageId),
    ["investments", "planning"],
  );
  assert.equal(target.textContent, "Order failed");
  assert.equal(target.classList.contains("hidden"), false);
  assert.deepEqual(visits, []);
  assert.deepEqual(
    buttons.map((button) => button.disabled),
    [false, false],
  );
});

test("page reorder allows only one in-flight request", async () => {
  const { buttons, container, target } = reorderFixture();
  const controller = controllerWith(target);
  let requests = 0;
  let resolveRequest;
  installRequestGlobals({ "reorder-error": target });
  globalThis.fetch = () => {
    requests += 1;
    return new Promise((resolve) => {
      resolveRequest = resolve;
    });
  };

  const first = controller._persistPageOrder(container);
  const second = controller._persistPageOrder(container);

  assert.equal(requests, 1);
  assert.deepEqual(
    buttons.map((button) => button.disabled),
    [true, true],
  );
  resolveRequest({ ok: true, status: 204 });
  await Promise.all([first, second]);
  assert.equal(requests, 1);
  assert.deepEqual(
    buttons.map((button) => button.disabled),
    [false, false],
  );
});
