# frozen_string_literal: true

# == Schema Information
#
# Table name: queued_messages
#
#  id            :integer          not null, primary key
#  attempts      :integer          default(0)
#  batch_key     :string(255)
#  domain        :string(255)
#  locked_at     :datetime
#  locked_by     :string(255)
#  manual        :boolean          default(FALSE)
#  mx_domain     :string(255)
#  retry_after   :datetime
#  created_at    :datetime
#  updated_at    :datetime
#  ip_address_id :integer
#  message_id    :integer
#  route_id      :integer
#  server_id     :integer
#
# Indexes
#
#  index_queued_messages_on_domain      (domain)
#  index_queued_messages_on_message_id  (message_id)
#  index_queued_messages_on_mx_domain   (mx_domain)
#  index_queued_messages_on_server_id   (server_id)
#

class QueuedMessage < ApplicationRecord

  include HasMessage
  include HasLocking

  belongs_to :server
  belongs_to :ip_address, optional: true

  before_create :allocate_ip_address

  scope :ready_with_delayed_retry, -> { where("retry_after IS NULL OR retry_after < ?", 30.seconds.ago) }
  scope :with_stale_lock, -> { where("locked_at IS NOT NULL AND locked_at < ?", Postal::Config.postal.queued_message_lock_stale_days.days.ago) }

  def retry_now
    update!(retry_after: nil)
  end

  def send_bounce
    return unless message.send_bounces?

    BounceMessage.new(server, message).queue
  end

  def allocate_ip_address
    return unless Postal.ip_pools?
    return if message.nil?

    pool = server.ip_pool_for_message(message)
    return if pool.nil?

    # Extract destination domain from the queued message
    destination_domain = domain || extract_domain_from_message

    # Use domain-aware IP selection that respects blacklists and warmup status
    if destination_domain.present?
      self.ip_address = pool.ip_addresses.select_by_priority_for_domain(destination_domain)
    else
      # Fallback to basic priority selection if domain cannot be determined
      self.ip_address = pool.ip_addresses.select_by_priority
    end
  end

  # Reallocate a different IP address for retry attempts (e.g., after a SoftFail).
  # Tries to select a different IP from the current one if possible.
  def reallocate_ip_address
    return unless Postal.ip_pools?
    return if message.nil?

    pool = server.ip_pool_for_message(message)
    return if pool.nil?

    available_ips = pool.ip_addresses.where.not(id: ip_address_id)
    if available_ips.exists?
      new_ip = available_ips.select_by_priority
    else
      # If there's only one IP in the pool, keep the same one
      new_ip = pool.ip_addresses.select_by_priority
    end

    update_column(:ip_address_id, new_ip.id) if new_ip
  end

  def batchable_messages(limit = 10)
    unless locked?
      raise Postal::Error, "Must lock current message before locking any friends"
    end

    if batch_key.nil?
      []
    else
      time = Time.now
      locker = Postal.locker_name
      self.class.ready.where(batch_key: batch_key, ip_address_id: ip_address_id, locked_by: nil, locked_at: nil).limit(limit).update_all(locked_by: locker, locked_at: time)
      QueuedMessage.where(batch_key: batch_key, ip_address_id: ip_address_id, locked_by: locker, locked_at: time).where.not(id: id)
    end
  end

  # Resolve and cache MX domain for this message
  def resolve_mx_domain!
    return mx_domain if mx_domain.present?

    recipient_domain = message&.recipient_domain
    return nil unless recipient_domain

    resolved = MXDomainResolver.resolve(recipient_domain)
    update_column(:mx_domain, resolved)
    resolved
  end

  # Check if MX is currently rate limited
  def mx_rate_limited?
    return false unless mx_domain.present?

    MXRateLimit.rate_limited?(server, mx_domain)
  end

  # Get active rate limit for this message's MX
  def mx_rate_limit
    return nil unless mx_domain.present?

    MXRateLimit.find_by(server: server, mx_domain: mx_domain)
  end

  private

  def extract_domain_from_message
    # Try to extract domain from message recipient if domain field is not set
    return nil unless message

    return unless message.respond_to?(:rcpt_to) && message.rcpt_to.present?

    message.rcpt_to.split("@").last&.downcase
  end

end
