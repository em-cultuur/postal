# frozen_string_literal: true

class AddRetryFieldsToIPBlacklistRecords < ActiveRecord::Migration[7.1]

  def change
    add_column :ip_blacklist_records, :next_retry_at, :datetime
    add_column :ip_blacklist_records, :last_retry_at, :datetime
    add_column :ip_blacklist_records, :retry_count, :integer, default: 0, null: false
    add_column :ip_blacklist_records, :retry_result, :string
    add_column :ip_blacklist_records, :retry_result_details, :text

    add_index :ip_blacklist_records, :next_retry_at
    add_index :ip_blacklist_records, [:status, :next_retry_at]
  end

end
