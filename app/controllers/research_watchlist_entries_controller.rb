class ResearchWatchlistEntriesController < ApplicationController
  before_action :set_entry, only: %i[update destroy]

  def index
    load_entries
    @entry = ResearchWatchlistEntry.new
  end

  def create
    @entry = Current.user.research_watchlist_entries.new(entry_params.except(:ticker))
    # Only an already-known security can be queued; this never creates placeholder securities.
    ticker = entry_params[:ticker].to_s.strip.upcase
    @entry.security = Security.where(ticker: ticker).order(:created_at).first if ticker.present?

    if @entry.security.nil?
      @entry.errors.add(:base, "Ticker not found. Search it in Ticker research first, then add it here.")
    elsif @entry.save
      return redirect_to research_watchlist_entries_path, notice: "#{ticker} added to your research watchlist."
    end

    load_entries
    render :index, status: :unprocessable_entity
  end

  def update
    if @entry.update(entry_params.except(:ticker))
      redirect_to research_watchlist_entries_path, notice: "Watchlist entry updated."
    else
      load_entries
      @entry_errors = @entry
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    @entry.destroy!
    redirect_to research_watchlist_entries_path, notice: "Removed from your research watchlist."
  end

  private
    def set_entry
      @entry = Current.user.research_watchlist_entries.find(params[:id])
    end

    def load_entries
      @entries = Current.user.research_watchlist_entries.includes(:security).order(:priority, created_at: :desc)
      @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ "Research Watchlist", nil ] ]
    end

    def entry_params
      params.require(:research_watchlist_entry).permit(:ticker, :status, :priority, :thesis)
    end
end
