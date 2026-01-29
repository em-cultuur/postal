# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPMetrics::Aggregator do
  describe ".aggregate" do
    let(:server) { create(:server) }
    let(:ip_address) { create(:ip_address) }

    context "with valid parameters" do
      it "accepts hourly period" do
        expect do
          described_class.aggregate(
            period: IPReputationMetric::HOURLY,
            period_date: Time.current
          )
        end.not_to raise_error
      end

      it "accepts daily period" do
        expect do
          described_class.aggregate(
            period: IPReputationMetric::DAILY,
            period_date: Date.current
          )
        end.not_to raise_error
      end

      it "returns total count of records created" do
        count = described_class.aggregate(
          period: IPReputationMetric::DAILY,
          period_date: Date.current
        )
        expect(count).to be >= 0
      end
    end

    context "with invalid period" do
      it "raises ArgumentError" do
        expect do
          described_class.aggregate(
            period: "invalid",
            period_date: Date.current
          )
        end.to raise_error(ArgumentError, /Invalid period/)
      end
    end
  end

  describe ".aggregate_recent" do
    it "aggregates hourly and daily by default" do
      expect(described_class).to receive(:aggregate).at_least(:twice)
      described_class.aggregate_recent
    end

    it "accepts custom periods" do
      expect(described_class).to receive(:aggregate).at_least(:once)
      described_class.aggregate_recent(periods: [IPReputationMetric::WEEKLY])
    end
  end

  describe ".normalize_period_date" do
    it "normalizes hourly to beginning of hour" do
      time = Time.parse("2026-01-28 14:45:30")
      normalized = described_class.send(:normalize_period_date, time, IPReputationMetric::HOURLY)
      expect(normalized).to eq(Time.parse("2026-01-28 14:00:00").to_date)
    end

    it "normalizes daily to date" do
      time = Time.parse("2026-01-28 14:45:30")
      normalized = described_class.send(:normalize_period_date, time, IPReputationMetric::DAILY)
      expect(normalized).to eq(Date.parse("2026-01-28"))
    end

    it "normalizes weekly to beginning of week" do
      time = Time.parse("2026-01-28 14:45:30") # Tuesday
      normalized = described_class.send(:normalize_period_date, time, IPReputationMetric::WEEKLY)
      # Should be Monday of that week
      expect(normalized.wday).to eq(1) # Monday
    end

    it "normalizes monthly to beginning of month" do
      time = Time.parse("2026-01-28 14:45:30")
      normalized = described_class.send(:normalize_period_date, time, IPReputationMetric::MONTHLY)
      expect(normalized).to eq(Date.parse("2026-01-01"))
    end
  end

  describe ".period_time_range" do
    it "returns 1 hour range for hourly period" do
      date = Date.parse("2026-01-28")
      start_time, end_time = described_class.send(:period_time_range, IPReputationMetric::HOURLY, date)
      expect(end_time - start_time).to eq(3600.0) # 1 hour in seconds
    end

    it "returns 1 day range for daily period" do
      date = Date.parse("2026-01-28")
      start_time, end_time = described_class.send(:period_time_range, IPReputationMetric::DAILY, date)
      expect(end_time - start_time).to eq(86_400.0) # 1 day in seconds
    end

    it "returns 1 week range for weekly period" do
      date = Date.parse("2026-01-26") # Monday
      start_time, end_time = described_class.send(:period_time_range, IPReputationMetric::WEEKLY, date)
      expect(end_time - start_time).to eq(604_800.0) # 1 week in seconds
    end
  end

  describe ".extract_domain" do
    it "extracts domain from email" do
      domain = described_class.send(:extract_domain, "user@example.com")
      expect(domain).to eq("example.com")
    end

    it "converts to lowercase" do
      domain = described_class.send(:extract_domain, "user@EXAMPLE.COM")
      expect(domain).to eq("example.com")
    end

    it "returns nil for blank email" do
      domain = described_class.send(:extract_domain, nil)
      expect(domain).to be_nil
    end
  end

  describe ".group_deliveries" do
    let(:deliveries) do
      [
        {
          status: "Sent",
          ip_address_id: 1,
          destination_domain: "gmail.com",
          sender_domain: "example.com"
        },
        {
          status: "Sent",
          ip_address_id: 1,
          destination_domain: "gmail.com",
          sender_domain: "example.com"
        },
        {
          status: "HardFail",
          ip_address_id: 1,
          destination_domain: "gmail.com",
          sender_domain: "example.com"
        },
        {
          status: "SoftFail",
          ip_address_id: 1,
          destination_domain: "gmail.com",
          sender_domain: "example.com"
        },
        {
          status: "Sent",
          ip_address_id: 1,
          destination_domain: "yahoo.com",
          sender_domain: "example.com"
        },
      ]
    end

    it "groups deliveries by IP, destination, and sender domain" do
      grouped = described_class.send(:group_deliveries, deliveries)
      expect(grouped.keys.size).to eq(2) # gmail.com and yahoo.com
    end

    it "counts sent messages correctly" do
      grouped = described_class.send(:group_deliveries, deliveries)
      gmail_key = grouped.keys.find { |k| k[:destination_domain] == "gmail.com" }
      expect(grouped[gmail_key][:sent_count]).to eq(4) # All non-held statuses
    end

    it "counts delivered messages" do
      grouped = described_class.send(:group_deliveries, deliveries)
      gmail_key = grouped.keys.find { |k| k[:destination_domain] == "gmail.com" }
      expect(grouped[gmail_key][:delivered_count]).to eq(2) # Only "Sent"
    end

    it "counts bounced messages" do
      grouped = described_class.send(:group_deliveries, deliveries)
      gmail_key = grouped.keys.find { |k| k[:destination_domain] == "gmail.com" }
      expect(grouped[gmail_key][:bounced_count]).to eq(2) # HardFail + SoftFail
    end

    it "separates hard and soft failures" do
      grouped = described_class.send(:group_deliveries, deliveries)
      gmail_key = grouped.keys.find { |k| k[:destination_domain] == "gmail.com" }
      expect(grouped[gmail_key][:hard_fail_count]).to eq(1)
      expect(grouped[gmail_key][:soft_fail_count]).to eq(1)
    end

    it "excludes Held messages from sent count" do
      deliveries_with_held = deliveries + [
        { status: "Held", ip_address_id: 1, destination_domain: "gmail.com", sender_domain: "example.com" },
      ]
      grouped = described_class.send(:group_deliveries, deliveries_with_held)
      gmail_key = grouped.keys.find { |k| k[:destination_domain] == "gmail.com" }
      expect(grouped[gmail_key][:sent_count]).to eq(4) # Held not counted
    end
  end

  describe ".update_metric_with_stats" do
    let(:ip_address) { create(:ip_address) }
    let(:metric) do
      create(:ip_reputation_metric,
             ip_address: ip_address,
             period: IPReputationMetric::DAILY,
             period_date: Date.current)
    end

    let(:stats) do
      {
        sent_count: 1000,
        delivered_count: 950,
        bounced_count: 50,
        hard_fail_count: 30,
        soft_fail_count: 20,
        spam_complaint_count: 5
      }
    end

    it "updates metric counts" do
      described_class.send(:update_metric_with_stats, metric, stats)
      expect(metric.sent_count).to eq(1000)
      expect(metric.delivered_count).to eq(950)
      expect(metric.bounced_count).to eq(50)
    end

    it "calculates rates" do
      described_class.send(:update_metric_with_stats, metric, stats)
      expect(metric.bounce_rate).to eq(500) # 5%
      expect(metric.delivery_rate).to eq(9500) # 95%
      expect(metric.spam_rate).to eq(50) # 0.5%
    end

    it "calculates reputation score" do
      described_class.send(:update_metric_with_stats, metric, stats)
      expect(metric.reputation_score).to be > 0
      expect(metric.reputation_score).to be <= 100
    end
  end
end
