# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_domain_cache
#
#  id               :integer          not null, primary key
#  expires_at       :datetime         not null
#  mx_domain        :string(255)      not null
#  mx_records       :text(65535)
#  recipient_domain :string(255)      not null
#  resolved_at      :datetime         not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_mx_domain_cache_on_expires_at        (expires_at)
#  index_mx_domain_cache_on_recipient_domain  (recipient_domain) UNIQUE
#
FactoryBot.define do
  factory :mx_domain_cache do
    sequence(:recipient_domain) { |n| "domain-#{n}.com" }
    sequence(:mx_domain) { |n| "mx-#{n}.example.com" }
    resolved_at { Time.current }
    expires_at { 1.hour.from_now }
    mx_records { nil }

    trait :expired do
      expires_at { 1.hour.ago }
    end

    trait :with_mx_records do
      mx_records { ["10 mx1.example.com", "20 mx2.example.com"].to_json }
    end
  end
end
