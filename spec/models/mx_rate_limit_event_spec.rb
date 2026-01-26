# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rate_limit_events
#
#  id                :integer          not null, primary key
#  delay_after       :integer
#  delay_before      :integer
#  error_count       :integer
#  event_type        :string(255)      not null
#  matched_pattern   :string(255)
#  mx_domain         :string(255)      not null
#  recipient_domain  :string(255)
#  smtp_response     :text(65535)
#  success_count     :integer
#  created_at        :datetime
#  queued_message_id :integer
#  server_id         :integer          not null
#
# Indexes
#
#  index_mx_rate_limit_events_on_created_at         (created_at)
#  index_mx_rate_limit_events_on_event_type         (event_type)
#  index_mx_rate_limit_events_on_queued_message_id  (queued_message_id)
#  index_mx_rate_limit_events_on_server_and_mx      (server_id,mx_domain)
#
# Foreign Keys
#
#  fk_rails_...  (server_id => servers.id)
#
require "rails_helper"

RSpec.describe MXRateLimitEvent do
  let(:organization) { create(:organization) }
  let(:server) { create(:server, organization: organization) }

  describe "validations" do
    it "requires mx_domain" do
      event = MXRateLimitEvent.new(server: server, event_type: "error")
      expect(event).not_to be_valid
      expect(event.errors[:mx_domain]).to include("can't be blank")
    end

    it "requires event_type" do
      event = MXRateLimitEvent.new(server: server, mx_domain: "google.com")
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to include("can't be blank")
    end

    it "validates event_type is valid" do
      event = MXRateLimitEvent.new(server: server, mx_domain: "google.com", event_type: "invalid")
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to be_present
    end

    it "allows valid event types" do
      MXRateLimitEvent::EVENT_TYPES.each do |event_type|
        event = MXRateLimitEvent.new(server: server, mx_domain: "google.com", event_type: event_type)
        expect(event).to be_valid
      end
    end
  end

  describe ".stats_for_mx" do
    before do
      # Recent events (last 24 hours)
      create(:mx_rate_limit_event, server: server, mx_domain: "google.com", event_type: "error", created_at: 1.hour.ago)
      create(:mx_rate_limit_event, server: server, mx_domain: "google.com", event_type: "error", created_at: 2.hours.ago)
      create(:mx_rate_limit_event, server: server, mx_domain: "google.com", event_type: "success", created_at: 30.minutes.ago)
      create(:mx_rate_limit_event, server: server, mx_domain: "google.com", event_type: "throttled", created_at: 3.hours.ago)

      # Old events (should not be counted)
      create(:mx_rate_limit_event, server: server, mx_domain: "google.com", event_type: "error", created_at: 25.hours.ago)

      # Different MX (should not be counted)
      create(:mx_rate_limit_event, server: server, mx_domain: "yahoo.com", event_type: "error", created_at: 1.hour.ago)
    end

    it "returns event counts for the specified MX domain" do
      stats = MXRateLimitEvent.stats_for_mx(server, "google.com")

      expect(stats["error"]).to eq(2)
      expect(stats["success"]).to eq(1)
      expect(stats["throttled"]).to eq(1)
    end

    it "only counts events since the specified time" do
      stats = MXRateLimitEvent.stats_for_mx(server, "google.com", since: 4.hours.ago)

      expect(stats["error"]).to eq(2)
      expect(stats["success"]).to eq(1)
      expect(stats["throttled"]).to eq(1)
    end

    it "returns empty hash when no events found" do
      stats = MXRateLimitEvent.stats_for_mx(server, "nonexistent.com")
      expect(stats).to eq({})
    end
  end

  describe ".cleanup_old" do
    it "deletes events older than 30 days" do
      old1 = create(:mx_rate_limit_event, server: server, mx_domain: "old1.com", created_at: 31.days.ago)
      old2 = create(:mx_rate_limit_event, server: server, mx_domain: "old2.com", created_at: 60.days.ago)
      recent = create(:mx_rate_limit_event, server: server, mx_domain: "recent.com", created_at: 29.days.ago)

      deleted_count = MXRateLimitEvent.cleanup_old

      expect(deleted_count).to eq(2)
      expect(MXRateLimitEvent.exists?(old1.id)).to be false
      expect(MXRateLimitEvent.exists?(old2.id)).to be false
      expect(MXRateLimitEvent.exists?(recent.id)).to be true
    end

    it "returns 0 when no old events exist" do
      create(:mx_rate_limit_event, server: server, mx_domain: "recent.com", created_at: 1.day.ago)
      expect(MXRateLimitEvent.cleanup_old).to eq(0)
    end
  end

  describe "scopes" do
    before do
      @error1 = create(:mx_rate_limit_event, server: server, event_type: "error", created_at: 1.hour.ago)
      @error2 = create(:mx_rate_limit_event, server: server, event_type: "error", created_at: 2.hours.ago)
      @success1 = create(:mx_rate_limit_event, :success, server: server, created_at: 30.minutes.ago)
      @success2 = create(:mx_rate_limit_event, :success, server: server, created_at: 3.hours.ago)
      @old_error = create(:mx_rate_limit_event, server: server, event_type: "error", created_at: 25.hours.ago)
    end

    describe ".errors" do
      it "returns only error events" do
        expect(MXRateLimitEvent.errors).to contain_exactly(@error1, @error2, @old_error)
      end
    end

    describe ".successes" do
      it "returns only success events" do
        expect(MXRateLimitEvent.successes).to contain_exactly(@success1, @success2)
      end
    end

    describe ".recent" do
      it "returns events from last 24 hours" do
        expect(MXRateLimitEvent.recent).to contain_exactly(@error1, @error2, @success1, @success2)
      end
    end
  end
end
