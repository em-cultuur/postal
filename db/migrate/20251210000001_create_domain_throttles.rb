# frozen_string_literal: true

class CreateDomainThrottles < ActiveRecord::Migration[7.1]
  def change
    create_table :domain_throttles, id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci" do |t|
      t.integer :server_id, null: false
      t.string :domain, null: false
      t.datetime :throttled_until, null: false
      t.string :reason
      t.timestamps precision: nil
    end

    add_index :domain_throttles, [:server_id, :domain], unique: true
    add_index :domain_throttles, :throttled_until
    add_foreign_key :domain_throttles, :servers
  end

end

