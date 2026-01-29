# frozen_string_literal: true

class CheckIPBlacklistsScheduledTask < ApplicationScheduledTask

  def call
    logger.info "[BLACKLIST CHECK] Starting IP blacklist check for all IPs"

    checked_count = 0
    error_count = 0

    IPAddress.find_each do |ip_address|
      logger.info "[BLACKLIST CHECK] Checking IP: #{ip_address.ipv4}"

      checker = IPBlacklist::Checker.new(ip_address, logger: logger)
      checker.check_all_dnsbls

      checked_count += 1
    rescue StandardError => e
      logger.error "[BLACKLIST CHECK] Error checking IP #{ip_address.ipv4}: #{e.message}"
      logger.error e.backtrace.join("\n")
      error_count += 1
    end

    logger.info "[BLACKLIST CHECK] Completed. Checked: #{checked_count} IPs, Errors: #{error_count}"
  end

  # Run every 15 minutes
  def self.next_run_after
    15.minutes.from_now
  end

end
