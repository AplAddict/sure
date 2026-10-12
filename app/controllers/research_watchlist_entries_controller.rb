class ResearchWatchlistEntriesController < ApplicationController
  # Adding an unseen ticker makes a live market lookup. Cap those per user so a
  # held key or a script cannot hammer the provider; known tickers cost nothing.
  LOOKUPS_PER_MINUTE = 5

  before_action :set_entry, only: %i[update destroy]

  def index
    load_entries
    @new_entry = ResearchWatchlistEntry.new(status: "watching", priority: 3)
  end

  def create
    ResearchWatchlistEntry.purge_expired!(user: Current.user) # a lapsed leftover must not block a manual add
    @new_entry = Current.user.research_watchlist_entries.new(entry_params.except(:ticker))
    @typed_ticker = entry_params[:ticker].to_s.strip.upcase

    return render_add_error(t(".too_many"), status: :too_many_requests) if lookup_throttled?(@typed_ticker)

    # Any real ticker can be queued. An unseen one is resolved against the
    # market source as a research-only security (never held, priced or imported
    # as a normal security), and its fundamentals are fetched in the background.
    security, status = TickerResearchGenerateJob.resolve_security(@typed_ticker)
    case status
    when :invalid then @new_entry.errors.add(:base, t(".invalid", ticker: @typed_ticker))
    when :unknown then @new_entry.errors.add(:base, t(".unknown", ticker: @typed_ticker))
    when :unavailable then @new_entry.errors.add(:base, t(".unavailable", ticker: @typed_ticker))
    end

    if security
      @new_entry.security = security
      if @new_entry.save
        TickerResearchGenerateJob.perform_later(@typed_ticker, enrich_only: true) if status == :created
        return redirect_to research_watchlist_entries_path, notice: t(".added", ticker: @typed_ticker)
      end
    end

    render_add_error
  end

  def update
    return keep_entry if params[:keep].present?

    # Saving an edit means the member reviewed it, so an assistant entry stops expiring.
    if @entry.update(entry_params.except(:ticker).merge(expires_at: nil))
      redirect_to research_watchlist_entries_path, notice: t(".updated")
    else
      load_entries
      @new_entry = ResearchWatchlistEntry.new(status: "watching", priority: 3)
      @failed_entry = @entry
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    @entry.destroy!
    redirect_to research_watchlist_entries_path, notice: t(".removed")
  end

  private
    def keep_entry
      @entry.keep!
      redirect_to research_watchlist_entries_path, notice: t("research_watchlist_entries.keep.kept", ticker: @entry.security.ticker)
    end

    def set_entry
      @entry = Current.user.research_watchlist_entries.find(params[:id])
    end

    def load_entries
      @entries = Current.user.research_watchlist_entries.active.includes(:security).order(:priority, created_at: :desc)
      @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.research_watchlist"), nil ] ]
    end

    def render_add_error(message = nil, status: :unprocessable_entity)
      @new_entry.errors.add(:base, message) if message
      load_entries
      render :index, status: status
    end

    # Only a ticker we would have to look up externally counts against the cap.
    def lookup_throttled?(ticker)
      return false if ticker.blank? || Security.where("UPPER(ticker) = ?", ticker).exists?

      key = "watchlist_lookups:#{Current.user.id}:#{Time.current.strftime("%Y%m%d%H%M")}"
      count = Rails.cache.read(key).to_i
      return true if count >= LOOKUPS_PER_MINUTE

      Rails.cache.write(key, count + 1, expires_in: 2.minutes)
      false
    end

    def entry_params
      params.require(:research_watchlist_entry).permit(:ticker, :status, :priority, :thesis)
    end
end
