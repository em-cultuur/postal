# frozen_string_literal: true

module MessageDequeuer

  class << self

    MAX_DEADLOCK_RETRIES = 3
    DEADLOCK_RETRY_DELAY = 0.1 # seconds

    def process(message, logger:)
      retries = 0
      begin
        processor = InitialProcessor.new(message, logger: logger)
        processor.process
      rescue ActiveRecord::Deadlocked => e
        retries += 1
        if retries <= MAX_DEADLOCK_RETRIES
          # Exponential backoff with jitter to reduce contention
          sleep_time = (DEADLOCK_RETRY_DELAY * (2**(retries - 1))) + rand(0.0..0.05)
          logger.warn "Deadlock detected (attempt #{retries}/#{MAX_DEADLOCK_RETRIES}), retrying in #{sleep_time.round(3)}s",
                      message_id: message.id,
                      error: e.message
          deadlock_sleep(sleep_time)
          retry
        else
          logger.error "Deadlock persisted after #{MAX_DEADLOCK_RETRIES} retries, requeueing message",
                       message_id: message.id,
                       error: e.message
          # Requeue the message for later processing
          message.retry_later unless message.destroyed?
          raise
        end
      end
    end

    private

    def deadlock_sleep(time)
      sleep(time)
    end

  end

end
