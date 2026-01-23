# frozen_string_literal: true

class CleanupMXRateLimitDataTask < ApplicationScheduledTask

  def call
    cleanup_inactive_rate_limits
    cleanup_old_events
    cleanup_expired_cache
  end

  def self.next_run_after
    # Run every hour
    1.hour.from_now
  end

  private

  def cleanup_inactive_rate_limits
    deleted_count = MXRateLimit.cleanup_inactive
    return unless deleted_count > 0

    logger.info "Cleaned up #{deleted_count} inactive MX rate limits"
  end

  def cleanup_old_events
    deleted_count = MXRateLimitEvent.cleanup_old
    return unless deleted_count > 0

    logger.info "Cleaned up #{deleted_count} old MX rate limit events"
  end

  def cleanup_expired_cache
    deleted_count = MXDomainCache.cleanup_expired
    return unless deleted_count > 0

    logger.info "Cleaned up #{deleted_count} expired MX domain cache entries"
  end

end
