# frozen_string_literal: true

class RecheckResolvedBlacklistsScheduledTask < ApplicationScheduledTask

  def call
    logger.info "[BLACKLIST RECHECK] Starting recheck of resolved blacklists"

    # Re-check blacklists resolved in the last 30 days
    records = IPBlacklistRecord
              .where(status: IPBlacklistRecord::RESOLVED)
              .where("resolved_at > ?", 30.days.ago)
              .where("last_checked_at IS NULL OR last_checked_at < ?", 1.day.ago)
              .includes(:ip_address)

    logger.info "[BLACKLIST RECHECK] Found #{records.count} resolved blacklists to recheck"

    rechecked_count = 0
    re_blacklisted_count = 0
    error_count = 0

    records.find_each do |record|
      logger.info "[BLACKLIST RECHECK] Rechecking #{record.blacklist_source} for IP #{record.ip_address.ipv4}"

      checker = IPBlacklist::Checker.new(record.ip_address, logger: logger)

      # This will update the record and potentially mark it as active again
      checker.recheck_specific_blacklist(record)

      rechecked_count += 1

      # Check if it got re-blacklisted
      record.reload
      re_blacklisted_count += 1 if record.status == IPBlacklistRecord::ACTIVE
    rescue StandardError => e
      logger.error "[BLACKLIST RECHECK] Error rechecking record #{record.id}: #{e.message}"
      logger.error e.backtrace.join("\n")
      error_count += 1
    end

    logger.info "[BLACKLIST RECHECK] Completed. Rechecked: #{rechecked_count}, Re-blacklisted: #{re_blacklisted_count}, Errors: #{error_count}"
  end

  # Run daily at 4 AM
  def self.next_run_after
    time = Time.current.change(hour: 4, min: 0, sec: 0)
    time += 1.day if time < Time.current
    time
  end

end
