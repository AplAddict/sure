class ResearchWatchlistEntriesController < ApplicationController
  before_action :set_entry, only: %i[update destroy]

  def index
    load_entries
    @entry = ResearchWatchlistEntry.new
  end

  def create
    @entry = Current.user.research_watchlist_entries.new(entry_params.except(:ticker))
    ticker = entry_params[:ticker].to_s.strip.upcase

    # Any real ticker can be queued. An unseen one is resolved against the
    # market source as a research-only security (never held, priced or imported
    # as a normal security), and its fundamentals are fetched in the background.
    security, status = TickerResearchGenerateJob.resolve_security(ticker)
    case status
    when :invalid then @entry.errors.add(:base, "\"#{ticker}\" doesn't look like a ticker symbol.")
    when :unknown then @entry.errors.add(:base, "#{ticker} isn't a known ticker. Check the symbol and try again.")
    when :unavailable then @entry.errors.add(:base, "#{ticker} couldn't be checked right now, so nothing was added. Try again in a moment.")
    end

    if security
      @entry.security = security
      if @entry.save
        TickerResearchGenerateJob.perform_later(ticker, enrich_only: true) if status == :created
        return redirect_to research_watchlist_entries_path, notice: "#{ticker} added to your research watchlist."
      end
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
