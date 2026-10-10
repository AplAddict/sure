require "test_helper"
require "ostruct"
require "tmpdir"

class Provider::SnaptradePersonalTest < ActiveSupport::TestCase
  setup do
    @original = Rails.configuration.x.snaptrade
    Rails.configuration.x.snaptrade = ActiveSupport::OrderedOptions.new
    @profile_path = File.join(Dir.mktmpdir, "snaptrade-profile.json")
    File.write(@profile_path, {
      "profiles" => [
        { "name" => "personal", "accountType" => "personal", "clientId" => "test-personal-client", "consumerKey" => "test-personal-consumer-key" }
      ]
    }.to_json)
    Rails.configuration.x.snaptrade.personal_profile_path = @profile_path
    Rails.configuration.x.snaptrade.personal_profile_name = "personal"
  end

  teardown do
    FileUtils.rm_rf(File.dirname(@profile_path))
    Rails.configuration.x.snaptrade = @original
  end

  test "reads only a named Personal profile without exposing its credentials" do
    profile = Provider::SnaptradePersonal::ProfileReader.read

    assert_equal "test-personal-client", profile.client_id
    assert_equal "test-personal-consumer-key", profile.consumer_key
  end

  test "reads the configured profile from a profile map" do
    Rails.configuration.x.snaptrade.personal_profile_name = "active-personal"
    File.write(@profile_path, {
      "activeProfile" => "active-personal",
      "profiles" => {
        "active-personal" => { "accountType" => "personal", "clientId" => "test-personal-client", "consumerKey" => "test-personal-consumer-key" }
      }
    }.to_json)

    profile = Provider::SnaptradePersonal::ProfileReader.read

    assert_equal "test-personal-client", profile.client_id
  end

  test "rejects a non-Personal profile without leaking profile contents" do
    File.write(@profile_path, { "profiles" => [ { "name" => "personal", "accountType" => "commercial", "clientId" => "test-personal-client", "consumerKey" => "test-personal-consumer-key" } ] }.to_json)

    error = assert_raises(Provider::SnaptradePersonal::ConfigurationError) { Provider::SnaptradePersonal::ProfileReader.read }

    refute_includes error.message, "test-personal-client"
    refute_includes error.message, "test-personal-consumer-key"
  end

  test "signs GET account reads without OAuth or commercial identity headers" do
    provider = Provider::SnaptradePersonal.new
    request = OpenStruct.new(headers: {}, params: {})
    connection = mock("faraday")
    connection.expects(:get).with("#{Provider::Snaptrade::API_BASE_URL}/api/v1/accounts").yields(request)
      .returns(faraday_response(status: 200, body: [ { id: "account-1" } ].to_json))
    provider.stubs(:api_connection).returns(connection)
    provider.stubs(:timestamp).returns("1700000000000")

    assert_equal [ { "id" => "account-1" } ], provider.list_accounts
    assert_equal "test-personal-client", request.headers["Client-ID"]
    assert_equal "1700000000000", request.headers["Timestamp"]
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", "test-personal-consumer-key", "test-personal-client1700000000000"), request.headers["Signature"]
    assert_nil request.headers["Authorization"]
    assert_nil request.headers["User-ID"]
    assert_nil request.headers["User-Secret"]
  end

  test "supports the importer read contract while rejecting remote writes" do
    provider = Provider::SnaptradePersonal.new

    assert_respond_to provider, :list_accounts
    assert_respond_to provider, :get_balances
    assert_respond_to provider, :get_positions
    assert_respond_to provider, :get_account_activities
    assert_not_respond_to provider, :delete_connection
    assert_not_respond_to provider, :get_connection_url
  end

  test "paginates account activities through signed GET requests" do
    provider = Provider::SnaptradePersonal.new
    provider.expects(:get_json)
      .with("/api/v1/accounts/account-1/activities", has_entries(offset: 0, limit: Provider::SnaptradePersonal::ACTIVITY_PAGE_SIZE))
      .returns({ "data" => [ { "id" => "first" } ], "pagination" => { "total" => 2 } })
    provider.expects(:get_json)
      .with("/api/v1/accounts/account-1/activities", has_entries(offset: 1, limit: Provider::SnaptradePersonal::ACTIVITY_PAGE_SIZE))
      .returns({ "data" => [ { "id" => "second" } ], "pagination" => { "total" => 2 } })

    response = provider.get_account_activities(account_id: "account-1")

    assert_equal %w[first second], response.fetch("data").pluck("id")
  end

  private

    def faraday_response(status:, body:)
      OpenStruct.new(status: status, body: body, success?: (200..299).cover?(status))
    end
end
