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
end
