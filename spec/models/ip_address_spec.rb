# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_addresses
#
#  id         :integer          not null, primary key
#  hostname   :string(255)
#  ipv4       :string(255)
#  ipv6       :string(255)
#  priority   :integer
#  created_at :datetime
#  updated_at :datetime
#  ip_pool_id :integer
#
require "rails_helper"

RSpec.describe IPAddress, type: :model do
  describe "associations" do
    it { should belong_to(:ip_pool) }
    it { should have_many(:ip_blacklist_records) }
    it { should have_many(:ip_health_actions) }
    it { should have_many(:ip_domain_exclusions) }
    it { should have_many(:ip_reputation_metrics) }
  end

  describe "blacklist-aware methods" do
    let(:ip_pool) { create(:ip_pool) }
    let(:ip_address) { create(:ip_address, ip_pool: ip_pool, priority: 100) }

    describe "#blacklisted_for?" do
      it "returns false when not blacklisted" do
        expect(ip_address.blacklisted_for?("gmail.com")).to be false
      end

      it "returns true when blacklisted for domain" do
        create(:ip_blacklist_record, ip_address: ip_address, destination_domain: "gmail.com", status: "active")
        expect(ip_address.blacklisted_for?("gmail.com")).to be true
      end

      it "returns false when blacklisted for different domain" do
        create(:ip_blacklist_record, ip_address: ip_address, destination_domain: "yahoo.com", status: "active")
        expect(ip_address.blacklisted_for?("gmail.com")).to be false
      end
    end

    describe "#excluded_for?" do
      it "returns false when not excluded" do
        expect(ip_address.excluded_for?("gmail.com")).to be false
      end

      it "returns true when excluded for domain" do
        create(:ip_domain_exclusion, ip_address: ip_address, destination_domain: "gmail.com")
        expect(ip_address.excluded_for?("gmail.com")).to be true
      end
    end

    describe "#effective_priority_for_domain" do
      context "when IP is healthy" do
        it "returns base priority" do
          expect(ip_address.effective_priority_for_domain("gmail.com")).to eq(100)
        end
      end

      context "when IP is blacklisted" do
        before do
          create(:ip_blacklist_record, ip_address: ip_address, destination_domain: "gmail.com", status: "active")
        end

        it "returns 0" do
          expect(ip_address.effective_priority_for_domain("gmail.com")).to eq(0)
        end
      end

      context "when IP is in warmup" do
        before do
          create(:ip_domain_exclusion, ip_address: ip_address, destination_domain: "gmail.com", warmup_stage: 2)
        end

        it "returns warmup stage priority" do
          expect(ip_address.effective_priority_for_domain("gmail.com")).to eq(40)
        end
      end
    end

    describe "#health_status_for" do
      it "returns healthy status by default" do
        status = ip_address.health_status_for("gmail.com")
        expect(status[:status]).to eq("healthy")
        expect(status[:priority]).to eq(100)
      end

      it "returns blacklisted status when blacklisted" do
        create(:ip_blacklist_record,
               ip_address: ip_address,
               destination_domain: "gmail.com",
               blacklist_source: "spamhaus_zen",
               status: "active")

        status = ip_address.health_status_for("gmail.com")
        expect(status[:status]).to eq("blacklisted")
        expect(status[:priority]).to eq(0)
        expect(status[:blacklists]).to include("spamhaus_zen")
      end

      it "returns excluded status when in warmup" do
        create(:ip_domain_exclusion,
               ip_address: ip_address,
               destination_domain: "gmail.com",
               warmup_stage: 3,
               reason: "Recovering from blacklist")

        status = ip_address.health_status_for("gmail.com")
        expect(status[:status]).to eq("excluded")
        expect(status[:warmup_stage]).to eq(3)
        expect(status[:priority]).to eq(60)
      end
    end
  end

  describe "scopes" do
    let(:ip_pool) { create(:ip_pool) }
    let!(:healthy_ip) { create(:ip_address, ip_pool: ip_pool) }
    let!(:blacklisted_ip) { create(:ip_address, ip_pool: ip_pool) }
    let!(:warming_ip) { create(:ip_address, ip_pool: ip_pool) }
    let!(:paused_ip) { create(:ip_address, ip_pool: ip_pool) }

    before do
      create(:ip_blacklist_record, ip_address: blacklisted_ip, destination_domain: "gmail.com", status: "active")
      create(:ip_domain_exclusion, ip_address: warming_ip, destination_domain: "gmail.com", warmup_stage: 2)
      create(:ip_domain_exclusion, ip_address: paused_ip, destination_domain: "gmail.com", warmup_stage: 0)
    end

    describe ".healthy_for_domain" do
      it "excludes paused IPs but includes warming IPs" do
        result = IPAddress.healthy_for_domain("gmail.com")
        expect(result).to include(healthy_ip, blacklisted_ip, warming_ip)
        expect(result).not_to include(paused_ip)
      end
    end

    describe ".not_blacklisted_for_domain" do
      it "excludes blacklisted IPs" do
        result = IPAddress.not_blacklisted_for_domain("gmail.com")
        expect(result).to include(healthy_ip, warming_ip)
        expect(result).not_to include(blacklisted_ip)
      end
    end

    describe ".available_for_sending" do
      it "returns only healthy and warming IPs, excluding blacklisted and paused" do
        result = IPAddress.available_for_sending("gmail.com")
        expect(result).to include(healthy_ip, warming_ip)
        expect(result).not_to include(blacklisted_ip, paused_ip)
      end
    end
  end

  describe ".select_by_priority_for_domain" do
    let(:ip_pool) { create(:ip_pool) }
    let!(:ip1) { create(:ip_address, ip_pool: ip_pool, priority: 100) }
    let!(:ip2) { create(:ip_address, ip_pool: ip_pool, priority: 100) }
    let!(:ip3) { create(:ip_address, ip_pool: ip_pool, priority: 100) }

    before do
      create(:ip_blacklist_record, ip_address: ip3, destination_domain: "gmail.com", status: "active")
      # Create paused exclusion for ip3 so it's filtered out
      create(:ip_domain_exclusion, ip_address: ip3, destination_domain: "gmail.com", warmup_stage: 0)
    end

    it "selects from available IPs only" do
      selected = ip_pool.ip_addresses.select_by_priority_for_domain("gmail.com")
      expect([ip1, ip2]).to include(selected)
      expect(selected).not_to eq(ip3)
    end

    it "returns nil when no IPs available" do
      create(:ip_blacklist_record, ip_address: ip1, destination_domain: "gmail.com", status: "active")
      create(:ip_blacklist_record, ip_address: ip2, destination_domain: "gmail.com", status: "active")
      create(:ip_domain_exclusion, ip_address: ip1, destination_domain: "gmail.com", warmup_stage: 0)
      create(:ip_domain_exclusion, ip_address: ip2, destination_domain: "gmail.com", warmup_stage: 0)

      expect(ip_pool.ip_addresses.select_by_priority_for_domain("gmail.com")).to be_nil
    end

    it "considers warmup stage priorities" do
      create(:ip_domain_exclusion, ip_address: ip2, destination_domain: "gmail.com", warmup_stage: 1)

      # ip1 has priority 100, ip2 has effective priority 20 (warmup stage 1)
      # ip1 should be selected more often
      selections = 100.times.map { ip_pool.ip_addresses.select_by_priority_for_domain("gmail.com") }

      expect(selections.count(ip1)).to be > selections.count(ip2)
    end
  end
end
