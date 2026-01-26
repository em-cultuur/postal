# frozen_string_literal: true

# == Schema Information
#
# Table name: domain_throttles
#
#  id              :integer          not null, primary key
#  domain          :string(255)      not null
#  reason          :string(255)
#  throttled_until :datetime         not null
#  created_at      :datetime
#  updated_at      :datetime
#  server_id       :integer          not null
#
# Indexes
#
#  index_domain_throttles_on_server_id_and_domain  (server_id,domain) UNIQUE
#  index_domain_throttles_on_throttled_until       (throttled_until)
#

class DomainThrottle < ApplicationRecord

  # Default throttle duration in seconds (5 minutes)
  DEFAULT_THROTTLE_DURATION = 300

  # Maximum throttle duration in seconds (30 minutes)
  MAX_THROTTLE_DURATION = 1800

  belongs_to :server

  validates :domain, presence: true
  validates :throttled_until, presence: true
  validates :domain, uniqueness: { scope: :server_id }

  scope :active, -> { where("throttled_until > ?", Time.current) }
  scope :expired, -> { where("throttled_until <= ?", Time.current) }

  # Check if a domain is currently throttled for a given server
  #
  # @param server [Server] the server to check
  # @param domain [String] the domain to check
  # @return [DomainThrottle, nil] the throttle record if active, nil otherwise
  def self.throttled?(server, domain)
    active.find_by(server: server, domain: domain.to_s.downcase)
  end

  # Apply or extend a throttle for a domain
  #
  # @param server [Server] the server to throttle for
  # @param domain [String] the domain to throttle
  # @param duration [Integer] duration in seconds
  # @param reason [String] the reason for throttling (e.g., the SMTP error message)
  # @return [DomainThrottle] the created or updated throttle record
  def self.apply(server, domain, duration: DEFAULT_THROTTLE_DURATION, reason: nil)
    normalized_domain = domain.to_s.downcase
    throttle = find_or_initialize_by(server: server, domain: normalized_domain)

    # If already throttled, extend the duration with exponential backoff
    if throttle.persisted? && throttle.throttled_until > Time.current
      # Double the remaining time, but cap at MAX_THROTTLE_DURATION
      remaining = throttle.throttled_until - Time.current
      new_duration = [(remaining * 2).to_i, duration, MAX_THROTTLE_DURATION].min
      duration = [new_duration, duration].max
    end

    throttle.throttled_until = Time.current + duration.seconds
    throttle.reason = reason.to_s.truncate(255) if reason.present?
    throttle.save!
    throttle
  end

  # Remove expired throttles from the database
  #
  # @return [Integer] the number of records deleted
  def self.cleanup_expired
    expired.delete_all
  end

  # Get the remaining throttle time in seconds
  #
  # @return [Integer] seconds remaining, or 0 if expired
  def remaining_seconds
    return 0 if throttled_until <= Time.current

    (throttled_until - Time.current).to_i
  end

  # Check if this throttle is still active
  #
  # @return [Boolean]
  def active?
    throttled_until > Time.current
  end

end

