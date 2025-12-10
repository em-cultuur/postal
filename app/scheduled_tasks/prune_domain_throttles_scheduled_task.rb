# frozen_string_literal: true

class PruneDomainThrottlesScheduledTask < ApplicationScheduledTask

  def call
    deleted_count = DomainThrottle.cleanup_expired
    if deleted_count > 0
      logger.info "Pruned #{deleted_count} expired domain throttles"
    end
  end

  def self.next_run_after
    # Run every 15 minutes
    15.minutes.from_now
  end

end

