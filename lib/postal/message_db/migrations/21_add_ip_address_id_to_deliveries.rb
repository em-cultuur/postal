# frozen_string_literal: true

module Postal
  module MessageDB
    module Migrations
      class AddIpAddressIdToDeliveries < Postal::MessageDB::Migration

        def up
          # Check if column already exists (for fresh installs that include it in CREATE TABLE)
          result = @database.query("SELECT COUNT(*) as count FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '#{@database.database_name}' AND TABLE_NAME = 'deliveries' AND COLUMN_NAME = 'ip_address_id'").first
          return if result["count"] > 0

          @database.query("ALTER TABLE `#{@database.database_name}`.`deliveries` ADD COLUMN `ip_address_id` int(11) NULL")
        end

        def down
          @database.query("ALTER TABLE `#{@database.database_name}`.`deliveries` DROP COLUMN `ip_address_id`")
        end

      end
    end
  end
end
