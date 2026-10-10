module SnaptradeItem::Provided
  extend ActiveSupport::Concern

  included do
    before_destroy :revoke_oauth_tokens, unless: :personal_profile?
  end

  def snaptrade_provider
    return Provider::SnaptradePersonal.new if personal_profile? && Provider::SnaptradePersonal.configured?
    return nil unless oauth_configured?

    Provider::Snaptrade.new(self)
  end

  # Exchange an authorization code for tokens and mark the item usable.
  def complete_oauth_exchange!(code:, redirect_uri:, code_verifier:)
    ensure_oauth_mode!
    payload = Provider::Snaptrade.exchange_code(
      code: code,
      redirect_uri: redirect_uri,
      code_verifier: code_verifier
    )
    apply_oauth_tokens!(payload)
    update!(status: :good)
    payload
  end

  # Ask SnapTrade for a device code the user confirms on their side. Returns the
  # device authorization payload; nothing is persisted until it is redeemed.
  def start_oauth_device_flow(scope: "read")
    ensure_oauth_mode!
    Provider::Snaptrade.start_device_authorization(scope: scope)
  end

  # Redeem a confirmed device code. The payload has the same shape as the
  # authorization-code response, so the item ends up in exactly the state
  # complete_oauth_exchange! leaves it in -- one token model, two grants.
  def complete_oauth_device_flow!(device_code:)
    ensure_oauth_mode!
    payload = Provider::Snaptrade.poll_device_token(device_code: device_code)
    apply_oauth_tokens!(payload)
    update!(status: :good)
    payload
  end

  # Get the connection portal URL for linking brokerages
  def connection_portal_url(redirect_url:, broker: nil)
    ensure_oauth_mode!
    provider = snaptrade_provider
    raise StandardError, "SnapTrade is not authorized" unless provider

    provider.get_connection_url(redirect_url: redirect_url, broker: broker)
  end

  # Fetch all brokerage connections from SnapTrade API. Returns Array<Hash>.
  def fetch_connections
    return [] if personal_profile?

    provider = snaptrade_provider
    return [] unless provider

    provider.list_connections
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.error "SnaptradeItem #{id} - Failed to list connections: #{e.message}"
    raise
  end

  private

    def ensure_oauth_mode!
      raise Provider::SnaptradePersonal::ModeError, "SnapTrade Personal does not support OAuth or remote connection management" if personal_profile?
    end

    # Best-effort token revocation when the item is destroyed.
    def revoke_oauth_tokens
      token = oauth_refresh_token.presence || oauth_access_token # pipelock:ignore Credential in URL
      return if token.blank?

      Provider::Snaptrade.revoke_token(token: token)
    rescue => e
      # Never block deletion on revocation failures
      Rails.logger.warn "SnapTrade: Failed to revoke tokens for item #{id}: #{e.class} - #{e.message}"
    end
end
