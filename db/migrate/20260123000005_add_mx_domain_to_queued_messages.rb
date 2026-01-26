# frozen_string_literal: true

class AddMXDomainToQueuedMessages < ActiveRecord::Migration[7.1]

  def change
    add_column :queued_messages, :mx_domain, :string
    add_index :queued_messages, :mx_domain
  end

end
