require "test_helper"

class OptionQuotesRefreshJobTest < ActiveJob::TestCase
  Result = OptionQuote::Refresher::Result

  def result(**overrides)
    Result.new(**{ refreshed: 4, failed: 1, skipped_for_rate_limit: false, requests: 5, backed_off: 2, pruned: 3 }.merge(overrides))
  end

  # Stands in for the calendar object that lives in the Options branch.
  Calendar = Struct.new(:open, :final) do
    attr_reader :asked

    def session_open?(now)
      (@asked ||= []) << [ :session_open?, now ]
      open
    end

    def final_window?(now)
      (@asked ||= []) << [ :final_window?, now ]
      final
    end
  end

  def run_job(calendar)
    job = OptionQuotesRefreshJob.new
    job.calendar = calendar
    job.perform_now
  end

  def refresher_runs
    runs = []
    OptionQuote::Refresher.any_instance.stubs(:refresh_all).with { runs << true; true }.returns(result)
    runs
  end

  test "runs on the scheduled queue" do
    assert_equal "scheduled", OptionQuotesRefreshJob.new.queue_name
  end

  test "logs a one-line summary" do
    OptionQuote::Refresher.any_instance.stubs(:refresh_all).returns(result)
    messages = []
    Rails.logger.stubs(:info).with { |message| messages << message.to_s; true }

    run_job(Calendar.new(true, false))

    line = messages.find { |m| m.start_with?("[OptionQuotesRefresh]") }
    assert line, "expected a summary log line"
    assert_no_match(/\n/, line)
    assert_includes line, "refreshed=4"
    assert_includes line, "failed=1"
    assert_includes line, "rate_limited=false"
  end

  test "partial failure and a rate limit do not raise" do
    OptionQuote::Refresher.any_instance.stubs(:refresh_all).returns(result(failed: 9, skipped_for_rate_limit: true))

    assert_nothing_raised { run_job(Calendar.new(true, false)) }
  end

  test "an unexpected refresher error is logged, not raised" do
    OptionQuote::Refresher.any_instance.stubs(:refresh_all).raises(RuntimeError, "boom")
    errors = []
    Rails.logger.stubs(:error).with { |message| errors << message.to_s; true }

    assert_nothing_raised { run_job(Calendar.new(true, false)) }
    assert errors.any? { |m| m.include?("boom") }
  end

  test "a real run over per-item failures completes without raising" do
    provider = mock("provider")
    provider.stubs(:fetch_option_chain).raises(RuntimeError, "kaput")
    OptionQuote::Refresher.stubs(:new).returns(OptionQuote::Refresher.allocate.tap { |r| r.send(:initialize, provider: provider, pause: 0) })
    account = families(:dylan_family).accounts.create!(name: "Job broker", balance: 1, cash_balance: 0, currency: "USD", accountable: Investment.new)
    item = SnaptradeItem.create!(family: families(:dylan_family), name: "Job item", client_id: "j", consumer_key: "j", status: "good")
    sa = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "job-sa", name: "Job", currency: "USD", current_balance: 1,
                                  raw_options_payload: [ { "instrument" => { "symbol" => "NVDA  #{(Date.current + 30).strftime('%y%m%d')}P00215000", "option_type" => "PUT", "expiration_date" => (Date.current + 30).iso8601, "strike_price" => "215", "multiplier" => "100" }, "units" => "-1", "price" => "1", "cost_basis" => "1", "currency" => { "code" => "USD" } } ])
    AccountProvider.create!(account: account, provider: sa)

    assert_nothing_raised { run_job(Calendar.new(true, false)) }
    assert_equal 0, OptionQuote.count
  end

  test "serialises runs: lock until_executed, conflicts logged" do
    options = OptionQuotesRefreshJob.sidekiq_options_hash

    assert_equal "until_executed", options["lock"].to_s
    assert_equal "log", options["on_conflict"].to_s
  end

  test "skips the whole run outside market hours and outside the settle window" do
    runs = refresher_runs
    calendar = Calendar.new(false, false)

    run_job(calendar)

    assert_empty runs
    assert_equal %i[session_open? final_window?], calendar.asked.map(&:first)
  end

  test "runs during the session without consulting the settle window" do
    runs = refresher_runs
    calendar = Calendar.new(true, false)

    run_job(calendar)

    assert_equal [ true ], runs
    assert_equal [ :session_open? ], calendar.asked.map(&:first)
  end

  test "runs in the final settle window even though the session is closed" do
    runs = refresher_runs

    run_job(Calendar.new(false, true))

    assert_equal [ true ], runs
  end

  test "the calendar is asked about the current time" do
    freeze_time do
      calendar = Calendar.new(true, false)
      refresher_runs

      run_job(calendar)

      assert_equal [ [ :session_open?, Time.current ] ], calendar.asked
    end
  end

  test "returns early in development without touching the calendar or the refresher" do
    runs = refresher_runs
    calendar = Calendar.new(true, true)
    Rails.env.stubs(:development?).returns(true)

    run_job(calendar)

    assert_empty runs
    assert_nil calendar.asked
  end

  test "a calendar that raises is logged and never propagates, and nothing is refreshed" do
    runs = refresher_runs
    calendar = Object.new
    calendar.define_singleton_method(:session_open?) { |_now| raise "calendar down" }
    errors = []
    Rails.logger.stubs(:error).with { |message| errors << message.to_s; true }

    assert_nothing_raised { run_job(calendar) }
    assert_empty runs
    assert_equal 1, errors.size
    assert_no_match(/\n/, errors.first)
  end

  test "a missing Options namespace (default calendar) is logged, not raised, and loading never fails" do
    skip "Options namespace is loaded" if defined?(::Options::MarketCalendar)
    runs = refresher_runs

    assert_nothing_raised { OptionQuotesRefreshJob.perform_now }
    assert_empty runs
  end

  test "the default calendar derives both guards from Options::MarketCalendar, resolved at call time" do
    skip "Options namespace is loaded" if defined?(::Options)
    stood_in = true
    calendar = OptionQuotesRefreshJob::DefaultCalendar.new
    monday_1620_et = Time.utc(2026, 10, 12, 20, 20)
    saturday_1620_et = Time.utc(2026, 10, 17, 20, 20)
    market = Module.new do
      define_singleton_method(:session_open?) { |now| now.hour == 15 }
      define_singleton_method(:market_date) { |now| now.in_time_zone("America/New_York").to_date }
      define_singleton_method(:trading_day?) { |date| !date.saturday? && !date.sunday? }
      define_singleton_method(:close_time) { |date| ActiveSupport::TimeZone["America/New_York"].local(date.year, date.month, date.day, 16, 0) }
    end
    Object.const_set(:Options, Module.new)
    ::Options.const_set(:MarketCalendar, market)

    assert calendar.session_open?(Time.utc(2026, 10, 12, 15, 0))
    assert_not calendar.session_open?(Time.utc(2026, 10, 12, 16, 0))
    assert calendar.final_window?(monday_1620_et)
    assert calendar.final_window?(Time.utc(2026, 10, 12, 20, 10)), "16:10 ET is inside 16:20 +/- 10"
    assert calendar.final_window?(Time.utc(2026, 10, 12, 20, 30)), "16:30 ET is inside 16:20 +/- 10"
    assert_not calendar.final_window?(Time.utc(2026, 10, 12, 20, 9))
    assert_not calendar.final_window?(Time.utc(2026, 10, 12, 20, 31))
    assert_not calendar.final_window?(Time.utc(2026, 10, 12, 21, 20)), "21:20 UTC is 17:20 ET in daylight time"
    assert calendar.final_window?(Time.utc(2026, 1, 12, 21, 20)), "21:20 UTC is 16:20 ET in standard time"
    assert_not calendar.final_window?(saturday_1620_et)
  ensure
    Object.send(:remove_const, :Options) if stood_in
  end

  test "default calendar uses the early close settle window instead of 16:20" do
    calendar = OptionQuotesRefreshJob::DefaultCalendar.new

    assert calendar.final_window?(Time.utc(2026, 11, 27, 18, 10)), "13:10 ET starts the settle window"
    assert calendar.final_window?(Time.utc(2026, 11, 27, 18, 20)), "13:20 ET is the early-close settle time"
    assert calendar.final_window?(Time.utc(2026, 11, 27, 18, 30)), "13:30 ET ends the settle window"
    assert_not calendar.final_window?(Time.utc(2026, 11, 27, 18, 9))
    assert_not calendar.final_window?(Time.utc(2026, 11, 27, 18, 31))
    assert_not calendar.final_window?(Time.utc(2026, 11, 27, 21, 20)), "16:20 ET must not run after an early close"
  end

  test "is scheduled for the market-hours poll plus the two settle candidates, from the contract's cron strings" do
    entries = schedule_entries

    assert_equal [ "*/30 13-20 * * 1-5", "20 20 * * 1-5", "20 21 * * 1-5" ].sort, entries.map { |job| job["cron"] }.sort
    assert entries.all? { |job| job["queue"] == "scheduled" }
    entries.each { |job| assert Fugit::Cron.parse(job["cron"]), "#{job['cron']} must parse" }
  end

  test "no option entry ever fires between 22:00 and 22:35 UTC (the fundamentals window)" do
    start = Time.utc(2026, 10, 12) # a Monday; one full week covers every weekday pattern
    fires = schedule_entries.flat_map do |job|
      # sidekiq-cron evaluates the grid in UTC; pin it so the host TZ cannot move it.
      cron = Fugit::Cron.parse("#{job['cron']} UTC")
      times = []
      cursor = start
      while (cursor = cron.next_time(cursor).to_utc_time) < start + 7.days
        times << cursor
        cursor += 1
      end
      times
    end

    assert_operator fires.size, :>=, 5 * 16, "the grid must actually fire on weekdays"
    clashes = fires.select { |time| (time.hour * 60 + time.min).between?(22 * 60, 22 * 60 + 35) }
    assert_empty clashes
  end

  test "the settle entries land on 16:20 New York in both daylight and standard time" do
    settle = schedule_entries.map { |job| job["cron"] }.select { |cron| cron.start_with?("20 ") }
    ny = ->(utc) { utc.in_time_zone("America/New_York").strftime("%H:%M") }

    assert_includes settle.map { |cron| ny.call(Time.utc(2026, 7, 15, cron.split[1].to_i, 20)) }, "16:20"
    assert_includes settle.map { |cron| ny.call(Time.utc(2026, 1, 15, cron.split[1].to_i, 20)) }, "16:20"
  end

  def schedule_entries
    YAML.load_file(Rails.root.join("config/schedule.yml")).values.select { |job| job["class"] == "OptionQuotesRefreshJob" }
  end

  test "every scheduled entry in schedule.yml still names a loadable job class" do
    YAML.load_file(Rails.root.join("config/schedule.yml")).each_value { |job| assert job["class"].safe_constantize, job["class"] }
  end
end
