# frozen_string_literal: true

module WaterDrop
  class Producer
    # Component for synchronous producer operations
    module Sync
      # Produces a message to Kafka and waits for it to be delivered
      #
      # @param message [Hash] hash that complies with the {Contracts::Message} contract
      #
      # @return [Rdkafka::Producer::DeliveryReport] delivery report
      #
      # @raise [Rdkafka::RdkafkaError] When adding the message to rdkafka's queue failed
      # @raise [Rdkafka::Producer::WaitTimeoutError] When the timeout has been reached and the
      #   handle is still pending
      # @raise [Errors::MessageInvalidError] When provided message details are invalid and the
      #   message could not be sent to Kafka
      def produce_sync(message)
        message = middleware.run(message)
        validate_message!(message)

        @monitor.instrument(
          'message.produced_sync',
          producer_id: id,
          message: message
        ) do
          wait(produce(message))
        end
      rescue *SUPPORTED_FLOW_ERRORS => e
        # We use this syntax here because we want to preserve the original `#cause` when we
        # instrument the error and there is no way to manually assign `#cause` value
        begin
          raise Errors::ProduceError, e.inspect
        rescue Errors::ProduceError => ex
          @monitor.instrument(
            'error.occurred',
            producer_id: id,
            message: message,
            error: ex,
            type: 'message.produce_sync'
          )

          raise ex
        end
      end

      # Produces many messages to Kafka and waits for them to be delivered
      #
      # @param messages [Array<Hash>] array with messages that comply with the
      #   {Contracts::Message} contract
      #
      # @return [Array<Rdkafka::Producer::DeliveryReport>] delivery reports
      #
      # @raise [Rdkafka::RdkafkaError] When adding the messages to rdkafka's queue failed
      # @raise [Rdkafka::Producer::WaitTimeoutError] When the timeout has been reached and some
      #   handles are still pending
      # @raise [Errors::MessageInvalidError] When any of the provided messages details are invalid
      #   and the message could not be sent to Kafka
      def produce_many_sync(messages)
        messages = middleware.run_many(messages)
        messages.each { |message| validate_message!(message) }

        dispatched = []

        @monitor.instrument('messages.produced_sync', producer_id: id, messages: messages) do
          with_transaction_if_transactional do
            messages.each do |message|
              dispatched << produce(message)
            end
          end

          dispatched.map! do |handler|
            wait(handler)
          end

          dispatched
        end
      rescue *SUPPORTED_FLOW_ERRORS => e
        re_raised = Errors::ProduceManyError.new(dispatched, e.inspect)

        @monitor.instrument(
          'error.occurred',
          producer_id: id,
          messages: messages,
          # If it is a transactional producer nothing was successfully dispatched on error, thus
          # we never return any dispatched handlers. While those messages might have reached
          # Kafka, in transactional mode they will not be visible to consumers with correct
          # isolation level.
          dispatched: transactional? ? EMPTY_ARRAY : dispatched,
          error: re_raised,
          type: 'messages.produce_many_sync'
        )

        raise re_raised
      end
    end
  end
end
