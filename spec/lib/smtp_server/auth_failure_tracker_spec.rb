# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe AuthFailureTracker do
    let(:ip_address) { "192.168.1.100" }
    let(:threshold) { 3 }
    let(:block_duration) { 60 }

    subject(:tracker) do
      described_class.new(
        ip_address: ip_address,
        threshold: threshold,
        block_duration_minutes: block_duration
      )
    end

    before do
      # Clear cache before each test
      Rails.cache.clear
    end

    describe "#blocked?" do
      context "when IP is not blocked" do
        it "returns false" do
          expect(tracker.blocked?).to be false
        end
      end

      context "when IP is blocked" do
        before do
          tracker.block_ip
        end

        it "returns true" do
          expect(tracker.blocked?).to be true
        end
      end
    end

    describe "#record_failure" do
      it "increments the failure counter" do
        expect { tracker.record_failure }.to change { tracker.current_failure_count }.from(0).to(1)
      end

      it "increments counter multiple times" do
        tracker.record_failure
        tracker.record_failure
        expect(tracker.current_failure_count).to eq(2)
      end
    end

    describe "#record_failure_and_check_threshold" do
      context "when threshold is not exceeded" do
        it "returns false" do
          expect(tracker.record_failure_and_check_threshold).to be false
        end

        it "does not block the IP" do
          tracker.record_failure_and_check_threshold
          expect(tracker.blocked?).to be false
        end
      end

      context "when threshold is exceeded" do
        before do
          (threshold - 1).times { tracker.record_failure }
        end

        it "returns true on the threshold attempt" do
          expect(tracker.record_failure_and_check_threshold).to be true
        end

        it "blocks the IP" do
          tracker.record_failure_and_check_threshold
          expect(tracker.blocked?).to be true
        end
      end

      context "when threshold is exactly met" do
        before do
          (threshold - 1).times { tracker.record_failure }
        end

        it "blocks on exactly the threshold number" do
          expect(tracker.record_failure_and_check_threshold).to be true
          expect(tracker.blocked?).to be true
        end
      end
    end

    describe "#record_success" do
      before do
        tracker.record_failure
        tracker.record_failure
      end

      it "resets the failure counter" do
        tracker.record_success
        expect(tracker.current_failure_count).to eq(0)
      end

      it "prevents blocking after reset" do
        tracker.record_success
        tracker.record_failure
        tracker.record_failure
        expect(tracker.blocked?).to be false
      end
    end

    describe "#block_ip" do
      it "blocks the IP" do
        tracker.block_ip
        expect(tracker.blocked?).to be true
      end

      it "stores block information" do
        tracker.record_failure
        tracker.record_failure
        tracker.block_ip

        info = tracker.block_info
        expect(info).to include(:blocked_at, :failure_count, :threshold)
        expect(info[:failure_count]).to eq(2)
        expect(info[:threshold]).to eq(threshold)
      end
    end

    describe "#unblock_ip" do
      before do
        tracker.block_ip
      end

      it "unblocks the IP" do
        tracker.unblock_ip
        expect(tracker.blocked?).to be false
      end

      it "removes block information" do
        tracker.unblock_ip
        expect(tracker.block_info).to be_nil
      end
    end

    describe "#reset_failure_counter" do
      before do
        tracker.record_failure
        tracker.record_failure
      end

      it "resets the counter to 0" do
        tracker.reset_failure_counter
        expect(tracker.current_failure_count).to eq(0)
      end
    end

    describe "#time_remaining_on_block" do
      context "when IP is not blocked" do
        it "returns nil" do
          expect(tracker.time_remaining_on_block).to be_nil
        end
      end

      context "when IP is blocked" do
        before do
          tracker.block_ip
        end

        it "returns a positive number of seconds" do
          remaining = tracker.time_remaining_on_block
          expect(remaining).to be > 0
          expect(remaining).to be <= (block_duration * 60)
        end
      end
    end

    describe "class methods" do
      describe ".blocked?" do
        it "returns false for unblocked IP" do
          expect(described_class.blocked?(ip_address)).to be false
        end

        it "returns true for blocked IP" do
          tracker.block_ip
          expect(described_class.blocked?(ip_address)).to be true
        end
      end

      describe ".record_and_check" do
        it "records failure and returns true when threshold exceeded" do
          (threshold - 1).times do
            described_class.record_and_check(
              ip_address: ip_address,
              threshold: threshold,
              block_duration_minutes: block_duration
            )
          end

          result = described_class.record_and_check(
            ip_address: ip_address,
            threshold: threshold,
            block_duration_minutes: block_duration
          )

          expect(result).to be true
          expect(described_class.blocked?(ip_address)).to be true
        end
      end

      describe ".unblock" do
        before do
          tracker.block_ip
        end

        it "unblocks the IP" do
          described_class.unblock(ip_address)
          expect(described_class.blocked?(ip_address)).to be false
        end
      end
    end

    describe "cache key security" do
      it "hashes IP addresses to prevent manipulation" do
        key = tracker.send(:failure_cache_key)
        expect(key).not_to include(ip_address)
        expect(key).to match(/^smtp_auth:failures:v1:[a-f0-9]{64}$/)
      end

      it "generates different keys for different IPs" do
        tracker1 = described_class.new(ip_address: "1.2.3.4")
        tracker2 = described_class.new(ip_address: "5.6.7.8")

        expect(tracker1.send(:failure_cache_key)).not_to eq(tracker2.send(:failure_cache_key))
      end
    end

    describe "integration with config" do
      context "when config values are set" do
        before do
          allow(Postal::Config).to receive(:smtp_server).and_return(
            double(
              auth_failure_threshold: 10,
              auth_failure_block_duration: 240
            )
          )
        end

        it "uses config values when not explicitly provided" do
          tracker = described_class.new(ip_address: ip_address)
          expect(tracker.threshold).to eq(10)
          expect(tracker.block_duration_minutes).to eq(240)
        end
      end

      context "when explicit values override config" do
        before do
          allow(Postal::Config).to receive(:smtp_server).and_return(
            double(
              auth_failure_threshold: 10,
              auth_failure_block_duration: 240
            )
          )
        end

        it "uses explicit values" do
          tracker = described_class.new(
            ip_address: ip_address,
            threshold: 5,
            block_duration_minutes: 120
          )
          expect(tracker.threshold).to eq(5)
          expect(tracker.block_duration_minutes).to eq(120)
        end
      end

      context "when config is not available" do
        before do
          allow(Postal::Config).to receive(:smtp_server).and_raise(StandardError)
        end

        it "uses default values" do
          tracker = described_class.new(ip_address: ip_address)
          expect(tracker.threshold).to eq(described_class::DEFAULT_THRESHOLD)
          expect(tracker.block_duration_minutes).to eq(described_class::DEFAULT_BLOCK_DURATION_MINUTES)
        end
      end
    end

    describe "blocked IP index management" do
      let(:ip1) { "192.168.1.100" }
      let(:ip2) { "192.168.1.101" }
      let(:ip3) { "192.168.1.102" }

      describe ".all_blocked" do
        context "with no blocked IPs" do
          it "returns empty array" do
            expect(described_class.all_blocked).to eq([])
          end
        end

        context "with blocked IPs" do
          before do
            # Block multiple IPs
            [ip1, ip2, ip3].each do |ip|
              tracker = described_class.new(ip_address: ip, threshold: 3, block_duration_minutes: 60)
              3.times { tracker.record_failure }
              tracker.block_ip
            end
          end

          it "returns all blocked IPs" do
            blocked = described_class.all_blocked
            expect(blocked.size).to eq(3)
            expect(blocked.map { |b| b[:ip_address] }).to match_array([ip1, ip2, ip3])
          end

          it "includes block information" do
            blocked = described_class.all_blocked.first
            expect(blocked).to include(:ip_address, :blocked_at, :failure_count, :threshold, :expires_at, :time_remaining)
            expect(blocked[:blocked_at]).to be_a(Time)
            expect(blocked[:expires_at]).to be_a(Time)
          end

          it "sorts by blocked_at descending (newest first)" do
            # Block another IP after a short delay
            sleep 1
            ip4 = "192.168.1.103"
            tracker = described_class.new(ip_address: ip4, threshold: 3)
            3.times { tracker.record_failure }
            tracker.block_ip

            blocked = described_class.all_blocked
            expect(blocked.first[:ip_address]).to eq(ip4)
          end

          it "excludes expired entries" do
            # Manually unblock one
            described_class.unblock(ip2)

            blocked = described_class.all_blocked
            expect(blocked.size).to eq(2)
            expect(blocked.map { |b| b[:ip_address] }).not_to include(ip2)
          end
        end
      end

      describe ".search_blocked" do
        before do
          # Block IPs with different patterns
          described_class.new(ip_address: "192.168.1.100", threshold: 3).tap do |t|
            3.times { t.record_failure }
            t.block_ip
          end

          described_class.new(ip_address: "10.0.0.50", threshold: 3).tap do |t|
            3.times { t.record_failure }
            t.block_ip
          end

          described_class.new(ip_address: "192.168.2.100", threshold: 3).tap do |t|
            3.times { t.record_failure }
            t.block_ip
          end
        end

        it "returns all when query is blank" do
          expect(described_class.search_blocked("").size).to eq(3)
          expect(described_class.search_blocked(nil).size).to eq(3)
        end

        it "searches by partial IP" do
          results = described_class.search_blocked("192.168.1")
          expect(results.size).to eq(1)
          expect(results.first[:ip_address]).to eq("192.168.1.100")
        end

        it "returns multiple matches" do
          results = described_class.search_blocked("192.168")
          expect(results.size).to eq(2)
        end

        it "returns empty for no matches" do
          results = described_class.search_blocked("999.999")
          expect(results).to be_empty
        end
      end

      describe ".cleanup_blocked_index" do
        before do
          # Block some IPs
          [ip1, ip2].each do |ip|
            tracker = described_class.new(ip_address: ip, threshold: 3)
            3.times { tracker.record_failure }
            tracker.block_ip
          end

          # Manually add expired entry to index
          index = Rails.cache.read(described_class.blocked_index_key) || []
          index << ip3 # This IP is in index but not actually blocked
          Rails.cache.write(described_class.blocked_index_key, index)
        end

        it "removes expired entries from index" do
          cleaned = described_class.cleanup_blocked_index
          expect(cleaned).to eq(1)

          index = Rails.cache.read(described_class.blocked_index_key)
          expect(index).to match_array([ip1, ip2])
          expect(index).not_to include(ip3)
        end

        it "returns zero when no cleanup needed" do
          # First cleanup
          described_class.cleanup_blocked_index

          # Second cleanup should find nothing
          cleaned = described_class.cleanup_blocked_index
          expect(cleaned).to eq(0)
        end
      end

      describe "index key" do
        it "has correct format" do
          expect(described_class.blocked_index_key).to eq("smtp_auth:blocked_index:v1")
        end
      end
    end
  end

end
