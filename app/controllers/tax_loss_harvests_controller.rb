class TaxLossHarvestsController < ApplicationController
  # Scoped to the signed-in user's accessible accounts, never the whole family:
  # a member must not see what another member holds. Read-only, no params.
  def show
    @harvest = TaxLossHarvest.new(user: Current.user)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.tax_loss_harvests"), nil ] ]
  end
end
