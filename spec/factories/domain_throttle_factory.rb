# frozen_string_literal: true

# == Schema Information
#
# Table name: domain_throttles
#
#  id              :integer          not null, primary key
#  domain          :string(255)      not null
#  reason          :string(255)
#  throttled_until :datetime         not null
#  created_at      :datetime
#  updated_at      :datetime
#  server_id       :integer          not null
#
# Indexes
#
#  index_domain_throttles_on_server_id_and_domain  (server_id,domain) UNIQUE
#  index_domain_throttles_on_throttled_until       (throttled_until)
#
FactoryBot.define do
  factory :domain_throttle do
    association :server
    sequence(:domain) { |n| "throttled-domain-#{n}.com" }
    throttled_until { 5.minutes.from_now }
    reason { "451 Too many messages, slow down" }
  end
end

