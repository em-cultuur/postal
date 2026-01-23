# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rate_limits
#
#  id                 :integer          not null, primary key
#  current_delay      :integer          default(0)
#  error_count        :integer          default(0)
#  last_error_at      :datetime
#  last_error_message :string(255)
#  last_success_at    :datetime
#  max_attempts       :integer          default(10)
#  mx_domain          :string(255)      not null
#  success_count      :integer          default(0)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  server_id          :integer          not null
#
# Indexes
#
#  index_mx_rate_limits_on_current_delay  (current_delay)
#  index_mx_rate_limits_on_last_error_at  (last_error_at)
#  index_mx_rate_limits_on_server_and_mx  (server_id,mx_domain) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (server_id => servers.id)
#
FactoryBot.define do
  factory :mx_rate_limit do
    association :server
    sequence(:mx_domain) { |n| "mx-#{n}.example.com" }
    current_delay { 0 }
    error_count { 0 }
    success_count { 0 }
    max_attempts { 10 }

    trait :active do
      current_delay { 300 }
      error_count { 1 }
      last_error_at { Time.current }
      last_error_message { "421 4.7.0 Try again later, closing connection" }
    end

    trait :heavily_throttled do
      current_delay { 3600 }
      error_count { 10 }
      last_error_at { Time.current }
      last_error_message { "421 4.7.0 Rate limit exceeded" }
    end

    trait :recovering do
      current_delay { 300 }
      error_count { 0 }
      success_count { 3 }
      last_success_at { Time.current }
    end
  end
end
