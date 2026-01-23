# frozen_string_literal: true

module Postal
  module MessageDB
    module Migrations
      class AddIpAddressIdToDeliveries < Postal::MessageDB::Migration

        def up
          @database.query("ALTER TABLE `#{@database.database_name}`.`deliveries` ADD COLUMN `ip_address_id` int(11)")
        end

        def down
          @database.query("ALTER TABLE `#{@database.database_name}`.`deliveries` DROP COLUMN `ip_address_id`")
        end

      end
    end
  end
end
