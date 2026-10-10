require "test_helper"
require "tmpdir"

class SnaptradeItemPersonalTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_config = Rails.configuration.x.snaptrade
    Rails.configuration.x.snaptrade = ActiveSupport::OrderedOptions.new
    @profile_dir = Dir.mktmpdir
    profile_path = File.join(@profile_dir, "snaptrade-profile.json")
    File.write(profile_path, { "accountType" => "personal", "clientId" => "test-client", "consumerKey" => "test-consumer" }.to_json)
    Rails.configuration.x.snaptrade.personal_profile_path = profile_path

    @item = snaptrade_items(:configured_item)
    @item.update_columns(connection_mode: "personal_profile", oauth_access_token: nil, oauth_refresh_token: nil)
  end

  teardown do
    FileUtils.rm_rf(@profile_dir)
    Rails.configuration.x.snaptrade = @original_config
  end

  test "personal profile items are syncable and dispatch to the read-only provider" do
    assert @item.personal_profile?
    assert @item.credentials_configured?
    assert @item.fully_configured?
    assert_includes SnaptradeItem.syncable, @item
    assert_instance_of Provider::SnaptradePersonal, @item.snaptrade_provider
  end

  test "personal profile items block OAuth and remote connection actions" do
    assert_raises(Provider::SnaptradePersonal::ModeError) { @item.start_oauth_device_flow }
    assert_raises(Provider::SnaptradePersonal::ModeError) { @item.complete_oauth_exchange!(code: "code", redirect_uri: "https://sure.test", code_verifier: "verifier") }
    assert_raises(Provider::SnaptradePersonal::ModeError) { @item.connection_portal_url(redirect_url: "https://sure.test") }
    assert_equal [], @item.fetch_connections
  end

  test "destroying a personal provider account never enqueues remote connection cleanup" do
    account = snaptrade_accounts(:fidelity_401k)
    account.update!(snaptrade_item: @item, snaptrade_authorization_id: "local-only-authorization")

    assert_no_enqueued_jobs only: SnaptradeConnectionCleanupJob do
      account.destroy!
    end
  end
end
