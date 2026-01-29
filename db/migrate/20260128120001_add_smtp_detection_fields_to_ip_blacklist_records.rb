# frozen_string_literal: true

class AddSMTPDetectionFieldsToIPBlacklistRecords < ActiveRecord::Migration[7.1]

  def change
    add_column :ip_blacklist_records, :detection_method, :string, default: "dnsbl_check"
    add_column :ip_blacklist_records, :smtp_response_code, :string
    add_column :ip_blacklist_records, :smtp_response_message, :text
    add_column :ip_blacklist_records, :smtp_rejection_event_id, :integer

    add_index :ip_blacklist_records, :detection_method
    add_index :ip_blacklist_records, :smtp_rejection_event_id
    add_foreign_key :ip_blacklist_records, :smtp_rejection_events, column: :smtp_rejection_event_id
  end

end
