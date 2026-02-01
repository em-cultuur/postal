# frozen_string_literal: true

class AddIndexesForQueuedMessageDeadlockPrevention < ActiveRecord::Migration[7.1]

  def change
    # Add composite index for the locking query
    # This index covers the WHERE clause in ProcessQueuedMessagesJob:
    # WHERE ip_address_id IN (...) AND locked_by IS NULL AND locked_at IS NULL AND (retry_after IS NULL OR retry_after < ?)
    add_index :queued_messages, [:locked_by, :locked_at, :retry_after, :ip_address_id],
              name: "index_queued_messages_on_lock_and_retry"

    # Add index for batch updates by domain (used in apply_domain_throttle_if_required)
    # WHERE server_id = ? AND domain = ? AND (retry_after IS NULL OR retry_after < ?)
    add_index :queued_messages, [:server_id, :domain, :retry_after],
              name: "index_queued_messages_on_server_domain_retry"

    # Add index for batch updates by mx_domain (used in requeue_messages_for_mx)
    # WHERE server_id = ? AND mx_domain = ? AND (retry_after IS NULL OR retry_after < ?)
    add_index :queued_messages, [:server_id, :mx_domain, :retry_after],
              name: "index_queued_messages_on_server_mx_retry"

    # Add index for batchable_messages query
    # WHERE batch_key = ? AND ip_address_id = ? AND locked_by IS NULL AND locked_at IS NULL
    add_index :queued_messages, [:batch_key, :ip_address_id, :locked_by, :locked_at],
              name: "index_queued_messages_on_batch_lock"
  end

end
