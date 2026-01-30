# frozen_string_literal: true

module IPBlacklist
  # Notification system for IP health events
  #
  # Sends notifications when:
  # - IPs are blacklisted
  # - IPs are paused due to reputation issues
  # - IPs recover and resume sending
  # - Reputation thresholds are exceeded
  #
  # Supports:
  # - Webhook notifications (HTTP POST)
  # - Email notifications
  # - Slack notifications (via webhook)
  #
  # Configuration:
  #   postal:
  #     ip_reputation_notification_webhooks:
  #       - https://example.com/webhook
  #     ip_reputation_notification_emails:
  #       - admin@example.com
  #     ip_reputation_notification_slack_webhook: https://hooks.slack.com/services/...
  #
  # Usage:
  #   notifier = IPBlacklist::Notifier.new
  #   notifier.notify_blacklist_detected(ip_address, blacklist_record)
  #
  class Notifier

    attr_reader :config

    def initialize
      @config = {
        webhooks: Array(Postal::Config.postal&.ip_reputation_notification_webhooks || []),
        email_addresses: Array(Postal::Config.postal&.ip_reputation_notification_emails || []),
        slack_webhook_url: Postal::Config.postal&.ip_reputation_notification_slack_webhook
      }
    end

    # Notify when an IP is detected on a blacklist
    def notify_blacklist_detected(ip_address, blacklist_record)
      event = {
        event_type: "ip_blacklisted",
        severity: "high",
        ip_address: ip_address.ipv4,
        hostname: ip_address.hostname,
        destination_domain: blacklist_record.destination_domain,
        blacklist_source: blacklist_record.blacklist_source,
        detected_at: blacklist_record.detected_at,
        timestamp: Time.current.iso8601
      }

      send_notifications(event)
    end

    # Notify when an IP is paused
    def notify_ip_paused(ip_address, domain, reason, health_action)
      event = {
        event_type: "ip_paused",
        severity: "high",
        ip_address: ip_address.ipv4,
        hostname: ip_address.hostname,
        destination_domain: domain,
        reason: reason,
        action_id: health_action.id,
        timestamp: Time.current.iso8601
      }

      send_notifications(event)
    end

    # Notify when an IP is unpaused/resumed
    def notify_ip_resumed(ip_address, domain, health_action)
      event = {
        event_type: "ip_resumed",
        severity: "info",
        ip_address: ip_address.ipv4,
        hostname: ip_address.hostname,
        destination_domain: domain,
        action_id: health_action.id,
        timestamp: Time.current.iso8601
      }

      send_notifications(event)
    end

    # Notify when reputation threshold is exceeded
    def notify_reputation_warning(ip_address, domain, metric_type, metric_value, threshold)
      event = {
        event_type: "reputation_warning",
        severity: "medium",
        ip_address: ip_address.ipv4,
        hostname: ip_address.hostname,
        destination_domain: domain,
        metric_type: metric_type,
        metric_value: metric_value,
        threshold: threshold,
        timestamp: Time.current.iso8601
      }

      send_notifications(event)
    end

    # Notify when warmup stage advances
    def notify_warmup_advanced(ip_address, domain, old_stage, new_stage)
      event = {
        event_type: "warmup_advanced",
        severity: "info",
        ip_address: ip_address.ipv4,
        hostname: ip_address.hostname,
        destination_domain: domain,
        old_stage: old_stage,
        new_stage: new_stage,
        timestamp: Time.current.iso8601
      }

      send_notifications(event)
    end

    # Notify when retry test succeeds
    def notify_retry_success(blacklist_record, test_result)
      event = {
        event_type: "blacklist_retry_success",
        severity: "info",
        ip_address: blacklist_record.ip_address.ipv4,
        hostname: blacklist_record.ip_address.hostname,
        destination_domain: blacklist_record.destination_domain,
        blacklist_source: blacklist_record.blacklist_source,
        retry_count: blacklist_record.retry_count,
        test_result: test_result[:reason],
        timestamp: Time.current.iso8601
      }

      send_notifications(event)
    end

    # Notify when retry test fails
    def notify_retry_failed(blacklist_record, test_result)
      event = {
        event_type: "blacklist_retry_failed",
        severity: "medium",
        ip_address: blacklist_record.ip_address.ipv4,
        hostname: blacklist_record.ip_address.hostname,
        destination_domain: blacklist_record.destination_domain,
        blacklist_source: blacklist_record.blacklist_source,
        retry_count: blacklist_record.retry_count,
        next_retry_at: blacklist_record.next_retry_at&.iso8601,
        test_result: test_result[:reason],
        smtp_code: test_result[:smtp_code],
        smtp_message: test_result[:smtp_message],
        timestamp: Time.current.iso8601
      }

      send_notifications(event)
    end

    # Notify when retry test encounters an error
    def notify_retry_error(blacklist_record, exception)
      event = {
        event_type: "blacklist_retry_error",
        severity: "medium",
        ip_address: blacklist_record.ip_address.ipv4,
        hostname: blacklist_record.ip_address.hostname,
        destination_domain: blacklist_record.destination_domain,
        blacklist_source: blacklist_record.blacklist_source,
        retry_count: blacklist_record.retry_count,
        next_retry_at: blacklist_record.next_retry_at&.iso8601,
        error: exception.message,
        timestamp: Time.current.iso8601
      }

      send_notifications(event)
    end

    private

    def send_notifications(event)
      send_webhook_notifications(event) if webhooks_configured?
      send_email_notifications(event) if email_configured?
      send_slack_notification(event) if slack_configured?
    end

    def send_webhook_notifications(event)
      webhooks = config[:webhooks] || []

      webhooks.each do |webhook_url|
        send_webhook(webhook_url, event)
      end
    end

    def send_webhook(url, event)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 5

      request = Net::HTTP::Post.new(uri.path || "/")
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "Postal-IPBlacklist/1.0"
      request.body = event.to_json

      response = http.request(request)

      if response.code.to_i >= 200 && response.code.to_i < 300
        Rails.logger.info "[Notifier] Webhook sent successfully to #{url}"
      else
        Rails.logger.error "[Notifier] Webhook failed: #{response.code} - #{response.body}"
      end
    rescue StandardError => e
      Rails.logger.error "[Notifier] Error sending webhook to #{url}: #{e.message}"
    end

    def send_email_notifications(event)
      email_addresses = config[:email_addresses] || []

      email_addresses.each do |email|
        send_email(email, event)
      end
    end

    def send_email(email_address, event)
      # Use Postal's own email sending system
      # This would need to be integrated with Postal's mailer system
      Rails.logger.info "[Notifier] Would send email to #{email_address}: #{event[:event_type]}"

      # TODO: Implement actual email sending via Postal's mailer
      # IPBlacklistMailer.notification_email(email_address, event).deliver_later
    rescue StandardError => e
      Rails.logger.error "[Notifier] Error sending email to #{email_address}: #{e.message}"
    end

    def send_slack_notification(event)
      slack_url = config[:slack_webhook_url]
      return unless slack_url

      slack_message = format_slack_message(event)

      uri = URI(slack_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5

      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request.body = slack_message.to_json

      response = http.request(request)

      if response.code.to_i == 200
        Rails.logger.info "[Notifier] Slack notification sent successfully"
      else
        Rails.logger.error "[Notifier] Slack notification failed: #{response.code}"
      end
    rescue StandardError => e
      Rails.logger.error "[Notifier] Error sending Slack notification: #{e.message}"
    end

    def format_slack_message(event)
      case event[:severity]
      when "high"
        color = "danger"
      when "medium"
        color = "warning"
      else
        color = "good"
      end

      case event[:event_type]
      when "ip_blacklisted"
        text = "🚨 IP #{event[:ip_address]} detected on #{event[:blacklist_source]} for domain #{event[:destination_domain]}"
      when "ip_paused"
        text = "⏸️  IP #{event[:ip_address]} paused for domain #{event[:destination_domain]}: #{event[:reason]}"
      when "ip_resumed"
        text = "✅ IP #{event[:ip_address]} resumed for domain #{event[:destination_domain]}"
      when "reputation_warning"
        text = "⚠️  IP #{event[:ip_address]} reputation warning: #{event[:metric_type]} = #{event[:metric_value]} (threshold: #{event[:threshold]})"
      when "warmup_advanced"
        text = "📈 IP #{event[:ip_address]} warmup advanced from stage #{event[:old_stage]} to #{event[:new_stage]} for domain #{event[:destination_domain]}"
      when "blacklist_retry_success"
        text = "✅ IP #{event[:ip_address]} retry successful! No longer blacklisted on #{event[:blacklist_source]} for #{event[:destination_domain]}"
      when "blacklist_retry_failed"
        text = "❌ IP #{event[:ip_address]} retry failed for #{event[:blacklist_source]} on #{event[:destination_domain]}. Next retry: #{event[:next_retry_at]}"
      when "blacklist_retry_error"
        text = "⚠️  IP #{event[:ip_address]} retry error for #{event[:blacklist_source]} on #{event[:destination_domain]}: #{event[:error]}"
      else
        text = "IP Health Event: #{event[:event_type]}"
      end

      {
        attachments: [
          {
            color: color,
            text: text,
            fields: event.map { |k, v| { title: k.to_s, value: v.to_s, short: true } },
            footer: "Postal IP Health Monitor",
            ts: Time.current.to_i
          },
        ]
      }
    end

    def webhooks_configured?
      config[:webhooks]&.any? || false
    end

    def email_configured?
      config[:email_addresses]&.any? || false
    end

    def slack_configured?
      config[:slack_webhook_url].present?
    end

  end
end
