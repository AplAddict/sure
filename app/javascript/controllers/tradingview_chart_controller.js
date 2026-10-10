import { Controller } from "@hotwired/stimulus";

// Gives the embedded TradingView chart a browser-native fullscreen mode.
export default class extends Controller {
  static targets = ["chart", "button"];

  connect() {
    this.onFullscreenChange = this.updateButton.bind(this);
    document.addEventListener("fullscreenchange", this.onFullscreenChange);
    this.updateButton();
  }

  disconnect() {
    document.removeEventListener("fullscreenchange", this.onFullscreenChange);
  }

  async toggle() {
    try {
      if (document.fullscreenElement === this.chartTarget) {
        await document.exitFullscreen();
      } else {
        await this.chartTarget.requestFullscreen();
      }
    } catch (_) {
      // Browsers can deny fullscreen in restricted embedded contexts.
      this.buttonTarget.textContent = "Fullscreen unavailable";
    }
  }

  updateButton() {
    this.buttonTarget.textContent = document.fullscreenElement === this.chartTarget ? "Exit full screen" : "Full screen";
  }
}
