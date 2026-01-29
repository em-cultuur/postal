# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_health_actions
#
#  id                        :integer          not null, primary key
#  action_type               :string(255)      not null
#  destination_domain        :string(255)
#  new_priority              :integer
#  paused                    :boolean          default(FALSE)
#  previous_priority         :integer
#  reason                    :text(65535)
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  ip_address_id             :integer          not null
#  triggered_by_blacklist_id :integer
#  user_id                   :integer
#
# Indexes
#
#  fk_rails_ae85b5e5c9                                      (triggered_by_blacklist_id)
#  fk_rails_b7e206eaea                                      (user_id)
#  index_ip_health_actions_on_action_type_and_created_at    (action_type,created_at)
#  index_ip_health_actions_on_ip_address_id                 (ip_address_id)
#  index_ip_health_actions_on_ip_address_id_and_created_at  (ip_address_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (ip_address_id => ip_addresses.id)
#  fk_rails_...  (triggered_by_blacklist_id => ip_blacklist_records.id)
#  fk_rails_...  (user_id => users.id)
#

class IPHealthAction < ApplicationRecord

  # Associations
  belongs_to :ip_address
  belongs_to :triggered_by_blacklist, class_name: "IPBlacklistRecord", optional: true
  belongs_to :user, optional: true

  # Action types
  PAUSE = "pause"
  UNPAUSE = "unpause"
  PRIORITY_CHANGE = "priority_change"
  ROTATE = "rotate"
  WARMUP_STAGE_ADVANCE = "warmup_stage_advance"
  MANUAL_OVERRIDE = "manual_override"
  MONITOR = "monitor"

  ACTION_TYPES = [
    PAUSE,
    UNPAUSE,
    PRIORITY_CHANGE,
    ROTATE,
    WARMUP_STAGE_ADVANCE,
    MANUAL_OVERRIDE,
    MONITOR,
  ].freeze

  # Validations
  validates :action_type, inclusion: { in: ACTION_TYPES }

  # Scopes
  scope :automated, -> { where(user_id: nil) }
  scope :manual, -> { where.not(user_id: nil) }
  scope :recent, -> (days = 30) { where("created_at > ?", days.days.ago).order(created_at: :desc) }
  scope :for_domain, -> (domain) { where(destination_domain: domain) }
  scope :by_type, -> (type) { where(action_type: type) }

  # Instance methods

  def automated?
    user_id.nil?
  end

  def manual?
    !automated?
  end

  def pause_action?
    action_type == PAUSE
  end

  def unpause_action?
    action_type == UNPAUSE
  end

  def warmup_action?
    action_type == WARMUP_STAGE_ADVANCE
  end

  def priority_changed?
    previous_priority.present? && new_priority.present? && previous_priority != new_priority
  end

  def priority_delta
    return nil unless priority_changed?

    new_priority - previous_priority
  end

  def human_action_type
    action_type.humanize
  end

  def summary
    parts = [human_action_type]
    parts << "for #{destination_domain}" if destination_domain.present?
    parts << "(#{reason})" if reason.present?
    parts.join(" ")
  end

end
