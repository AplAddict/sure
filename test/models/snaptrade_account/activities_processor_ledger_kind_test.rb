require "test_helper"

class SnaptradeAccount::ActivitiesProcessorLedgerKindTest < ActiveSupport::TestCase
  setup { @processor = SnaptradeAccount::ActivitiesProcessor.allocate }

  test "journals are internal funds movements" do
    assert_equal "funds_movement", @processor.send(:ledger_kind_for, "OTHER", "JOURNALED JNL VS X77")
    assert_equal "funds_movement", @processor.send(:ledger_kind_for, "JOURNAL", "anything")
  end

  test "plain withdrawals are investment ledger movements" do
    assert_equal "investment_contribution", @processor.send(:ledger_kind_for, "WITHDRAWAL", "Electronic Funds Transfer Paid")
  end

  test "margin interest, fees and dividends stay ordinary" do
    assert_nil @processor.send(:ledger_kind_for, "WITHDRAWAL", "MARGIN INTEREST")
    assert_nil @processor.send(:ledger_kind_for, "FEE", "ADJUST FEE")
    assert_nil @processor.send(:ledger_kind_for, "DIVIDEND", "DIVIDEND RECEIVED")
  end
end
