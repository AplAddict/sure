# Backwards-compatible entry point for saved links and insight actions. The
# tax workspace now contains the harvest review alongside per-lot analysis.
class TaxLossHarvestsController < ApplicationController
  def show
    redirect_to tax_lot_review_path(tab: "harvest")
  end
end
