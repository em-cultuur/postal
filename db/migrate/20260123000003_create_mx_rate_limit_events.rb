# frozen_string_literal: true

class CreateMXRateLimitEvents < ActiveRecord::Migration[7.1]

  def change
    create_table :mx_rate_limit_events, id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci" do |t|
      t.integer :server_id, null: false
      t.string :mx_domain, null: false
      t.string :recipient_domain
      t.string :event_type, null: false
      t.integer :delay_before
      t.integer :delay_after
      t.integer :error_count
      t.integer :success_count
      t.text :smtp_response
      t.string :matched_pattern
      t.integer :queued_message_id
      t.datetime :created_at, precision: nil
    end

    add_index :mx_rate_limit_events, [:server_id, :mx_domain], name: "index_mx_rate_limit_events_on_server_and_mx"
    add_index :mx_rate_limit_events, :event_type
    add_index :mx_rate_limit_events, :created_at
    add_index :mx_rate_limit_events, :queued_message_id
    add_foreign_key :mx_rate_limit_events, :servers
  end

end
