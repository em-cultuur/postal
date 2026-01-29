# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rate_limits
#
#  id                                                 :integer          not null, primary key
#  current_delay                                      :integer          default(0)
#  error_count                                        :integer          default(0)
#  last_error_at                                      :datetime
#  last_error_message                                 :string(255)
#  last_success_at                                    :datetime
#  max_attempts                                       :integer          default(10)
#  mx_domain                                          :string(255)      not null
#  success_count                                      :integer          default(0)
#  whitelisted(Skip rate limiting for this MX domain) :boolean          default(FALSE)
#  created_at                                         :datetime         not null
#  updated_at                                         :datetime         not null
#  server_id                                          :integer          not null
#
# Indexes
#
#  index_mx_rate_limits_on_current_delay  (current_delay)
#  index_mx_rate_limits_on_last_error_at  (last_error_at)
#  index_mx_rate_limits_on_server_and_mx  (server_id,mx_domain) UNIQUE
#  index_mx_rate_limits_whitelisted       (server_id,whitelisted)
#
# Foreign Keys
#
#  fk_rails_...  (server_id => servers.id)
#
require "rails_helper"

RSpec.describe MXRateLimit do
  let(:organization) { create(:organization) }
  let(:server) { create(:server, organization: organization) }

  describe "validations" do
    it "requires an mx_domain" do
      rate_limit = MXRateLimit.new(server: server)
      expect(rate_limit).not_to be_valid
      expect(rate_limit.errors[:mx_domain]).to include("can't be blank")
    end

    it "enforces uniqueness of mx_domain per server" do
      MXRateLimit.create!(server: server, mx_domain: "google.com")
      duplicate = MXRateLimit.new(server: server, mx_domain: "google.com")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:mx_domain]).to include("has already been taken")
    end

    it "allows same mx_domain for different servers" do
      other_server = create(:server, organization: organization, name: "other-server-#{SecureRandom.hex(4)}")
      MXRateLimit.create!(server: server, mx_domain: "google.com")
      other_rate_limit = MXRateLimit.new(server: other_server, mx_domain: "google.com")
      expect(other_rate_limit).to be_valid
    end

    it "requires current_delay to be >= 0" do
      rate_limit = MXRateLimit.new(server: server, mx_domain: "google.com", current_delay: -1)
      expect(rate_limit).not_to be_valid
      expect(rate_limit.errors[:current_delay]).to be_present
    end
  end

  describe ".rate_limited?" do
    it "returns false when MX domain is not rate limited" do
      expect(MXRateLimit.rate_limited?(server, "google.com")).to be false
    end

    it "returns false when rate limit exists but delay is 0" do
      MXRateLimit.create!(server: server, mx_domain: "google.com", current_delay: 0)
      expect(MXRateLimit.rate_limited?(server, "google.com")).to be false
    end

    it "returns true when MX domain is actively rate limited" do
      MXRateLimit.create!(server: server, mx_domain: "google.com", current_delay: 300)
      expect(MXRateLimit.rate_limited?(server, "google.com")).to be true
    end

    it "normalizes mx_domain to lowercase" do
      MXRateLimit.create!(server: server, mx_domain: "google.com", current_delay: 300)
      expect(MXRateLimit.rate_limited?(server, "GOOGLE.COM")).to be true
    end

    it "returns false when mx_domain is blank" do
      expect(MXRateLimit.rate_limited?(server, "")).to be false
      expect(MXRateLimit.rate_limited?(server, nil)).to be false
    end
  end

  describe ".cleanup_inactive" do
    it "removes inactive rate limits with old last_success" do
      inactive_old = MXRateLimit.create!(
        server: server,
        mx_domain: "old.com",
        current_delay: 0,
        last_success_at: 25.hours.ago
      )
      inactive_recent = MXRateLimit.create!(
        server: server,
        mx_domain: "recent.com",
        current_delay: 0,
        last_success_at: 23.hours.ago
      )
      active = MXRateLimit.create!(
        server: server,
        mx_domain: "active.com",
        current_delay: 300
      )

      deleted_count = MXRateLimit.cleanup_inactive

      expect(deleted_count).to eq(1)
      expect(MXRateLimit.exists?(inactive_old.id)).to be false
      expect(MXRateLimit.exists?(inactive_recent.id)).to be true
      expect(MXRateLimit.exists?(active.id)).to be true
    end

    it "removes abandoned active rate limits (no activity for delay * multiplier)" do
      # Active rate limit with delay=3600s (1h), last activity 11h ago
      # With multiplier=3, threshold is 3h, so 11h > 3h -> should be deleted
      # But minimum is 48h (2 days), so it should NOT be deleted yet
      active_recent = MXRateLimit.create!(
        server: server,
        mx_domain: "active-recent.com",
        current_delay: 3600, # 1 hour
        last_success_at: 11.hours.ago,
        last_error_at: 12.hours.ago
      )

      # Active rate limit with delay=3600s (1h), last activity 3 days ago
      # Minimum threshold is 48h (2 days), so it should be deleted
      active_old = MXRateLimit.create!(
        server: server,
        mx_domain: "active-old.com",
        current_delay: 3600, # 1 hour
        last_success_at: 3.days.ago,
        last_error_at: 4.days.ago
      )

      # Active rate limit with delay=7200s (2h), last activity 1 day ago
      # Minimum threshold is 48h (2 days), so should NOT be deleted yet
      active_medium = MXRateLimit.create!(
        server: server,
        mx_domain: "active-medium.com",
        current_delay: 7200, # 2 hours
        last_success_at: 1.day.ago
      )

      deleted_count = MXRateLimit.cleanup_inactive

      expect(deleted_count).to eq(1)
      expect(MXRateLimit.exists?(active_recent.id)).to be true
      expect(MXRateLimit.exists?(active_old.id)).to be false
      expect(MXRateLimit.exists?(active_medium.id)).to be true
    end

    it "uses last_success_at when last_error_at is nil" do
      active_old = MXRateLimit.create!(
        server: server,
        mx_domain: "success-only.com",
        current_delay: 300,
        last_success_at: 3.days.ago,
        last_error_at: nil
      )

      deleted_count = MXRateLimit.cleanup_inactive

      expect(deleted_count).to eq(1)
      expect(MXRateLimit.exists?(active_old.id)).to be false
    end

    it "uses last_error_at when last_success_at is nil" do
      active_old = MXRateLimit.create!(
        server: server,
        mx_domain: "error-only.com",
        current_delay: 300,
        last_success_at: nil,
        last_error_at: 3.days.ago
      )

      deleted_count = MXRateLimit.cleanup_inactive

      expect(deleted_count).to eq(1)
      expect(MXRateLimit.exists?(active_old.id)).to be false
    end

    it "uses the most recent timestamp when both are present" do
      # Last error was 4 days ago but last success was 1 day ago
      # Should use 1 day (more recent), so NOT deleted yet (< 48h minimum)
      active_mixed = MXRateLimit.create!(
        server: server,
        mx_domain: "mixed.com",
        current_delay: 300,
        last_success_at: 1.day.ago,
        last_error_at: 4.days.ago
      )

      deleted_count = MXRateLimit.cleanup_inactive

      expect(deleted_count).to eq(0)
      expect(MXRateLimit.exists?(active_mixed.id)).to be true
    end

    it "combines inactive and abandoned cleanup counts" do
      # Inactive old
      inactive_old = MXRateLimit.create!(
        server: server,
        mx_domain: "inactive-old.com",
        current_delay: 0,
        last_success_at: 25.hours.ago
      )

      # Abandoned active
      active_old = MXRateLimit.create!(
        server: server,
        mx_domain: "active-old.com",
        current_delay: 300,
        last_success_at: 3.days.ago
      )

      # Should delete both
      deleted_count = MXRateLimit.cleanup_inactive

      expect(deleted_count).to eq(2)
      expect(MXRateLimit.exists?(inactive_old.id)).to be false
      expect(MXRateLimit.exists?(active_old.id)).to be false
    end
  end

  describe ".cleanup_abandoned" do
    it "returns count of deleted abandoned rate limits" do
      MXRateLimit.create!(
        server: server,
        mx_domain: "abandoned1.com",
        current_delay: 300,
        last_success_at: 3.days.ago
      )
      MXRateLimit.create!(
        server: server,
        mx_domain: "abandoned2.com",
        current_delay: 600,
        last_error_at: 3.days.ago
      )

      deleted_count = MXRateLimit.cleanup_abandoned

      expect(deleted_count).to eq(2)
    end

    it "does not delete active rate limits with recent activity" do
      recent = MXRateLimit.create!(
        server: server,
        mx_domain: "recent.com",
        current_delay: 300,
        last_success_at: 1.day.ago
      )

      deleted_count = MXRateLimit.cleanup_abandoned

      expect(deleted_count).to eq(0)
      expect(MXRateLimit.exists?(recent.id)).to be true
    end

    it "does not delete inactive rate limits (delay=0)" do
      inactive = MXRateLimit.create!(
        server: server,
        mx_domain: "inactive.com",
        current_delay: 0,
        last_success_at: 10.days.ago
      )

      deleted_count = MXRateLimit.cleanup_abandoned

      expect(deleted_count).to eq(0)
      expect(MXRateLimit.exists?(inactive.id)).to be true
    end
  end

  describe "#record_error" do
    let(:rate_limit) { create(:mx_rate_limit, server: server, mx_domain: "google.com") }

    it "increments error_count" do
      expect do
        rate_limit.record_error(smtp_response: "421 Try again later")
      end.to change { rate_limit.reload.error_count }.from(0).to(1)
    end

    it "resets success_count" do
      rate_limit.update(success_count: 3)
      rate_limit.record_error(smtp_response: "421 Try again later")
      expect(rate_limit.reload.success_count).to eq(0)
    end

    it "increases current_delay by configured increment" do
      expect do
        rate_limit.record_error(smtp_response: "421 Try again later")
      end.to change { rate_limit.reload.current_delay }.from(0).to(MXRateLimit.delay_increment)
    end

    it "caps current_delay at configured maximum" do
      rate_limit.update(current_delay: MXRateLimit.max_delay - 100)
      rate_limit.record_error(smtp_response: "421 Try again later")
      expect(rate_limit.reload.current_delay).to eq(MXRateLimit.max_delay)
    end

    it "updates last_error_at" do
      Timecop.freeze do
        rate_limit.record_error(smtp_response: "421 Try again later")
        expect(rate_limit.reload.last_error_at).to be_within(1.second).of(Time.current)
      end
    end

    it "updates last_error_message" do
      rate_limit.record_error(smtp_response: "421 Try again later")
      expect(rate_limit.reload.last_error_message).to eq("421 Try again later")
    end

    it "truncates long error messages to 255 characters" do
      long_message = "x" * 500
      rate_limit.record_error(smtp_response: long_message)
      expect(rate_limit.reload.last_error_message.length).to eq(255)
    end

    it "creates an error event" do
      expect do
        rate_limit.record_error(smtp_response: "421 Try again later", pattern: "SMTP 421 Rate Limit")
      end.to change { MXRateLimitEvent.where(event_type: "error").count }.by(1)

      event = MXRateLimitEvent.where(event_type: "error").last
      expect(event.mx_domain).to eq("google.com")
      expect(event.smtp_response).to eq("421 Try again later")
      expect(event.matched_pattern).to eq("SMTP 421 Rate Limit")
    end

    it "creates a delay_increased event when delay changes" do
      expect do
        rate_limit.record_error(smtp_response: "421 Try again later")
      end.to change { MXRateLimitEvent.where(event_type: "delay_increased").count }.by(1)

      event = MXRateLimitEvent.where(event_type: "delay_increased").last
      expect(event.delay_before).to eq(0)
      expect(event.delay_after).to eq(MXRateLimit.delay_increment)
    end
  end

  describe "#record_success" do
    let(:rate_limit) { create(:mx_rate_limit, :active, server: server, mx_domain: "google.com") }

    it "increments success_count" do
      expect do
        rate_limit.record_success
      end.to change { rate_limit.reload.success_count }.by(1)
    end

    it "resets error_count" do
      rate_limit.update(error_count: 5)
      rate_limit.record_success
      expect(rate_limit.reload.error_count).to eq(0)
    end

    it "updates last_success_at" do
      Timecop.freeze do
        rate_limit.record_success
        expect(rate_limit.reload.last_success_at).to be_within(1.second).of(Time.current)
      end
    end

    it "creates a success event" do
      expect do
        rate_limit.record_success
      end.to change { MXRateLimitEvent.where(event_type: "success").count }.by(1)
    end

    context "when success_count reaches configured recovery threshold" do
      before do
        rate_limit.update(success_count: MXRateLimit.recovery_threshold - 1, current_delay: 600)
      end

      it "decreases current_delay by configured decrement" do
        expect do
          rate_limit.record_success
        end.to change { rate_limit.reload.current_delay }.from(600).to(600 - MXRateLimit.delay_decrement)
      end

      it "resets success_count to 0" do
        rate_limit.record_success
        expect(rate_limit.reload.success_count).to eq(0)
      end

      it "creates a delay_decreased event" do
        expect do
          rate_limit.record_success
        end.to change { MXRateLimitEvent.where(event_type: "delay_decreased").count }.by(1)
      end

      it "does not go below 0 delay" do
        rate_limit.update(current_delay: 60)
        rate_limit.record_success
        expect(rate_limit.reload.current_delay).to eq(0)
      end
    end

    context "when success_count is below threshold" do
      before do
        rate_limit.update(success_count: 2, current_delay: 600)
      end

      it "does not decrease delay" do
        expect do
          rate_limit.record_success
        end.not_to change { rate_limit.reload.current_delay }
      end

      it "does not create delay_decreased event" do
        expect do
          rate_limit.record_success
        end.not_to change { MXRateLimitEvent.where(event_type: "delay_decreased").count }
      end
    end
  end

  describe "#active?" do
    it "returns true when current_delay > 0" do
      rate_limit = MXRateLimit.new(current_delay: 300)
      expect(rate_limit.active?).to be true
    end

    it "returns false when current_delay = 0" do
      rate_limit = MXRateLimit.new(current_delay: 0)
      expect(rate_limit.active?).to be false
    end
  end

  describe "#wait_seconds" do
    it "returns current_delay" do
      rate_limit = MXRateLimit.new(current_delay: 600)
      expect(rate_limit.wait_seconds).to eq(600)
    end
  end

  describe "scopes" do
    before do
      @active1 = create(:mx_rate_limit, server: server, mx_domain: "active1.com", current_delay: 300)
      @active2 = create(:mx_rate_limit, server: server, mx_domain: "active2.com", current_delay: 600)
      @inactive1 = create(:mx_rate_limit, server: server, mx_domain: "inactive1.com", current_delay: 0)
      @inactive2 = create(:mx_rate_limit, server: server, mx_domain: "inactive2.com", current_delay: 0)
    end

    describe ".active" do
      it "returns only rate limits with current_delay > 0" do
        expect(MXRateLimit.active).to contain_exactly(@active1, @active2)
      end
    end

    describe ".inactive" do
      it "returns only rate limits with current_delay = 0" do
        expect(MXRateLimit.inactive).to contain_exactly(@inactive1, @inactive2)
      end
    end
  end

  describe "destroying rate limits and associated events" do
    let(:rate_limit) { create(:mx_rate_limit, server: server, mx_domain: "test.com") }

    before do
      # Create some events for this rate limit
      3.times do |i|
        MXRateLimitEvent.create!(
          server_id: rate_limit.server_id,
          mx_domain: rate_limit.mx_domain,
          event_type: "error",
          delay_before: i * 100,
          delay_after: (i + 1) * 100,
          created_at: i.hours.ago
        )
      end
    end

    it "deletes associated events when rate limit is manually destroyed" do
      expect do
        rate_limit.destroy
      end.to change { MXRateLimitEvent.where(server_id: rate_limit.server_id, mx_domain: rate_limit.mx_domain).count }.from(3).to(0)
    end

    it "deletes associated events when rate limit is cleaned up by cleanup_inactive" do
      rate_limit.update(current_delay: 0, last_success_at: 25.hours.ago)

      expect do
        MXRateLimit.cleanup_inactive
      end.to change { MXRateLimitEvent.where(server_id: rate_limit.server_id, mx_domain: rate_limit.mx_domain).count }.from(3).to(0)
    end

    it "deletes associated events when rate limit is cleaned up by cleanup_abandoned" do
      rate_limit.update(current_delay: 300, last_success_at: 3.days.ago)

      expect do
        MXRateLimit.cleanup_abandoned
      end.to change { MXRateLimitEvent.where(server_id: rate_limit.server_id, mx_domain: rate_limit.mx_domain).count }.from(3).to(0)
    end

    it "does not delete events for other rate limits" do
      other_rate_limit = create(:mx_rate_limit, server: server, mx_domain: "other.com")
      other_event = MXRateLimitEvent.create!(
        server_id: other_rate_limit.server_id,
        mx_domain: other_rate_limit.mx_domain,
        event_type: "success"
      )

      rate_limit.destroy

      expect(MXRateLimitEvent.exists?(other_event.id)).to be true
    end

    it "does not delete events for same mx_domain but different server" do
      other_server = create(:server, organization: organization, name: "other-server-#{SecureRandom.hex(4)}")
      other_rate_limit = create(:mx_rate_limit, server: other_server, mx_domain: rate_limit.mx_domain)
      other_event = MXRateLimitEvent.create!(
        server_id: other_rate_limit.server_id,
        mx_domain: other_rate_limit.mx_domain,
        event_type: "success"
      )

      rate_limit.destroy

      expect(MXRateLimitEvent.exists?(other_event.id)).to be true
    end
  end

  describe "#allow_probe?" do
    let(:rate_limit) { create(:mx_rate_limit, server: server, mx_domain: "google.com") }

    context "when rate limit is not active (current_delay = 0)" do
      before do
        rate_limit.update(current_delay: 0, last_error_at: 10.minutes.ago)
      end

      it "returns false" do
        expect(rate_limit.allow_probe?).to be false
      end
    end

    context "when last_error_at is nil" do
      before do
        rate_limit.update(current_delay: 300, last_error_at: nil)
      end

      it "returns false" do
        expect(rate_limit.allow_probe?).to be false
      end
    end

    context "when rate limit is active and last_error_at is present" do
      before do
        rate_limit.update(current_delay: 300)
      end

      context "when enough time has passed since last error" do
        it "returns true when time since last error >= current_delay" do
          Timecop.freeze do
            rate_limit.update(last_error_at: 301.seconds.ago)
            expect(rate_limit.allow_probe?).to be true
          end
        end

        it "returns true when time since last error exactly equals current_delay" do
          Timecop.freeze do
            rate_limit.update(last_error_at: 300.seconds.ago)
            expect(rate_limit.allow_probe?).to be true
          end
        end
      end

      context "when not enough time has passed since last error" do
        it "returns false when time since last error < current_delay" do
          Timecop.freeze do
            rate_limit.update(last_error_at: 299.seconds.ago)
            expect(rate_limit.allow_probe?).to be false
          end
        end

        it "returns false when last error was just now" do
          Timecop.freeze do
            rate_limit.update(last_error_at: Time.current)
            expect(rate_limit.allow_probe?).to be false
          end
        end
      end
    end

    context "with different delay values" do
      it "respects delay of 600 seconds" do
        Timecop.freeze do
          rate_limit.update(current_delay: 600, last_error_at: 599.seconds.ago)
          expect(rate_limit.allow_probe?).to be false

          rate_limit.update(last_error_at: 600.seconds.ago)
          expect(rate_limit.allow_probe?).to be true
        end
      end

      it "respects delay of 60 seconds" do
        Timecop.freeze do
          rate_limit.update(current_delay: 60, last_error_at: 59.seconds.ago)
          expect(rate_limit.allow_probe?).to be false

          rate_limit.update(last_error_at: 60.seconds.ago)
          expect(rate_limit.allow_probe?).to be true
        end
      end
    end
  end

  describe "#mark_probe_attempt" do
    let(:rate_limit) { create(:mx_rate_limit, server: server, mx_domain: "google.com") }

    it "updates last_error_at to current time" do
      Timecop.freeze do
        old_time = 10.minutes.ago
        rate_limit.update(last_error_at: old_time)

        rate_limit.mark_probe_attempt

        expect(rate_limit.reload.last_error_at).to be_within(1.second).of(Time.current)
        expect(rate_limit.reload.last_error_at).not_to eq(old_time)
      end
    end

    it "updates updated_at timestamp" do
      Timecop.freeze do
        old_updated_at = 10.minutes.ago
        rate_limit.update_columns(updated_at: old_updated_at)

        rate_limit.mark_probe_attempt

        expect(rate_limit.reload.updated_at).to be_within(1.second).of(Time.current)
        expect(rate_limit.reload.updated_at).not_to eq(old_updated_at)
      end
    end

    it "does not change current_delay" do
      rate_limit.update(current_delay: 300)

      expect do
        rate_limit.mark_probe_attempt
      end.not_to change { rate_limit.reload.current_delay }
    end

    it "does not change error_count" do
      rate_limit.update(error_count: 5)

      expect do
        rate_limit.mark_probe_attempt
      end.not_to change { rate_limit.reload.error_count }
    end

    it "does not change success_count" do
      rate_limit.update(success_count: 3)

      expect do
        rate_limit.mark_probe_attempt
      end.not_to change { rate_limit.reload.success_count }
    end
  end

  describe "probe message flow" do
    let(:rate_limit) { create(:mx_rate_limit, server: server, mx_domain: "google.com") }

    context "preventing multiple simultaneous probes" do
      it "allows only one probe per delay period" do
        Timecop.freeze do
          # Initial error creates 300s delay
          rate_limit.record_error(smtp_response: "421 Rate limited")
          expect(rate_limit.reload.current_delay).to eq(300)

          # Not enough time passed - no probe
          Timecop.travel(299.seconds.from_now) do
            expect(rate_limit.allow_probe?).to be false
          end

          # Exactly 300 seconds - probe allowed
          Timecop.travel(300.seconds.from_now) do
            expect(rate_limit.allow_probe?).to be true

            # Mark probe attempt
            rate_limit.mark_probe_attempt

            # Immediately after marking, no new probe should be allowed
            expect(rate_limit.reload.allow_probe?).to be false
          end

          # After another delay period, next probe is allowed
          Timecop.travel(600.seconds.from_now) do
            expect(rate_limit.reload.allow_probe?).to be true
          end
        end
      end
    end

    context "recovery scenario" do
      it "allows gradual recovery through successful probes" do
        base_time = Time.current
        Timecop.freeze(base_time) do
          # Start with active rate limit
          rate_limit.update(
            current_delay: 600,
            error_count: 10,
            success_count: 0,
            last_error_at: base_time - 601.seconds
          )

          # First probe - is allowed
          expect(rate_limit.allow_probe?).to be true
          rate_limit.mark_probe_attempt

          # Simulate successful probe delivery
          rate_limit.record_success
          expect(rate_limit.reload.success_count).to eq(1)

          # Not enough successes yet - delay unchanged
          expect(rate_limit.current_delay).to eq(600)
        end

        # Simulate 4 more successful probes at 600 second intervals
        (1..4).each do |i|
          Timecop.freeze(base_time + (i * 600).seconds) do
            expect(rate_limit.reload.allow_probe?).to be true
            rate_limit.mark_probe_attempt
            rate_limit.record_success
          end
        end

        # After 5th success, delay should decrease
        expect(rate_limit.reload.current_delay).to eq(600 - MXRateLimit.delay_decrement)
        expect(rate_limit.success_count).to eq(0) # Reset after decrease
      end
    end

    context "failed probe scenario" do
      it "increases delay if probe fails" do
        Timecop.freeze do
          rate_limit.update(current_delay: 300, last_error_at: 301.seconds.ago)

          # Probe is allowed
          expect(rate_limit.allow_probe?).to be true
          rate_limit.mark_probe_attempt

          # Probe fails - record another error
          rate_limit.record_error(smtp_response: "421 Still rate limited")

          # Delay should increase
          expect(rate_limit.reload.current_delay).to eq(600)

          # Success count reset
          expect(rate_limit.success_count).to eq(0)
        end
      end
    end
  end
end
