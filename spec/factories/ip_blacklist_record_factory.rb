# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_blacklist_records
#
#  id                      :integer          not null, primary key
#  blacklist_source        :string(255)      not null
#  check_count             :integer          default(0)
#  destination_domain      :string(255)      not null
#  details                 :text(65535)
#  detected_at             :datetime         not null
#  detection_method        :string(255)      default("dnsbl_check")
#  last_checked_at         :datetime
#  last_retry_at           :datetime
#  next_retry_at           :datetime
#  resolved_at             :datetime
#  retry_count             :integer          default(0), not null
#  retry_result            :string(255)
#  retry_result_details    :text(65535)
#  smtp_response_code      :string(255)
#  smtp_response_message   :text(65535)
#  status                  :string(255)      default("active"), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  ip_address_id           :integer          not null
#  smtp_rejection_event_id :integer
#
# Indexes
#
#  index_blacklist_on_ip_domain_source                       (ip_address_id,destination_domain,blacklist_source) UNIQUE
#  index_ip_blacklist_records_on_destination_domain          (destination_domain)
#  index_ip_blacklist_records_on_detection_method            (detection_method)
#  index_ip_blacklist_records_on_ip_address_id               (ip_address_id)
#  index_ip_blacklist_records_on_next_retry_at               (next_retry_at)
#  index_ip_blacklist_records_on_smtp_rejection_event_id     (smtp_rejection_event_id)
#  index_ip_blacklist_records_on_status_and_last_checked_at  (status,last_checked_at)
#  index_ip_blacklist_records_on_status_and_next_retry_at    (status,next_retry_at)
#
# Foreign Keys
#
#  fk_rails_...  (ip_address_id => ip_addresses.id)
#  fk_rails_...  (smtp_rejection_event_id => smtp_rejection_events.id)
#
FactoryBot.define do
  factory :ip_blacklist_record do
    ip_address
    destination_domain { "gmail.com" }
    blacklist_source { "spamhaus_zen" }
    status { "active" }
    detected_at { Time.current }
    check_count { 1 }

    trait :resolved do
      status { "resolved" }
      resolved_at { Time.current }
    end

    trait :ignored do
      status { "ignored" }
    end

    trait :with_details do
      details { { reason: "Listed for spam", code: 127 }.to_json }
    end
  end
end
