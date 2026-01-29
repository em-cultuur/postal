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
#  resolved_at             :datetime
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
#  index_ip_blacklist_records_on_smtp_rejection_event_id     (smtp_rejection_event_id)
#  index_ip_blacklist_records_on_status_and_last_checked_at  (status,last_checked_at)
#
# Foreign Keys
#
#  fk_rails_...  (ip_address_id => ip_addresses.id)
#  fk_rails_...  (smtp_rejection_event_id => smtp_rejection_events.id)
#

class IPBlacklistRecord < ApplicationRecord

  # Associations
  belongs_to :ip_address
  belongs_to :smtp_rejection_event, optional: true
  has_many :ip_health_actions, foreign_key: :triggered_by_blacklist_id, dependent: :nullify
  has_one :ip_domain_exclusion, dependent: :nullify

  # Detection methods
  DNSBL_CHECK = "dnsbl_check"
  SMTP_RESPONSE = "smtp_response"

  DETECTION_METHODS = [DNSBL_CHECK, SMTP_RESPONSE].freeze

  # Statuses
  ACTIVE = "active"
  RESOLVED = "resolved"
  IGNORED = "ignored"

  STATUSES = [ACTIVE, RESOLVED, IGNORED].freeze

  # Validations
  validates :destination_domain, presence: true
  validates :blacklist_source, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :detection_method, inclusion: { in: DETECTION_METHODS }
  validates :detected_at, presence: true

  # Scopes
  scope :active, -> { where(status: ACTIVE) }
  scope :resolved, -> { where(status: RESOLVED) }
  scope :ignored, -> { where(status: IGNORED) }
  scope :for_domain, -> (domain) { where(destination_domain: domain) }
  scope :from_dnsbl, -> { where(detection_method: DNSBL_CHECK) }
  scope :from_smtp, -> { where(detection_method: SMTP_RESPONSE) }
  scope :needs_check, lambda {
    where(status: ACTIVE)
      .where("last_checked_at IS NULL OR last_checked_at < ?", 1.hour.ago)
  }
  scope :recent, -> { order(detected_at: :desc) }

  # Instance methods

  def mark_resolved!
    update!(status: RESOLVED, resolved_at: Time.current)
    trigger_recovery_actions
  end

  def mark_ignored!
    update!(status: IGNORED)
  end

  def parsed_details
    return {} if details.blank?

    JSON.parse(details)
  rescue JSON::ParserError
    {}
  end

  def active?
    status == ACTIVE
  end

  def resolved?
    status == RESOLVED
  end

  def ignored?
    status == IGNORED
  end

  def detected_via_smtp?
    detection_method == SMTP_RESPONSE
  end

  def detected_via_dnsbl?
    detection_method == DNSBL_CHECK
  end

  private

  def trigger_recovery_actions
    # Start warmup process through IPHealthManager
    Rails.logger.info "[BLACKLIST] IP #{ip_address.ipv4} delisted from #{blacklist_source} for domain #{destination_domain.presence || 'all domains'}"

    # Only trigger warmup for domain-specific blacklists
    return if destination_domain.blank?

    # Trigger warmup if this was the only active blacklist for this domain
    other_active_blacklists = IPBlacklistRecord
                              .where(ip_address: ip_address, destination_domain: destination_domain, status: ACTIVE)
                              .where.not(id: id)
                              .exists?

    if other_active_blacklists
      Rails.logger.info "[BLACKLIST] Other active blacklists still exist for IP #{ip_address.ipv4} on domain #{destination_domain}, warmup delayed"
    else
      Rails.logger.info "[BLACKLIST] No other active blacklists for IP #{ip_address.ipv4} on domain #{destination_domain}, starting warmup"
      IPBlacklist::IPHealthManager.start_warmup(ip_address, destination_domain)
    end
  end

end
