# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/ip_blacklist/soft_bounce_tracker"

RSpec.describe IPBlacklist::SoftBounceTracker do
  let(:ip_address_id) { 123 }
  let(:destination_domain) { "gmail.com" }
  let(:threshold) { 5 }
  let(:window_minutes) { 60 }

  let(:tracker) do
    described_class.new(
      ip_address_id: ip_address_id,
      destination_domain: destination_domain,
      threshold: threshold,
      window_minutes: window_minutes
    )
  end

  before do
    # Clear cache before each test
    Rails.cache.clear
  end

  describe "#initialize" do
    it "sets the ip_address_id" do
      expect(tracker.ip_address_id).to eq(ip_address_id)
    end

    it "sets the destination_domain" do
      expect(tracker.destination_domain).to eq(destination_domain)
    end

    it "sets the threshold" do
      expect(tracker.threshold).to eq(threshold)
    end

    it "sets the window_minutes" do
      expect(tracker.window_minutes).to eq(window_minutes)
    end

    it "uses default threshold if not provided" do
      tracker = described_class.new(ip_address_id: ip_address_id, destination_domain: destination_domain)
      expect(tracker.threshold).to eq(described_class::DEFAULT_THRESHOLD)
    end

    it "uses default window_minutes if not provided" do
      tracker = described_class.new(ip_address_id: ip_address_id, destination_domain: destination_domain)
      expect(tracker.window_minutes).to eq(described_class::DEFAULT_WINDOW_MINUTES)
    end
  end

  describe "#current_count" do
    it "returns 0 when no soft bounces recorded" do
      expect(tracker.current_count).to eq(0)
    end

    it "returns the count after recording" do
      tracker.record
      expect(tracker.current_count).to eq(1)
    end

    it "returns correct count after multiple records" do
      3.times { tracker.record }
      expect(tracker.current_count).to eq(3)
    end
  end

  describe "#record" do
    it "increments the counter" do
      expect { tracker.record }.to change { tracker.current_count }.from(0).to(1)
    end

    it "returns the new count" do
      expect(tracker.record).to eq(1)
      expect(tracker.record).to eq(2)
    end

    it "increments independently for different domains" do
      tracker_gmail = described_class.new(ip_address_id: ip_address_id, destination_domain: "gmail.com")
      tracker_yahoo = described_class.new(ip_address_id: ip_address_id, destination_domain: "yahoo.com")

      tracker_gmail.record
      tracker_gmail.record
      tracker_yahoo.record

      expect(tracker_gmail.current_count).to eq(2)
      expect(tracker_yahoo.current_count).to eq(1)
    end

    it "increments independently for different IPs" do
      tracker_ip1 = described_class.new(ip_address_id: 100, destination_domain: destination_domain)
      tracker_ip2 = described_class.new(ip_address_id: 200, destination_domain: destination_domain)

      tracker_ip1.record
      tracker_ip2.record
      tracker_ip2.record

      expect(tracker_ip1.current_count).to eq(1)
      expect(tracker_ip2.current_count).to eq(2)
    end
  end

  describe "#threshold_exceeded?" do
    it "returns false when count is below threshold" do
      3.times { tracker.record }
      expect(tracker.threshold_exceeded?).to be false
    end

    it "returns true when count equals threshold" do
      5.times { tracker.record }
      expect(tracker.threshold_exceeded?).to be true
    end

    it "returns true when count exceeds threshold" do
      7.times { tracker.record }
      expect(tracker.threshold_exceeded?).to be true
    end

    it "returns false initially" do
      expect(tracker.threshold_exceeded?).to be false
    end
  end

  describe "#record_and_check_threshold" do
    it "returns false when count is below threshold" do
      3.times { tracker.record }
      expect(tracker.record_and_check_threshold).to be false
    end

    it "returns true when count reaches threshold" do
      4.times { tracker.record }
      expect(tracker.record_and_check_threshold).to be true
      expect(tracker.current_count).to eq(5)
    end

    it "returns true when count exceeds threshold" do
      5.times { tracker.record }
      expect(tracker.record_and_check_threshold).to be true
      expect(tracker.current_count).to eq(6)
    end

    it "increments counter as side effect" do
      expect { tracker.record_and_check_threshold }.to change { tracker.current_count }.from(0).to(1)
    end
  end

  describe "#reset" do
    it "clears the counter" do
      5.times { tracker.record }
      expect(tracker.current_count).to eq(5)

      tracker.reset

      expect(tracker.current_count).to eq(0)
    end

    it "allows recording after reset" do
      3.times { tracker.record }
      tracker.reset
      tracker.record

      expect(tracker.current_count).to eq(1)
    end
  end

  describe "#time_until_expiry" do
    it "returns the window duration in seconds" do
      expect(tracker.time_until_expiry).to eq(window_minutes * 60)
    end
  end

  describe ".threshold_exceeded?" do
    it "returns true when threshold is exceeded" do
      tracker = described_class.new(ip_address_id: ip_address_id, destination_domain: destination_domain)
      5.times { tracker.record }

      result = described_class.threshold_exceeded?(
        ip_address_id: ip_address_id,
        destination_domain: destination_domain
      )

      expect(result).to be true
    end

    it "returns false when threshold is not exceeded" do
      result = described_class.threshold_exceeded?(
        ip_address_id: ip_address_id,
        destination_domain: destination_domain
      )

      expect(result).to be false
    end

    it "accepts custom threshold and window" do
      tracker = described_class.new(
        ip_address_id: ip_address_id,
        destination_domain: destination_domain,
        threshold: 3,
        window_minutes: 30
      )
      2.times { tracker.record }

      result = described_class.threshold_exceeded?(
        ip_address_id: ip_address_id,
        destination_domain: destination_domain,
        threshold: 3,
        window_minutes: 30
      )

      expect(result).to be false
    end
  end

  describe ".record_and_check" do
    it "records and returns threshold status" do
      3.times do
        described_class.record_and_check(
          ip_address_id: ip_address_id,
          destination_domain: destination_domain,
          threshold: 5
        )
      end

      result = described_class.record_and_check(
        ip_address_id: ip_address_id,
        destination_domain: destination_domain,
        threshold: 5
      )

      expect(result).to be false

      # 5th record should trigger threshold
      result = described_class.record_and_check(
        ip_address_id: ip_address_id,
        destination_domain: destination_domain,
        threshold: 5
      )

      expect(result).to be true
    end
  end

  describe ".reset" do
    it "resets the counter" do
      tracker = described_class.new(ip_address_id: ip_address_id, destination_domain: destination_domain)
      5.times { tracker.record }

      described_class.reset(ip_address_id: ip_address_id, destination_domain: destination_domain)

      expect(tracker.current_count).to eq(0)
    end
  end

  describe "cache key generation" do
    it "uses different keys for different IPs" do
      tracker1 = described_class.new(ip_address_id: 100, destination_domain: "gmail.com")
      tracker2 = described_class.new(ip_address_id: 200, destination_domain: "gmail.com")

      tracker1.record
      tracker2.record
      tracker2.record

      expect(tracker1.current_count).to eq(1)
      expect(tracker2.current_count).to eq(2)
    end

    it "uses different keys for different domains" do
      tracker1 = described_class.new(ip_address_id: 100, destination_domain: "gmail.com")
      tracker2 = described_class.new(ip_address_id: 100, destination_domain: "yahoo.com")

      tracker1.record
      tracker2.record
      tracker2.record

      expect(tracker1.current_count).to eq(1)
      expect(tracker2.current_count).to eq(2)
    end
  end

  describe "expiry behavior" do
    it "stores counter with expiry time" do
      # This is hard to test without mocking time, but we can verify the counter is set
      tracker.record
      expect(tracker.current_count).to eq(1)

      # Verify cache key exists
      cache_key = tracker.send(:cache_key)
      expect(Rails.cache.exist?(cache_key)).to be true
    end
  end
end
