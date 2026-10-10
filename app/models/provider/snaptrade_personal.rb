# SnapTrade Personal uses a locally mounted profile and the Personal signed-request
# scheme. It deliberately exposes only the read endpoints the importer consumes.
class Provider::SnaptradePersonal
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ApiError < Error; end
  class ModeError < Error; end

  Profile = Data.define(:client_id, :consumer_key)

  class ProfileReader
    def self.read
      path = configured_path
      raise ConfigurationError, "SnapTrade Personal profile path is not configured" if path.blank?

      payload = JSON.parse(File.read(path))
      profile = select_profile(payload)
      raise ConfigurationError, "SnapTrade Personal profile is unavailable" unless profile.is_a?(Hash)
      raise ConfigurationError, "SnapTrade Personal profile is not a Personal account" unless profile["accountType"].to_s.downcase == "personal"

      client_id = profile["clientId"].presence
      consumer_key = profile["consumerKey"].presence
      raise ConfigurationError, "SnapTrade Personal profile is incomplete" if client_id.blank? || consumer_key.blank?

      Profile.new(client_id:, consumer_key:)
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      raise ConfigurationError, "SnapTrade Personal profile is unreadable"
    end

    def self.configured?
      read
      true
    rescue ConfigurationError
      false
    end

    def self.configured_path
      Setting.snaptrade_personal_profile_path.presence || Rails.configuration.x.snaptrade&.personal_profile_path
    end

    def self.configured_profile_name
      Setting.snaptrade_personal_profile_name.presence || Rails.configuration.x.snaptrade&.personal_profile_name
    end

    def self.select_profile(payload)
      profiles = payload.is_a?(Hash) ? payload["profiles"] : nil
      return payload unless profiles.present?

      profile_name = configured_profile_name.presence || payload["activeProfile"].presence
      case profiles
      when Hash
        profiles[profile_name]
      when Array
        profiles.find { |candidate| candidate.is_a?(Hash) && candidate["name"].to_s == profile_name.to_s }
      end
    end
    private_class_method :select_profile
  end

  API_BASE_URL = Provider::Snaptrade::API_BASE_URL
  ACTIVITY_PAGE_SIZE = 1_000

  def self.configured?
    ProfileReader.configured?
  end

  def initialize(profile: ProfileReader.read)
    @profile = profile
  end

  def list_accounts
    get_json("/api/v1/accounts")
  end

  def get_balances(account_id:)
    get_json("/api/v1/accounts/#{account_id}/balances")
  end

  def get_positions(account_id:, include_unsupported: false)
    response = get_json("/api/v1/accounts/#{account_id}/positions/all")
    results = response["results"] if response.is_a?(Hash)
    raise ApiError, "SnapTrade Personal positions response has no results array" unless results.is_a?(Array)

    include_unsupported ? results : results.reject { |position| unsupported_instrument?(position) }
  end

  def get_account_activities(account_id:, start_date: nil, end_date: nil)
    params = {}
    params[:startDate] = start_date.to_date.to_s if start_date
    params[:endDate] = end_date.to_date.to_s if end_date
    paginated_get("/api/v1/accounts/#{account_id}/activities", params)
  end

  def get_activities(start_date: nil, end_date: nil, accounts: nil, brokerage_authorizations: nil, type: nil)
    params = {}
    params[:startDate] = start_date.to_date.to_s if start_date
    params[:endDate] = end_date.to_date.to_s if end_date
    params[:accounts] = accounts if accounts
    params[:brokerageAuthorizations] = brokerage_authorizations if brokerage_authorizations
    params[:type] = type if type
    paginated_get("/api/v1/activities", params)
  end

  private

    attr_reader :profile

    def get_json(path, params = {})
      request_json(path, params:)
    end

    def paginated_get(path, params)
      offset = 0
      all = []

      loop do
        response = get_json(path, params.merge(offset:, limit: ACTIVITY_PAGE_SIZE))
        return response unless response.is_a?(Hash) && response["data"].is_a?(Array)

        all.concat(response["data"])
        pagination = response["pagination"].to_h
        total = pagination["total"] || pagination[:total]
        next_offset = pagination["nextOffset"] || pagination[:nextOffset]
        break if next_offset.blank? && (total.blank? || offset + response["data"].size >= total.to_i)

        offset = next_offset.present? ? next_offset.to_i : offset + response["data"].size
        break if response["data"].empty?
      end

      { "data" => all }
    end

    def request_json(path, params:)
      # Personal API keys use SnapTrade's partner-request signing contract,
      # not OAuth-style timestamp headers.  The SDK signs the fully serialized
      # query string (including clientId and timestamp) and sends a base64
      # HMAC in the Signature header.
      query = encoded_query(params)
      response = api_connection.get("#{API_BASE_URL}#{path}?#{query}") do |request|
        request.headers["Signature"] = signature(path, query)
        request.headers["Accept"] = "application/json"
      end
      handle_response(response, "GET #{path}")
    rescue Faraday::Error
      raise ApiError, "SnapTrade Personal request failed"
    end

    def encoded_query(params)
      query = { clientId: profile.client_id }
      query.merge!(params.compact)
      query[:timestamp] = Time.now.to_i.to_s
      # Faraday re-serializes URL query strings. Sign with the same encoder it
      # will put on the wire; URI.encode_www_form differs for some client IDs
      # and makes otherwise-valid requests fail signature verification.
      Faraday::Utils.default_params_encoder.encode(query)
    end

    def signature(path, query)
      payload = JSON.generate(content: nil, path:, query:)
      Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", profile.consumer_key, payload))
    end

    def handle_response(response, operation)
      if response.success?
        return {} if response.body.blank?

        JSON.parse(response.body)
      elsif [ 401, 403 ].include?(response.status)
        raise ApiError, "SnapTrade Personal authentication failed (#{operation})"
      else
        raise ApiError, "SnapTrade Personal request failed (#{operation}): HTTP #{response.status}"
      end
    rescue JSON::ParserError
      raise ApiError, "SnapTrade Personal response was invalid"
    end

    def api_connection
      @api_connection ||= Faraday.new do |faraday|
        faraday.options.timeout = 30
        faraday.options.open_timeout = 10
      end
    end

    def unsupported_instrument?(position)
      instrument = position["instrument"] if position.is_a?(Hash)
      Provider::Snaptrade::UNSUPPORTED_INSTRUMENT_KINDS.include?(instrument&.dig("kind").to_s.downcase)
    end
end
