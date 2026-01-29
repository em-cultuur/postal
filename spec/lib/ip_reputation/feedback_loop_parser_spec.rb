# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPReputation::FeedbackLoopParser do
  let(:ip_address) { create(:ip_address, ipv4: "192.0.2.1") }

  let(:arf_email) do
    <<~EMAIL
      From: fbl@aol.com
      To: abuse@example.com
      Subject: FW: Complaint about message
      Content-Type: multipart/report; report-type=feedback-report; boundary="boundary"
      MIME-Version: 1.0

      --boundary
      Content-Type: text/plain

      This is an email abuse report for an email message received from IP 192.0.2.1

      --boundary
      Content-Type: message/feedback-report

      Feedback-Type: abuse
      User-Agent: AOL SComp
      Version: 1
      Original-Mail-From: sender@example.com
      Original-Rcpt-To: user@aol.com
      Arrival-Date: Mon, 15 Jan 2024 10:00:00 -0500
      Reported-Domain: example.com
      Source-IP: 192.0.2.1
      Authentication-Results: dkim=pass

      --boundary
      Content-Type: message/rfc822

      From: sender@example.com
      To: user@aol.com
      Subject: Test Message
      Message-ID: <test123@example.com>
      Date: Mon, 15 Jan 2024 09:00:00 -0500

      This is the original message body.
      --boundary--
    EMAIL
  end

  let(:parser) { described_class.new(arf_email) }

  describe "#initialize" do
    it "parses the email" do
      expect(parser.mail).to be_a(Mail::Message)
    end

    it "extracts feedback report" do
      expect(parser.feedback_report).to be_a(Hash)
      expect(parser.feedback_report[:feedback_type]).to eq("abuse")
    end

    it "extracts original message" do
      expect(parser.original_message).to be_a(Mail::Message)
      expect(parser.original_message.message_id).to eq("test123@example.com")
    end
  end

  describe "#valid_arf?" do
    it "returns true for valid ARF email" do
      expect(parser.valid_arf?).to be true
    end

    context "when email is not multipart" do
      let(:simple_email) do
        <<~EMAIL
          From: sender@example.com
          To: receiver@example.com
          Subject: Not an ARF

          Simple email body
        EMAIL
      end
      let(:parser) { described_class.new(simple_email) }

      it "returns false" do
        expect(parser.valid_arf?).to be false
      end
    end

    context "when email does not contain feedback-report" do
      let(:multipart_email) do
        <<~EMAIL
          From: sender@example.com
          To: receiver@example.com
          Content-Type: multipart/mixed; boundary="boundary"

          --boundary
          Content-Type: text/plain

          First part
          --boundary
          Content-Type: text/html

          Second part
          --boundary--
        EMAIL
      end
      let(:parser) { described_class.new(multipart_email) }

      it "returns false" do
        expect(parser.valid_arf?).to be false
      end
    end
  end

  describe "#process_complaint" do
    # Ensure IP address is created before running tests
    before { ip_address }

    it "stores complaint metric" do
      expect do
        parser.process_complaint
      end.to change(IPReputationMetric, :count).by(1)

      metric = IPReputationMetric.last
      expect(metric.ip_address).to eq(ip_address)
      expect(metric.metric_type).to eq(IPReputationMetric::METRIC_TYPE_FEEDBACK_LOOP)
      expect(metric.destination_domain).to eq("aol.com")
    end

    it "returns complaint data" do
      data = parser.process_complaint

      expect(data).to be_a(Hash)
      expect(data[:feedback_type]).to eq("abuse")
      expect(data[:source_ip]).to eq("192.0.2.1")
      expect(data[:original_mail_from]).to eq("sender@example.com")
      expect(data[:original_rcpt_to]).to eq("user@aol.com")
    end

    it "includes metadata from feedback report" do
      data = parser.process_complaint

      expect(data[:user_agent]).to eq("AOL SComp")
      expect(data[:reported_domain]).to eq("example.com")
      expect(data[:authentication_results]).to eq("dkim=pass")
    end

    it "includes original message details" do
      data = parser.process_complaint

      expect(data[:original_message_id]).to eq("test123@example.com")
    end

    context "when not a valid ARF email" do
      let(:simple_email) do
        <<~EMAIL
          From: sender@example.com
          To: receiver@example.com

          Simple email
        EMAIL
      end
      let(:parser) { described_class.new(simple_email) }

      it "returns nil" do
        expect(parser.process_complaint).to be_nil
      end

      it "does not create metrics" do
        expect do
          parser.process_complaint
        end.not_to change(IPReputationMetric, :count)
      end
    end

    context "when IP address is not found" do
      let(:arf_email_unknown_ip) do
        <<~EMAIL
          From: fbl@aol.com
          Content-Type: multipart/report; report-type=feedback-report; boundary="boundary"

          --boundary
          Content-Type: message/feedback-report

          Feedback-Type: abuse
          Source-IP: 203.0.113.1

          --boundary
          Content-Type: message/rfc822

          From: sender@unknown.com
          To: user@aol.com

          Test
          --boundary--
        EMAIL
      end
      let(:parser) { described_class.new(arf_email_unknown_ip) }

      it "returns nil" do
        expect(parser.process_complaint).to be_nil
      end

      it "logs warning" do
        allow(Rails.logger).to receive(:warn)

        parser.process_complaint

        expect(Rails.logger).to have_received(:warn).with(/Could not find IP address/)
      end
    end
  end

  describe "complaint threshold checking" do
    before do
      # Ensure IP exists before creating metrics
      ip_address

      # Create existing complaints using different period values to avoid unique constraint
      # We can use multiple period values per day: hourly, daily, weekly, monthly
      periods = [IPReputationMetric::HOURLY, IPReputationMetric::DAILY, IPReputationMetric::WEEKLY, IPReputationMetric::MONTHLY]
      4.times do |i|
        create(:ip_reputation_metric,
               ip_address: ip_address,
               destination_domain: "aol.com",
               period: periods[i % 4],
               period_date: ((i / 4) + 1).days.ago.to_date,
               metric_type: IPReputationMetric::METRIC_TYPE_FEEDBACK_LOOP,
               created_at: ((i / 4) + 1).days.ago)
      end
    end

    context "when complaint count reaches warning threshold (5+)" do
      it "creates a monitor action" do
        expect do
          parser.process_complaint
        end.to change(IPHealthAction, :count).by(1)

        action = IPHealthAction.last
        expect(action.action_type).to eq(IPHealthAction::MONITOR)
        expect(action.reason).to match(/Elevated feedback loop complaints/)
      end

      it "logs warning" do
        allow(Rails.logger).to receive(:warn)

        parser.process_complaint

        expect(Rails.logger).to have_received(:warn).with(/Elevated complaint count/)
      end
    end

    context "when complaint count reaches pause threshold (10+)" do
      before do
        # Ensure IP exists
        ip_address

        # Add 5 more complaints using different period values to reach 10 total (4 + 5 + 1 new)
        periods = [IPReputationMetric::HOURLY, IPReputationMetric::DAILY, IPReputationMetric::WEEKLY, IPReputationMetric::MONTHLY]
        5.times do |i|
          create(:ip_reputation_metric,
                 ip_address: ip_address,
                 destination_domain: "aol.com",
                 period: periods[i % 4],
                 period_date: ((i / 4) + 2).days.ago.to_date,
                 metric_type: IPReputationMetric::METRIC_TYPE_FEEDBACK_LOOP,
                 created_at: ((i / 4) + 2).days.ago)
        end
      end

      it "pauses IP for domain" do
        expect(IPBlacklist::IPHealthManager).to receive(:pause_for_domain)
          .with(ip_address, "aol.com", hash_including(reason: /High feedback loop complaint count/))

        parser.process_complaint
      end

      it "logs high complaint warning" do
        allow(Rails.logger).to receive(:warn)
        allow(IPBlacklist::IPHealthManager).to receive(:pause_for_domain)

        parser.process_complaint

        expect(Rails.logger).to have_received(:warn).with(/High complaint count/)
      end

      it "creates IP domain exclusion" do
        allow(IPBlacklist::IPHealthManager).to receive(:pause_for_domain).and_call_original

        expect do
          parser.process_complaint
        end.to change(IPDomainExclusion, :count).by(1)

        exclusion = IPDomainExclusion.last
        expect(exclusion.ip_address).to eq(ip_address)
        expect(exclusion.destination_domain).to eq("aol.com")
        expect(exclusion.warmup_stage).to eq(0) # Paused
      end
    end

    context "when complaint count is below thresholds" do
      before do
        # Clear existing complaints so we only have 1 total
        IPReputationMetric.where(metric_type: "feedback_loop_complaint").delete_all
      end

      it "does not create actions" do
        expect do
          parser.process_complaint
        end.not_to change(IPHealthAction, :count)
      end

      it "does not pause IP" do
        expect(IPBlacklist::IPHealthManager).not_to receive(:pause_for_domain)

        parser.process_complaint
      end
    end
  end

  describe "IP address extraction" do
    # Ensure IP address is created before running tests
    before { ip_address }

    context "when IP is found from source_ip field" do
      it "finds the IP address" do
        data = parser.process_complaint

        expect(data).not_to be_nil
        metric = IPReputationMetric.last
        expect(metric.ip_address).to eq(ip_address)
      end
    end

    context "when IP is found from Received headers" do
      let(:arf_email_with_received) do
        <<~EMAIL
          From: fbl@yahoo.com
          Content-Type: multipart/report; report-type=feedback-report; boundary="boundary"

          --boundary
          Content-Type: message/feedback-report

          Feedback-Type: abuse

          --boundary
          Content-Type: message/rfc822

          Received: from mail.example.com ([192.0.2.1]) by mx.yahoo.com
          From: sender@example.com
          To: user@yahoo.com

          Test
          --boundary--
        EMAIL
      end
      let(:parser) { described_class.new(arf_email_with_received) }

      it "extracts IP from Received header" do
        data = parser.process_complaint

        expect(data).not_to be_nil
        metric = IPReputationMetric.last
        expect(metric.ip_address).to eq(ip_address)
      end
    end
  end
end
