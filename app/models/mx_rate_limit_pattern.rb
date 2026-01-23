# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rate_limit_patterns
#
#  id              :integer          not null, primary key
#  action          :string(255)
#  enabled         :boolean          default(TRUE)
#  name            :string(255)      not null
#  pattern         :text(65535)      not null
#  priority        :integer          default(0)
#  suggested_delay :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_mx_rate_limit_patterns_on_enabled   (enabled)
#  index_mx_rate_limit_patterns_on_priority  (priority)
#

class MXRateLimitPattern < ApplicationRecord

  VALID_ACTIONS = %w[rate_limit hard_fail soft_fail].freeze

  validates :name, presence: true
  validates :pattern, presence: true
  validates :action, inclusion: { in: VALID_ACTIONS }

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(priority: :desc) }

  # Find the first matching pattern for an SMTP message
  #
  # @param smtp_message [String] the SMTP error message to match
  # @return [MxRateLimitPattern, nil] the first matching pattern or nil
  def self.match_message(smtp_message)
    return nil if smtp_message.blank?

    enabled.ordered.find { |pattern| pattern.match?(smtp_message) }
  end

  # Create default rate limiting patterns
  #
  # @return [Array<MxRateLimitPattern>] the created patterns
  def self.create_defaults!
    default_patterns = [
      {
        name: "SMTP 421 Rate Limit",
        pattern: '\b421\b.*\b(rate limit|too many)\b',
        action: "rate_limit",
        priority: 100,
        suggested_delay: 300
      },
      {
        name: "SMTP 450 Rate Limit",
        pattern: '\b450\b.*\b(rate limit|too many)\b',
        action: "rate_limit",
        priority: 90,
        suggested_delay: 300
      },
      {
        name: "SMTP 451 Temporary",
        pattern: '\b451\b.*\b(try again|slow down|temporarily deferred)\b',
        action: "rate_limit",
        priority: 80,
        suggested_delay: 300
      },
      {
        name: "Too Many Messages",
        pattern: '\b(too many messages|too many connections|sending rate)\b',
        action: "rate_limit",
        priority: 70,
        suggested_delay: 300
      },
      {
        name: "Temporarily Rejected",
        pattern: '\b(temporarily rejected|temporarily deferred)\b.*\b(rate|limit)\b',
        action: "rate_limit",
        priority: 60,
        suggested_delay: 300
      },
      {
        name: "Permanent Block",
        pattern: '\b5[0-9]{2}\b.*\b(blocked|blacklisted|banned)\b',
        action: "hard_fail",
        priority: 50
      },
    ]

    default_patterns.map do |attrs|
      find_or_create_by!(name: attrs[:name]) do |pattern|
        pattern.assign_attributes(attrs)
      end
    end
  end

  # Test if this pattern matches an SMTP message
  #
  # @param smtp_message [String] the SMTP error message to test
  # @return [Boolean] true if the pattern matches
  def match?(smtp_message)
    return false if smtp_message.blank? || pattern.blank?

    regex = Regexp.new(pattern, Regexp::IGNORECASE)
    regex.match?(smtp_message)
  rescue RegexpError => e
    Rails.logger.error("Invalid regex pattern '#{pattern}': #{e.message}")
    false
  end

end
