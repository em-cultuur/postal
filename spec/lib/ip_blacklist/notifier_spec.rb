# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPBlacklist::Notifier do
  let(:notifier) { described_class.new }
  let(:ip_address) { create(:ip_address, ipv4: "192.0.2.1", hostname: "mail1.example.com") }
  let(:destination_domain) { "gmail.com" }

  describe "#notify_blacklist_detected" do
    let(:blacklist_record) do
      create(:ip_blacklist_record,
             ip_address: ip_address,
             destination_domain: destination_domain,
             blacklist_source: "zen.spamhaus.org")
    end

    it "sends notifications with correct event data" do
      expect(notifier).to receive(:send_notifications).with(hash_including(
                                                              event_type: "ip_blacklisted",
                                                              severity: "high",
                                                              ip_address: "192.0.2.1",
                                                              hostname: "mail1.example.com",
                                                              destination_domain: destination_domain,
                                                              blacklist_source: "zen.spamhaus.org"
                                                            ))

      notifier.notify_blacklist_detected(ip_address, blacklist_record)
    end
  end

  describe "#notify_ip_paused" do
    let(:health_action) do
      create(:ip_health_action,
             ip_address: ip_address,
             action_type: IPHealthAction::PAUSE,
             destination_domain: destination_domain)
    end
    let(:reason) { "Blacklisted on zen.spamhaus.org" }

    it "sends notifications with correct event data" do
      expect(notifier).to receive(:send_notifications).with(hash_including(
                                                              event_type: "ip_paused",
                                                              severity: "high",
                                                              ip_address: "192.0.2.1",
                                                              destination_domain: destination_domain,
                                                              reason: reason
                                                            ))

      notifier.notify_ip_paused(ip_address, destination_domain, reason, health_action)
    end
  end

  describe "#notify_ip_resumed" do
    let(:health_action) do
      create(:ip_health_action,
             ip_address: ip_address,
             action_type: IPHealthAction::UNPAUSE,
             destination_domain: destination_domain)
    end

    it "sends notifications with correct event data" do
      expect(notifier).to receive(:send_notifications).with(hash_including(
                                                              event_type: "ip_resumed",
                                                              severity: "info",
                                                              ip_address: "192.0.2.1",
                                                              destination_domain: destination_domain
                                                            ))

      notifier.notify_ip_resumed(ip_address, destination_domain, health_action)
    end
  end

  describe "#notify_reputation_warning" do
    it "sends notifications with correct event data" do
      expect(notifier).to receive(:send_notifications).with(hash_including(
                                                              event_type: "reputation_warning",
                                                              severity: "medium",
                                                              ip_address: "192.0.2.1",
                                                              metric_type: "spam_rate",
                                                              metric_value: 0.08,
                                                              threshold: 0.05
                                                            ))

      notifier.notify_reputation_warning(ip_address, destination_domain, "spam_rate", 0.08, 0.05)
    end
  end

  describe "#notify_warmup_advanced" do
    it "sends notifications with correct event data" do
      expect(notifier).to receive(:send_notifications).with(hash_including(
                                                              event_type: "warmup_advanced",
                                                              severity: "info",
                                                              ip_address: "192.0.2.1",
                                                              old_stage: 1,
                                                              new_stage: 2
                                                            ))

      notifier.notify_warmup_advanced(ip_address, destination_domain, 1, 2)
    end
  end

  describe "notification channels" do
    describe "webhooks" do
      let(:notifier_with_webhook) do
        notifier_instance = described_class.new
        allow(notifier_instance).to receive(:config).and_return(
          { webhooks: ["https://example.com/webhook"] }
        )
        notifier_instance
      end

      it "sends webhook when configured" do
        stub_request(:post, "https://example.com/webhook")
          .to_return(status: 200)

        health_action = create(:ip_health_action, ip_address: ip_address)
        notifier_with_webhook.notify_ip_paused(ip_address, destination_domain, "test", health_action)

        expect(WebMock).to have_requested(:post, "https://example.com/webhook")
          .with(headers: { "Content-Type" => "application/json" })
      end

      it "handles webhook failures gracefully" do
        stub_request(:post, "https://example.com/webhook")
          .to_return(status: 500)

        health_action = create(:ip_health_action, ip_address: ip_address)

        expect do
          notifier_with_webhook.notify_ip_paused(ip_address, destination_domain, "test", health_action)
        end.not_to raise_error
      end
    end

    describe "slack" do
      let(:notifier_with_slack) do
        notifier_instance = described_class.new
        allow(notifier_instance).to receive(:config).and_return(
          { slack_webhook_url: "https://hooks.slack.com/services/TEST" }
        )
        notifier_instance
      end

      it "sends slack notification when configured" do
        stub_request(:post, "https://hooks.slack.com/services/TEST")
          .to_return(status: 200)

        health_action = create(:ip_health_action, ip_address: ip_address)
        notifier_with_slack.notify_ip_paused(ip_address, destination_domain, "test", health_action)

        expect(WebMock).to have_requested(:post, "https://hooks.slack.com/services/TEST")
          .with(headers: { "Content-Type" => "application/json" })
      end

      it "formats slack messages with appropriate colors" do
        stub_request(:post, "https://hooks.slack.com/services/TEST")
          .to_return(status: 200)

        health_action = create(:ip_health_action, ip_address: ip_address)
        notifier_with_slack.notify_ip_paused(ip_address, destination_domain, "test", health_action)

        expect(WebMock).to have_requested(:post, "https://hooks.slack.com/services/TEST")
          .with { |req| JSON.parse(req.body)["attachments"].first["color"] == "danger" }
      end
    end
  end

  describe "configuration checks" do
    it "returns false for webhooks_configured? when config is empty" do
      notifier_instance = described_class.new
      allow(notifier_instance).to receive(:config).and_return({})
      expect(notifier_instance.send(:webhooks_configured?)).to be false
    end

    it "returns false for email_configured? when config is empty" do
      notifier_instance = described_class.new
      allow(notifier_instance).to receive(:config).and_return({})
      expect(notifier_instance.send(:email_configured?)).to be false
    end

    it "returns false for slack_configured? when config is empty" do
      notifier_instance = described_class.new
      allow(notifier_instance).to receive(:config).and_return({})
      expect(notifier_instance.send(:slack_configured?)).to be false
    end
  end
end
