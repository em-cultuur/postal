# frozen_string_literal: true

require "rails_helper"

RSpec.describe MessageDequeuer do
  describe ".process" do
    it "calls the initial process with the given message and logger" do
      message = create(:queued_message)
      logger = TestLogger.new

      mock = double("InitialProcessor")
      expect(mock).to receive(:process).with(no_args)
      expect(MessageDequeuer::InitialProcessor).to receive(:new).with(message, logger: logger).and_return(mock)

      described_class.process(message, logger: logger)
    end

    context "when a deadlock occurs" do
      let(:logger) { TestLogger.new }
      let(:queued_message) { create(:queued_message) }
      let(:processor) { instance_double(MessageDequeuer::InitialProcessor) }

      before do
        allow(MessageDequeuer::InitialProcessor).to receive(:new).and_return(processor)
        # Mock sleep to avoid actual delays in tests
        allow(described_class).to receive(:deadlock_sleep)
      end

      it "retries up to MAX_DEADLOCK_RETRIES times" do
        call_count = 0
        max_retries = MessageDequeuer.singleton_class::MAX_DEADLOCK_RETRIES
        allow(processor).to receive(:process) do
          call_count += 1
          raise ActiveRecord::Deadlocked, "Deadlock found" if call_count <= max_retries
        end

        expect { described_class.process(queued_message, logger: logger) }.not_to raise_error
        expect(call_count).to eq(max_retries + 1)
      end

      it "logs warnings on each retry" do
        call_count = 0
        allow(processor).to receive(:process) do
          call_count += 1
          raise ActiveRecord::Deadlocked, "Deadlock found" if call_count == 1
        end

        described_class.process(queued_message, logger: logger)

        expect(logger.logged[:warn].size).to eq(1)
        expect(logger.logged[:warn].first[:text]).to match(/Deadlock detected/)
      end

      it "uses exponential backoff" do
        call_count = 0
        allow(processor).to receive(:process) do
          call_count += 1
          raise ActiveRecord::Deadlocked, "Deadlock found" if call_count <= 2
        end

        sleep_times = []
        allow(described_class).to receive(:deadlock_sleep) { |time| sleep_times << time }

        described_class.process(queued_message, logger: logger)

        expect(sleep_times.size).to eq(2)
        # First retry should be around 0.1s, second around 0.2s (with jitter)
        expect(sleep_times[0]).to be_between(0.1, 0.15)
        expect(sleep_times[1]).to be_between(0.2, 0.25)
      end

      it "requeues the message after max retries" do
        allow(processor).to receive(:process).and_raise(ActiveRecord::Deadlocked, "Deadlock found")
        allow(queued_message).to receive(:retry_later)
        allow(queued_message).to receive(:destroyed?).and_return(false)

        expect { described_class.process(queued_message, logger: logger) }.to raise_error(ActiveRecord::Deadlocked)
        expect(queued_message).to have_received(:retry_later)
      end

      it "logs an error when max retries exceeded" do
        allow(processor).to receive(:process).and_raise(ActiveRecord::Deadlocked, "Deadlock found")
        allow(queued_message).to receive(:retry_later)
        allow(queued_message).to receive(:destroyed?).and_return(false)

        expect { described_class.process(queued_message, logger: logger) }.to raise_error(ActiveRecord::Deadlocked)

        expect(logger.logged[:error].size).to eq(1)
        expect(logger.logged[:error].first[:text]).to match(/Deadlock persisted after.*retries/)
      end

      it "does not requeue if message was destroyed" do
        allow(processor).to receive(:process).and_raise(ActiveRecord::Deadlocked, "Deadlock found")
        allow(queued_message).to receive(:retry_later)
        allow(queued_message).to receive(:destroyed?).and_return(true)

        expect { described_class.process(queued_message, logger: logger) }.to raise_error(ActiveRecord::Deadlocked)
        expect(queued_message).not_to have_received(:retry_later)
      end
    end

    context "when other exceptions occur" do
      let(:logger) { TestLogger.new }
      let(:queued_message) { create(:queued_message) }
      let(:processor) { instance_double(MessageDequeuer::InitialProcessor) }

      before do
        allow(MessageDequeuer::InitialProcessor).to receive(:new).and_return(processor)
      end

      it "does not retry for non-deadlock errors" do
        allow(processor).to receive(:process).and_raise(StandardError, "Some other error")

        expect { described_class.process(queued_message, logger: logger) }.to raise_error(StandardError, "Some other error")
        expect(processor).to have_received(:process).once
      end
    end
  end
end
