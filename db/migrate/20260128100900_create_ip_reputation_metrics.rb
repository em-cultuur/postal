# frozen_string_literal: true

class CreateIPReputationMetrics < ActiveRecord::Migration[7.1]

  def change
    create_table :ip_reputation_metrics, charset: "utf8mb4", collation: "utf8mb4_general_ci" do |t|
      t.integer :ip_address_id, null: false
      t.string :destination_domain
      t.string :sender_domain
      t.string :period, null: false, default: "daily"
      t.date :period_date, null: false
      t.integer :sent_count, default: 0
      t.integer :delivered_count, default: 0
      t.integer :bounced_count, default: 0
      t.integer :hard_fail_count, default: 0
      t.integer :soft_fail_count, default: 0
      t.integer :spam_complaint_count, default: 0
      t.integer :bounce_rate, default: 0
      t.integer :delivery_rate, default: 0
      t.integer :spam_rate, default: 0
      t.integer :reputation_score, default: 100
      t.timestamps precision: nil
    end

    add_index :ip_reputation_metrics, :ip_address_id
    add_index :ip_reputation_metrics, :period_date
    add_index :ip_reputation_metrics, :reputation_score
    add_index :ip_reputation_metrics, [:ip_address_id, :destination_domain, :period, :period_date],
              unique: true, name: "index_reputation_on_ip_dest_period"

    add_foreign_key :ip_reputation_metrics, :ip_addresses, column: :ip_address_id
  end

end
