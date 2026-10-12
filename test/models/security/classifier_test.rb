require "test_helper"

class Security::ClassifierTest < ActiveSupport::TestCase
  setup { @security = Security.create!(ticker: "CLSA#{SecureRandom.hex(1).upcase}"[0, 6], name: "Classify", exchange_mic: "XNAS") }

  test "a stock is classified from the provider's quote type, sector and industry" do
    Security::Classifier.apply(@security, { "quote_type" => "EQUITY", "sector" => "Technology", "industry" => "Software" })

    @security.reload
    assert_equal "equity", @security.asset_class
    assert_equal "stock", @security.asset_sub_class
    assert_equal "Technology", @security.sector
    assert_equal "Software", @security.industry
    assert_equal "provider", @security.classification_source
  end

  test "a fund that is almost all stock is equity, almost all bonds is fixed income" do
    Security::Classifier.apply(@security, { "quote_type" => "ETF", "fund_mix" => { "stock" => 0.9987, "bond" => 0.0, "cash" => 0.0013 } })
    assert_equal [ "equity", "etf" ], [ @security.reload.asset_class, @security.asset_sub_class ]

    Security::Classifier.apply(@security, { "quote_type" => "ETF", "fund_mix" => { "stock" => 0.0, "bond" => 0.97, "cash" => 0.02 } })
    assert_equal [ "fixed_income", "etf" ], [ @security.reload.asset_class, @security.asset_sub_class ]
  end

  test "a mixed or unreported fund gets a sub-class but no guessed asset class" do
    Security::Classifier.apply(@security, { "quote_type" => "ETF", "fund_mix" => { "stock" => 0.6, "bond" => 0.4, "cash" => 0.0 } })
    assert_nil @security.reload.asset_class
    assert_equal "etf", @security.asset_sub_class

    Security::Classifier.apply(@security, { "quote_type" => "MUTUALFUND" })
    assert_nil @security.reload.asset_class
    assert_equal "mutual_fund", @security.asset_sub_class
  end

  test "an unrecognised quote type changes nothing" do
    Security::Classifier.apply(@security, { "quote_type" => "FUTURE", "sector" => "Energy" })

    @security.reload
    assert_nil @security.asset_class
    assert_nil @security.sector
    assert_nil @security.classification_source
  end

  test "never overwrites a locked classification or one set by the user or the AI" do
    @security.update!(sector: "Mine", asset_class: "commodity", classification_source: "manual")
    Security::Classifier.apply(@security, { "quote_type" => "EQUITY", "sector" => "Technology" })
    assert_equal [ "Mine", "commodity" ], [ @security.reload.sector, @security.asset_class ]

    @security.update!(classification_source: "ai")
    Security::Classifier.apply(@security, { "quote_type" => "EQUITY", "sector" => "Technology" })
    assert_equal "Mine", @security.reload.sector

    @security.update!(classification_source: "provider", classification_locked: true)
    Security::Classifier.apply(@security, { "quote_type" => "EQUITY", "sector" => "Technology" })
    assert_equal "Mine", @security.reload.sector
  end

  test "a later refresh may replace an earlier provider classification, but a missing field never blanks one" do
    Security::Classifier.apply(@security, { "quote_type" => "EQUITY", "sector" => "Technology", "industry" => "Software" })
    Security::Classifier.apply(@security, { "quote_type" => "EQUITY", "sector" => "Communication Services" })

    @security.reload
    assert_equal "Communication Services", @security.sector
    assert_equal "Software", @security.industry
  end
end
