# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_reputation_metrics
#
#  id                   :integer          not null, primary key
#  auth_success_rate    :decimal(10, 4)
#  bounce_rate          :integer          default(0)
#  bounced_count        :integer          default(0)
#  complaint_rate       :decimal(10, 6)
#  delivered_count      :integer          default(0)
#  delivery_rate        :integer          default(0)
#  destination_domain   :string(255)
#  hard_fail_count      :integer          default(0)
#  metadata             :text(65535)
#  metric_type          :string(255)
#  metric_value         :decimal(10, 4)
#  period               :string(255)      default("daily"), not null
#  period_date          :date             not null
#  reputation_score     :integer          default(100)
#  sender_domain        :string(255)
#  sent_count           :integer          default(0)
#  soft_fail_count      :integer          default(0)
#  spam_complaint_count :integer          default(0)
#  spam_rate            :integer          default(0)
#  trap_hits            :integer          default(0)
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  ip_address_id        :integer          not null
#
# Indexes
#
#  index_ip_reputation_metrics_on_ip_address_id     (ip_address_id)
#  index_ip_reputation_metrics_on_metric_type       (metric_type)
#  index_ip_reputation_metrics_on_period_date       (period_date)
#  index_ip_reputation_metrics_on_reputation_score  (reputation_score)
#  index_ip_reputation_on_ip_type_date              (ip_address_id,metric_type,period_date)
#  index_reputation_on_ip_dest_period               (ip_address_id,destination_domain,period,period_date) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (ip_address_id => ip_addresses.id)
#
FactoryBot.define do
  factory :ip_reputation_metric do
    ip_address
    period { "daily" }
    period_date { Date.current }
    sent_count { 1000 }
    delivered_count { 950 }
    bounced_count { 50 }
    soft_fail_count { 30 }
    hard_fail_count { 20 }
    spam_complaint_count { 5 }
    reputation_score { 95 }

    trait :with_domain do
      destination_domain { "gmail.com" }
    end

    trait :with_sender do
      sender_domain { "example.com" }
    end

    trait :poor_reputation do
      sent_count { 1000 }
      delivered_count { 600 }
      bounced_count { 400 }
      spam_complaint_count { 50 }
      reputation_score { 30 }
    end

    trait :good_reputation do
      sent_count { 1000 }
      delivered_count { 990 }
      bounced_count { 10 }
      spam_complaint_count { 1 }
      reputation_score { 99 }
    end
  end
end
