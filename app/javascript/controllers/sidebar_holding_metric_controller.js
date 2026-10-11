import { Controller } from "@hotwired/stimulus"

// Switches the right-side value in the Holdings sidebar without fetching or
// changing the holding scope. Each row carries server-formatted, sourced values.
export default class extends Controller {
  static targets = ["selector", "value"]

  connect() {
    this.update()
  }

  update() {
    const metric = this.selectorTarget.value

    this.valueTargets.forEach((element) => {
      const value = JSON.parse(element.dataset.sidebarHoldingMetricValues)[metric]
      element.textContent = value.text
      element.classList.remove("text-primary", "text-secondary", "text-success", "text-destructive")
      element.classList.add(value.tone)
    })
  }
}
