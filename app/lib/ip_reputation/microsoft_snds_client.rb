# frozen_string_literal: true

require "net/http"
require "json"
require "csv"

module IPReputation
  # Client for fetching IP reputation data from Microsoft SNDS (Smart Network Data Services)
  #
  # Microsoft SNDS provides IP-level reputation metrics including:
  # - Filter results (green, yellow, red)
  # - Spam trap hits
  # - Message volume
  # - Complaint rates
  # - Sender reputation color code
  #
  # Setup:
  # 1. Register IPs at https://postmaster.live.com/snds/
  # 2. Obtain API key or set up automated CSV export
  # 3. Configure credentials in Postal config file
  #
  # Usage:
  #   client = IPReputation::MicrosoftSndsClient.new(api_key: "your_key")
  #   data = client.fetch_ip_reputation("192.0.2.1")
  #
  class MicrosoftSndsClient

    SNDS_DATA_URL = "https://postmaster.live.com/snds/data.aspx"

    attr_reader :api_key

    def initialize(api_key: nil)
      @api_key = api_key || default_api_key
    end

    # Fetch reputation data for a specific IP address
    # Returns a hash with reputation metrics or nil if unavailable
    def fetch_ip_reputation(ip_address, date: Date.yesterday)
      return nil unless configured?

      begin
        response = fetch_snds_data(date: date)
        parse_ip_data(response, ip_address)
      rescue StandardError => e
        Rails.logger.error "[SNDS] Error fetching data for IP #{ip_address}: #{e.message}"
        nil
      end
    end

    # Fetch reputation data for all registered IPs
    def fetch_all_ips_reputation(date: Date.yesterday)
      return [] unless configured?

      begin
        response = fetch_snds_data(date: date)
        parse_all_ips_data(response)
      rescue StandardError => e
        Rails.logger.error "[SNDS] Error fetching data: #{e.message}"
        []
      end
    end

    # Check if credentials are configured
    def configured?
      api_key.present?
    end

    # Map SNDS color codes to numeric severity
    def severity_for_color(color)
      case color&.downcase
      when "green"
        0 # Good reputation
      when "yellow"
        1 # Warning
      when "red"
        2 # Poor reputation
      when "trap"
        3 # Spam trap hits
      end
    end

    private

    def default_api_key
      Postal::Config.ip_reputation&.microsoft_snds&.[](:api_key)
    end

    def fetch_snds_data(date:)
      uri = URI(SNDS_DATA_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Get.new(uri)
      request["key"] = api_key
      request["date"] = date.strftime("%Y/%m/%d")

      response = http.request(request)

      unless response.code.to_i == 200
        raise "SNDS API error: #{response.code} - #{response.body}"
      end

      response.body
    end

    def parse_ip_data(csv_data, ip_address)
      all_data = parse_all_ips_data(csv_data)
      all_data.find { |data| data[:ip_address] == ip_address }
    end

    def parse_all_ips_data(csv_data)
      results = []

      CSV.parse(csv_data, headers: true) do |row|
        results << {
          ip_address: row["IP Address"],
          date: row["Date"],
          filter_result: row["Filter Result"],
          complaint_rate: row["Complaint Rate"]&.to_f,
          trap_message_end_users: row["Trap Message End Users"]&.to_i,
          trap_message_send_ips: row["Trap Message Send IPs"]&.to_i,
          message_volume: row["Message Volume"]&.to_i,
          sample_helo: row["Sample HELO"],
          sample_mailfrom: row["Sample MailFrom"],
          severity: severity_for_color(row["Filter Result"]),
          fetched_at: Time.current
        }
      end

      results
    end

  end
end
