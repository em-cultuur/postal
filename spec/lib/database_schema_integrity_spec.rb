# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Database Schema Integrity" do
  describe "schema version" do
    it "matches the latest migration timestamp" do
      # Ottieni tutte le migration dalla directory
      migration_files = Dir.glob(Rails.root.join("db", "migrate", "*.rb"))

      # Estrai i timestamp dalle migration
      migration_versions = migration_files.map do |file|
        File.basename(file).split("_").first.to_i
      end

      # Trova la versione più recente
      latest_migration_version = migration_versions.max

      # Ottieni la versione corrente dello schema
      schema_version = ActiveRecord::Base.connection.migration_context.current_version

      # Verifica che corrispondano
      expect(schema_version).to eq(latest_migration_version),
                                   "Schema version (#{schema_version}) should match the latest migration (#{latest_migration_version})"
    end
  end

  describe "schema file" do
    it "contains the correct version number" do
      schema_content = File.read(Rails.root.join("db", "schema.rb"))

      # Estrai la versione dal file schema.rb
      schema_version_match = schema_content.match(/ActiveRecord::Schema\[[\d.]+\]\.define\(version: (\d+)\)/)
      expect(schema_version_match).not_to be_nil, "Could not find schema version in db/schema.rb"

      schema_file_version = schema_version_match[1].to_i

      # Ottieni l'ultima migration
      migration_files = Dir.glob(Rails.root.join("db", "migrate", "*.rb"))
      migration_versions = migration_files.map { |file| File.basename(file).split("_").first.to_i }
      latest_migration_version = migration_versions.max

      # Verifica che corrispondano
      expect(schema_file_version).to eq(latest_migration_version),
                                        "Schema file version (#{schema_file_version}) should match the latest migration (#{latest_migration_version})"
    end
  end

  describe "DMARC fields migration" do
    it "adds dmarc_status and dmarc_error columns to domains table" do
      expect(Domain.column_names).to include("dmarc_status")
      expect(Domain.column_names).to include("dmarc_error")
    end
  end

  describe "Truemail integration migration" do
    it "adds truemail_enabled column to servers table" do
      expect(Server.column_names).to include("truemail_enabled")
    end

    it "has correct default value for truemail_enabled" do
      column = Server.columns_hash["truemail_enabled"]
      expect(column.default).to eq("0"), "truemail_enabled should default to false (0)"
    end
  end

  describe "MTA-STS and TLS-RPT migration" do
    it "adds MTA-STS fields to domains table" do
      expect(Domain.column_names).to include("mta_sts_enabled")
      expect(Domain.column_names).to include("mta_sts_mode")
      expect(Domain.column_names).to include("mta_sts_max_age")
      expect(Domain.column_names).to include("mta_sts_mx_patterns")
      expect(Domain.column_names).to include("mta_sts_status")
      expect(Domain.column_names).to include("mta_sts_error")
    end

    it "adds TLS-RPT fields to domains table" do
      expect(Domain.column_names).to include("tls_rpt_enabled")
      expect(Domain.column_names).to include("tls_rpt_email")
      expect(Domain.column_names).to include("tls_rpt_status")
      expect(Domain.column_names).to include("tls_rpt_error")
    end
  end

  describe "Server priority migration" do
    it "adds priority column to servers table" do
      expect(Server.column_names).to include("priority")
    end
  end

  describe "all migrations" do
    it "have been applied to the database" do
      # Ottieni tutte le migration dalla directory
      migration_files = Dir.glob(Rails.root.join("db", "migrate", "*.rb"))
      migration_versions = migration_files.map { |file| File.basename(file).split("_").first }

      # Ottieni le migration applicate dal database
      applied_migrations = ActiveRecord::Base.connection.migration_context.get_all_versions

      # Verifica che tutte le migration siano state applicate
      missing_migrations = migration_versions.map(&:to_i) - applied_migrations.map(&:to_i)

      expect(missing_migrations).to be_empty,
                                      "The following migrations have not been applied: #{missing_migrations.join(', ')}"
    end
  end
end

