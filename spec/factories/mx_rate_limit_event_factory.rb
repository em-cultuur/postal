# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rate_limit_events
#
#  id                :integer          not null, primary key
#  delay_after       :integer
#  delay_before      :integer
#  error_count       :integer
#  event_type        :string(255)      not null
#  matched_pattern   :string(255)
#  mx_domain         :string(255)      not null
#  recipient_domain  :string(255)
#  smtp_response     :text(65535)
#  success_count     :integer
#  created_at        :datetime
#  queued_message_id :integer
#  server_id         :integer          not null
#
# Indexes
#
#  index_mx_rate_limit_events_on_created_at         (created_at)
#  index_mx_rate_limit_events_on_event_type         (event_type)
#  index_mx_rate_limit_events_on_queued_message_id  (queued_message_id)
#  index_mx_rate_limit_events_on_server_and_mx      (server_id,mx_domain)
#
# Foreign Keys
#
#  fk_rails_...  (server_id => servers.id)
#
FactoryBot.define do
  factory :mx_rate_limit_event do
    association :server
    mx_domain { "google.com" }
    recipient_domain { "gmail.com" }
    event_type { "error" }
    delay_before { 0 }
    delay_after { 300 }
    error_count { 1 }
    success_count { 0 }
    created_at { Time.current }

    trait :success do
      event_type { "success" }
      error_count { 0 }
      success_count { 1 }
    end

    trait :delay_increased do
      event_type { "delay_increased" }
    end

    trait :delay_decreased do
      event_type { "delay_decreased" }
      delay_before { 300 }
      delay_after { 120 }
    end

    trait :throttled do
      event_type { "throttled" }
    end

    trait :with_smtp_response do
      smtp_response { "421 4.7.0 Try again later, closing connection" }
      matched_pattern { "SMTP 421 Rate Limit" }
    end
  end
end
