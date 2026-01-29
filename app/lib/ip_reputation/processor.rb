# frozen_string_literal: true

module IPReputation
  # Processes reputation data from external sources and takes action based on thresholds
  #
  # This service:
  # - Fetches data from Google Postmaster and Microsoft SNDS
  # - Stores metrics in IPReputationMetric table
  # - Triggers automatic IP pausing based on reputation thresholds
  # - Integrates with IPBlacklist::IPHealthManager for consistent action handling
  #
  # Usage:
  #   processor = IPReputation::Processor.new
  #   processor.process_all_ips
  #
  class Processor

    # Reputation thresholds for automatic actions
    THRESHOLDS = {
      google_postmaster: {
        domain_reputation: {
          bad: :pause,      # Pause immediately on BAD reputation
          low: :warn        # Log warning on LOW reputation
        },
        spam_rate: {
          high: 0.10,       # Pause if spam rate > 10%
          medium: 0.05      # Warn if spam rate > 5%
        },
        user_spam_rate: {
          high: 0.03,       # Pause if user-reported spam > 3%
          medium: 0.01      # Warn if user-reported spam > 1%
        }
      },
      microsoft_snds: {
        filter_result: {
          red: :pause,      # Pause on RED status
          yellow: :warn,    # Warn on YELLOW status
          trap: :pause      # Pause immediately on trap hits
        },
        complaint_rate: {
          high: 0.003,      # Pause if complaint rate > 0.3%
          medium: 0.001     # Warn if complaint rate > 0.1%
        }
      }
    }.freeze

    attr_reader :google_client, :snds_client

    def initialize(google_credentials: nil, snds_api_key: nil)
      @google_client = GooglePostmasterClient.new(
        domain: Postal::Config.dns&.return_path_domain || "example.com",
        credentials: google_credentials
      )
      @snds_client = MicrosoftSndsClient.new(api_key: snds_api_key)
    end

    # Process reputation data for all IPs in the system
    def process_all_ips
      IPAddress.find_each do |ip|
        process_ip(ip)
      end
    end

    # Process reputation data for a specific IP
    def process_ip(ip_address)
      {
        google_postmaster: process_google_postmaster(ip_address),
        microsoft_snds: process_microsoft_snds(ip_address)
      }
    end

    # Process reputation for a specific domain (Google Postmaster)
    def process_domain_reputation(domain)
      return unless google_client.configured?

      data = google_client.fetch_reputation_data
      return unless data

      # Find all IPs that have sent to this domain recently
      ip_addresses = find_ips_for_domain(domain)

      ip_addresses.each do |ip|
        store_google_metric(ip, data)
        check_google_thresholds(ip, domain, data)
      end

      data
    end

    private

    def process_google_postmaster(ip_address)
      return nil unless google_client.configured?

      # Google Postmaster is domain-level, not IP-level
      # We'll fetch domain reputation and apply it to IPs sending to that domain
      domains = recently_sent_domains(ip_address)

      domains.each do |domain|
        client = GooglePostmasterClient.new(domain: domain)
        data = client.fetch_reputation_data
        next unless data

        store_google_metric(ip_address, data)
        check_google_thresholds(ip_address, domain, data)
      end
    end

    def process_microsoft_snds(ip_address)
      return nil unless snds_client.configured?

      data = snds_client.fetch_ip_reputation(ip_address.ipv4)
      return unless data

      store_snds_metric(ip_address, data)
      check_snds_thresholds(ip_address, data)

      data
    end

    def store_google_metric(ip_address, data)
      IPReputationMetric.create!(
        ip_address: ip_address,
        destination_domain: data[:domain],
        period_date: Date.current,
        metric_type: IPReputationMetric::METRIC_TYPE_GOOGLE_POSTMASTER,
        metric_value: reputation_to_numeric(data[:domain_reputation]),
        spam_rate: (data[:spam_rate].to_f * 10_000).to_i,
        complaint_rate: data[:user_reported_spam_rate],
        auth_success_rate: [
          data[:dkim_success_rate],
          data[:spf_success_rate],
          data[:dmarc_success_rate],
        ].compact.sum / 3.0,
        metadata: data.to_json
      )
    end

    def store_snds_metric(ip_address, data)
      IPReputationMetric.create!(
        ip_address: ip_address,
        destination_domain: "outlook.com",
        period_date: Date.current,
        metric_type: IPReputationMetric::METRIC_TYPE_MICROSOFT_SNDS,
        metric_value: data[:severity],
        spam_rate: 0,
        complaint_rate: data[:complaint_rate],
        trap_hits: data[:trap_message_end_users],
        metadata: data.to_json
      )
    end

    def check_google_thresholds(ip_address, domain, data)
      # Check domain reputation
      if data[:domain_reputation] == "BAD"
        pause_ip_for_domain(ip_address, domain, "Google Postmaster: BAD domain reputation")
      elsif data[:domain_reputation] == "LOW"
        log_warning(ip_address, domain, "Google Postmaster: LOW domain reputation")
      end

      # Check spam rate
      if data[:spam_rate] && data[:spam_rate] > THRESHOLDS[:google_postmaster][:spam_rate][:high]
        pause_ip_for_domain(ip_address, domain, "Google Postmaster: High spam rate (#{(data[:spam_rate] * 100).round(2)}%)")
      elsif data[:spam_rate] && data[:spam_rate] > THRESHOLDS[:google_postmaster][:spam_rate][:medium]
        log_warning(ip_address, domain, "Google Postmaster: Elevated spam rate (#{(data[:spam_rate] * 100).round(2)}%)")
      end

      # Check user-reported spam rate
      return unless data[:user_reported_spam_rate] && data[:user_reported_spam_rate] > THRESHOLDS[:google_postmaster][:user_spam_rate][:high]

      pause_ip_for_domain(ip_address, domain, "Google Postmaster: High user-reported spam (#{(data[:user_reported_spam_rate] * 100).round(2)}%)")
    end

    def check_snds_thresholds(ip_address, data)
      domain = "outlook.com"

      # Check filter result color
      case data[:filter_result]&.downcase
      when "red"
        pause_ip_for_domain(ip_address, domain, "Microsoft SNDS: RED filter status")
      when "yellow"
        log_warning(ip_address, domain, "Microsoft SNDS: YELLOW filter status")
      when "trap"
        pause_ip_for_domain(ip_address, domain, "Microsoft SNDS: Spam trap hits detected")
      end

      # Check complaint rate
      if data[:complaint_rate] && data[:complaint_rate] > THRESHOLDS[:microsoft_snds][:complaint_rate][:high]
        pause_ip_for_domain(ip_address, domain, "Microsoft SNDS: High complaint rate (#{(data[:complaint_rate] * 100).round(3)}%)")
      elsif data[:complaint_rate] && data[:complaint_rate] > THRESHOLDS[:microsoft_snds][:complaint_rate][:medium]
        log_warning(ip_address, domain, "Microsoft SNDS: Elevated complaint rate (#{(data[:complaint_rate] * 100).round(3)}%)")
      end
    end

    def pause_ip_for_domain(ip_address, domain, reason)
      Rails.logger.warn "[IPReputation] Pausing #{ip_address.ipv4} for domain #{domain}: #{reason}"

      # Use IPHealthManager to handle the pause action consistently
      IPBlacklist::IPHealthManager.pause_for_domain(ip_address, domain, reason: reason)
    end

    def log_warning(ip_address, domain, message)
      Rails.logger.warn "[IPReputation] #{ip_address.ipv4} / #{domain}: #{message}"

      # Create a health action record for tracking
      IPHealthAction.create!(
        ip_address: ip_address,
        action_type: IPHealthAction::MONITOR,
        destination_domain: domain,
        reason: message
      )
    end

    def reputation_to_numeric(reputation)
      case reputation&.upcase
      when "HIGH"
        100
      when "MEDIUM"
        60
      when "LOW"
        30
      when "BAD"
        0
      end
    end

    def recently_sent_domains(ip_address)
      # Find domains this IP has sent to in the last 7 days
      # This would need to query the message database
      # For now, return major ISPs that have reputation systems
      ["gmail.com", "googlemail.com", "yahoo.com", "aol.com", "outlook.com", "hotmail.com"]
    end

    def find_ips_for_domain(domain)
      # Find IPs that have sent to this domain recently
      # For now, return all IPs
      IPAddress.all
    end

  end
end
