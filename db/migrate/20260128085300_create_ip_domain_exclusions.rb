# frozen_string_literal: true

class CreateIPDomainExclusions < ActiveRecord::Migration[7.1]

  def change
    create_table :ip_domain_exclusions, id: :integer do |t|
      t.integer :ip_address_id, null: false
      t.string :destination_domain, null: false
      t.datetime :excluded_at, null: false
      t.datetime :excluded_until
      t.string :reason
      t.integer :warmup_stage, default: 0
      t.datetime :next_warmup_at
      t.integer :ip_blacklist_record_id
      t.timestamps
    end

    add_index :ip_domain_exclusions, :ip_address_id
    add_index :ip_domain_exclusions, [:ip_address_id, :destination_domain],
              name: "index_exclusions_on_ip_domain", unique: true
    add_index :ip_domain_exclusions, :excluded_until
    add_index :ip_domain_exclusions, :next_warmup_at
    add_foreign_key :ip_domain_exclusions, :ip_addresses
    add_foreign_key :ip_domain_exclusions, :ip_blacklist_records
  end

end
