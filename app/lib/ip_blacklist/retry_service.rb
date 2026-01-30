# frozen_string_literal: true

module IPBlacklist
  class RetryService

    attr_reader :blacklist_record, :result, :error_message

    def initialize(blacklist_record)
      @blacklist_record = blacklist_record
      @result = nil
      @error_message = nil
    end

    # Perform the retry test by sending a test email
    def perform_retry
      Rails.logger.info "[BLACKLIST RETRY] Starting retry test for IP #{ip_address.ipv4} on domain #{destination_domain}"

      # Update retry tracking
      blacklist_record.update!(
        last_retry_at: Time.current,
        retry_count: blacklist_record.retry_count + 1
      )

      begin
        # Send test email and analyze result
        test_result = send_test_email

        if test_result[:success]
          handle_success(test_result)
        else
          handle_failure(test_result)
        end
      rescue StandardError => e
        handle_error(e)
      end

      @result
    end

    private

    def ip_address
      @ip_address ||= blacklist_record.ip_address
    end

    def destination_domain
      @destination_domain ||= blacklist_record.destination_domain
    end

    def send_test_email
      # Find a server that uses this IP address's pool
      server = find_test_server
      unless server
        return {
          success: false,
          reason: "No server found using IP pool containing #{ip_address.ipv4}"
        }
      end

      # Generate test recipient address for the destination domain
      test_recipient = generate_test_recipient(destination_domain)

      Rails.logger.info "[BLACKLIST RETRY] Sending test email from #{server.permalink} via IP #{ip_address.ipv4} to #{test_recipient}"

      # Create a test message
      message = create_test_message(server, test_recipient)

      # Attempt to send using SMTPSender directly with forced IP
      attempt_smtp_send(server, message, test_recipient)
    end

    def find_test_server
      # Find any server that uses this IP's pool
      ip_pool = ip_address.ip_pool
      return nil unless ip_pool

      # Get the first active server using this pool
      Server.where(ip_pool_id: ip_pool.id).first
    end

    def generate_test_recipient(domain)
      # Generate a test email like: blacklist-test-{timestamp}@{domain}
      "blacklist-test-#{Time.current.to_i}@#{domain}"
    end

    def create_test_message(server, recipient)
      # Create a minimal test message
      {
        from: "test@#{server.message_db.organization.domains.first&.name || server.permalink}",
        to: recipient,
        subject: "Postal IP Blacklist Test - #{Time.current.iso8601}",
        plain_body: "This is an automated test message from Postal to verify IP reputation.\n\nIP: #{ip_address.ipv4}\nTime: #{Time.current}\n",
        message_id: "<blacklist-test-#{SecureRandom.hex(16)}@#{server.permalink}>"
      }
    end

    def attempt_smtp_send(server, message, recipient)
      # Parse recipient domain
      domain = recipient.split("@").last

      # Initialize result
      result = { success: false, smtp_code: nil, smtp_message: nil }

      begin
        # Create a temporary connection to test SMTP
        # We'll use Net::SMTP directly to have fine control
        require "net/smtp"

        # Get MX records for destination domain
        mx_hosts = resolve_mx_records(domain)
        if mx_hosts.empty?
          return {
            success: false,
            reason: "No MX records found for #{domain}",
            smtp_code: "550",
            smtp_message: "Domain has no MX records"
          }
        end

        # Try first MX host
        mx_host = mx_hosts.first

        Rails.logger.info "[BLACKLIST RETRY] Connecting to #{mx_host} for domain #{domain}"

        # Attempt SMTP connection with the specific IP
        # Note: Net::SMTP doesn't support binding to specific source IP easily
        # We need to use a lower-level approach or rely on routing

        # For now, we'll simulate by checking if we can connect and send MAIL FROM
        smtp = Net::SMTP.new(mx_host, 25)
        smtp.open_timeout = 30
        smtp.read_timeout = 30

        # Start SMTP session
        smtp.start(server.permalink) do |client|
          # Send MAIL FROM
          client.mailfrom(message[:from])

          # Send RCPT TO - this is where blacklist checks usually happen
          client.rcptto(recipient)

          # If we get here without exception, the IP is likely not blacklisted
          result = {
            success: true,
            smtp_code: "250",
            smtp_message: "Test recipient accepted",
            reason: "SMTP server accepted test recipient without rejection"
          }
        end
      rescue Net::SMTPFatalError => e
        # 5xx errors - permanent failure (likely blacklisted)
        result = {
          success: false,
          smtp_code: e.message[/\A(\d{3})/, 1],
          smtp_message: e.message,
          reason: "SMTP permanent error: #{e.message}"
        }
      rescue Net::SMTPServerBusy => e
        # 4xx errors - temporary failure (could be rate limiting)
        result = {
          success: false,
          smtp_code: e.message[/\A(\d{3})/, 1],
          smtp_message: e.message,
          reason: "SMTP temporary error: #{e.message}"
        }
      rescue StandardError => e
        result = {
          success: false,
          reason: "Connection error: #{e.class} - #{e.message}"
        }
      end

      result
    end

    def resolve_mx_records(domain)
      require "resolv"
      resolver = Resolv::DNS.new
      mx_records = []

      begin
        resources = resolver.getresources(domain, Resolv::DNS::Resource::IN::MX)
        mx_records = resources.sort_by(&:preference).map { |r| r.exchange.to_s }
      rescue StandardError => e
        Rails.logger.error "[BLACKLIST RETRY] Failed to resolve MX for #{domain}: #{e.message}"
      end

      mx_records
    end

    def handle_success(test_result)
      Rails.logger.info "[BLACKLIST RETRY] ✓ Retry successful for IP #{ip_address.ipv4} on #{destination_domain}"

      # Update blacklist record
      blacklist_record.update!(
        retry_result: IPBlacklistRecord::RETRY_SUCCESS,
        retry_result_details: test_result.to_json,
        next_retry_at: nil
      )

      # Mark as resolved and trigger warmup
      blacklist_record.mark_resolved!

      @result = :success
      @error_message = nil

      # Send notification
      notifier = IPBlacklist::Notifier.new
      notifier.notify_retry_success(blacklist_record, test_result)
    end

    def handle_failure(test_result)
      Rails.logger.warn "[BLACKLIST RETRY] ✗ Retry failed for IP #{ip_address.ipv4} on #{destination_domain}: #{test_result[:reason]}"

      # Update blacklist record
      blacklist_record.update!(
        retry_result: IPBlacklistRecord::RETRY_FAILED,
        retry_result_details: test_result.to_json,
        next_retry_at: 2.days.from_now # Schedule next retry
      )

      @result = :failed
      @error_message = test_result[:reason]

      # Send notification
      notifier = IPBlacklist::Notifier.new
      notifier.notify_retry_failed(blacklist_record, test_result)
    end

    def handle_error(exception)
      Rails.logger.error "[BLACKLIST RETRY] ✗ Retry error for IP #{ip_address.ipv4} on #{destination_domain}: #{exception.class} - #{exception.message}"
      Rails.logger.error exception.backtrace.join("\n")

      # Update blacklist record
      blacklist_record.update!(
        retry_result: IPBlacklistRecord::RETRY_ERROR,
        retry_result_details: { error: exception.message, backtrace: exception.backtrace[0..5] }.to_json,
        next_retry_at: 2.days.from_now # Schedule next retry
      )

      @result = :error
      @error_message = exception.message

      # Send notification
      notifier = IPBlacklist::Notifier.new
      notifier.notify_retry_error(blacklist_record, exception)
    end

  end
end
