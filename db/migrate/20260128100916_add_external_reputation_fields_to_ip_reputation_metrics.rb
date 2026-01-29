# frozen_string_literal: true

class AddExternalReputationFieldsToIPReputationMetrics < ActiveRecord::Migration[7.1]

  def change
    add_column :ip_reputation_metrics, :metric_type, :string
    add_column :ip_reputation_metrics, :metric_value, :decimal, precision: 10, scale: 4
    add_column :ip_reputation_metrics, :complaint_rate, :decimal, precision: 10, scale: 6
    add_column :ip_reputation_metrics, :auth_success_rate, :decimal, precision: 10, scale: 4
    add_column :ip_reputation_metrics, :trap_hits, :integer, default: 0
    add_column :ip_reputation_metrics, :metadata, :text

    add_index :ip_reputation_metrics, :metric_type
    add_index :ip_reputation_metrics, [:ip_address_id, :metric_type, :period_date], name: "index_ip_reputation_on_ip_type_date"
  end

end
