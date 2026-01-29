# frozen_string_literal: true

# Scheduled task to process IP warmup stages
# Runs every 6 hours to advance IPs through warmup stages after blacklist removal
#
# Warmup stages:
# - Stage 0: Paused (priority 0) - waiting for admin/automated trigger to start warmup
# - Stage 1: Priority 20 for 2 days
# - Stage 2: Priority 40 for 3 days
# - Stage 3: Priority 60 for 4 days
# - Stage 4: Priority 80 for 5 days
# - Stage 5: Priority 100 (full) - exclusion auto-deleted
#
class ProcessIPWarmupScheduledTask < ApplicationScheduledTask

  def call
    logger.info "[WARMUP PROCESSOR] Starting IP warmup processing"

    # Find all exclusions that are ready for the next warmup stage
    # - Must be in warmup (stage > 0)
    # - Must not be at final stage yet (stage < 5)
    # - Must have reached the scheduled warmup time
    ready_for_warmup = IPDomainExclusion
                       .where("warmup_stage > 0 AND warmup_stage < 5")
                       .where("next_warmup_at IS NOT NULL AND next_warmup_at <= ?", Time.current)
                       .includes(:ip_address)

    if ready_for_warmup.empty?
      logger.info "[WARMUP PROCESSOR] No IPs ready for warmup advancement"
      return
    end

    logger.info "[WARMUP PROCESSOR] Found #{ready_for_warmup.count} IP(s) ready for warmup advancement"

    advanced_count = 0
    error_count = 0

    ready_for_warmup.find_each do |exclusion|
      ip_address = exclusion.ip_address
      current_stage = exclusion.warmup_stage
      destination_domain = exclusion.destination_domain

      logger.info "[WARMUP PROCESSOR] Advancing IP #{ip_address.ipv4} for domain #{destination_domain} from stage #{current_stage}"

      # Advance to next stage
      exclusion.advance_warmup_stage!

      advanced_count += 1

      # Log if this completed the warmup
      if exclusion.destroyed?
        logger.info "[WARMUP PROCESSOR] IP #{ip_address.ipv4} completed warmup for domain #{destination_domain} (reached full priority)"
      else
        logger.info "[WARMUP PROCESSOR] IP #{ip_address.ipv4} advanced to stage #{exclusion.warmup_stage} for domain #{destination_domain}"
      end
    rescue StandardError => e
      error_count += 1
      logger.error "[WARMUP PROCESSOR] Error advancing warmup for IP #{exclusion.ip_address.ipv4} on domain #{exclusion.destination_domain}: #{e.message}"
      logger.error e.backtrace.join("\n")
    end

    logger.info "[WARMUP PROCESSOR] Completed: #{advanced_count} advanced, #{error_count} errors"
  end

  # Run every 6 hours
  def self.next_run_after
    6.hours.from_now
  end

end
