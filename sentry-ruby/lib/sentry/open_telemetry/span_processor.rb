module Sentry
  module OpenTelemetry
    class SpanProcessor

      ATTRIBUTE_NET_PEER_NAME = "net.peer.name"
      ATTRIBUTE_DB_STATEMENT = "db.statement"

      # https://github.com/open-telemetry/opentelemetry-ruby/blob/18bfd391f2bda2c958d5d6935886c8cba61414dd/api/lib/opentelemetry/trace.rb#L18-L22
      # An invalid trace identifier, a 16-byte string with all zero bytes.
      INVALID_TRACE_ID = ("\0" * 16).b

      # An invalid span identifier, an 8-byte string with all zero bytes.
      INVALID_SPAN_ID = ("\0" * 8).b

      def initialize
        @otel_span_map = {}
      end

      def on_start(otel_span, _parent_context)
        return unless Sentry.initialized? && Sentry.configuration.instrumenter == :otel
        return if from_sentry_sdk?(otel_span)

        span_id, trace_id, parent_span_id = get_trace_data(otel_span)
        return unless span_id

        scope = Sentry.get_current_scope
        parent_sentry_span = scope.get_span

        sentry_span = if parent_sentry_span
          Sentry.configuration.logger.info("Continuing otel span #{otel_span.name} on parent #{parent_sentry_span.name}")

          parent_sentry_span.start_child(span_id: span_id, description: otel_span.name)
        else
          continue_options = {
            span_id: span_id,
            name: otel_span.name
          }

          options = {
            trace_id: trace_id,
            parent_span_id: parent_span_id,
            **continue_options
          }

          sentry_trace = scope.sentry_trace
          baggage = scope.baggage

          Sentry.configuration.logger.info("Starting otel transaction #{otel_span.name}")
          transaction = Sentry::Transaction.from_sentry_trace(sentry_trace, baggage: baggage, **continue_options) if sentry_trace
          Sentry.start_transaction(transaction: transaction, instrumenter: :otel, **options)
        end

        scope.set_span(sentry_span)
        @otel_span_map[span_id] = [sentry_span, parent_sentry_span]
      end

      def on_finish(otel_span)
        return unless Sentry.initialized? && Sentry.configuration.instrumenter == :otel

        span_id = otel_span.context.hex_span_id unless otel_span.context.span_id == INVALID_SPAN_ID
        return unless span_id

        sentry_span, parent_span = @otel_span_map.delete(span_id)
        return unless sentry_span

        current_scope = Sentry.get_current_scope

        # TODO-neel ops
        sentry_span.set_op(otel_span.name)

        if sentry_span.is_a?(Sentry::Transaction)
          current_scope.set_transaction_name(otel_span.name)
          current_scope.set_context(:otel, otel_context_hash(otel_span))
        else
          otel_span.attributes&.each do |key, value|
            sentry_span.set_data(key, value)
            if key == ATTRIBUTE_DB_STATEMENT
              sentry_span.set_description(value)
            end
          end
        end

        Sentry.configuration.logger.info("Finishing sentry_span #{sentry_span.op}")
        sentry_span.finish
        current_scope.set_span(parent_span) if parent_span
      end

      def force_flush(timeout: nil)
        # no-op: we rely on Sentry.close being called for the same reason as
        # whatever triggered this shutdown.
      end

      def shutdown(timeout: nil)
        # no-op: we rely on Sentry.close being called for the same reason as
        # whatever triggered this shutdown.
      end

      private

      def from_sentry_sdk?(otel_span)
        dsn = Sentry.configuration.dsn
        return false unless dsn

        if otel_span.name.start_with?("HTTP")
          # only check client requests, connects are sometimes internal
          return false unless %i(client internal).include?(otel_span.kind)

          address = otel_span.attributes[ATTRIBUTE_NET_PEER_NAME]

          # if no address drop it, just noise
          return true unless address
          return true if dsn.host == address
        end

        false
      end

      def get_trace_data(otel_span)
        span_id = otel_span.context.hex_span_id unless otel_span.context.span_id == INVALID_SPAN_ID
        trace_id = otel_span.context.hex_trace_id unless otel_span.context.trace_id == INVALID_TRACE_ID
        parent_span_id = otel_span.parent_span_id.unpack1("H*") unless otel_span.parent_span_id == INVALID_SPAN_ID

        [span_id, trace_id, parent_span_id]
      end

      def otel_context_hash(otel_span)
        otel_context = {}
        otel_context[:attributes] = otel_span.attributes unless otel_span.attributes.empty?

        resource_attributes = otel_span.resource.attribute_enumerator.to_h
        otel_context[:resource] = resource_attributes unless resource_attributes.empty?

        otel_context
      end
    end
  end
end
