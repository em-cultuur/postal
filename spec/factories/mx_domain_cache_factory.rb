# frozen_string_literal: true

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
