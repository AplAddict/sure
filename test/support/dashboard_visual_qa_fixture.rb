# Synthetic, network-free dashboard fixture for browser QA. It deliberately uses
# non-real securities and persisted research records: dashboard rendering should
# consume local evidence only and must not depend on providers or a member's
# production saved layout.
module DashboardVisualQaFixture
  QA_ACCOUNT_USD = "QA Visual USD Brokerage".freeze
  QA_PAGE = "QA Visual Dashboard".freeze
  QA_ARTICLES = [
    [ "ZZVQAALPHA", "QA Alpha beats fictional estimates", "bullish", 15_000 ],
    [ "ZZVQABETA", "QA Beta faces fictional headwinds", "bearish", 8_000 ],
    [ "ZZVQAGAMMA", "QA Gamma stays neutral", "neutral", 2_000 ]
  ].freeze

  def build_dashboard_visual_qa_fixture!(user:)
    raise "dashboard visual QA fixtures are test-only" unless Rails.env.test?

    @dashboard_visual_qa_network_guard = WebMock::Config.instance.allow_net_connect
    WebMock.disable_net_connect!(allow_localhost: true)

    usd = user.family.accounts.create!(
      name: QA_ACCOUNT_USD, owner: user, accountable: Investment.new,
      balance: 25_000, cash_balance: 2_000, currency: "USD"
    )
    QA_ARTICLES.each do |ticker, title, tone, amount|
      security = Security.create!(ticker: ticker, name: "#{ticker} Synthetic Security", exchange_mic: "XNAS")
      usd.holdings.create!(security: security, date: Date.current, qty: 10, price: amount / 10, amount: amount, currency: "USD")
      create_current_qa_news!(security:, title:, tone:)
    end

    page = user.create_dashboard_page!(QA_PAGE, template_key: "blank")
    %w[portfolio.pulse review.needs_review portfolio.day_movers portfolio.cash_liquidity portfolio.largest_position portfolio.top_holdings research.news].each do |key|
      settings = key == "research.news" ? { "filter" => "sentiment", "rows" => 5 } : nil
      user.add_dashboard_widget!(page.fetch("id"), key, settings:)
    end
    user.select_dashboard_page!(page.fetch("id"))
    { page_id: page.fetch("id") }
  end

  def restore_dashboard_visual_qa_network_guard!
    WebMock.allow_net_connect! if @dashboard_visual_qa_network_guard
    WebMock.disable_net_connect! unless @dashboard_visual_qa_network_guard
  end

  private

  def create_current_qa_news!(security:, title:, tone:)
    source = "Dashboard QA Wire"
    digest = Digest::SHA256.hexdigest([ source, title ].join("\u0000"))
    SecurityResearchSnapshot.create!(
      security:, status: "current", generated_at: Time.current, imported_at: Time.current,
      payload: { "news" => [
        { "title" => title, "link" => "https://example.test/#{security.ticker.downcase}", "source" => source,
          "description" => "Synthetic dashboard QA article", "published" => Time.current.iso8601, "tickers" => [ security.ticker ] }
      ] }
    )
    SecurityHeadlineAnalysis.create!(
      security:, status: "current", source_digest: Digest::SHA256.hexdigest("qa-#{security.ticker}"), analyzed_at: Time.current,
      payload: { "articleTones" => { digest => { "tone" => tone } } }
    )
  end
end
