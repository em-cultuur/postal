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

class IPReputationMetric < ApplicationRecord

  # Associations
  belongs_to :ip_address

  # Periods
  HOURLY = "hourly"
  DAILY = "daily"
  WEEKLY = "weekly"
  MONTHLY = "monthly"

  PERIODS = [HOURLY, DAILY, WEEKLY, MONTHLY].freeze

  # Metric Types (for external reputation data)
  METRIC_TYPE_GOOGLE_POSTMASTER = "google_postmaster_reputation"
  METRIC_TYPE_MICROSOFT_SNDS = "microsoft_snds"
  METRIC_TYPE_FEEDBACK_LOOP = "feedback_loop_complaint"

  METRIC_TYPES = [
    METRIC_TYPE_GOOGLE_POSTMASTER,
    METRIC_TYPE_MICROSOFT_SNDS,
    METRIC_TYPE_FEEDBACK_LOOP,
  ].freeze

  # Validations
  validates :period, inclusion: { in: PERIODS }
  validates :period_date, presence: true
  validates :metric_type, inclusion: { in: METRIC_TYPES }, allow_nil: true

  # Scopes
  scope :for_period, -> (period) { where(period: period) }
  scope :for_domain, -> (domain) { where(destination_domain: domain) }
  scope :for_sender, -> (domain) { where(sender_domain: domain) }
  scope :recent, -> (days = 30) { where("period_date >= ?", days.days.ago) }
  scope :ordered, -> { order(period_date: :desc) }
  scope :for_metric_type, -> (type) { where(metric_type: type) }
  scope :external_reputation, -> { where.not(metric_type: nil) }
  scope :internal_metrics, -> { where(metric_type: nil) }

  # Instance methods

  def calculate_rates
    IPMetrics::Calculator.calculate_rates(self)
  end

  def calculate_reputation_score
    self.reputation_score = IPMetrics::Calculator.calculate_reputation_score(self)
  end

  def reputation_status
    IPMetrics::Calculator.reputation_status(reputation_score)
  end

  def bounce_rate_status
    IPMetrics::Calculator.bounce_rate_status(bounce_rate)
  end

  def spam_rate_status
    IPMetrics::Calculator.spam_rate_status(spam_rate)
  end

  def delivery_rate_status
    IPMetrics::Calculator.delivery_rate_status(delivery_rate)
  end

  def analyze
    IPMetrics::Calculator.analyze_metric(self)
  end

  def bounce_rate_percentage
    bounce_rate / 100.0
  end

  def delivery_rate_percentage
    delivery_rate / 100.0
  end

  def spam_rate_percentage
    spam_rate / 100.0
  end

  # Class methods

  def self.record_send(ip_address_id, destination_domain: nil, sender_domain: nil)
    metric = find_or_create_for_today(ip_address_id, destination_domain, sender_domain)
    metric.increment!(:sent_count)
    metric
  end

  def self.record_delivery(ip_address_id, destination_domain: nil, sender_domain: nil)
    metric = find_or_create_for_today(ip_address_id, destination_domain, sender_domain)
    metric.increment!(:delivered_count)
    metric.calculate_rates
    metric.calculate_reputation_score
    metric.save
    metric
  end

  def self.record_bounce(ip_address_id, destination_domain: nil, sender_domain: nil, hard: false)
    metric = find_or_create_for_today(ip_address_id, destination_domain, sender_domain)
    metric.increment!(:bounced_count)
    metric.increment!(hard ? :hard_fail_count : :soft_fail_count)
    metric.calculate_rates
    metric.calculate_reputation_score
    metric.save
    metric
  end

  def self.record_spam_complaint(ip_address_id, destination_domain: nil, sender_domain: nil)
    metric = find_or_create_for_today(ip_address_id, destination_domain, sender_domain)
    metric.increment!(:spam_complaint_count)
    metric.calculate_rates
    metric.calculate_reputation_score
    metric.save
    metric
  end

  def self.find_or_create_for_today(ip_address_id, destination_domain, sender_domain)
    find_or_create_by!(
      ip_address_id: ip_address_id,
      destination_domain: destination_domain,
      sender_domain: sender_domain,
      period: DAILY,
      period_date: Date.current
    )
  end

end
