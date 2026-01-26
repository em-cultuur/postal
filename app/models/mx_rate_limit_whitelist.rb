# frozen_string_literal: true

require "timeout"

# == Schema Information
#
# Table name: mx_rate_limit_whitelists
#
#  id                                                        :integer          not null, primary key
#  description(Why this domain is whitelisted)               :text(65535)
#  mx_domain(Whitelisted MX domain (e.g., mail.example.com)) :string(255)      not null
#  pattern_type(exact, prefix, or regex)                     :string(255)      default("exact"), not null
#  created_at                                                :datetime         not null
#  updated_at                                                :datetime         not null
#  created_by_id(User who created the whitelist entry)       :integer
#  server_id                                                 :integer          not null
#
# Indexes
#
#  fk_rails_680cf527f5               (created_by_id)
#  index_whitelist_on_server         (server_id)
#  index_whitelist_on_server_and_mx  (server_id,mx_domain) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (created_by_id => users.id)
#  fk_rails_...  (server_id => servers.id)
#

class MXRateLimitWhitelist < ApplicationRecord

  belongs_to :server
  belongs_to :created_by, class_name: "User", optional: true

  validates :mx_domain, presence: true
  validates :mx_domain, uniqueness: { scope: :server_id, case_sensitive: false }
  validates :pattern_type, inclusion: { in: %w[exact prefix regex] }

  # Normalize domain to lowercase for consistency
  before_save { self.mx_domain = mx_domain.downcase if mx_domain.present? }

  # Pattern types for whitelisting
  PATTERN_TYPES = {
    exact: "exact",
    prefix: "prefix",
    regex: "regex"
  }.freeze

  # Check if an MX domain matches this whitelist entry
  #
  # @param mx_domain [String] the domain to check
  # @return [Boolean] true if domain matches this whitelist rule
  def matches?(mx_domain)
    case pattern_type.to_sym
    when :exact
      self.mx_domain.downcase == mx_domain.downcase
    when :prefix
      mx_domain.downcase.start_with?(self.mx_domain.downcase)
    when :regex
      begin
        Timeout.timeout(0.1) do
          mx_domain.match?(Regexp.new(self.mx_domain))
        end
      rescue Timeout::Error, RegexpError, StandardError
        false
      end
    else
      false
    end
  end

  # Check if an MX domain is whitelisted for a server
  #
  # @param server [Server] the server to check
  # @param mx_domain [String] the MX domain to check
  # @return [Boolean] true if whitelisted
  def self.whitelisted?(server, mx_domain)
    return false if mx_domain.blank?

    where(server: server).any? { |whitelist| whitelist.matches?(mx_domain) }
  end

  # Get all whitelisted domains for a server
  #
  # @param server [Server] the server to get whitelists for
  # @return [Array<String>] array of whitelisted domain patterns
  def self.for_server(server)
    where(server: server).pluck(:mx_domain)
  end

end
