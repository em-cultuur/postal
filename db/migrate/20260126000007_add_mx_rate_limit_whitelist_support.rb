# frozen_string_literal: true

class AddMXRateLimitWhitelistSupport < ActiveRecord::Migration[7.1]

  def change
    # Add whitelisting flag to MX rate limits table
    add_column :mx_rate_limits, :whitelisted, :boolean, default: false, comment: "Skip rate limiting for this MX domain"

    # Add a separate whitelist table for managing whitelisted domains
    create_table :mx_rate_limit_whitelists, id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci" do |t|
      t.integer :server_id, null: false
      t.string :mx_domain, null: false, comment: "Whitelisted MX domain (e.g., mail.example.com)"
      t.string :pattern_type, null: false, default: "exact", comment: "exact, prefix, or regex"
      t.text :description, comment: "Why this domain is whitelisted"
      t.integer :created_by_id, comment: "User who created the whitelist entry"
      t.timestamps precision: nil
    end

    add_index :mx_rate_limit_whitelists, [:server_id, :mx_domain], unique: true, name: "index_whitelist_on_server_and_mx"
    add_index :mx_rate_limit_whitelists, :server_id, name: "index_whitelist_on_server"
    add_foreign_key :mx_rate_limit_whitelists, :servers
    add_foreign_key :mx_rate_limit_whitelists, :users, column: :created_by_id

    # Add index on whitelisted flag for quick filtering
    add_index :mx_rate_limits, [:server_id, :whitelisted], name: "index_mx_rate_limits_whitelisted"
  end

end
