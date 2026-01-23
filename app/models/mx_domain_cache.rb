# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_domain_cache
#
#  id               :integer          not null, primary key
#  recipient_domain :string(255)      not null
#  mx_domain        :string(255)      not null
#  mx_records       :text
#  resolved_at      :datetime         not null
#  expires_at       :datetime         not null
#  created_at       :datetime
#  updated_at       :datetime
#
# Indexes
#
#  index_mx_domain_cache_on_expires_at        (expires_at)
#  index_mx_domain_cache_on_recipient_domain  (recipient_domain) UNIQUE
#

class MXDomainCache < ApplicationRecord

  self.table_name = "mx_domain_cache"

  # Default cache TTL (1 hour)
  DEFAULT_TTL = 3600

  validates :recipient_domain, presence: true
  validates :mx_domain, presence: true
  validates :recipient_domain, uniqueness: true

  scope :expired, -> { where("expires_at < ?", Time.current) }

  # Resolve MX domain for a recipient domain (with caching)
  #
  # @param recipient_domain [String] the recipient email domain
  # @return [String, nil] the resolved MX domain or nil
  def self.resolve(recipient_domain)
    return nil if recipient_domain.blank?

    normalized_domain = recipient_domain.downcase

    # Try to find cached entry
    cache_entry = find_by(recipient_domain: normalized_domain)

    if cache_entry && !cache_entry.expired?
      return cache_entry.mx_domain
    end

    # Cache miss or expired - resolve via service
    # This will be implemented in MxDomainResolver service
    nil
  end

  # Delete expired cache entries
  #
  # @return [Integer] the number of records deleted
  def self.cleanup_expired
    expired.delete_all
  end

  # Check if this cache entry has expired
  #
  # @return [Boolean]
  def expired?
    expires_at < Time.current
  end

end
