# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_domain_exclusions
#
#  id                     :integer          not null, primary key
#  destination_domain     :string(255)      not null
#  excluded_at            :datetime         not null
#  excluded_until         :datetime
#  next_warmup_at         :datetime
#  reason                 :string(255)
#  warmup_stage           :integer          default(0)
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  ip_address_id          :integer          not null
#  ip_blacklist_record_id :integer
#
# Indexes
#
#  fk_rails_9800e8bc75                           (ip_blacklist_record_id)
#  index_exclusions_on_ip_domain                 (ip_address_id,destination_domain) UNIQUE
#  index_ip_domain_exclusions_on_excluded_until  (excluded_until)
#  index_ip_domain_exclusions_on_ip_address_id   (ip_address_id)
#  index_ip_domain_exclusions_on_next_warmup_at  (next_warmup_at)
#
# Foreign Keys
#
#  fk_rails_...  (ip_address_id => ip_addresses.id)
#  fk_rails_...  (ip_blacklist_record_id => ip_blacklist_records.id)
#
FactoryBot.define do
  factory :ip_domain_exclusion do
    ip_address
    destination_domain { "gmail.com" }
    excluded_at { Time.current }
    warmup_stage { 0 }
    reason { "Blacklisted" }

    trait :warming do
      warmup_stage { 2 }
      next_warmup_at { 3.days.from_now }
    end

    trait :paused do
      warmup_stage { 0 }
    end

    trait :with_blacklist do
      ip_blacklist_record
    end
  end
end
