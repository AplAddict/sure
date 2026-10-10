Rails.application.configure do
  config.x.snaptrade ||= ActiveSupport::OrderedOptions.new
  config.x.snaptrade.oauth_client_id = ENV["SNAPTRADE_OAUTH_CLIENT_ID"].presence ||
                                      Rails.application.credentials.dig(:snaptrade, :oauth_client_id)
  config.x.snaptrade.oauth_client_secret = ENV["SNAPTRADE_OAUTH_CLIENT_SECRET"].presence ||
                                          Rails.application.credentials.dig(:snaptrade, :oauth_client_secret)
  # Personal credentials remain exclusively in a host-mounted profile. These
  # non-secret selectors are operational configuration only; Settings can
  # override them for self-hosted deployments.
  config.x.snaptrade.personal_profile_path = ENV["SNAPTRADE_PERSONAL_PROFILE_PATH"].presence
  config.x.snaptrade.personal_profile_name = ENV["SNAPTRADE_PERSONAL_PROFILE_NAME"].presence
end
