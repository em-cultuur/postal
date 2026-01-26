# frozen_string_literal: true

class CreateMXRateLimitPatterns < ActiveRecord::Migration[7.1]

  def change
    create_table :mx_rate_limit_patterns, id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci" do |t|
      t.string :name, null: false
      t.text :pattern, null: false
      t.boolean :enabled, default: true
      t.integer :priority, default: 0
      t.string :action
      t.integer :suggested_delay
      t.timestamps precision: nil
    end

    add_index :mx_rate_limit_patterns, :enabled
    add_index :mx_rate_limit_patterns, :priority
  end

end
