# frozen_string_literal: true

class CreateIPHealthActions < ActiveRecord::Migration[7.1]

  def change
    create_table :ip_health_actions, id: :integer do |t|
      t.integer :ip_address_id, null: false
      t.string :action_type, null: false
      t.string :destination_domain
      t.text :reason
      t.integer :previous_priority
      t.integer :new_priority
      t.boolean :paused, default: false
      t.integer :triggered_by_blacklist_id
      t.integer :user_id
      t.timestamps
    end

    add_index :ip_health_actions, :ip_address_id
    add_index :ip_health_actions, [:ip_address_id, :created_at]
    add_index :ip_health_actions, [:action_type, :created_at]
    add_foreign_key :ip_health_actions, :ip_addresses
    add_foreign_key :ip_health_actions, :ip_blacklist_records, column: :triggered_by_blacklist_id
    add_foreign_key :ip_health_actions, :users
  end

end
