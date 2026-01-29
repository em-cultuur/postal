# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rate_limits
#
#  id                                                 :integer          not null, primary key
#  current_delay                                      :integer          default(0)
#  error_count                                        :integer          default(0)
#  last_error_at                                      :datetime
#  last_error_message                                 :string(255)
#  last_success_at                                    :datetime
#  max_attempts                                       :integer          default(10)
#  mx_domain                                          :string(255)      not null
#  success_count                                      :integer          default(0)
#  whitelisted(Skip rate limiting for this MX domain) :boolean          default(FALSE)
#  created_at                                         :datetime         not null
#  updated_at                                         :datetime         not null
#  server_id                                          :integer          not null
#
# Indexes
#
#  index_mx_rate_limits_on_current_delay  (current_delay)
#  index_mx_rate_limits_on_last_error_at  (last_error_at)
#  index_mx_rate_limits_on_server_and_mx  (server_id,mx_domain) UNIQUE
#  index_mx_rate_limits_whitelisted       (server_id,whitelisted)
#
# Foreign Keys
#
#  fk_rails_...  (server_id => servers.id)
#

class MXRateLimit < ApplicationRecord

  # Maximum length for error messages stored in last_error_message field (matches DB column length)
  MAX_ERROR_MESSAGE_LENGTH = 255

  # Maximum length for SMTP responses stored in events (text field allows 65535 but truncate for consistency)
  MAX_SMTP_RESPONSE_LENGTH = 512

  belongs_to :server

  # Delete associated events when rate limit is destroyed
  before_destroy :delete_associated_events

  # Events are associated by server_id and mx_domain (no direct foreign key)
  # Use MXRateLimitEvent.where(server_id: rate_limit.server_id, mx_domain: rate_limit.mx_domain)
  # to query events for this rate limit

  # NOTE: whitelist is managed separately in MXRateLimitWhitelist table
  # Use MXRateLimitWhitelist.whitelisted?(server, mx_domain) to check

  validates :mx_domain, presence: true
  validates :mx_domain, uniqueness: { scope: :server_id }
  validates :current_delay, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where("current_delay > ?", 0) }
  scope :inactive, -> { where(current_delay: 0) }

  # Get events for this rate limit
  #
  # @return [ActiveRecord::Relation<MXRateLimitEvent>]
  def events
    MXRateLimitEvent.where(server_id: server_id, mx_domain: mx_domain)
  end

  # Configuration accessors
  #
  # @return [Integer] delay increment in seconds
  def self.delay_increment
    Postal::Config.postal.mx_rate_limiting_delay_increment
  end

  # @return [Integer] maximum delay in seconds
  def self.max_delay
    Postal::Config.postal.mx_rate_limiting_max_delay
  end

  # @return [Integer] recovery success threshold
  def self.recovery_threshold
    Postal::Config.postal.mx_rate_limiting_recovery_threshold
  end

  # @return [Integer] delay decrement in seconds
  def self.delay_decrement
    Postal::Config.postal.mx_rate_limiting_delay_decrement
  end

  # @return [Boolean] whether MX rate limiting is enabled
  def self.enabled?
    Postal::Config.postal.mx_rate_limiting_enabled
  end

  # @return [Boolean] whether running in shadow mode
  def self.shadow_mode?
    Postal::Config.postal.mx_rate_limiting_shadow_mode
  end

  # Check if an MX domain is currently rate limited for a given server
  #
  # @param server [Server] the server to check
  # @param mx_domain [String] the MX domain to check
  # @return [Boolean] true if rate limited, false otherwise
  def self.rate_limited?(server, mx_domain)
    return false if mx_domain.blank?

    # Check if domain is whitelisted first
    return false if MXRateLimitWhitelist.whitelisted?(server, mx_domain)

    active.exists?(server: server, mx_domain: mx_domain.downcase)
  end

  # Check if an MX domain is whitelisted and should skip rate limiting
  #
  # @param server [Server] the server to check
  # @param mx_domain [String] the MX domain to check
  # @return [Boolean] true if whitelisted
  def self.whitelisted?(server, mx_domain)
    MXRateLimitWhitelist.whitelisted?(server, mx_domain)
  end

  # Remove inactive rate limits (delay=0, last_success > cleanup threshold)
  # Also removes abandoned active rate limits (delay>0 but no activity for delay * multiplier)
  #
  # @return [Integer] the number of records deleted
  def self.cleanup_inactive
    deleted_count = 0

    # Cleanup inactive rate limits (delay=0)
    # Use destroy_all to trigger callbacks and clean up associated events
    cleanup_hours = Postal::Config.postal.mx_rate_limiting_inactive_cleanup_hours
    inactive_records = inactive
                       .where("last_success_at < ?", cleanup_hours.hours.ago)
                       .to_a
    deleted_count += inactive_records.size
    inactive_records.each(&:destroy)

    # Cleanup abandoned active rate limits (delay>0 but no recent activity)
    deleted_count += cleanup_abandoned

    deleted_count
  end

  # Remove abandoned active rate limits that have had no activity for a long time
  # Criteria: current_delay > 0 AND last_activity_at < (current_delay * multiplier) ago
  # Also applies a minimum threshold to prevent premature cleanup of short delays
  #
  # @return [Integer] the number of records deleted
  def self.cleanup_abandoned
    multiplier = Postal::Config.postal.mx_rate_limiting_abandoned_multiplier
    min_hours = Postal::Config.postal.mx_rate_limiting_abandoned_min_hours
    min_threshold_seconds = min_hours.hours.to_i

    deleted_count = 0

    # Process in batches to avoid loading all records at once
    active.find_each do |rate_limit|
      # Calculate the most recent activity timestamp
      last_activity = [rate_limit.last_success_at, rate_limit.last_error_at].compact.max

      # Skip if no activity recorded (shouldn't happen, but be safe)
      next unless last_activity

      # Calculate time since last activity in seconds
      time_since_activity = (Time.current - last_activity).to_i

      # Calculate the abandonment threshold (max of delay-based and minimum absolute)
      delay_based_threshold = rate_limit.current_delay * multiplier
      abandonment_threshold = [delay_based_threshold, min_threshold_seconds].max

      # Delete if abandoned
      if time_since_activity >= abandonment_threshold
        rate_limit.destroy
        deleted_count += 1
      end
    end

    deleted_count
  end

  # Record an error and apply rate limiting
  #
  # @param smtp_response [String] the SMTP error message
  # @param pattern [String] the matched pattern name
  # @param queued_message [QueuedMessage] the message that triggered the error
  # @return [void]
  def record_error(smtp_response:, pattern: nil, queued_message: nil)
    transaction do
      increment!(:error_count)
      delay_inc = self.class.delay_increment
      max_delay_val = self.class.max_delay
      previous_delay = current_delay
      new_delay = [current_delay + delay_inc, max_delay_val].min

      update_columns(
        success_count: 0,
        current_delay: new_delay,
        last_error_at: Time.current,
        last_error_message: smtp_response.to_s.truncate(MAX_ERROR_MESSAGE_LENGTH),
        updated_at: Time.current
      )

      # Log event
      events.create!(
        server_id: server_id,
        mx_domain: mx_domain,
        recipient_domain: queued_message&.domain,
        event_type: "error",
        delay_before: previous_delay,
        delay_after: new_delay,
        error_count: error_count,
        success_count: success_count,
        smtp_response: smtp_response.to_s.truncate(MAX_SMTP_RESPONSE_LENGTH),
        matched_pattern: pattern,
        queued_message_id: queued_message&.id
      )

      # Log delay increase
      if previous_delay != new_delay
        events.create!(
          server_id: server_id,
          mx_domain: mx_domain,
          recipient_domain: queued_message&.domain,
          event_type: "delay_increased",
          delay_before: previous_delay,
          delay_after: new_delay,
          error_count: error_count,
          success_count: success_count,
          queued_message_id: queued_message&.id
        )
      end
    end
  end

  # Record a successful delivery
  #
  # @param queued_message [QueuedMessage] the message that was successfully sent
  # @return [void]
  def record_success(queued_message: nil)
    transaction do
      increment!(:success_count)
      update_columns(
        error_count: 0,
        last_success_at: Time.current,
        updated_at: Time.current
      )

      # Check if we should reduce delay
      recovery_thresh = self.class.recovery_threshold
      delay_dec = self.class.delay_decrement

      if success_count >= recovery_thresh && current_delay > 0
        previous_delay = current_delay
        new_delay = [current_delay - delay_dec, 0].max

        update_columns(
          current_delay: new_delay,
          success_count: 0,
          updated_at: Time.current
        )

        # Log delay decrease
        events.create!(
          server_id: server_id,
          mx_domain: mx_domain,
          recipient_domain: queued_message&.domain,
          event_type: "delay_decreased",
          delay_before: previous_delay,
          delay_after: new_delay,
          error_count: error_count,
          success_count: 0,
          queued_message_id: queued_message&.id
        )
      end

      # Log success
      events.create!(
        server_id: server_id,
        mx_domain: mx_domain,
        recipient_domain: queued_message&.domain,
        event_type: "success",
        delay_before: current_delay,
        delay_after: current_delay,
        error_count: error_count,
        success_count: success_count,
        queued_message_id: queued_message&.id
      )
    end
  end

  # Check if this rate limit is currently active
  #
  # @return [Boolean]
  def active?
    current_delay > 0
  end

  # Get the number of seconds to wait before next send
  #
  # @return [Integer] seconds to wait
  def wait_seconds
    current_delay
  end

  # Mark that a probe message is being attempted
  # Updates last_error_at to prevent multiple simultaneous probes
  #
  # @return [void]
  def mark_probe_attempt
    update_columns(last_error_at: Time.current, updated_at: Time.current)
  end

  # Check if enough time has passed to allow a probe message
  # Probes help break deadlock by testing if remote server now accepts messages
  #
  # @return [Boolean] true if a probe should be allowed
  def allow_probe?
    return false unless last_error_at.present?
    return false unless active?

    time_since_last_attempt = Time.current - last_error_at
    time_since_last_attempt >= current_delay
  end

  private

  # Delete all associated events when the rate limit is destroyed
  # This callback ensures events don't become orphaned
  #
  # @return [void]
  def delete_associated_events
    events.delete_all
  end

end
