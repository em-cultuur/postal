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
FactoryBot.define do
  factory :mx_rate_limit_pattern do
    sequence(:name) { |n| "Pattern #{n}" }
    pattern { '\b421\b.*\b(rate limit|too many)\b' }
    enabled { true }
    priority { 100 }
    action { "rate_limit" }
    suggested_delay { 300 }

    trait :disabled do
      enabled { false }
    end

    trait :hard_fail do
      action { "hard_fail" }
      pattern { '\b5[0-9]{2}\b.*\b(blocked|blacklisted|banned)\b' }
    end

    trait :soft_fail do
      action { "soft_fail" }
    end
  end
end
