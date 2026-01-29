# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPBlacklist::Checker do
  let(:ip_address) { create(:ip_address) }
  let(:checker) { described_class.new(ip_address) }

  describe "#initialize" do
    it "sets the ip_address" do
      expect(checker.ip_address).to eq(ip_address)
    end
  end

  describe "DNSBL configuration" do
    it "has 11 DNSBLs configured" do
      expect(described_class::DNSBLS.size).to eq(11)
    end

    it "includes major DNSBLs" do
      dnsbl_names = described_class::DNSBLS.map { |d| d[:name] }
      expect(dnsbl_names).to include("spamhaus_zen", "spamcop", "barracuda", "sorbs", "mailspike")
    end
  end

  describe "#check_dnsbl" do
    let(:dnsbl) { { name: "spamhaus_zen", host: "zen.spamhaus.org" } }

    before do
      # Mock infer_affected_domains to return test domain
      allow_any_instance_of(described_class).to receive(:infer_affected_domains).and_return(["example.com"])
    end

    context "when IP is blacklisted" do
      before do
        allow_any_instance_of(described_class).to receive(:query_dnsbl).and_return(
          { listed: true, result: "127.0.0.2", lookup_host: "100.2.0.192.zen.spamhaus.org" }
        )
      end

      it "creates a blacklist record" do
        expect { checker.check_dnsbl(dnsbl) }.to change(IPBlacklistRecord, :count).by(1)
      end

      it "creates record with correct attributes" do
        checker.check_dnsbl(dnsbl)
        record = IPBlacklistRecord.last
        expect(record.ip_address_id).to eq(ip_address.id)
        expect(record.blacklist_source).to eq("spamhaus_zen")
        expect(record.destination_domain).to eq("example.com")
        expect(record.status).to eq("active")
      end

      it "triggers health manager on new blacklist" do
        expect(IPBlacklist::IPHealthManager).to receive(:handle_blacklist_detected).once
        checker.check_dnsbl(dnsbl)
      end
    end

    context "when IP is not blacklisted" do
      before do
        allow_any_instance_of(described_class).to receive(:query_dnsbl).and_return(
          { listed: false, lookup_host: "100.2.0.192.zen.spamhaus.org" }
        )
      end

      it "does not create a record" do
        expect { checker.check_dnsbl(dnsbl) }.not_to change(IPBlacklistRecord, :count)
      end
    end

    context "when existing active record exists" do
      let!(:existing_record) do
        create(:ip_blacklist_record,
               ip_address: ip_address,
               blacklist_source: "spamhaus_zen",
               destination_domain: "example.com",
               status: "active",
               check_count: 5)
      end

      before do
        allow_any_instance_of(described_class).to receive(:query_dnsbl).and_return(
          { listed: true, result: "127.0.0.2", lookup_host: "100.2.0.192.zen.spamhaus.org" }
        )
      end

      it "does not create duplicate record" do
        expect { checker.check_dnsbl(dnsbl) }.not_to change(IPBlacklistRecord, :count)
      end

      it "increments check count" do
        expect { checker.check_dnsbl(dnsbl) }.to change { existing_record.reload.check_count }.by(1)
      end

      it "does not trigger health manager for existing blacklist" do
        expect(IPBlacklist::IPHealthManager).not_to receive(:handle_blacklist_detected)
        checker.check_dnsbl(dnsbl)
      end
    end
  end

  describe "#recheck_specific_blacklist" do
    let!(:resolved_record) do
      create(:ip_blacklist_record, :resolved,
             ip_address: ip_address,
             blacklist_source: "spamhaus_zen",
             destination_domain: "gmail.com",
             check_count: 10)
    end

    context "when IP is still not blacklisted" do
      before do
        allow_any_instance_of(described_class).to receive(:query_dnsbl).and_return(
          { listed: false, lookup_host: "100.2.0.192.zen.spamhaus.org" }
        )
      end

      it "updates last_checked_at" do
        expect { checker.recheck_specific_blacklist(resolved_record) }
          .to change { resolved_record.reload.last_checked_at }
      end

      it "increments check count" do
        expect { checker.recheck_specific_blacklist(resolved_record) }
          .to change { resolved_record.reload.check_count }.by(1)
      end

      it "keeps status as resolved" do
        checker.recheck_specific_blacklist(resolved_record)
        expect(resolved_record.reload.status).to eq("resolved")
      end
    end

    context "when IP is blacklisted again" do
      before do
        allow_any_instance_of(described_class).to receive(:query_dnsbl).and_return(
          { listed: true, result: "127.0.0.2", lookup_host: "100.2.0.192.zen.spamhaus.org" }
        )
      end

      it "changes status back to active" do
        checker.recheck_specific_blacklist(resolved_record)
        expect(resolved_record.reload.status).to eq("active")
      end

      it "clears resolved_at timestamp" do
        checker.recheck_specific_blacklist(resolved_record)
        expect(resolved_record.reload.resolved_at).to be_nil
      end

      it "triggers health manager" do
        expect(IPBlacklist::IPHealthManager).to receive(:handle_blacklist_detected).with(resolved_record)
        checker.recheck_specific_blacklist(resolved_record)
      end
    end
  end

  describe "#infer_affected_domains" do
    # This method queries message databases which would require complex setup
    # Testing it via integration tests or by mocking as done in other tests above
    it "returns wildcard when no domains can be inferred" do
      # When no servers have message DBs
      domains = checker.send(:infer_affected_domains)
      expect(domains).to eq(["*"])
    end
  end
end
