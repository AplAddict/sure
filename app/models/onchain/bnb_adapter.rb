# frozen_string_literal: true

# BNB Smart Chain, native BNB only.
#
# There is no free keyless indexer for this network, so a public JSON-RPC node is
# the only source: it can report the native balance of an address and nothing
# else. Token (BEP-20) balances and transfer history are therefore not read, and
# every snapshot says so by marking its history incomplete — a wallet is tracked
# at its true BNB balance rather than shown with invented history.
class Onchain::BnbAdapter
  include Onchain::ChainAdapter

  ADDRESS_PATTERN = /\A0x[0-9a-fA-F]{40}\z/
  WEI_PER_BNB = (10.to_d**18)

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  # Hex is hex: 0xABC… and 0xabc… are one wallet.
  def canonical_address(address)
    address.to_s.strip.downcase
  end

  # One request. An address with a BNB balance is worth tracking here; an empty
  # one is not (BEP-20-only wallets cannot be detected without an indexer).
  # nil means the node could not tell, which must never read as "empty".
  def has_activity?(address)
    return false unless valid_address?(address)

    detection_provider.get_balance(address).positive?
  rescue StandardError => e
    Rails.logger.warn("Onchain::BnbAdapter - activity probe failed: #{e.class}")
    nil
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid BNB Smart Chain address" unless valid_address?(address)

    wrap_provider_errors do
      balance = provider.get_balance(canonical_address(address)).to_d / WEI_PER_BNB

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: balance) ],
        movements: [],
        history_truncated: true,
        assets_truncated: false
      )
    end
  end

  def provider_error_classes
    [ Provider::BnbRpc::RateLimitError, Provider::BnbRpc::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::BNB)
    end

    def provider
      @provider ||= Provider::BnbRpc.new
    end

    def detection_provider
      @detection_provider ||= Provider::BnbRpc.new(
        request_timeout: Onchain::DetectionBudget.timeout,
        max_retries: Onchain::DetectionBudget.retries
      )
    end
end
