# frozen_string_literal: true

# == Schema Information
#
# Table name: smtp_rejection_events
#
#  id                 :integer          not null, primary key
#  bounce_type        :string(255)      not null
#  destination_domain :string(255)      not null
#  occurred_at        :datetime         not null
#  parsed_details     :text(65535)
#  smtp_code          :string(255)      not null
#  smtp_message       :text(65535)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  ip_address_id      :integer          not null
#
# Indexes
#
#  index_smtp_events_on_ip_domain_time                         (ip_address_id,destination_domain,occurred_at)
#  index_smtp_rejection_events_on_bounce_type_and_occurred_at  (bounce_type,occurred_at)
#  index_smtp_rejection_events_on_destination_domain           (destination_domain)
#  index_smtp_rejection_events_on_ip_address_id                (ip_address_id)
#
# Foreign Keys
#
#  fk_rails_...  (ip_address_id => ip_addresses.id)
#

class SMTPRejectionEvent < ApplicationRecord

  # Associations
  belongs_to :ip_address
  has_many :ip_blacklist_records, foreign_key: :smtp_rejection_event_id, dependent: :nullify

  # Bounce types
  SOFT_BOUNCE = "soft"
  HARD_BOUNCE = "hard"

  BOUNCE_TYPES = [SOFT_BOUNCE, HARD_BOUNCE].freeze

  # Validations
  validates :destination_domain, presence: true
  validates :smtp_code, presence: true
  validates :bounce_type, inclusion: { in: BOUNCE_TYPES }
  validates :occurred_at, presence: true

  # Scopes
  scope :soft_bounces, -> { where(bounce_type: SOFT_BOUNCE) }
  scope :hard_bounces, -> { where(bounce_type: HARD_BOUNCE) }
  scope :for_domain, -> (domain) { where(destination_domain: domain) }
  scope :for_ip, -> (ip_address_id) { where(ip_address_id: ip_address_id) }
  scope :recent, -> (time = 1.hour.ago) { where("occurred_at >= ?", time) }
  scope :ordered, -> { order(occurred_at: :desc) }

  # Instance methods

  def soft_bounce?
    bounce_type == SOFT_BOUNCE
  end

  def hard_bounce?
    bounce_type == HARD_BOUNCE
  end

  def details
    return {} if parsed_details.blank?

    JSON.parse(parsed_details)
  rescue JSON::ParserError
    {}
  end

  def blacklist_detected?
    details["blacklist_detected"] == true
  end

  def blacklist_source
    details["blacklist_source"]
  end

  def smtp_code_category
    return nil if smtp_code.blank?

    case smtp_code[0]
    when "2"
      "success"
    when "4"
      "temporary_failure"
    when "5"
      "permanent_failure"
    else
      "unknown"
    end
  end

  # Class methods

  def self.count_recent_soft_bounces(ip_address_id, destination_domain, window_minutes = 60)
    soft_bounces
      .for_ip(ip_address_id)
      .for_domain(destination_domain)
      .where("occurred_at >= ?", window_minutes.minutes.ago)
      .count
  end

end
