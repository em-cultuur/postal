# frozen_string_literal: true

class PopulateDefaultMXRateLimitPatterns < ActiveRecord::Migration[7.1]

  def up
    MXRateLimitPattern.create_defaults!
  end

  def down
    # This is a data migration, so we don't delete data on rollback
    # The default patterns should remain in the database
  end

end
