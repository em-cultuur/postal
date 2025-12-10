# frozen_string_literal: true

require "rails_helper"

RSpec.describe DomainThrottle do
  let(:organization) { create(:organization) }
  let(:server) { create(:server, organization: organization) }

  describe "validations" do
    it "requires a domain" do
      throttle = DomainThrottle.new(server: server, throttled_until: 1.hour.from_now)
      expect(throttle).not_to be_valid
      expect(throttle.errors[:domain]).to include("can't be blank")
    end

    it "requires a throttled_until" do
      throttle = DomainThrottle.new(server: server, domain: "example.com")
      expect(throttle).not_to be_valid
      expect(throttle.errors[:throttled_until]).to include("can't be blank")
    end

    it "enforces uniqueness of domain per server" do
      DomainThrottle.create!(server: server, domain: "example.com", throttled_until: 1.hour.from_now)
      duplicate = DomainThrottle.new(server: server, domain: "example.com", throttled_until: 2.hours.from_now)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:domain]).to include("has already been taken")
    end

    it "allows same domain for different servers" do
      other_server = create(:server, organization: organization, name: "other-server-#{SecureRandom.hex(4)}")
      DomainThrottle.create!(server: server, domain: "example.com", throttled_until: 1.hour.from_now)
      other_throttle = DomainThrottle.new(server: other_server, domain: "example.com", throttled_until: 2.hours.from_now)
      expect(other_throttle).to be_valid
    end
  end

  describe ".throttled?" do
    it "returns nil when domain is not throttled" do
      expect(DomainThrottle.throttled?(server, "example.com")).to be_nil
    end

    it "returns nil when throttle has expired" do
      DomainThrottle.create!(server: server, domain: "example.com", throttled_until: 1.hour.ago)
      expect(DomainThrottle.throttled?(server, "example.com")).to be_nil
    end

    it "returns the throttle when domain is actively throttled" do
      throttle = DomainThrottle.create!(server: server, domain: "example.com", throttled_until: 1.hour.from_now)
      expect(DomainThrottle.throttled?(server, "example.com")).to eq(throttle)
    end

    it "normalizes domain to lowercase" do
      throttle = DomainThrottle.create!(server: server, domain: "example.com", throttled_until: 1.hour.from_now)
      expect(DomainThrottle.throttled?(server, "EXAMPLE.COM")).to eq(throttle)
    end
  end

  describe ".apply" do
    it "creates a new throttle for a domain" do
      expect {
        DomainThrottle.apply(server, "example.com", duration: 300, reason: "451 too many messages")
      }.to change(DomainThrottle, :count).by(1)

      throttle = DomainThrottle.last
      expect(throttle.domain).to eq("example.com")
      expect(throttle.reason).to eq("451 too many messages")
      expect(throttle.throttled_until).to be_within(5.seconds).of(Time.current + 300.seconds)
    end

    it "normalizes domain to lowercase" do
      DomainThrottle.apply(server, "EXAMPLE.COM", duration: 300)
      expect(DomainThrottle.last.domain).to eq("example.com")
    end

    it "updates existing throttle with longer duration" do
      existing = DomainThrottle.create!(
        server: server,
        domain: "example.com",
        throttled_until: 2.minutes.from_now,
        reason: "original reason"
      )

      DomainThrottle.apply(server, "example.com", duration: 600, reason: "new reason")

      existing.reload
      expect(existing.reason).to eq("new reason")
      expect(existing.throttled_until).to be_within(5.seconds).of(Time.current + 600.seconds)
    end

    it "uses default duration when not specified" do
      DomainThrottle.apply(server, "example.com")
      throttle = DomainThrottle.last
      expect(throttle.throttled_until).to be_within(5.seconds).of(
        Time.current + DomainThrottle::DEFAULT_THROTTLE_DURATION.seconds
      )
    end

    it "truncates long reason strings" do
      long_reason = "x" * 500
      DomainThrottle.apply(server, "example.com", reason: long_reason)
      expect(DomainThrottle.last.reason.length).to eq(255)
    end
  end

  describe ".cleanup_expired" do
    it "removes expired throttles" do
      expired1 = DomainThrottle.create!(server: server, domain: "expired1.com", throttled_until: 2.hours.ago)
      expired2 = DomainThrottle.create!(server: server, domain: "expired2.com", throttled_until: 1.minute.ago)
      active = DomainThrottle.create!(server: server, domain: "active.com", throttled_until: 1.hour.from_now)

      deleted_count = DomainThrottle.cleanup_expired

      expect(deleted_count).to eq(2)
      expect(DomainThrottle.exists?(expired1.id)).to be false
      expect(DomainThrottle.exists?(expired2.id)).to be false
      expect(DomainThrottle.exists?(active.id)).to be true
    end

    it "returns 0 when no expired throttles exist" do
      DomainThrottle.create!(server: server, domain: "active.com", throttled_until: 1.hour.from_now)
      expect(DomainThrottle.cleanup_expired).to eq(0)
    end
  end

  describe "#remaining_seconds" do
    it "returns the remaining seconds for an active throttle" do
      throttle = DomainThrottle.new(throttled_until: 5.minutes.from_now)
      expect(throttle.remaining_seconds).to be_within(5).of(300)
    end

    it "returns 0 for an expired throttle" do
      throttle = DomainThrottle.new(throttled_until: 1.minute.ago)
      expect(throttle.remaining_seconds).to eq(0)
    end
  end

  describe "#active?" do
    it "returns true when throttle is still active" do
      throttle = DomainThrottle.new(throttled_until: 1.hour.from_now)
      expect(throttle.active?).to be true
    end

    it "returns false when throttle has expired" do
      throttle = DomainThrottle.new(throttled_until: 1.minute.ago)
      expect(throttle.active?).to be false
    end
  end

  describe "scopes" do
    before do
      @active1 = DomainThrottle.create!(server: server, domain: "active1.com", throttled_until: 1.hour.from_now)
      @active2 = DomainThrottle.create!(server: server, domain: "active2.com", throttled_until: 30.minutes.from_now)
      @expired1 = DomainThrottle.create!(server: server, domain: "expired1.com", throttled_until: 1.hour.ago)
      @expired2 = DomainThrottle.create!(server: server, domain: "expired2.com", throttled_until: 1.minute.ago)
    end

    describe ".active" do
      it "returns only active throttles" do
        expect(DomainThrottle.active).to contain_exactly(@active1, @active2)
      end
    end

    describe ".expired" do
      it "returns only expired throttles" do
        expect(DomainThrottle.expired).to contain_exactly(@expired1, @expired2)
      end
    end
  end
end

