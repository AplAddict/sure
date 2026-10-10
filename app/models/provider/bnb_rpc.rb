# frozen_string_literal: true

# Keyless BNB Smart Chain data source backed by a public JSON-RPC endpoint.
#
# A dumb RPC client: it can only answer "how much native BNB does this address
# hold". Token balances and transfer history need an indexer, which BNB Smart
# Chain does not have a free keyless one for. Self-hosters can point this at their
# own node with BNB_RPC_URL.
class Provider::BnbRpc
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_URL = "https://bsc-dataseed.binance.org"
  MIN_REQUEST_INTERVAL = 0.2
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  headers "Content-Type" => "application/json"
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def self.url
    ENV["BNB_RPC_URL"].presence || DEFAULT_URL
  end

  # Detection reads on the request thread and cannot afford the sync's patience,
  # so both the per-request timeout and the retry count are the caller's to set.
  def initialize(request_timeout: nil, max_retries: MAX_RETRIES)
    @request_timeout = request_timeout
    @max_retries = max_retries
  end

  # @return [Integer] wei
  def get_balance(address)
    result = rpc("eth_getBalance", [ address, "latest" ])
    raise ApiError, "Unexpected BNB RPC balance" unless result.to_s.match?(/\A0x[0-9a-fA-F]+\z/)

    result.to_i(16)
  end

  private
    def rpc(method, params)
      attempts = 0
      body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json

      begin
        attempts += 1
        throttle_request
        translate_transport_errors { handle_response(self.class.post(self.class.url, **request_options(body: body))) }
      rescue RateLimitError => e
        raise if attempts > @max_retries

        Rails.logger.warn("Provider::BnbRpc - rate limited (attempt #{attempts}/#{@max_retries}): #{e.message}")
        sleep(RETRY_BASE_DELAY * (2**(attempts - 1)))
        retry
      end
    end

    def request_options(**options)
      return options if @request_timeout.nil?

      options.merge(timeout: @request_timeout)
    end

    def throttle_request
      @last_request_at ||= Time.at(0)
      remaining = MIN_REQUEST_INTERVAL - (Time.current - @last_request_at)
      sleep(remaining) if remaining.positive?
      @last_request_at = Time.current
    end

    def handle_response(response)
      raise RateLimitError, "BNB RPC rate limit exceeded" if response.code == 429
      raise ApiError, "BNB RPC error: #{response.code}" unless response.code.between?(200, 299)

      payload = response.parsed_response
      raise ApiError, "Unexpected BNB RPC response" unless payload.is_a?(Hash)
      raise ApiError, "BNB RPC error: #{payload.dig("error", "message")}" if payload["error"]

      payload["result"]
    end
end
