# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_addresses
#
#  id         :integer          not null, primary key
#  ip_pool_id :integer
#  ipv4       :string(255)
#  ipv6       :string(255)
#  created_at :datetime
#  updated_at :datetime
#  hostname   :string(255)
#  priority   :integer
#

class IPAddress < ApplicationRecord

  belongs_to :ip_pool

  # Blacklist management associations
  has_many :ip_blacklist_records, dependent: :destroy
  has_many :ip_health_actions, dependent: :destroy
  has_many :ip_domain_exclusions, dependent: :destroy
  has_many :ip_reputation_metrics, dependent: :destroy

  validates :ipv4, presence: true, uniqueness: true
  validates :hostname, presence: true
  validates :ipv6, uniqueness: { allow_blank: true }
  validates :priority, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100, only_integer: true }

  scope :order_by_priority, -> { order(priority: :desc) }

  # Blacklist-aware scopes
  scope :healthy_for_domain, lambda { |domain|
    # Only filter out paused IPs (warmup_stage == 0)
    # Warming IPs (stages 1-4) should still be available with reduced priority
    where.not(id: IPDomainExclusion.active.paused.where(destination_domain: domain).select(:ip_address_id))
  }

  scope :not_blacklisted_for_domain, lambda { |domain|
    where.not(id: IPBlacklistRecord.active.where(destination_domain: domain).select(:ip_address_id))
  }

  scope :available_for_sending, lambda { |destination_domain|
    healthy_for_domain(destination_domain)
      .not_blacklisted_for_domain(destination_domain)
  }

  before_validation :set_default_priority

  # Instance methods for blacklist management

  def blacklisted_for?(destination_domain)
    ip_blacklist_records.active.where(destination_domain: destination_domain).exists?
  end

  def excluded_for?(destination_domain)
    ip_domain_exclusions.active.where(destination_domain: destination_domain).exists?
  end

  def health_status_for(destination_domain)
    if excluded_for?(destination_domain)
      exclusion = ip_domain_exclusions.active.find_by(destination_domain: destination_domain)
      {
        status: "excluded",
        warmup_stage: exclusion.warmup_stage,
        priority: exclusion.current_priority,
        reason: exclusion.reason
      }
    elsif blacklisted_for?(destination_domain)
      {
        status: "blacklisted",
        priority: 0,
        blacklists: ip_blacklist_records.active.where(destination_domain: destination_domain).pluck(:blacklist_source)
      }
    else
      {
        status: "healthy",
        priority: priority
      }
    end
  end

  def effective_priority_for_domain(destination_domain)
    if excluded_for?(destination_domain)
      exclusion = ip_domain_exclusions.active.find_by(destination_domain: destination_domain)
      exclusion.current_priority
    elsif blacklisted_for?(destination_domain)
      0
    else
      priority
    end
  end

  private

  def set_default_priority
    return if priority.present?

    self.priority = 100
  end

  class << self

    def select_by_priority
      order(Arel.sql("RAND() * priority DESC")).first
    end

    # Domain-aware IP selection with blacklist filtering
    def select_by_priority_for_domain(destination_domain)
      available = available_for_sending(destination_domain)

      # Get effective priorities considering exclusions
      weighted = available.map do |ip|
        [ip, ip.effective_priority_for_domain(destination_domain)]
      end

      # Remove paused IPs
      weighted.reject! { |_, priority| priority == 0 }

      return nil if weighted.empty?

      # Weighted random selection
      total = weighted.sum { |_, p| p }
      random = rand(total)

      cumulative = 0
      weighted.each do |ip, priority|
        cumulative += priority
        return ip if random < cumulative
      end

      weighted.last.first
    end

  end

end
