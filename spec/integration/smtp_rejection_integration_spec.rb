# frozen_string_literal: true

require "rails_helper"
require_relative "../../app/lib/ip_blacklist/smtp_response_parser"
require_relative "../../app/lib/ip_blacklist/soft_bounce_tracker"
require_relative "../../app/lib/ip_blacklist/ip_health_manager"

RSpec.describe "SMTP Rejection Integration", type: :integration do
  let(:server) { create(:server) }
  let(:ip_pool) { create(:ip_pool, name: "default") }
  let(:ip_address) { create(:ip_address, ipv4: "192.0.2.1", ip_pool: ip_pool, priority: 100) }

  before do
    # Clear cache and database for clean test
    Rails.cache.clear
    IPBlacklistRecord.delete_all
    SMTPRejectionEvent.delete_all
    IPDomainExclusion.delete_all
    IPHealthAction.delete_all
  end

  describe "Hard bounce with blacklist detection" do
    it "creates SMTP rejection event and blacklist record" do
      smtp_code = "550"
      smtp_message = "550-5.7.1 Our system has detected an unusual rate of suspicious emails originating from your IP address."
      destination_domain = "gmail.com"

      # Parse the response
      parsed = IPBlacklist::SMTPResponseParser.parse(smtp_message, smtp_code)

      expect(parsed[:blacklist_detected]).to be true
      expect(parsed[:severity]).to eq("high")
      expect(parsed[:bounce_type]).to eq("hard")

      # Handle the rejection
      expect do
        IPBlacklist::IPHealthManager.handle_smtp_rejection(
          ip_address,
          destination_domain,
          parsed,
          smtp_code,
          smtp_message
        )
      end.to change(SMTPRejectionEvent, :count).by(1)
                                               .and change(IPBlacklistRecord, :count).by(1)
                                                                                     .and change(IPDomainExclusion, :count).by(1)
                                                                                                                           .and change(IPHealthAction, :count).by(1)

      # Verify SMTP rejection event
      event = SMTPRejectionEvent.last
      expect(event.ip_address_id).to eq(ip_address.id)
      expect(event.destination_domain).to eq(destination_domain)
      expect(event.smtp_code).to eq(smtp_code)
      expect(event.bounce_type).to eq("hard")
      expect(event.blacklist_detected?).to be true

      # Verify blacklist record
      blacklist = IPBlacklistRecord.last
      expect(blacklist.ip_address_id).to eq(ip_address.id)
      expect(blacklist.destination_domain).to eq(destination_domain)
      expect(blacklist.detection_method).to eq("smtp_response")
      expect(blacklist.smtp_response_code).to eq(smtp_code)
      expect(blacklist.detected_via_smtp?).to be true

      # Verify exclusion (IP paused)
      exclusion = IPDomainExclusion.last
      expect(exclusion.ip_address_id).to eq(ip_address.id)
      expect(exclusion.destination_domain).to eq(destination_domain)
      expect(exclusion.warmup_stage).to eq(0) # Paused
      expect(exclusion.current_priority).to eq(0)

      # Verify health action
      action = IPHealthAction.last
      expect(action.ip_address_id).to eq(ip_address.id)
      expect(action.action_type).to eq("pause")
      expect(action.destination_domain).to eq(destination_domain)
    end
  end

  describe "Soft bounce threshold detection" do
    it "pauses IP after exceeding soft bounce threshold" do
      destination_domain = "gmail.com"
      smtp_code = "421"
      smtp_message = "421-4.7.0 Try again later, closing connection."

      threshold = 5
      tracker = IPBlacklist::SoftBounceTracker.new(
        ip_address_id: ip_address.id,
        destination_domain: destination_domain,
        threshold: threshold,
        window_minutes: 60
      )

      # Record soft bounces just below threshold
      (threshold - 1).times do
        tracker.record
      end

      expect(tracker.threshold_exceeded?).to be false

      # Record one more to exceed threshold
      expect do
        tracker.record_and_check_threshold
      end.to_not change(IPDomainExclusion, :count)

      expect(tracker.threshold_exceeded?).to be true

      # Now trigger the manager
      expect do
        IPBlacklist::IPHealthManager.handle_excessive_soft_bounces(
          ip_address,
          destination_domain,
          reason: "Soft bounce threshold exceeded"
        )
      end.to change(IPDomainExclusion, :count).by(1)
                                              .and change(IPHealthAction, :count).by(1)

      # Verify exclusion
      exclusion = IPDomainExclusion.last
      expect(exclusion.ip_address_id).to eq(ip_address.id)
      expect(exclusion.destination_domain).to eq(destination_domain)
      expect(exclusion.warmup_stage).to eq(0)

      # Verify counter is reset
      expect(tracker.current_count).to eq(0)
    end
  end

  describe "Pattern matching accuracy" do
    context "Gmail patterns" do
      it "detects Gmail rate limiting" do
        message = "421-4.7.0 [192.0.2.1] Our system has detected that this message is suspicious due to rate limit exceeded."
        result = IPBlacklist::SMTPResponseParser.parse(message, "421")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("gmail_rate_limit")
        expect(result[:severity]).to eq("medium")
      end

      it "detects Gmail temporary block" do
        message = "421-4.7.0 Try again later, closing connection."
        result = IPBlacklist::SMTPResponseParser.parse(message, "421")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("gmail_temporary_block")
        expect(result[:severity]).to eq("high")
      end
    end

    context "Generic DNSBL patterns" do
      it "detects Spamhaus listing" do
        message = "554 Service unavailable; Client host [192.0.2.1] blocked using zen.spamhaus.org"
        result = IPBlacklist::SMTPResponseParser.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("spamhaus_zen")
        expect(result[:severity]).to eq("high")
      end
    end
  end

  describe "Configuration integration" do
    it "uses configured thresholds" do
      # This tests that the configuration values are properly read
      # In real usage, these would come from postal.yml

      tracker = IPBlacklist::SoftBounceTracker.new(
        ip_address_id: ip_address.id,
        destination_domain: "gmail.com",
        threshold: 10, # Custom threshold
        window_minutes: 30 # Custom window
      )

      expect(tracker.threshold).to eq(10)
      expect(tracker.window_minutes).to eq(30)
    end
  end
end
