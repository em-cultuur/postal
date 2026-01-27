# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rate_limit_events
#
#  id                :integer          not null, primary key
#  delay_after       :integer
#  delay_before      :integer
#  error_count       :integer
#  event_type        :string(255)      not null
#  matched_pattern   :string(255)
#  mx_domain         :string(255)      not null
#  recipient_domain  :string(255)
#  smtp_response     :text(65535)
#  success_count     :integer
#  created_at        :datetime
#  queued_message_id :integer
#  server_id         :integer          not null
#
# Indexes
#
#  index_mx_rate_limit_events_on_created_at         (created_at)
#  index_mx_rate_limit_events_on_event_type         (event_type)
#  index_mx_rate_limit_events_on_queued_message_id  (queued_message_id)
#  index_mx_rate_limit_events_on_server_and_mx      (server_id,mx_domain)
#
# Foreign Keys
#
#  fk_rails_...  (server_id => servers.id)
#

class MXRateLimitEvent < ApplicationRecord

  EVENT_TYPES = %w[error success delay_increased delay_decreased throttled].freeze

  belongs_to :server
  belongs_to :queued_message, optional: true

  validates :mx_domain, presence: true
  validates :event_type, presence: true
  validates :event_type, inclusion: { in: EVENT_TYPES }

  scope :errors, -> { where(event_type: "error") }
  scope :successes, -> { where(event_type: "success") }
  scope :throttled, -> { where(event_type: "throttled") }
  scope :recent, -> { where("created_at > ?", 24.hours.ago) }

  # Get statistics for an MX domain
  #
  # @param server [Server] the server to query
  # @param mx_domain [String] the MX domain to query
  # @param since [Time] the time from which to gather stats (default: 24 hours ago)
  # @return [Hash] hash of event_type => count
  def self.stats_for_mx(server, mx_domain, since: 24.hours.ago)
    where(server: server, mx_domain: mx_domain)
      .where("created_at > ?", since)
      .group(:event_type)
      .count
  end

  # Delete events older than retention period
  #
  # @return [Integer] the number of records deleted
  def self.cleanup_old
    retention_days = Postal::Config.postal.mx_rate_limiting_event_retention_days
    where("created_at < ?", retention_days.days.ago).delete_all
  end

  # Check if a throttled event was recently logged for an MX domain
  #
  # @param server [Server] the server to check
  # @param mx_domain [String] the MX domain to check
  # @param within [ActiveSupport::Duration] the time window to check (default: from config)
  # @return [Boolean] true if a throttled event exists within the time window
  def self.recent_throttled_event_exists?(server, mx_domain, within: nil)
    window = within || Postal::Config.postal.mx_rate_limiting_throttled_event_window.seconds
    throttled
      .where(server: server, mx_domain: mx_domain)
      .where("created_at > ?", window.ago)
      .exists?
  end

end
