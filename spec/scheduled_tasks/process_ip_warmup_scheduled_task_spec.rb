# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProcessIPWarmupScheduledTask do
  let(:logger) { TestLogger.new }
  subject(:task) { described_class.new(logger: logger) }

  describe "#call" do
    context "when no IPs are ready for warmup" do
      it "logs that no IPs are ready" do
        task.call
        expect(logger).to have_logged(/No IPs ready for warmup advancement/)
      end
    end

    context "when IPs are ready for warmup advancement" do
      let(:ip_address) { create(:ip_address, priority: 100) }
      let(:destination_domain) { "gmail.com" }

      let!(:exclusion_stage_1) do
        create(:ip_domain_exclusion,
               ip_address: ip_address,
               destination_domain: destination_domain,
               warmup_stage: 1,
               next_warmup_at: 1.hour.ago) # Ready to advance
      end

      it "advances the exclusion to the next stage" do
        expect { task.call }.to change { exclusion_stage_1.reload.warmup_stage }.from(1).to(2)
      end

      it "updates next_warmup_at for the next stage" do
        task.call
        expect(exclusion_stage_1.reload.next_warmup_at).to be_within(1.minute).of(3.days.from_now)
      end

      it "logs the advancement" do
        task.call
        expect(logger).to have_logged(/Found 1 IP\(s\) ready for warmup advancement/)
        expect(logger).to have_logged(/Advancing IP #{ip_address.ipv4}/)
        expect(logger).to have_logged(/advanced to stage 2/)
      end

      it "counts advanced IPs correctly" do
        task.call
        expect(logger).to have_logged(/Completed: 1 advanced, 0 errors/)
      end
    end

    context "when IP reaches final warmup stage (stage 5)" do
      let(:ip_address) { create(:ip_address, priority: 100) }
      let(:destination_domain) { "yahoo.com" }

      let!(:exclusion_stage_4) do
        create(:ip_domain_exclusion,
               ip_address: ip_address,
               destination_domain: destination_domain,
               warmup_stage: 4,
               next_warmup_at: 1.hour.ago)
      end

      it "destroys the exclusion" do
        task.call
        expect(IPDomainExclusion.exists?(exclusion_stage_4.id)).to be false
      end

      it "logs warmup completion" do
        task.call
        expect(logger).to have_logged(/completed warmup.*reached full priority/)
      end
    end

    context "when multiple IPs are ready for warmup" do
      let(:ip1) { create(:ip_address) }
      let(:ip2) { create(:ip_address) }

      let!(:exclusion1) do
        create(:ip_domain_exclusion,
               ip_address: ip1,
               destination_domain: "gmail.com",
               warmup_stage: 1,
               next_warmup_at: 1.hour.ago)
      end

      let!(:exclusion2) do
        create(:ip_domain_exclusion,
               ip_address: ip2,
               destination_domain: "yahoo.com",
               warmup_stage: 2,
               next_warmup_at: 30.minutes.ago)
      end

      it "advances all ready exclusions" do
        expect { task.call }.to change { exclusion1.reload.warmup_stage }.from(1).to(2)
                                                                         .and change { exclusion2.reload.warmup_stage }.from(2).to(3)
      end

      it "logs correct count" do
        task.call
        expect(logger).to have_logged(/Found 2 IP\(s\) ready for warmup advancement/)
        expect(logger).to have_logged(/Completed: 2 advanced, 0 errors/)
      end
    end

    context "when IP is not yet ready for warmup" do
      let(:ip_address) { create(:ip_address) }

      let!(:exclusion_not_ready) do
        create(:ip_domain_exclusion,
               ip_address: ip_address,
               destination_domain: "gmail.com",
               warmup_stage: 1,
               next_warmup_at: 1.day.from_now) # Not ready yet
      end

      it "does not advance the exclusion" do
        expect { task.call }.not_to change { exclusion_not_ready.reload.warmup_stage }
      end

      it "logs that no IPs are ready" do
        task.call
        expect(logger).to have_logged(/No IPs ready for warmup advancement/)
      end
    end

    context "when IP is at stage 0 (paused)" do
      let(:ip_address) { create(:ip_address) }

      let!(:exclusion_paused) do
        create(:ip_domain_exclusion,
               ip_address: ip_address,
               destination_domain: "gmail.com",
               warmup_stage: 0,
               next_warmup_at: 1.hour.ago)
      end

      it "does not advance paused exclusions" do
        expect { task.call }.not_to change { exclusion_paused.reload.warmup_stage }
      end

      it "logs that no IPs are ready" do
        task.call
        expect(logger).to have_logged(/No IPs ready for warmup advancement/)
      end
    end

    context "when warmup advancement fails" do
      let(:ip_address) { create(:ip_address) }

      let!(:exclusion) do
        create(:ip_domain_exclusion,
               ip_address: ip_address,
               destination_domain: "gmail.com",
               warmup_stage: 1,
               next_warmup_at: 1.hour.ago)
      end

      before do
        allow_any_instance_of(IPDomainExclusion).to receive(:advance_warmup_stage!)
          .and_raise(StandardError.new("Test error"))
      end

      it "logs the error" do
        task.call
        expect(logger).to have_logged(/Error advancing warmup/)
        expect(logger).to have_logged(/Test error/)
      end

      it "counts errors correctly" do
        task.call
        expect(logger).to have_logged(/Completed: 0 advanced, 1 errors/)
      end

      it "continues processing other exclusions" do
        other_ip = create(:ip_address)
        other_exclusion = create(:ip_domain_exclusion,
                                 ip_address: other_ip,
                                 destination_domain: "yahoo.com",
                                 warmup_stage: 2,
                                 next_warmup_at: 1.hour.ago)

        allow(IPDomainExclusion).to receive(:where).and_call_original
        allow_any_instance_of(IPDomainExclusion).to receive(:advance_warmup_stage!).and_call_original
        allow(exclusion).to receive(:advance_warmup_stage!).and_raise(StandardError.new("Test error"))

        task.call

        # The other exclusion should still be processed
        expect(other_exclusion.reload.warmup_stage).to eq(3)
      end
    end
  end

  describe ".next_run_after" do
    it "schedules the next run in 6 hours" do
      next_run = described_class.next_run_after
      expect(next_run).to be_within(1.minute).of(6.hours.from_now)
    end
  end
end
