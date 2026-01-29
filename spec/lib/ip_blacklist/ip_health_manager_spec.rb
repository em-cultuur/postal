# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPBlacklist::IPHealthManager do
  let(:ip_address) { create(:ip_address, priority: 100) }
  let(:destination_domain) { "gmail.com" }

  describe ".handle_blacklist_detected" do
    let(:blacklist_record) do
      create(:ip_blacklist_record,
             ip_address: ip_address,
             destination_domain: destination_domain,
             blacklist_source: "spamhaus_zen",
             status: "active")
    end

    context "when IP is newly blacklisted" do
      it "creates an IP domain exclusion" do
        expect { described_class.handle_blacklist_detected(blacklist_record) }
          .to change(IPDomainExclusion, :count).by(1)
      end

      it "creates exclusion with warmup stage 0 (paused)" do
        described_class.handle_blacklist_detected(blacklist_record)
        exclusion = IPDomainExclusion.last
        expect(exclusion.warmup_stage).to eq(0)
        expect(exclusion.current_priority).to eq(0)
      end

      it "logs a pause action" do
        expect { described_class.handle_blacklist_detected(blacklist_record) }
          .to change(IPHealthAction, :count).by(1)

        action = IPHealthAction.last
        expect(action.action_type).to eq(IPHealthAction::PAUSE)
        expect(action.ip_address_id).to eq(ip_address.id)
        expect(action.destination_domain).to eq(destination_domain)
      end
    end

    context "when exclusion already exists" do
      let!(:existing_exclusion) do
        create(:ip_domain_exclusion,
               ip_address: ip_address,
               destination_domain: destination_domain,
               warmup_stage: 1)
      end

      it "does not create duplicate exclusion" do
        expect { described_class.handle_blacklist_detected(blacklist_record) }
          .not_to change(IPDomainExclusion, :count)
      end

      it "resets warmup stage to 0" do
        described_class.handle_blacklist_detected(blacklist_record)
        expect(existing_exclusion.reload.warmup_stage).to eq(0)
      end

      it "still logs an action" do
        expect { described_class.handle_blacklist_detected(blacklist_record) }
          .to change(IPHealthAction, :count).by(1)
      end
    end

    context "when healthy IPs are available for rotation" do
      let!(:healthy_ip) do
        create(:ip_address, ipv4: "192.0.2.101", priority: 100, ip_pool: ip_address.ip_pool)
      end

      it "does not raise error" do
        expect { described_class.handle_blacklist_detected(blacklist_record) }.not_to raise_error
      end
    end

    context "when no healthy IPs are available" do
      before do
        # Create another IP in the same pool but also blacklist it
        other_ip = create(:ip_address, ipv4: "192.0.2.101", ip_pool: ip_address.ip_pool)
        create(:ip_blacklist_record,
               ip_address: other_ip,
               destination_domain: destination_domain,
               status: "active")
      end

      it "does not raise error" do
        expect { described_class.handle_blacklist_detected(blacklist_record) }.not_to raise_error
      end
    end
  end

  describe ".start_warmup" do
    let!(:exclusion) do
      create(:ip_domain_exclusion,
             ip_address: ip_address,
             destination_domain: destination_domain,
             warmup_stage: 0)
    end

    it "advances exclusion to warmup stage 1" do
      described_class.start_warmup(ip_address, destination_domain)
      expect(exclusion.reload.warmup_stage).to eq(1)
    end

    it "sets priority to 20 for stage 1" do
      described_class.start_warmup(ip_address, destination_domain)
      expect(exclusion.reload.current_priority).to eq(20)
    end

    it "sets next_warmup_at to 2 days from now" do
      described_class.start_warmup(ip_address, destination_domain)
      expect(exclusion.reload.next_warmup_at).to be_within(1.second).of(2.days.from_now)
    end

    it "creates a warmup stage advance action" do
      expect { described_class.start_warmup(ip_address, destination_domain) }
        .to change(IPHealthAction, :count).by(1)

      action = IPHealthAction.last
      expect(action.action_type).to eq(IPHealthAction::WARMUP_STAGE_ADVANCE)
    end

    context "when exclusion does not exist" do
      let(:non_existent_domain) { "yahoo.com" }

      it "does not raise error" do
        expect { described_class.start_warmup(ip_address, non_existent_domain) }
          .not_to raise_error
      end
    end
  end

  describe ".unpause_for_domain" do
    let(:user) { "admin@example.com" }
    let!(:exclusion) do
      create(:ip_domain_exclusion,
             ip_address: ip_address,
             destination_domain: destination_domain,
             warmup_stage: 0)
    end

    it "destroys the exclusion" do
      expect { described_class.unpause_for_domain(ip_address, destination_domain, user: user) }
        .to change(IPDomainExclusion, :count).by(-1)
    end

    it "creates a manual unpause action" do
      expect { described_class.unpause_for_domain(ip_address, destination_domain, user: user) }
        .to change(IPHealthAction, :count).by(1)

      action = IPHealthAction.last
      expect(action.action_type).to eq(IPHealthAction::UNPAUSE)
    end

    context "when exclusion does not exist" do
      let(:non_existent_domain) { "yahoo.com" }

      it "does not raise error" do
        expect { described_class.unpause_for_domain(ip_address, non_existent_domain, user: user) }
          .not_to raise_error
      end
    end
  end

  describe ".pause_for_domain" do
    let(:user) { "admin@example.com" }
    let(:reason) { "ISP feedback loop complaint" }

    context "when no exclusion exists" do
      it "creates a new paused exclusion" do
        expect { described_class.pause_for_domain(ip_address, destination_domain, reason: reason, user: user) }
          .to change(IPDomainExclusion, :count).by(1)

        exclusion = IPDomainExclusion.last
        expect(exclusion.warmup_stage).to eq(0)
        expect(exclusion.reason).to eq(reason)
      end

      it "creates a manual pause action" do
        expect { described_class.pause_for_domain(ip_address, destination_domain, reason: reason, user: user) }
          .to change(IPHealthAction, :count).by(1)

        action = IPHealthAction.last
        expect(action.action_type).to eq(IPHealthAction::PAUSE)
      end
    end

    context "when exclusion already exists" do
      let!(:existing_exclusion) do
        create(:ip_domain_exclusion,
               ip_address: ip_address,
               destination_domain: destination_domain,
               warmup_stage: 2,
               reason: "Original reason")
      end

      it "does not create duplicate exclusion" do
        expect { described_class.pause_for_domain(ip_address, destination_domain, reason: reason, user: user) }
          .not_to change(IPDomainExclusion, :count)
      end

      it "resets exclusion to stage 0" do
        described_class.pause_for_domain(ip_address, destination_domain, reason: reason, user: user)
        expect(existing_exclusion.reload.warmup_stage).to eq(0)
      end

      it "updates the reason" do
        described_class.pause_for_domain(ip_address, destination_domain, reason: reason, user: user)
        expect(existing_exclusion.reload.reason).to eq(reason)
      end

      it "creates a manual pause action" do
        expect { described_class.pause_for_domain(ip_address, destination_domain, reason: reason, user: user) }
          .to change(IPHealthAction, :count).by(1)
      end
    end
  end

  describe "integration scenarios" do
    context "full blacklist to warmup flow" do
      let(:blacklist_record) do
        create(:ip_blacklist_record,
               ip_address: ip_address,
               destination_domain: destination_domain,
               status: "active")
      end

      it "handles complete flow from detection to warmup start" do
        # Step 1: Handle blacklist detection (creates paused exclusion)
        described_class.handle_blacklist_detected(blacklist_record)
        exclusion = IPDomainExclusion.find_by(ip_address: ip_address, destination_domain: destination_domain)
        expect(exclusion.warmup_stage).to eq(0)

        # Step 2: Mark blacklist as resolved
        blacklist_record.mark_resolved!
        expect(blacklist_record.status).to eq("resolved")

        # Step 3: Warmup should have been started automatically (via callback)
        expect(exclusion.reload.warmup_stage).to eq(1)
        expect(exclusion.current_priority).to eq(20)

        # Verify actions were logged
        expect(IPHealthAction.count).to be >= 2 # pause + warmup_stage_advance
        expect(IPHealthAction.pluck(:action_type)).to include(
          IPHealthAction::PAUSE,
          IPHealthAction::WARMUP_STAGE_ADVANCE
        )
      end
    end

    context "manual override during automated warmup" do
      let!(:exclusion) do
        create(:ip_domain_exclusion,
               ip_address: ip_address,
               destination_domain: destination_domain,
               warmup_stage: 2)
      end

      it "allows admin to manually unpause during warmup" do
        described_class.unpause_for_domain(ip_address, destination_domain, user: "admin@example.com")

        # Exclusion should be destroyed
        expect(IPDomainExclusion.exists?(exclusion.id)).to be false

        # Manual unpause action should be logged
        action = IPHealthAction.last
        expect(action.action_type).to eq(IPHealthAction::UNPAUSE)
      end

      it "allows admin to manually re-pause" do
        described_class.pause_for_domain(ip_address, destination_domain,
                                         reason: "Manual intervention needed",
                                         user: "admin@example.com")

        # Exclusion should be reset to stage 0
        expect(exclusion.reload.warmup_stage).to eq(0)
        expect(exclusion.reason).to eq("Manual intervention needed")

        # Manual pause action should be logged
        action = IPHealthAction.last
        expect(action.action_type).to eq(IPHealthAction::PAUSE)
      end
    end
  end
end
