# frozen_string_literal: true

# == Schema Information
#
# Table name: queued_messages
#
#  id            :integer          not null, primary key
#  server_id     :integer
#  message_id    :integer
#  domain        :string(255)
#  locked_by     :string(255)
#  locked_at     :datetime
#  retry_after   :datetime
#  created_at    :datetime
#  updated_at    :datetime
#  ip_address_id :integer
#  attempts      :integer          default(0)
#  route_id      :integer
#  manual        :boolean          default(FALSE)
#  batch_key     :string(255)
#
# Indexes
#
#  index_queued_messages_on_domain      (domain)
#  index_queued_messages_on_message_id  (message_id)
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

    self.ip_address = pool.ip_addresses.select_by_priority
  end

  # Reallocate a different IP address for retry attempts (e.g., after a SoftFail).
  # Tries to select a different IP from the current one if possible.
  def reallocate_ip_address
    return unless Postal.ip_pools?
    return if message.nil?

    pool = server.ip_pool_for_message(message)
    return if pool.nil?

    available_ips = pool.ip_addresses.where.not(id: ip_address_id)
    new_ip = if available_ips.exists?
               available_ips.select_by_priority
             else
               # If there's only one IP in the pool, keep the same one
               pool.ip_addresses.select_by_priority
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

end
