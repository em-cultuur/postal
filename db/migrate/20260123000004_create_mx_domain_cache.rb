# frozen_string_literal: true

class CreateMXDomainCache < ActiveRecord::Migration[7.1]

  def change
    create_table :mx_domain_cache, id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci" do |t|
      t.string :recipient_domain, null: false
      t.string :mx_domain, null: false
      t.text :mx_records
      t.datetime :resolved_at, null: false
      t.datetime :expires_at, null: false
      t.timestamps precision: nil
    end

    add_index :mx_domain_cache, :recipient_domain, unique: true
    add_index :mx_domain_cache, :expires_at
  end

end
