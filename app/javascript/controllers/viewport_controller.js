import { Controller } from "@hotwired/stimulus";

// Lives on <html>. Publishes the visible viewport and bottom-navigation CSS
// contracts used by content and fixed overlays:
//   --app-height            the visible viewport height (mobile browser chrome moves it)
//   --bottom-nav-height     the rendered height of the fixed bottom bar,
//                           excluding its safe-area padding
//   --bottom-overlay-offset the bar height plus safe area below fixed overlays
// Content reserves var(--bottom-nav-height) + env(safe-area-inset-bottom), so a
// taller bar (larger text or a wrapped label) never hides the end of the page.
export default class extends Controller {
  static targets = ["bottomNav", "content"];

  connect() {
    this.updateViewport();

    this.boundResize = this.handleResize.bind(this);

    window.addEventListener("resize", this.boundResize);
    window.addEventListener("orientationchange", this.boundResize);
  }

  disconnect() {
    window.removeEventListener("resize", this.boundResize);
    window.removeEventListener("orientationchange", this.boundResize);
    this.stopObservingBottomNav();
  }

  bottomNavTargetConnected(element) {
    this.stopObservingBottomNav();
    this.updateBottomNavHeight(element);
    if (typeof ResizeObserver === "undefined") return;

    this.bottomNavObserver = new ResizeObserver(() =>
      this.updateBottomNavHeight(element),
    );
    this.bottomNavObserver.observe(element);
  }

  bottomNavTargetDisconnected() {
    this.stopObservingBottomNav();
    document.documentElement.style.removeProperty("--bottom-nav-height");
    document.documentElement.style.removeProperty("--bottom-overlay-offset");
    this.contentTargets.forEach((content) => {
      content.style.paddingBottom =
        "calc(var(--bottom-nav-height, 5rem) + env(safe-area-inset-bottom))";
    });
  }

  handleResize() {
    this.updateViewport();
    if (this.hasBottomNavTarget)
      this.updateBottomNavHeight(this.bottomNavTarget);
  }

  updateViewport() {
    const height = window.innerHeight;
    document.documentElement.style.setProperty("--app-height", `${height}px`);
  }

  updateBottomNavHeight(element) {
    // offsetHeight is zero while the bar is display:none (lg and up).
    if (!element.offsetHeight) {
      document.documentElement.style.setProperty("--bottom-nav-height", "0px");
      document.documentElement.style.setProperty(
        "--bottom-overlay-offset",
        "1.5rem",
      );
      this.contentTargets.forEach((content) =>
        content.style.removeProperty("padding-bottom"),
      );
      return;
    }

    const safeArea =
      Number.parseFloat(getComputedStyle(element).paddingBottom) || 0;
    const height = Math.max(element.offsetHeight - safeArea, 0);
    document.documentElement.style.setProperty(
      "--bottom-nav-height",
      `${height}px`,
    );
    document.documentElement.style.setProperty(
      "--bottom-overlay-offset",
      "calc(var(--bottom-nav-height) + env(safe-area-inset-bottom))",
    );
    this.contentTargets.forEach((content) => {
      content.style.paddingBottom =
        "calc(var(--bottom-nav-height, 5rem) + env(safe-area-inset-bottom))";
    });
  }

  stopObservingBottomNav() {
    this.bottomNavObserver?.disconnect();
    this.bottomNavObserver = null;
  }
}
