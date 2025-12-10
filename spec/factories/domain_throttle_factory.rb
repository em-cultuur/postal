# frozen_string_literal: true

FactoryBot.define do
  factory :domain_throttle do
    association :server
    sequence(:domain) { |n| "throttled-domain-#{n}.com" }
    throttled_until { 5.minutes.from_now }
    reason { "451 Too many messages, slow down" }
  end
end

