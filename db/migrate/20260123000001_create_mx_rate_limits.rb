# frozen_string_literal: true

class CreateMXRateLimits < ActiveRecord::Migration[7.1]

  def change
    create_table :mx_rate_limits, id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci" do |t|
      t.integer :server_id, null: false
      t.string :mx_domain, null: false
      t.integer :current_delay, default: 0
      t.integer :error_count, default: 0
      t.integer :success_count, default: 0
      t.datetime :last_error_at
      t.datetime :last_success_at
      t.string :last_error_message
      t.integer :max_attempts, default: 10
      t.timestamps precision: nil
    end

    add_index :mx_rate_limits, [:server_id, :mx_domain], unique: true, name: "index_mx_rate_limits_on_server_and_mx"
    add_index :mx_rate_limits, :current_delay
    add_index :mx_rate_limits, :last_error_at
    add_foreign_key :mx_rate_limits, :servers
  end

end
