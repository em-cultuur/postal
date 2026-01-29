# frozen_string_literal: true

require "mail"

module IPReputation
  # Parser for Feedback Loop (FBL) complaint emails in ARF format
  #
  # Feedback loops are complaint reporting mechanisms provided by ISPs:
  # - AOL, Yahoo, Outlook, and others send ARF (Abuse Reporting Format) emails
  # - These emails contain information about spam complaints
  # - We parse them to track complaint rates and take action
  #
  # ARF format structure:
  # - Part 1: Human-readable text description
  # - Part 2: Machine-readable report (message/feedback-report)
  # - Part 3: Original message or headers (message/rfc822)
  #
  # Usage:
  #   parser = IPReputation::FeedbackLoopParser.new(raw_email)
  #   if parser.valid_arf?
  #     parser.process_complaint
  #   end
  #
  class FeedbackLoopParser

    attr_reader :mail, :feedback_report, :original_message

    def initialize(raw_email)
      @mail = Mail.new(raw_email)
      parse_arf_parts
    end

    # Check if this is a valid ARF complaint email
    def valid_arf?
      @mail.multipart? &&
        @mail.parts.any? { |p| p.content_type =~ /message\/feedback-report/ }
    end

    # Process the complaint and create metrics/take action
    def process_complaint
      return unless valid_arf?

      complaint_data = extract_complaint_data

      # Find the IP address that sent the original message
      ip_address = find_ip_address(complaint_data)
      return unless ip_address

      # Store the complaint as a reputation metric
      store_complaint_metric(ip_address, complaint_data)

      # Check if we need to take action based on complaint rate
      check_complaint_thresholds(ip_address, complaint_data)

      complaint_data
    end

    private

    def parse_arf_parts
      return unless @mail.multipart?

      @mail.parts.each do |part|
        case part.content_type
        when /message\/feedback-report/
          @feedback_report = parse_feedback_report(part.body.decoded)
        when /message\/rfc822/
          @original_message = Mail.new(part.body.decoded)
        end
      end
    end

    def parse_feedback_report(body)
      report = {}

      body.split("\n").each do |line|
        next if line.strip.empty?

        key, value = line.split(":", 2)
        next unless key && value

        report[key.strip.downcase.tr("-", "_").to_sym] = value.strip
      end

      report
    end

    def extract_complaint_data
      {
        feedback_type: feedback_report[:feedback_type],
        user_agent: feedback_report[:user_agent],
        version: feedback_report[:version],
        original_mail_from: feedback_report[:original_mail_from] || original_message&.from&.first,
        original_rcpt_to: feedback_report[:original_rcpt_to] || original_message&.to&.first,
        arrival_date: feedback_report[:arrival_date],
        reported_domain: feedback_report[:reported_domain],
        reported_uri: feedback_report[:reported_uri],
        source_ip: feedback_report[:source_ip],
        authentication_results: feedback_report[:authentication_results],
        original_message_id: original_message&.message_id,
        reported_at: Time.current
      }
    end

    def find_ip_address(complaint_data)
      # Try to find IP by source_ip in the report
      if complaint_data[:source_ip].present?
        ip = IPAddress.find_by(ipv4: complaint_data[:source_ip])
        return ip if ip
      end

      # Try to find IP from Received headers in original message
      if original_message
        received_headers = original_message.header.fields.select { |f| f.name == "Received" }
        received_headers.each do |header|
          # Parse IP from "Received: from ... ([1.2.3.4])"
          ip_match = header.value.match(/\[(\d+\.\d+\.\d+\.\d+)\]/)
          next unless ip_match

          ip = IPAddress.find_by(ipv4: ip_match[1])
          return ip if ip
        end
      end

      Rails.logger.warn "[FBL] Could not find IP address for complaint: #{complaint_data[:source_ip]}"
      nil
    end

    def store_complaint_metric(ip_address, complaint_data)
      # Extract destination domain from recipient
      destination_domain = complaint_data[:original_rcpt_to]&.split("@")&.last

      # Use hourly period for FBL complaints to allow multiple per day
      # Set period_date to beginning of current hour to avoid conflicts
      current_time = Time.current
      period_date = current_time.to_date

      IPReputationMetric.create!(
        ip_address: ip_address,
        destination_domain: destination_domain,
        period: IPReputationMetric::HOURLY,
        period_date: period_date,
        metric_type: IPReputationMetric::METRIC_TYPE_FEEDBACK_LOOP,
        complaint_rate: nil, # Will be calculated from aggregate data
        metadata: complaint_data.to_json
      )

      Rails.logger.info "[FBL] Recorded complaint for IP #{ip_address.ipv4} to domain #{destination_domain}"
    end

    def check_complaint_thresholds(ip_address, complaint_data)
      destination_domain = complaint_data[:original_rcpt_to]&.split("@")&.last
      return unless destination_domain

      # Calculate complaint rate over the last 7 days
      complaints_count = IPReputationMetric
                         .where(ip_address: ip_address, destination_domain: destination_domain, metric_type: IPReputationMetric::METRIC_TYPE_FEEDBACK_LOOP)
                         .where("created_at > ?", 7.days.ago)
                         .count

      # Estimate sent volume (this would ideally come from message database)
      # For now, use a simple threshold
      if complaints_count >= 10
        # Pause IP if we have 10+ complaints in a week
        Rails.logger.warn "[FBL] High complaint count (#{complaints_count}) for IP #{ip_address.ipv4} on domain #{destination_domain}"

        manager = IPBlacklist::IPHealthManager
        manager.pause_for_domain(
          ip_address,
          destination_domain,
          reason: "High feedback loop complaint count (#{complaints_count} in 7 days)"
        )
      elsif complaints_count >= 5
        # Log warning if we have 5+ complaints
        Rails.logger.warn "[FBL] Elevated complaint count (#{complaints_count}) for IP #{ip_address.ipv4} on domain #{destination_domain}"

        IPHealthAction.create!(
          ip_address: ip_address,
          action_type: IPHealthAction::MONITOR,
          destination_domain: destination_domain,
          reason: "Elevated feedback loop complaints (#{complaints_count} in 7 days)"
        )
      end
    end

  end
end
