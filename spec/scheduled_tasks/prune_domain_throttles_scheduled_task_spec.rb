# frozen_string_literal: true

require "rails_helper"

RSpec.describe PruneDomainThrottlesScheduledTask do
  let(:organization) { create(:organization) }
  let(:server) { create(:server, organization: organization) }
  let(:logger) { instance_double("Logger", info: nil, debug: nil, error: nil) }
  let(:task) { described_class.new(logger: logger) }

  describe "#call" do
    it "removes expired domain throttles" do
      expired1 = DomainThrottle.create!(server: server, domain: "expired1.com", throttled_until: 2.hours.ago)
      expired2 = DomainThrottle.create!(server: server, domain: "expired2.com", throttled_until: 1.minute.ago)
      active = DomainThrottle.create!(server: server, domain: "active.com", throttled_until: 1.hour.from_now)

      task.call

      expect(DomainThrottle.exists?(expired1.id)).to be false
      expect(DomainThrottle.exists?(expired2.id)).to be false
      expect(DomainThrottle.exists?(active.id)).to be true
    end

    it "does not raise errors when no throttles exist" do
      expect { task.call }.not_to raise_error
    end
  end

  describe ".next_run_after" do
    it "returns a time 15 minutes in the future" do
      next_run = described_class.next_run_after
      expect(next_run).to be_within(1.minute).of(15.minutes.from_now)
    end
  end
end

