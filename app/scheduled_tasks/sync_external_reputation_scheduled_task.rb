# frozen_string_literal: true

class SyncExternalReputationScheduledTask < ApplicationScheduledTask

  def call
    logger.info "[REPUTATION SYNC] Starting external reputation data sync"

    processor = IPReputation::Processor.new

    # Process Microsoft SNDS data (IP-level)
    if processor.snds_client.configured?
      sync_microsoft_snds(processor)
    else
      logger.info "[REPUTATION SYNC] Microsoft SNDS not configured, skipping"
    end

    # Process Google Postmaster data (domain-level)
    if processor.google_client.configured?
      sync_google_postmaster(processor)
    else
      logger.info "[REPUTATION SYNC] Google Postmaster not configured, skipping"
    end

    logger.info "[REPUTATION SYNC] Completed"
  end

  # Run daily at 6 AM
  def self.next_run_after
    now = Time.current
    scheduled_time = now.change(hour: 6, min: 0, sec: 0)

    # If it's already past 6 AM today, schedule for tomorrow
    scheduled_time += 1.day if now > scheduled_time

    scheduled_time
  end

  private

  def sync_microsoft_snds(processor)
    logger.info "[REPUTATION SYNC] Syncing Microsoft SNDS data"

    ip_count = 0
    error_count = 0

    IPAddress.find_each do |ip_address|
      logger.debug "[REPUTATION SYNC] Processing SNDS data for IP: #{ip_address.ipv4}"

      data = processor.send(:process_microsoft_snds, ip_address)

      if data
        ip_count += 1
        logger.info "[REPUTATION SYNC] SNDS - #{ip_address.ipv4}: #{data[:filter_result]} " \
                    "(complaint_rate: #{data[:complaint_rate]}, traps: #{data[:trap_message_end_users]})"
      end
    rescue StandardError => e
      logger.error "[REPUTATION SYNC] Error processing SNDS for IP #{ip_address.ipv4}: #{e.message}"
      logger.error e.backtrace.join("\n")
      error_count += 1
    end

    logger.info "[REPUTATION SYNC] SNDS complete. Processed: #{ip_count} IPs, Errors: #{error_count}"
  end

  def sync_google_postmaster(processor)
    logger.info "[REPUTATION SYNC] Syncing Google Postmaster data"

    # Google Postmaster is domain-based, so we process by domain
    domains = major_email_domains

    domain_count = 0
    error_count = 0

    domains.each do |domain|
      logger.debug "[REPUTATION SYNC] Processing Google Postmaster data for domain: #{domain}"

      data = processor.process_domain_reputation(domain)

      if data
        domain_count += 1
        logger.info "[REPUTATION SYNC] Postmaster - #{domain}: #{data[:domain_reputation]} " \
                    "(spam_rate: #{(data[:spam_rate] * 100).round(2)}%, " \
                    "user_spam_rate: #{(data[:user_reported_spam_rate] * 100).round(2)}%)"
      end
    rescue StandardError => e
      logger.error "[REPUTATION SYNC] Error processing Google Postmaster for domain #{domain}: #{e.message}"
      logger.error e.backtrace.join("\n")
      error_count += 1
    end

    logger.info "[REPUTATION SYNC] Google Postmaster complete. Processed: #{domain_count} domains, Errors: #{error_count}"
  end

  def major_email_domains
    # Major ISPs that use Google Postmaster or have reputation systems
    [
      "gmail.com",
      "googlemail.com",
      "yahoo.com",
      "aol.com",
      "outlook.com",
      "hotmail.com",
      "live.com",
    ]
  end

end
