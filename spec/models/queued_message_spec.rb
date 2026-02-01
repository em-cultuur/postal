# frozen_string_literal: true

# == Schema Information
#
# Table name: queued_messages
#
#  id            :integer          not null, primary key
#  attempts      :integer          default(0)
#  batch_key     :string(255)
#  domain        :string(255)
#  locked_at     :datetime
#  locked_by     :string(255)
#  manual        :boolean          default(FALSE)
#  mx_domain     :string(255)
#  retry_after   :datetime
#  created_at    :datetime
#  updated_at    :datetime
#  ip_address_id :integer
#  message_id    :integer
#  route_id      :integer
#  server_id     :integer
#
# Indexes
#
#  index_queued_messages_on_batch_lock           (batch_key,ip_address_id,locked_by,locked_at)
#  index_queued_messages_on_domain               (domain)
#  index_queued_messages_on_lock_and_retry       (locked_by,locked_at,retry_after,ip_address_id)
#  index_queued_messages_on_message_id           (message_id)
#  index_queued_messages_on_mx_domain            (mx_domain)
#  index_queued_messages_on_server_domain_retry  (server_id,domain,retry_after)
#  index_queued_messages_on_server_id            (server_id)
#  index_queued_messages_on_server_mx_retry      (server_id,mx_domain,retry_after)
#
require "rails_helper"

RSpec.describe QueuedMessage do
  subject(:queued_message) { build(:queued_message) }

  describe "relationships" do
    it { is_expected.to belong_to(:server) }
    it { is_expected.to belong_to(:ip_address).optional }
  end

  describe ".ready_with_delayed_retry" do
    it "returns messages where retry after is null" do
      message = create(:queued_message, retry_after: nil)
      expect(described_class.ready_with_delayed_retry).to eq [message]
    end

    it "returns messages where retry after is less than 30 seconds from now" do
      Timecop.freeze do
        message1 = create(:queued_message, retry_after: 45.seconds.ago)
        message2 = create(:queued_message, retry_after: 5.minutes.ago)
        create(:queued_message, retry_after: Time.now)
        create(:queued_message, retry_after: 1.minute.from_now)
        expect(described_class.ready_with_delayed_retry.order(:id)).to eq [message1, message2]
      end
    end
  end

  describe ".with_stale_lock" do
    it "returns messages where lock time is less than the configured number of stale days" do
      allow(Postal::Config.postal).to receive(:queued_message_lock_stale_days).and_return(2)
      message1 = create(:queued_message, locked_at: 3.days.ago, locked_by: "test")
      message2 = create(:queued_message, locked_at: 2.days.ago, locked_by: "test")
      create(:queued_message, locked_at: 1.days.ago, locked_by: "test")
      create(:queued_message)
      expect(described_class.with_stale_lock.order(:id)).to eq [message1, message2]
    end
  end

  describe "#retry_now" do
    it "removes the retry time" do
      message = create(:queued_message, retry_after: 2.minutes.from_now)
      expect { message.retry_now }.to change { message.reload.retry_after }.from(kind_of(Time)).to(nil)
    end

    it "raises an error if invalid" do
      message = create(:queued_message, retry_after: 2.minutes.from_now)
      message.update_columns(server_id: nil) # unlikely to actually happen
      expect { message.retry_now }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "#send_bounce" do
    let(:server) { create(:server) }
    let(:message) { MessageFactory.incoming(server) }

    subject(:queued_message) { create(:queued_message, message: message) }

    context "when the message is eligiable for bounces" do
      it "queues a bounce message for sending" do
        expect(BounceMessage).to receive(:new).with(server, kind_of(Postal::MessageDB::Message)).and_wrap_original do |original, *args|
          bounce = original.call(*args)
          expect(bounce).to receive(:queue)
          bounce
        end
        queued_message.send_bounce
      end
    end

    context "when the message is not eligible for bounces" do
      it "returns nil" do
        message.update(bounce: true)
        expect(queued_message.send_bounce).to be nil
      end

      it "does not queue a bounce message for sending" do
        message.update(bounce: true)
        expect(BounceMessage).not_to receive(:new)
        queued_message.send_bounce
      end
    end
  end

  describe "#allocate_ip_address" do
    subject(:queued_message) { create(:queued_message) }

    context "when ip pools is disabled" do
      it "returns nil" do
        expect(queued_message.allocate_ip_address).to be nil
      end

      it "does not allocate an IP address" do
        expect { queued_message.allocate_ip_address }.not_to change(queued_message, :ip_address)
      end
    end

    context "when IP pools is enabled" do
      before do
        allow(Postal::Config.postal).to receive(:use_ip_pools?).and_return(true)
      end

      context "when there is no backend message" do
        it "returns nil" do
          expect(queued_message.allocate_ip_address).to be nil
        end

        it "does not allocate an IP address" do
          expect { queued_message.allocate_ip_address }.not_to change(queued_message, :ip_address)
        end
      end

      context "when no IP pool can be determined for the message" do
        let(:server) { create(:server) }
        let(:message) { MessageFactory.outgoing(server) }

        subject(:queued_message) { create(:queued_message, message: message) }

        it "returns nil" do
          expect(queued_message.allocate_ip_address).to be nil
        end

        it "does not allocate an IP address" do
          expect { queued_message.allocate_ip_address }.not_to change(queued_message, :ip_address)
        end
      end

      context "when an IP pool can be determined for the message" do
        let(:ip_pool) { create(:ip_pool, :with_ip_address) }
        let(:server) { create(:server, ip_pool: ip_pool) }
        let(:message) { MessageFactory.outgoing(server) }

        subject(:queued_message) { create(:queued_message, message: message) }

        it "returns an IP address" do
          expect(queued_message.allocate_ip_address).to be_a IPAddress
        end

        it "allocates an IP address to the queued message" do
          queued_message.update(ip_address: nil)
          expect { queued_message.allocate_ip_address }.to change(queued_message, :ip_address).from(nil).to(ip_pool.ip_addresses.first)
        end
      end

      context "when IP pool has multiple IPs with blacklist considerations" do
        let(:ip_pool) { create(:ip_pool) }
        let(:server) { create(:server, ip_pool: ip_pool) }
        let(:destination_domain) { "gmail.com" }
        let(:message) do
          MessageFactory.outgoing(server) do |msg|
            msg.rcpt_to = "user@#{destination_domain}"
          end
        end

        let!(:healthy_ip) { create(:ip_address, ip_pool: ip_pool, priority: 100) }
        let!(:blacklisted_ip) { create(:ip_address, ip_pool: ip_pool, priority: 100) }
        let!(:warming_ip) { create(:ip_address, ip_pool: ip_pool, priority: 100) }

        subject(:queued_message) { build(:queued_message, message: message, domain: destination_domain, server: server) }

        before do
          # Blacklist one IP for gmail.com
          blacklist_record = create(:ip_blacklist_record,
                                    ip_address: blacklisted_ip,
                                    destination_domain: destination_domain,
                                    status: "active")

          # Create exclusion for blacklisted IP (paused)
          create(:ip_domain_exclusion,
                 ip_address: blacklisted_ip,
                 destination_domain: destination_domain,
                 warmup_stage: 0,
                 reason: "Blacklisted")

          # Put another IP in warmup stage 1 (priority 20)
          create(:ip_domain_exclusion,
                 ip_address: warming_ip,
                 destination_domain: destination_domain,
                 warmup_stage: 1,
                 reason: "Warming up",
                 next_warmup_at: 1.day.from_now)
        end

        it "does not allocate blacklisted IPs" do
          # Test multiple times to ensure blacklisted IP is never selected
          100.times do
            qm = build(:queued_message, message: message, domain: destination_domain, server: server)
            qm.allocate_ip_address
            expect(qm.ip_address).not_to eq(blacklisted_ip) if qm.ip_address
          end
        end

        it "prefers healthy IPs over warming IPs" do
          # Due to weighted selection, healthy IP (priority 100) should be selected
          # much more often than warming IP (priority 20)
          selections = 100.times.map do
            qm = build(:queued_message, message: message, domain: destination_domain, server: server)
            qm.allocate_ip_address
            qm.ip_address
          end.compact

          healthy_count = selections.count(healthy_ip)
          warming_count = selections.count(warming_ip)

          # Healthy IP should be selected significantly more often
          # With priorities 100 vs 20, we expect roughly 5:1 ratio
          expect(healthy_count).to be > warming_count * 2
        end

        it "can still select warming IPs occasionally" do
          # Warming IPs should still be selected sometimes (not paused)
          selections = 50.times.map do
            qm = build(:queued_message, message: message, domain: destination_domain, server: server)
            qm.allocate_ip_address
            qm.ip_address
          end.compact

          expect(selections).to include(warming_ip)
        end
      end

      context "when all IPs in pool are blacklisted for destination domain" do
        let(:ip_pool) { create(:ip_pool) }
        let(:server) { create(:server, ip_pool: ip_pool) }
        let(:destination_domain) { "gmail.com" }
        let(:message) do
          MessageFactory.outgoing(server) do |msg|
            msg.rcpt_to = "user@#{destination_domain}"
          end
        end

        let!(:ip1) { create(:ip_address, ip_pool: ip_pool) }
        let!(:ip2) { create(:ip_address, ip_pool: ip_pool) }

        subject(:queued_message) { build(:queued_message, message: message, domain: destination_domain, server: server) }

        before do
          # Blacklist both IPs for this domain
          [ip1, ip2].each do |ip|
            create(:ip_blacklist_record,
                   ip_address: ip,
                   destination_domain: destination_domain,
                   status: "active")
            create(:ip_domain_exclusion,
                   ip_address: ip,
                   destination_domain: destination_domain,
                   warmup_stage: 0)
          end
        end

        it "returns nil when no healthy IPs are available" do
          queued_message.allocate_ip_address
          expect(queued_message.ip_address).to be_nil
        end
      end

      context "when IP is blacklisted for one domain but not another" do
        let(:ip_pool) { create(:ip_pool) }
        let(:server) { create(:server, ip_pool: ip_pool) }
        let(:message_gmail) do
          MessageFactory.outgoing(server) do |msg|
            msg.rcpt_to = "user@gmail.com"
          end
        end
        let(:message_yahoo) do
          MessageFactory.outgoing(server) do |msg|
            msg.rcpt_to = "user@yahoo.com"
          end
        end

        let!(:ip_address) { create(:ip_address, ip_pool: ip_pool, priority: 100) }

        before do
          # Blacklist IP for gmail.com only
          create(:ip_blacklist_record,
                 ip_address: ip_address,
                 destination_domain: "gmail.com",
                 status: "active")
          create(:ip_domain_exclusion,
                 ip_address: ip_address,
                 destination_domain: "gmail.com",
                 warmup_stage: 0)
        end

        it "does not allocate IP for blacklisted domain" do
          qm_gmail = build(:queued_message, message: message_gmail, domain: "gmail.com", server: server)
          qm_gmail.allocate_ip_address
          expect(qm_gmail.ip_address).to be_nil
        end

        it "allocates IP for non-blacklisted domain" do
          qm_yahoo = build(:queued_message, message: message_yahoo, domain: "yahoo.com", server: server)
          qm_yahoo.allocate_ip_address
          expect(qm_yahoo.ip_address).to eq(ip_address)
        end
      end
    end
  end

  describe "#reallocate_ip_address" do
    subject(:queued_message) { create(:queued_message) }

    context "when ip pools is disabled" do
      it "returns nil" do
        expect(queued_message.reallocate_ip_address).to be nil
      end

      it "does not change the IP address" do
        original_ip_id = queued_message.ip_address_id
        queued_message.reallocate_ip_address
        expect(queued_message.reload.ip_address_id).to eq original_ip_id
      end
    end

    context "when IP pools is enabled" do
      before do
        allow(Postal::Config.postal).to receive(:use_ip_pools?).and_return(true)
      end

      context "when there is no backend message" do
        it "returns nil" do
          expect(queued_message.reallocate_ip_address).to be nil
        end
      end

      context "when no IP pool can be determined for the message" do
        let(:server) { create(:server) }
        let(:message) { MessageFactory.outgoing(server) }

        subject(:queued_message) { create(:queued_message, message: message) }

        it "returns nil" do
          expect(queued_message.reallocate_ip_address).to be nil
        end
      end

      context "when an IP pool has multiple IP addresses" do
        let(:ip_pool) { create(:ip_pool) }
        let!(:ip_address1) { create(:ip_address, ip_pool: ip_pool, ipv4: "10.0.0.1", ipv6: "2001:db8::1") }
        let!(:ip_address2) { create(:ip_address, ip_pool: ip_pool, ipv4: "10.0.0.2", ipv6: "2001:db8::2") }
        let(:server) { create(:server, ip_pool: ip_pool) }
        let(:message) { MessageFactory.outgoing(server) }

        subject(:queued_message) do
          qm = create(:queued_message, message: message)
          qm.update_column(:ip_address_id, ip_address1.id)
          qm
        end

        it "allocates a different IP address" do
          queued_message.reallocate_ip_address
          expect(queued_message.reload.ip_address_id).to eq ip_address2.id
        end

        it "updates the ip_address_id in the database" do
          expect { queued_message.reallocate_ip_address }.to change { queued_message.reload.ip_address_id }.from(ip_address1.id).to(ip_address2.id)
        end
      end

      context "when an IP pool has only one IP address" do
        let(:ip_pool) { create(:ip_pool, :with_ip_address) }
        let(:server) { create(:server, ip_pool: ip_pool) }
        let(:message) { MessageFactory.outgoing(server) }

        subject(:queued_message) { create(:queued_message, message: message) }

        it "keeps the same IP address when there are no alternatives" do
          original_ip_id = queued_message.ip_address_id
          queued_message.reallocate_ip_address
          expect(queued_message.reload.ip_address_id).to eq original_ip_id
        end
      end
    end
  end

  describe "#batchable_messages" do
    context "when the message is not locked" do
      subject(:queued_message) { build(:queued_message) }

      it "raises an error" do
        expect { queued_message.batchable_messages }.to raise_error(Postal::Error, /must lock current message before locking any friends/i)
      end
    end

    context "when the message is locked" do
      let(:batch_key) { nil }
      subject(:queued_message) { build(:queued_message, :locked, batch_key: batch_key) }

      context "when there is no batch key on the queued message" do
        it "returns an empty array" do
          expect(queued_message.batch_key).to be nil
          expect(queued_message.batchable_messages).to eq []
        end
      end

      context "when there is a batch key" do
        let(:batch_key) { "1234" }

        it "finds and locks messages with the same batch key and IP address up to the limit specified" do
          other_message1 = create(:queued_message, batch_key: batch_key, ip_address: nil)
          other_message2 = create(:queued_message, batch_key: batch_key, ip_address: nil)
          create(:queued_message, batch_key: batch_key, ip_address: nil)

          messages = queued_message.batchable_messages(2)
          expect(messages).to eq [other_message1, other_message2]
          expect(messages).to all be_locked
        end

        it "does not find messages with a different batch key" do
          create(:queued_message, batch_key: "5678", ip_address: nil)
          expect(queued_message.batchable_messages).to eq []
        end

        it "does not find messages that are not queued for sending yet" do
          create(:queued_message, batch_key: batch_key, ip_address: nil, retry_after: 1.minute.from_now)
          expect(queued_message.batchable_messages).to eq []
        end

        it "does not find messages that are for a different IP address" do
          create(:queued_message, batch_key: batch_key, ip_address: create(:ip_address))
          expect(queued_message.batchable_messages).to eq []
        end
      end
    end
  end

  describe "#resolve_mx_domain!" do
    let(:server) { create(:server) }
    let(:message) do
      MessageFactory.outgoing(server) do |msg|
        msg.rcpt_to = "user@example.com"
      end
    end

    subject(:queued_message) { create(:queued_message, message: message, mx_domain: nil) }

    context "when mx_domain is already set" do
      before { queued_message.update_column(:mx_domain, "google.com") }

      it "returns existing mx_domain without resolving" do
        expect(MXDomainResolver).not_to receive(:resolve)
        expect(queued_message.resolve_mx_domain!).to eq("google.com")
      end
    end

    context "when mx_domain is not set" do
      it "resolves and caches MX domain" do
        allow(MXDomainResolver).to receive(:resolve).with("example.com").and_return("mail-provider.com")

        result = queued_message.resolve_mx_domain!

        expect(result).to eq("mail-provider.com")
        expect(queued_message.reload.mx_domain).to eq("mail-provider.com")
      end
    end

    context "when message has no recipient domain" do
      let(:message) do
        MessageFactory.outgoing(server) do |msg|
          msg.rcpt_to = nil
        end
      end

      it "returns nil" do
        expect(queued_message.resolve_mx_domain!).to be_nil
      end
    end
  end

  describe "#mx_rate_limited?" do
    let(:server) { create(:server) }
    let(:message) { MessageFactory.outgoing(server) }

    subject(:queued_message) { create(:queued_message, message: message, mx_domain: "google.com") }

    context "when mx_domain is not set" do
      before { queued_message.update_column(:mx_domain, nil) }

      it "returns false" do
        expect(queued_message.mx_rate_limited?).to be false
      end
    end

    context "when mx_domain is set" do
      it "checks MXRateLimit.rate_limited?" do
        expect(MXRateLimit).to receive(:rate_limited?).with(server, "google.com").and_return(true)
        expect(queued_message.mx_rate_limited?).to be true
      end
    end
  end

  describe "#mx_rate_limit" do
    let(:server) { create(:server) }
    let(:message) { MessageFactory.outgoing(server) }

    subject(:queued_message) { create(:queued_message, message: message, mx_domain: "google.com") }

    context "when mx_domain is not set" do
      before { queued_message.update_column(:mx_domain, nil) }

      it "returns nil" do
        expect(queued_message.mx_rate_limit).to be_nil
      end
    end

    context "when mx_domain is set" do
      let!(:rate_limit) { create(:mx_rate_limit, server: server, mx_domain: "google.com") }

      it "returns the MXRateLimit record" do
        expect(queued_message.mx_rate_limit).to eq(rate_limit)
      end
    end

    context "when no rate limit exists" do
      it "returns nil" do
        expect(queued_message.mx_rate_limit).to be_nil
      end
    end
  end
end
