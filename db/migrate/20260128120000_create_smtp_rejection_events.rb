# frozen_string_literal: true

class CreateSMTPRejectionEvents < ActiveRecord::Migration[7.1]

  def change
    create_table :smtp_rejection_events, id: :integer do |t|
      t.integer :ip_address_id, null: false
      t.string :destination_domain, null: false
      t.string :smtp_code, null: false # 421, 450, 550, 554, etc.
      t.string :bounce_type, null: false # 'soft' or 'hard'
      t.text :smtp_message
      t.text :parsed_details  # JSON with blacklist info if detected
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :smtp_rejection_events, :ip_address_id
    add_index :smtp_rejection_events, :destination_domain
    add_index :smtp_rejection_events, [:ip_address_id, :destination_domain, :occurred_at],
              name: "index_smtp_events_on_ip_domain_time"
    add_index :smtp_rejection_events, [:bounce_type, :occurred_at]
    add_foreign_key :smtp_rejection_events, :ip_addresses
  end

end
