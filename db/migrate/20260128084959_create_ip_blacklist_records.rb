# frozen_string_literal: true

class CreateIPBlacklistRecords < ActiveRecord::Migration[7.1]

  def change
    create_table :ip_blacklist_records, id: :integer do |t|
      t.integer :ip_address_id, null: false
      t.string :destination_domain, null: false
      t.string :blacklist_source, null: false
      t.string :status, null: false, default: "active"
      t.text :details
      t.datetime :detected_at, null: false
      t.datetime :resolved_at
      t.datetime :last_checked_at
      t.integer :check_count, default: 0
      t.timestamps
    end

    add_index :ip_blacklist_records, :ip_address_id
    add_index :ip_blacklist_records, :destination_domain
    add_index :ip_blacklist_records, [:status, :last_checked_at]
    add_index :ip_blacklist_records, [:ip_address_id, :destination_domain, :blacklist_source],
              name: "index_blacklist_on_ip_domain_source", unique: true
    add_foreign_key :ip_blacklist_records, :ip_addresses
  end

end
