# frozen_string_literal: true

module Postal
  module MessageDB
    module Migrations
      class AddTimeToDeliveries < Postal::MessageDB::Migration

        def up
          # Check if column already exists (for fresh installs that include it in CREATE TABLE)
          result = @database.query("SELECT COUNT(*) as count FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '#{@database.database_name}' AND TABLE_NAME = 'deliveries' AND COLUMN_NAME = 'time'").first
          return if result["count"] > 0

          @database.query("ALTER TABLE `#{@database.database_name}`.`deliveries` ADD COLUMN `time` decimal(8,2)")
        end

      end
    end
  end
end
