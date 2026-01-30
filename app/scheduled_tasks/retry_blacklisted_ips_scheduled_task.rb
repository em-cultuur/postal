# frozen_string_literal: true

class RetryBlacklistedIpsScheduledTask < ApplicationScheduledTask

  def call
    logger.info "[BLACKLIST RETRY] Starting automatic retry check for SMTP-detected blacklists"

    records_to_retry = IPBlacklistRecord.needs_retry
    retry_count = 0
    success_count = 0
    failure_count = 0
    error_count = 0

    logger.info "[BLACKLIST RETRY] Found #{records_to_retry.count} blacklist records ready for retry"

    records_to_retry.find_each do |record|
      logger.info "[BLACKLIST RETRY] Processing retry for IP #{record.ip_address.ipv4} on domain #{record.destination_domain}"

      begin
        retry_service = IPBlacklist::RetryService.new(record)
        result = retry_service.perform_retry

        retry_count += 1

        case result
        when :success
          success_count += 1
          logger.info "[BLACKLIST RETRY] ✓ IP #{record.ip_address.ipv4} successfully verified for #{record.destination_domain}"
        when :failed
          failure_count += 1
          logger.warn "[BLACKLIST RETRY] ✗ IP #{record.ip_address.ipv4} still blacklisted for #{record.destination_domain}"
        when :error
          error_count += 1
          logger.error "[BLACKLIST RETRY] ✗ Error retrying IP #{record.ip_address.ipv4} for #{record.destination_domain}"
        end
      rescue StandardError => e
        error_count += 1
        logger.error "[BLACKLIST RETRY] Exception processing retry for record #{record.id}: #{e.message}"
        logger.error e.backtrace.join("\n")

        # Schedule next retry even on exception
        begin
          record.update(next_retry_at: 2.days.from_now)
        rescue StandardError
          nil
        end
      end
    end

    logger.info "[BLACKLIST RETRY] Completed. Total: #{retry_count}, Success: #{success_count}, Failed: #{failure_count}, Errors: #{error_count}"
  end

  # Run every 6 hours
  def self.next_run_after
    6.hours.from_now
  end

end
