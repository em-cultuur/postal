# frozen_string_literal: true

require "rails_helper"

RSpec.describe CleanupMXRateLimitDataTask do
  let(:organization) { create(:organization) }
  let(:server) { create(:server, organization: organization) }
  let(:logger) { instance_double("Logger", info: nil, debug: nil, error: nil) }

  subject(:task) { described_class.new(logger: logger) }

  describe "#call" do
    context "cleaning up inactive rate limits" do
      it "removes inactive rate limits" do
        inactive1 = create(:mx_rate_limit, server: server, mx_domain: "inactive1.com", error_count: 0, current_delay: 0, last_success_at: 25.hours.ago)
        inactive2 = create(:mx_rate_limit, server: server, mx_domain: "inactive2.com", error_count: 0, current_delay: 0, last_success_at: 2.days.ago)
        active = create(:mx_rate_limit, server: server, mx_domain: "active.com", error_count: 3, current_delay: 900)

        task.call

        expect(MXRateLimit.exists?(inactive1.id)).to be false
        expect(MXRateLimit.exists?(inactive2.id)).to be false
        expect(MXRateLimit.exists?(active.id)).to be true
      end
    end

    context "cleaning up old events" do
      it "removes events older than 30 days" do
        rate_limit = create(:mx_rate_limit, server: server, mx_domain: "example.com", error_count: 3, current_delay: 900)
        old_event1 = create(:mx_rate_limit_event, server: server, mx_domain: "example.com", created_at: 31.days.ago)
        old_event2 = create(:mx_rate_limit_event, server: server, mx_domain: "example.com", created_at: 60.days.ago)
        recent_event = create(:mx_rate_limit_event, server: server, mx_domain: "example.com", created_at: 1.day.ago)

        task.call

        expect(MXRateLimitEvent.exists?(old_event1.id)).to be false
        expect(MXRateLimitEvent.exists?(old_event2.id)).to be false
        expect(MXRateLimitEvent.exists?(recent_event.id)).to be true
      end
    end

    context "cleaning up expired MX domain cache" do
      it "removes expired cache entries" do
        expired1 = create(:mx_domain_cache, recipient_domain: "expired1.com", mx_domain: "mx1.expired.com", expires_at: 2.hours.ago)
        expired2 = create(:mx_domain_cache, recipient_domain: "expired2.com", mx_domain: "mx2.expired.com", expires_at: 1.day.ago)
        valid = create(:mx_domain_cache, recipient_domain: "valid.com", mx_domain: "mx.valid.com", expires_at: 1.hour.from_now)

        task.call

        expect(MXDomainCache.exists?(expired1.id)).to be false
        expect(MXDomainCache.exists?(expired2.id)).to be false
        expect(MXDomainCache.exists?(valid.id)).to be true
      end
    end

    it "does not raise errors when no data exists" do
      expect { task.call }.not_to raise_error
    end

    it "performs all cleanup operations" do
      expect(MXRateLimit).to receive(:cleanup_inactive).and_return(0)
      expect(MXRateLimitEvent).to receive(:cleanup_old).and_return(0)
      expect(MXDomainCache).to receive(:cleanup_expired).and_return(0)

      task.call
    end
  end

  describe ".next_run_after" do
    it "returns a time 1 hour in the future" do
      next_run = described_class.next_run_after
      expect(next_run).to be_within(1.minute).of(1.hour.from_now)
    end
  end
end
