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
FactoryBot.define do
  factory :ip_health_action do
    ip_address
    action_type { "pause" }
    destination_domain { "gmail.com" }
    reason { "IP blacklisted" }

    trait :automated do
      user { nil }
    end

    trait :manual do
      user
    end

    trait :pause do
      action_type { "pause" }
      paused { true }
      previous_priority { 100 }
      new_priority { 0 }
    end

    trait :unpause do
      action_type { "unpause" }
      paused { false }
      previous_priority { 0 }
      new_priority { 100 }
    end

    trait :warmup do
      action_type { "warmup_stage_advance" }
      previous_priority { 20 }
      new_priority { 40 }
    end

    trait :with_blacklist do
      triggered_by_blacklist factory: :ip_blacklist_record
    end
  end
end
