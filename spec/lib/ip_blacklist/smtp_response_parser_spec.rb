# frozen_string_literal: true

require "rails_helper"
require_relative "../../../app/lib/ip_blacklist/smtp_response_parser"

RSpec.describe IPBlacklist::SMTPResponseParser do
  describe ".parse" do
    context "with empty or nil message" do
      it "returns default result for nil message" do
        result = described_class.parse(nil, "550")
        expect(result[:blacklist_detected]).to be false
        expect(result[:bounce_type]).to eq("hard")
        expect(result[:severity]).to eq("low")
      end

      it "returns default result for empty message" do
        result = described_class.parse("", "421")
        expect(result[:blacklist_detected]).to be false
        expect(result[:bounce_type]).to eq("soft")
      end
    end

    context "bounce type detection" do
      it "detects soft bounce from 421 code" do
        result = described_class.parse("Generic error", "421")
        expect(result[:bounce_type]).to eq("soft")
      end

      it "detects soft bounce from 450 code" do
        result = described_class.parse("Generic error", "450")
        expect(result[:bounce_type]).to eq("soft")
      end

      it "detects hard bounce from 550 code" do
        result = described_class.parse("Generic error", "550")
        expect(result[:bounce_type]).to eq("hard")
      end

      it "detects hard bounce from 554 code" do
        result = described_class.parse("Generic error", "554")
        expect(result[:bounce_type]).to eq("hard")
      end
    end

    context "SMTP code categorization" do
      it "categorizes 2xx as success" do
        result = described_class.parse("OK", "250")
        expect(result[:smtp_code_category]).to eq("success")
      end

      it "categorizes 4xx as temporary_failure" do
        result = described_class.parse("Temp error", "421")
        expect(result[:smtp_code_category]).to eq("temporary_failure")
      end

      it "categorizes 5xx as permanent_failure" do
        result = described_class.parse("Permanent error", "550")
        expect(result[:smtp_code_category]).to eq("permanent_failure")
      end
    end

    context "Gmail patterns" do
      it "detects Gmail rate limiting" do
        message = "421-4.7.0 [192.0.2.1] Our system has detected that this message is suspicious due to rate limit exceeded. Try again later."
        result = described_class.parse(message, "421")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("gmail_rate_limit")
        expect(result[:severity]).to eq("medium")
        expect(result[:bounce_type]).to eq("soft")
        expect(result[:suggested_action]).to eq("monitor_closely")
      end

      it "detects Gmail temporary block" do
        message = "421-4.7.0 Try again later, closing connection."
        result = described_class.parse(message, "421")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("gmail_temporary_block")
        expect(result[:severity]).to eq("high")
        expect(result[:suggested_action]).to eq("track_soft_bounces")
      end

      it "detects Gmail suspicious activity block" do
        message = "550-5.7.1 Our system has detected an unusual rate of suspicious emails originating from your IP address."
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("gmail_suspicious_activity")
        expect(result[:severity]).to eq("high")
        expect(result[:bounce_type]).to eq("hard")
        expect(result[:suggested_action]).to eq("pause_immediately")
      end

      it "detects Gmail policy block" do
        message = "550-5.7.1 The email account that you tried to reach is blocked due to policy that prohibits."
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("gmail_policy_block")
        expect(result[:severity]).to eq("high")
      end

      it "detects Gmail authentication failure" do
        message = "550-5.7.26 This message does not pass authentication checks (SPF and DKIM both do not pass)."
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("gmail_authentication_failure")
        expect(result[:severity]).to eq("medium")
      end
    end

    context "Outlook/Hotmail patterns" do
      it "detects Outlook IP blocking" do
        message = "550 5.7.1 Service unavailable; Client host [192.0.2.1] rejected due to poor reputation."
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("outlook_ip_blocked")
        expect(result[:severity]).to eq("high")
        expect(result[:bounce_type]).to eq("hard")
        expect(result[:suggested_action]).to eq("pause_immediately")
      end

      it "detects Outlook reputation block" do
        message = "550 5.7.1 Message blocked due to IP reputation issues."
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("outlook_reputation_block")
        expect(result[:severity]).to eq("high")
      end

      it "detects Outlook DNSBL block" do
        message = "550 SC-001 (BAY004) Unfortunately, messages from [192.0.2.1] weren't sent. " \
                  "Please contact your Internet service provider since part of their network is on our block list (S3140). DNSBL issue."
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("outlook_dnsbl_block")
        expect(result[:severity]).to eq("high")
      end

      it "detects Outlook temporary deferral" do
        message = "421 4.3.2 Service not available, temporarily deferred."
        result = described_class.parse(message, "421")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("outlook_temporary_defer")
        expect(result[:severity]).to eq("medium")
        expect(result[:bounce_type]).to eq("soft")
      end

      it "detects Outlook/Exchange 'blocked using Spamhaus' format (without explicit DNSBL domain)" do
        message = "550 5.7.1 Service unavailable, Client host [51.38.27.245] blocked using Spamhaus. " \
                  "To request removal from this list see https://www.spamhaus.org/query/ip/51.38.27.245 (AS3130). " \
                  "[Name=Protocol Filter Agent][AGT=PFA][MxId=11BD0A29A5D92F32] [DB1PEPF0005"
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("outlook_blocked_using_dnsbl")
        expect(result[:severity]).to eq("high")
        expect(result[:bounce_type]).to eq("hard")
        expect(result[:suggested_action]).to eq("pause_immediately")
      end

      it "detects Outlook/Exchange 'blocked using Barracuda' format" do
        message = "550 5.7.1 Service unavailable, Client host [1.2.3.4] blocked using Barracuda. " \
                  "To request removal see https://www.barracudacentral.org/"
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("outlook_blocked_using_dnsbl")
        expect(result[:severity]).to eq("high")
        expect(result[:bounce_type]).to eq("hard")
      end
    end

    context "Yahoo patterns" do
      it "detects Yahoo throttling" do
        message = "421 4.7.0 [TS03] Messages from 192.0.2.1 temporarily deferred due to user complaints."
        result = described_class.parse(message, "421")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("yahoo_throttle")
        expect(result[:severity]).to eq("medium")
        expect(result[:bounce_type]).to eq("soft")
      end

      it "detects Yahoo policy block" do
        message = "554 5.7.9 Message not accepted for policy reasons. See http://help.yahoo.com/l/us/yahoo/mail/postmaster/errors/postmaster-28.html"
        result = described_class.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("yahoo_policy_block")
        expect(result[:severity]).to eq("high")
        expect(result[:bounce_type]).to eq("hard")
      end

      it "detects Yahoo spam block" do
        message = "553 Mail from 192.0.2.1 rejected due to spam content blocked."
        result = described_class.parse(message, "553")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("yahoo_spam_block")
        expect(result[:severity]).to eq("high")
      end
    end

    context "iCloud/Apple patterns" do
      it "detects iCloud policy rejection with HM code" do
        message = "554 5.7.1 [HM08] Message rejected due to local policy. Please visit https://support.apple.com/en-us/HT204137"
        result = described_class.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("icloud_policy_rejection")
        expect(result[:severity]).to eq("high")
        expect(result[:bounce_type]).to eq("hard")
        expect(result[:suggested_action]).to eq("pause_immediately")
      end

      it "detects iCloud policy rejection with support URL" do
        message = "554 5.7.1 Message rejected. See support.apple.com/en-us/HT204137 for more information."
        result = described_class.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("icloud_policy_rejection")
        expect(result[:severity]).to eq("high")
      end

      it "detects iCloud temporary block" do
        message = "421 4.7.0 [HM15] Message temporarily deferred. Try again later."
        result = described_class.parse(message, "421")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("icloud_temporary_block")
        expect(result[:severity]).to eq("medium")
        expect(result[:bounce_type]).to eq("soft")
        expect(result[:suggested_action]).to eq("monitor_closely")
      end
    end

    context "Proofpoint patterns" do
      it "detects Proofpoint DNSBL block" do
        message = "554 5.7.0 Blocked - see https://support.proofpoint.com/dnsbl-lookup.cgi?ip=5.196.61.193"
        result = described_class.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("proofpoint_dnsbl_block")
        expect(result[:severity]).to eq("high")
        expect(result[:bounce_type]).to eq("hard")
        expect(result[:suggested_action]).to eq("pause_immediately")
      end

      it "detects Proofpoint reputation block" do
        message = "554 5.7.1 Service unavailable; Host is blocked by Proofpoint"
        result = described_class.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("proofpoint_reputation_block")
        expect(result[:severity]).to eq("high")
      end

      it "detects Proofpoint temporary block" do
        message = "421 4.7.1 Service temporarily unavailable - contact Proofpoint for assistance"
        result = described_class.parse(message, "421")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("proofpoint_temporary_block")
        expect(result[:severity]).to eq("medium")
        expect(result[:bounce_type]).to eq("soft")
        expect(result[:suggested_action]).to eq("monitor_closely")
      end
    end

    context "Generic DNSBL patterns" do
      it "detects Spamhaus ZEN listing" do
        message = "554 Service unavailable; Client host [192.0.2.1] blocked using zen.spamhaus.org"
        result = described_class.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("spamhaus_zen")
        expect(result[:severity]).to eq("high")
        expect(result[:description]).to include("Spamhaus Zen")
      end

      it "detects Spamhaus SBL listing" do
        message = "550 Rejected - 192.0.2.1 is listed in sbl.spamhaus.org"
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("spamhaus_sbl")
      end

      it "detects SpamCop listing" do
        message = "550 5.7.1 IP blocked by bl.spamcop.net"
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("spamcop")
      end

      it "detects Barracuda listing" do
        message = "554 Your access to this mail system has been rejected due to the sending MTA's poor reputation. If you believe that this failure is in error, please contact b.barracudacentral.org"
        result = described_class.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("barracuda")
      end

      it "detects SORBS listing" do
        message = "550 Mail from 192.0.2.1 rejected by dnsbl.sorbs.net"
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("sorbs")
      end

      it "detects PSBL listing" do
        message = "554 Service unavailable; Sender address [192.0.2.1] blocked using psbl.surriel.com"
        result = described_class.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("psbl")
      end

      it "detects generic DNSBL reference" do
        message = "550 5.7.1 Message rejected due to DNSBL listing"
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("generic_dnsbl")
      end

      it "detects generic blacklist reference" do
        message = "550 IP address is blacklisted"
        result = described_class.parse(message, "550")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("generic_blacklist")
      end

      it "detects generic RBL reference" do
        message = "554 Rejected due to RBL listing"
        result = described_class.parse(message, "554")

        expect(result[:blacklist_detected]).to be true
        expect(result[:blacklist_source]).to eq("generic_rbl")
      end
    end

    context "suggested actions" do
      it "suggests pause_immediately for high severity hard bounce" do
        message = "550 5.7.1 IP blacklisted"
        result = described_class.parse(message, "550")
        # This will match generic_blacklist pattern
        expect(result[:suggested_action]).to eq("pause_immediately")
      end

      it "suggests track_soft_bounces for high severity soft bounce" do
        message = "421-4.7.0 Try again later, closing connection."
        result = described_class.parse(message, "421")
        expect(result[:suggested_action]).to eq("track_soft_bounces")
      end

      it "suggests monitor for non-blacklist errors" do
        message = "550 Mailbox full"
        result = described_class.parse(message, "550")
        expect(result[:blacklist_detected]).to be false
        expect(result[:suggested_action]).to eq("monitor")
      end
    end

    context "preserves raw message" do
      it "includes raw message in result" do
        message = "550 Test error message"
        result = described_class.parse(message, "550")
        expect(result[:raw_message]).to eq(message)
      end
    end

    context "pattern priority" do
      it "prioritizes provider-specific patterns over generic" do
        # This message could match both Gmail pattern and generic blacklist pattern
        # Gmail pattern should win
        message = "550-5.7.1 Our system has detected that this email blocked due to policy"
        result = described_class.parse(message, "550")

        expect(result[:blacklist_source]).to eq("gmail_policy_block")
      end
    end
  end

  describe "private methods" do
    describe ".determine_bounce_type" do
      it "correctly determines soft bounce codes" do
        %w[421 450 451 452].each do |code|
          expect(described_class.send(:determine_bounce_type, code)).to eq("soft")
        end
      end

      it "correctly determines hard bounce codes" do
        %w[550 551 552 553 554].each do |code|
          expect(described_class.send(:determine_bounce_type, code)).to eq("hard")
        end
      end

      it "defaults to hard for 5xx codes not in list" do
        expect(described_class.send(:determine_bounce_type, "555")).to eq("hard")
      end

      it "defaults to soft for 4xx codes not in list" do
        expect(described_class.send(:determine_bounce_type, "455")).to eq("soft")
      end
    end

    describe ".categorize_smtp_code" do
      it "categorizes codes correctly" do
        expect(described_class.send(:categorize_smtp_code, "250")).to eq("success")
        expect(described_class.send(:categorize_smtp_code, "421")).to eq("temporary_failure")
        expect(described_class.send(:categorize_smtp_code, "550")).to eq("permanent_failure")
        expect(described_class.send(:categorize_smtp_code, "999")).to eq("unknown")
      end
    end
  end
end
