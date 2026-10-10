# frozen_string_literal: true

require "test_helper"

class Onchain::BnbAdapterTest < ActiveSupport::TestCase
  ADDRESS = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::BNB)
  end

  test "is registered as a native-only chain" do
    definition = Onchain::Chains.find!("bnb")

    assert_equal "BNB", definition.native.symbol
    assert_equal 18, definition.native.decimals
    assert_not definition.supports_tokens?
    assert_equal "BNB Smart Chain", definition.label
  end

  test "accepts 0x addresses and canonicalizes case" do
    assert @adapter.valid_address?(ADDRESS)
    assert_equal ADDRESS.downcase, @adapter.canonical_address(" #{ADDRESS} ")

    [ "", "0x123", "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM" ].each do |bad|
      assert_not @adapter.valid_address?(bad), "#{bad.inspect} should be rejected"
    end
  end

  test "snapshot reports the native balance and flags history as incomplete" do
    request = stub_rpc("eth_getBalance", "0x" + (2_500_000_000_000_000_000).to_s(16))

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_requested request, times: 1
    assert_equal 1, snapshot.assets.size
    asset = snapshot.assets.first
    assert asset.native?
    assert_equal "BNB", asset.symbol
    assert_equal BigDecimal("2.5"), asset.quantity
    assert_empty snapshot.movements
    assert snapshot.history_truncated?
  end

  test "a zero balance is still tracked as a zero BNB asset" do
    stub_rpc("eth_getBalance", "0x0")

    assert_equal BigDecimal("0"), @adapter.fetch_snapshot(ADDRESS).assets.first.quantity
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot("nope") }
  end

  test "activity is one request and means a positive balance" do
    request = stub_rpc("eth_getBalance", "0xde0b6b3a7640000")

    assert_equal true, @adapter.has_activity?(ADDRESS)
    assert_requested request, times: 1
  end

  test "an empty address is not detected as BNB" do
    stub_rpc("eth_getBalance", "0x0")

    assert_equal false, @adapter.has_activity?(ADDRESS)
  end

  test "a node failure means could not tell rather than empty" do
    stub_request(:post, Provider::BnbRpc.url).to_return(status: 500)

    assert_nil @adapter.has_activity?(ADDRESS)
  end

  test "node errors surface as chain errors during a snapshot" do
    stub_request(:post, Provider::BnbRpc.url).to_return(status: 500)
    assert_raises(Onchain::Chains::UnreachableError) { @adapter.fetch_snapshot(ADDRESS) }

    stub_request(:post, Provider::BnbRpc.url).to_return(status: 429)
    Provider::BnbRpc.any_instance.stubs(:sleep)
    assert_raises(Onchain::Chains::RateLimitedError) { @adapter.fetch_snapshot(ADDRESS) }
  end

  test "an RPC error payload is rejected" do
    stub_request(:post, Provider::BnbRpc.url)
      .to_return(status: 200, body: { "error" => { "message" => "bad" } }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises(Onchain::Chains::UnreachableError) { @adapter.fetch_snapshot(ADDRESS) }
  end

  test "WBNB is priced as BNB" do
    assert_equal "BNB", Onchain::AssetSymbol.canonical("WBNB")
  end

  private
    def stub_rpc(method, result)
      stub_request(:post, Provider::BnbRpc.url)
        .with(body: hash_including("method" => method))
        .to_return(status: 200, body: { "result" => result }.to_json, headers: { "Content-Type" => "application/json" })
    end
end
