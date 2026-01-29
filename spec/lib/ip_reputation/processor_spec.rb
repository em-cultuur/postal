# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPReputation::Processor do
  let(:google_client) { instance_double(IPReputation::GooglePostmasterClient) }
  let(:snds_client) { instance_double(IPReputation::MicrosoftSndsClient) }
  let(:processor) { described_class.new }
  let(:ip_address) { create(:ip_address, ipv4: "192.0.2.1") }

  before do
    allow(IPReputation::GooglePostmasterClient).to receive(:new).and_return(google_client)
    allow(IPReputation::MicrosoftSndsClient).to receive(:new).and_return(snds_client)
  end

  describe "#initialize" do
    it "creates Google Postmaster client" do
      processor # Force instantiation
      expect(IPReputation::GooglePostmasterClient).to have_received(:new)
    end

    it "creates Microsoft SNDS client" do
      processor # Force instantiation
      expect(IPReputation::MicrosoftSndsClient).to have_received(:new)
    end
  end

  describe "#process_ip" do
    let(:google_data) do
      {
        domain: "gmail.com",
        domain_reputation: "HIGH",
        spam_rate: 0.02,
        user_reported_spam_rate: 0.01
      }
    end

    let(:snds_data) do
      {
        ip_address: "192.0.2.1",
        filter_result: "green",
        complaint_rate: 0.001,
        severity: 0
      }
    end

    before do
      allow(google_client).to receive(:configured?).and_return(true)
      allow(snds_client).to receive(:configured?).and_return(true)
      allow(snds_client).to receive(:fetch_ip_reputation).and_return(snds_data)

      # Mock recently_sent_domains to return empty array (Google Postmaster needs domains)
      allow(processor).to receive(:recently_sent_domains).and_return([])
    end

    it "processes both Google and SNDS data" do
      result = processor.process_ip(ip_address)

      expect(result).to be_a(Hash)
      expect(result).to have_key(:google_postmaster)
      expect(result).to have_key(:microsoft_snds)
    end
  end

  describe "#process_domain_reputation" do
    let(:domain) { "gmail.com" }
    let(:google_data) do
      {
        domain: domain,
        domain_reputation: "HIGH",
        spam_rate: 0.02,
        user_reported_spam_rate: 0.01,
        dkim_success_rate: 0.95,
        spf_success_rate: 0.98,
        dmarc_success_rate: 0.92
      }
    end

    before do
      allow(google_client).to receive(:configured?).and_return(true)
      allow(google_client).to receive(:fetch_reputation_data).and_return(google_data)
      allow(processor).to receive(:find_ips_for_domain).and_return([ip_address])
    end

    it "fetches reputation data for domain" do
      processor.process_domain_reputation(domain)

      expect(google_client).to have_received(:fetch_reputation_data)
    end

    it "stores metrics for each IP" do
      expect do
        processor.process_domain_reputation(domain)
      end.to change(IPReputationMetric, :count).by(1)

      metric = IPReputationMetric.last
      expect(metric.ip_address).to eq(ip_address)
      expect(metric.destination_domain).to eq(domain)
      expect(metric.metric_type).to eq("google_postmaster_reputation")
    end

    it "checks thresholds" do
      allow(processor).to receive(:check_google_thresholds)

      processor.process_domain_reputation(domain)

      expect(processor).to have_received(:check_google_thresholds).with(ip_address, domain, google_data)
    end

    context "when Google client is not configured" do
      before do
        allow(google_client).to receive(:configured?).and_return(false)
      end

      it "returns nil" do
        expect(processor.process_domain_reputation(domain)).to be_nil
      end
    end

    context "when no data is returned" do
      before do
        allow(google_client).to receive(:fetch_reputation_data).and_return(nil)
      end

      it "does not create metrics" do
        expect do
          processor.process_domain_reputation(domain)
        end.not_to change(IPReputationMetric, :count)
      end
    end
  end

  describe "Google Postmaster threshold checking" do
    let(:domain) { "gmail.com" }

    describe "BAD reputation" do
      let(:bad_reputation_data) do
        {
          domain: domain,
          domain_reputation: "BAD",
          spam_rate: 0.02
        }
      end

      it "pauses IP for BAD reputation" do
        expect(IPBlacklist::IPHealthManager).to receive(:pause_for_domain)
          .with(ip_address, domain, hash_including(reason: /BAD domain reputation/))

        processor.send(:check_google_thresholds, ip_address, domain, bad_reputation_data)
      end

      it "creates an IP domain exclusion" do
        allow(IPBlacklist::IPHealthManager).to receive(:pause_for_domain).and_call_original
        # Mock the notifier to avoid side effects
        allow_any_instance_of(IPBlacklist::Notifier).to receive(:notify_ip_paused)

        expect do
          processor.send(:check_google_thresholds, ip_address, domain, bad_reputation_data)
        end.to change(IPDomainExclusion, :count).by(1)
      end
    end

    describe "LOW reputation" do
      let(:low_reputation_data) do
        {
          domain: domain,
          domain_reputation: "LOW",
          spam_rate: 0.02
        }
      end

      it "logs warning for LOW reputation" do
        allow(Rails.logger).to receive(:warn)

        processor.send(:check_google_thresholds, ip_address, domain, low_reputation_data)

        expect(Rails.logger).to have_received(:warn).with(/LOW domain reputation/)
      end

      it "creates a monitor action" do
        expect do
          processor.send(:check_google_thresholds, ip_address, domain, low_reputation_data)
        end.to change(IPHealthAction, :count).by(1)

        action = IPHealthAction.last
        expect(action.action_type).to eq(IPHealthAction::MONITOR)
      end
    end

    describe "High spam rate" do
      let(:high_spam_data) do
        {
          domain: domain,
          domain_reputation: "HIGH",
          spam_rate: 0.12 # > 10% threshold
        }
      end

      it "pauses IP for high spam rate" do
        expect(IPBlacklist::IPHealthManager).to receive(:pause_for_domain)
          .with(ip_address, domain, hash_including(reason: /High spam rate/))

        processor.send(:check_google_thresholds, ip_address, domain, high_spam_data)
      end
    end

    describe "Elevated spam rate" do
      let(:medium_spam_data) do
        {
          domain: domain,
          domain_reputation: "HIGH",
          spam_rate: 0.07 # > 5% threshold, < 10%
        }
      end

      it "logs warning for elevated spam rate" do
        allow(Rails.logger).to receive(:warn)

        processor.send(:check_google_thresholds, ip_address, domain, medium_spam_data)

        expect(Rails.logger).to have_received(:warn).with(/Elevated spam rate/)
      end
    end

    describe "High user-reported spam" do
      let(:high_user_spam_data) do
        {
          domain: domain,
          domain_reputation: "HIGH",
          user_reported_spam_rate: 0.04 # > 3% threshold
        }
      end

      it "pauses IP for high user-reported spam" do
        expect(IPBlacklist::IPHealthManager).to receive(:pause_for_domain)
          .with(ip_address, domain, hash_including(reason: /High user-reported spam/))

        processor.send(:check_google_thresholds, ip_address, domain, high_user_spam_data)
      end
    end
  end

  describe "Microsoft SNDS threshold checking" do
    let(:domain) { "outlook.com" }

    describe "RED filter status" do
      let(:red_status_data) do
        {
          ip_address: "192.0.2.1",
          filter_result: "red",
          complaint_rate: 0.002,
          severity: 2
        }
      end

      it "pauses IP for RED status" do
        expect(IPBlacklist::IPHealthManager).to receive(:pause_for_domain)
          .with(ip_address, domain, hash_including(reason: /RED filter status/))

        processor.send(:check_snds_thresholds, ip_address, red_status_data)
      end
    end

    describe "YELLOW filter status" do
      let(:yellow_status_data) do
        {
          ip_address: "192.0.2.1",
          filter_result: "yellow",
          complaint_rate: 0.002,
          severity: 1
        }
      end

      it "logs warning for YELLOW status" do
        allow(Rails.logger).to receive(:warn)

        processor.send(:check_snds_thresholds, ip_address, yellow_status_data)

        expect(Rails.logger).to have_received(:warn).with(/YELLOW filter status/)
      end
    end

    describe "TRAP filter status" do
      let(:trap_status_data) do
        {
          ip_address: "192.0.2.1",
          filter_result: "trap",
          complaint_rate: 0.002,
          severity: 3
        }
      end

      it "pauses IP for trap hits" do
        expect(IPBlacklist::IPHealthManager).to receive(:pause_for_domain)
          .with(ip_address, domain, hash_including(reason: /Spam trap hits/))

        processor.send(:check_snds_thresholds, ip_address, trap_status_data)
      end
    end

    describe "High complaint rate" do
      let(:high_complaint_data) do
        {
          ip_address: "192.0.2.1",
          filter_result: "green",
          complaint_rate: 0.004, # > 0.3% threshold
          severity: 0
        }
      end

      it "pauses IP for high complaint rate" do
        expect(IPBlacklist::IPHealthManager).to receive(:pause_for_domain)
          .with(ip_address, domain, hash_including(reason: /High complaint rate/))

        processor.send(:check_snds_thresholds, ip_address, high_complaint_data)
      end
    end
  end

  describe "#reputation_to_numeric" do
    it "converts HIGH to 100" do
      expect(processor.send(:reputation_to_numeric, "HIGH")).to eq(100)
    end

    it "converts MEDIUM to 60" do
      expect(processor.send(:reputation_to_numeric, "MEDIUM")).to eq(60)
    end

    it "converts LOW to 30" do
      expect(processor.send(:reputation_to_numeric, "LOW")).to eq(30)
    end

    it "converts BAD to 0" do
      expect(processor.send(:reputation_to_numeric, "BAD")).to eq(0)
    end

    it "handles nil input" do
      expect(processor.send(:reputation_to_numeric, nil)).to be_nil
    end

    it "is case-insensitive" do
      expect(processor.send(:reputation_to_numeric, "high")).to eq(100)
      expect(processor.send(:reputation_to_numeric, "bad")).to eq(0)
    end
  end
end
