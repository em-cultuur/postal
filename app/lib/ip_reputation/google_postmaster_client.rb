# frozen_string_literal: true

module IPReputation
  # Client for fetching reputation data from Google Postmaster Tools API
  #
  # Google Postmaster provides domain-level reputation metrics including:
  # - Domain reputation (HIGH, MEDIUM, LOW, BAD)
  # - Spam rate
  # - User-reported spam rate
  # - Feedback loop complaint rate
  # - DKIM/SPF/DMARC authentication rates
  #
  # Setup:
  # 1. Register domains at https://postmaster.google.com/
  # 2. Set up OAuth2 credentials in Google Cloud Console
  # 3. Configure credentials in Postal config file
  #
  # Usage:
  #   client = IPReputation::GooglePostmasterClient.new(
  #     credentials: credentials_hash,
  #     domain: "example.com"
  #   )
  #   data = client.fetch_reputation_data
  #
  class GooglePostmasterClient

    API_BASE_URL = "https://gmailpostmastertools.googleapis.com/v1"

    attr_reader :domain, :credentials

    def initialize(domain:, credentials: nil)
      @domain = domain
      @credentials = credentials || default_credentials
    end

    # Fetch domain reputation data from Google Postmaster
    # Returns a hash with reputation metrics or nil if unavailable
    def fetch_reputation_data(date: Date.yesterday)
      return nil unless configured?

      begin
        response = make_api_request("/domains/#{domain}/trafficStats/#{date.strftime('%Y%m%d')}")
        parse_response(response)
      rescue StandardError => e
        Rails.logger.error "[GooglePostmaster] Error fetching data for #{domain}: #{e.message}"
        nil
      end
    end

    # Fetch domain reputation trend over date range
    def fetch_reputation_trend(start_date:, end_date: Date.today)
      return [] unless configured?

      (start_date..end_date).map do |date|
        fetch_reputation_data(date: date)
      end.compact
    end

    # Check if credentials are configured
    def configured?
      credentials.present? && credentials[:access_token].present?
    end

    private

    def default_credentials
      config = Postal::Config.ip_reputation
      return nil unless config

      {
        access_token: config.google_postmaster_access_token,
        refresh_token: config.google_postmaster_refresh_token,
        client_id: config.google_postmaster_client_id,
        client_secret: config.google_postmaster_client_secret
      }
    end

    def make_api_request(path)
      uri = URI("#{API_BASE_URL}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{credentials[:access_token]}"
      request["Content-Type"] = "application/json"

      response = http.request(request)

      if response.code.to_i == 401
        # Token expired, try to refresh
        refresh_access_token
        # Retry the request once
        request["Authorization"] = "Bearer #{credentials[:access_token]}"
        response = http.request(request)
      end

      response
    end

    def refresh_access_token
      return unless credentials[:refresh_token].present?

      uri = URI("https://oauth2.googleapis.com/token")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request.set_form_data(
        refresh_token: credentials[:refresh_token],
        client_id: credentials[:client_id],
        client_secret: credentials[:client_secret],
        grant_type: "refresh_token"
      )

      response = http.request(request)
      if response.code.to_i == 200
        data = JSON.parse(response.body)
        @credentials[:access_token] = data["access_token"]
        Rails.logger.info "[GooglePostmaster] Refreshed access token"
      else
        Rails.logger.error "[GooglePostmaster] Failed to refresh token: #{response.body}"
      end
    end

    def parse_response(response)
      unless response.code.to_i == 200
        Rails.logger.error "[GooglePostmaster] Error fetching data: HTTP #{response.code} - #{response.body}"
        return nil
      end

      data = JSON.parse(response.body)

      {
        domain: domain,
        date: data["name"]&.split("/")&.last,
        domain_reputation: data["domainReputation"],
        spam_rate: data["spamRate"]&.to_f,
        user_reported_spam_rate: data["userReportedSpamRate"]&.to_f,
        dkim_success_rate: data["dkimSuccessRate"]&.to_f,
        spf_success_rate: data["spfSuccessRate"]&.to_f,
        dmarc_success_rate: data["dmarcSuccessRate"]&.to_f,
        inbound_encryption_rate: data["inboundEncryptionRate"]&.to_f,
        fetched_at: Time.current
      }
    end

  end
end
