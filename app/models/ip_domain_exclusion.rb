# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_domain_exclusions
#
#  id                     :integer          not null, primary key
#  destination_domain     :string(255)      not null
#  excluded_at            :datetime         not null
#  excluded_until         :datetime
#  next_warmup_at         :datetime
#  reason                 :string(255)
#  warmup_stage           :integer          default(0)
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  ip_address_id          :integer          not null
#  ip_blacklist_record_id :integer
#
# Indexes
#
#  fk_rails_9800e8bc75                           (ip_blacklist_record_id)
#  index_exclusions_on_ip_domain                 (ip_address_id,destination_domain) UNIQUE
#  index_ip_domain_exclusions_on_excluded_until  (excluded_until)
#  index_ip_domain_exclusions_on_ip_address_id   (ip_address_id)
#  index_ip_domain_exclusions_on_next_warmup_at  (next_warmup_at)
#
# Foreign Keys
#
#  fk_rails_...  (ip_address_id => ip_addresses.id)
#  fk_rails_...  (ip_blacklist_record_id => ip_blacklist_records.id)
#

class IPDomainExclusion < ApplicationRecord

  # Associations
  belongs_to :ip_address
  belongs_to :ip_blacklist_record, optional: true

  # Warmup stages configuration
  WARMUP_STAGES = {
    0 => { priority: 0,   duration: nil },      # Paused
    1 => { priority: 20,  duration: 2.days },
    2 => { priority: 40,  duration: 3.days },
    3 => { priority: 60,  duration: 3.days },
    4 => { priority: 80,  duration: 4.days },
    5 => { priority: 100, duration: nil }       # Full recovery
  }.freeze

  # Validations
  validates :destination_domain, presence: true
  validates :excluded_at, presence: true
  validates :warmup_stage, inclusion: { in: WARMUP_STAGES.keys }

  # Scopes
  scope :active, -> { where("excluded_until IS NULL OR excluded_until > ?", Time.current) }
  scope :expired, -> { where("excluded_until IS NOT NULL AND excluded_until <= ?", Time.current) }
  scope :ready_for_warmup, -> { where("next_warmup_at IS NOT NULL AND next_warmup_at <= ?", Time.current) }
  scope :paused, -> { where(warmup_stage: 0) }
  scope :warming, -> { where("warmup_stage > 0 AND warmup_stage < 5") }
  scope :for_domain, -> (domain) { where(destination_domain: domain) }

  # Instance methods

  def advance_warmup_stage!
    return if warmup_stage >= 5

    old_stage = warmup_stage
    new_stage = warmup_stage + 1
    stage_config = WARMUP_STAGES[new_stage]

    update!(
      warmup_stage: new_stage,
      next_warmup_at: stage_config[:duration] ? Time.current + stage_config[:duration] : nil
    )

    # Log action
    IPHealthAction.create!(
      ip_address: ip_address,
      action_type: IPHealthAction::WARMUP_STAGE_ADVANCE,
      destination_domain: destination_domain,
      reason: "Advanced to warmup stage #{new_stage}",
      previous_priority: WARMUP_STAGES[old_stage][:priority],
      new_priority: stage_config[:priority]
    )

    Rails.logger.info "[WARMUP] IP #{ip_address.ipv4} advanced to stage #{new_stage} for domain #{destination_domain}"

    # Send notification
    notifier = IPBlacklist::Notifier.new
    notifier.notify_warmup_advanced(ip_address, destination_domain, old_stage, new_stage)

    # If fully recovered, remove exclusion
    return unless new_stage == 5

    Rails.logger.info "[WARMUP] IP #{ip_address.ipv4} fully recovered for domain #{destination_domain}"
    destroy
  end

  def current_priority
    WARMUP_STAGES[warmup_stage][:priority]
  end

  def stage_config
    WARMUP_STAGES[warmup_stage]
  end

  def paused?
    warmup_stage == 0
  end

  def warming?
    warmup_stage > 0 && warmup_stage < 5
  end

  def fully_recovered?
    warmup_stage == 5
  end

  def active?
    excluded_until.nil? || excluded_until > Time.current
  end

  def expired?
    !active?
  end

  def days_until_next_warmup
    return nil if next_warmup_at.nil?

    ((next_warmup_at - Time.current) / 1.day).ceil
  end

  def warmup_progress_percentage
    return 0 if warmup_stage == 0
    return 100 if warmup_stage >= 5

    (warmup_stage.to_f / 5 * 100).round
  end

end
