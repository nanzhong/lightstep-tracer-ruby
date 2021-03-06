require 'json'
require 'concurrent'

require 'lightstep/span'
require 'lightstep/reporter'
require 'lightstep/transport/http_json'
require 'lightstep/transport/nil'
require 'lightstep/transport/callback'

module LightStep
  class Tracer
    FORMAT_TEXT_MAP = 1
    FORMAT_BINARY = 2
    FORMAT_RACK = 3

    class Error < LightStep::Error; end
    class ConfigurationError < LightStep::Tracer::Error; end

    attr_reader :access_token, :guid

    # Initialize a new tracer. Either an access_token or a transport must be
    # provided. A component_name is always required.
    # @param component_name [String] Component name to use for the tracer
    # @param access_token [String] The project access token when pushing to LightStep
    # @param transport [LightStep::Transport] How the data should be transported
    # @param tags [Hash] Tracer-level tags
    # @return LightStep::Tracer
    # @raise LightStep::ConfigurationError if the group name or access token is not a valid string.
    def initialize(component_name:, access_token: nil, transport: nil, tags: {})
      configure(component_name: component_name, access_token: access_token, transport: transport, tags: tags)
    end

    def max_log_records
      @max_log_records ||= DEFAULT_MAX_LOG_RECORDS
    end

    def max_log_records=(max)
      @max_log_records = [MIN_MAX_LOG_RECORDS, max].max
    end

    def max_span_records
      @max_span_records ||= DEFAULT_MAX_SPAN_RECORDS
    end

    def max_span_records=(max)
      @max_span_records = [MIN_MAX_SPAN_RECORDS, max].max
      @reporter.max_span_records = @max_span_records
    end

    # Set the report flushing period. If set to 0, no flushing will be done, you
    # must manually call flush.
    def report_period_seconds=(seconds)
      @reporter.period = seconds
    end

    # TODO(ngauthier@gmail.com) inherit SpanContext from references

    # Starts a new span.
    # @param operation_name [String] the operation name for the Span
    # @param child_of [Span] Span to inherit from
    # @param start_time [Time] When the Span started, if not now
    # @param tags [Hash] tags for the span
    # @return [Span]
    def start_span(operation_name, child_of: nil, start_time: nil, tags: nil)
      child_of_id = nil
      trace_id = nil
      if Span === child_of
        child_of_id = child_of.span_context.id
        trace_id = child_of.span_context.trace_id
      else
        trace_id = LightStep.guid
      end

      span = Span.new(
        tracer: self,
        operation_name: operation_name,
        child_of_id: child_of_id,
        trace_id: trace_id,
        start_micros: start_time.nil? ? LightStep.micros(Time.now) : LightStep.micros(start_time),
        tags: tags,
        max_log_records: max_log_records
      )

      if Span === child_of
        span.set_baggage(child_of.baggage)
      end

      span
    end

    # Inject a span into the given carrier
    # @param span [Span]
    # @param format [LightStep::Tracer::FORMAT_TEXT_MAP, LightStep::Tracer::FORMAT_BINARY]
    # @param carrier [Hash]
    def inject(span, format, carrier)
      case format
      when LightStep::Tracer::FORMAT_TEXT_MAP
        inject_to_text_map(span, carrier)
      when LightStep::Tracer::FORMAT_BINARY
        warn 'Binary inject format not yet implemented'
      when LightStep::Tracer::FORMAT_RACK
        inject_to_rack(span, carrier)
      else
        warn 'Unknown inject format'
      end
    end

    # Extract a span from a carrier
    # @param operation_name [String]
    # @param format [LightStep::Tracer::FORMAT_TEXT_MAP, LightStep::Tracer::FORMAT_BINARY]
    # @param carrier [Hash]
    # @return [Span]
    def extract(operation_name, format, carrier)
      case format
      when LightStep::Tracer::FORMAT_TEXT_MAP
        extract_from_text_map(operation_name, carrier)
      when LightStep::Tracer::FORMAT_BINARY
        warn 'Binary join format not yet implemented'
        nil
      when LightStep::Tracer::FORMAT_RACK
        extract_from_rack(operation_name, carrier)
      else
        warn 'Unknown join format'
        nil
      end
    end

    # @return true if the tracer is enabled
    def enabled?
      return @enabled if defined?(@enabled)
      @enabled = true
    end

    # Enables the tracer
    def enable
      @enabled = true
    end

    # Disables the tracer
    # @param discard [Boolean] whether to discard queued data
    def disable(discard: true)
      @enabled = false
      @reporter.clear if discard
      @reporter.flush
    end

    # Flush to the Transport
    def flush
      return unless enabled?
      @reporter.flush
    end

    # Internal use only.
    # @private
    def finish_span(span)
      return unless enabled?
      @reporter.add_span(span)
    end

    protected

    def configure(component_name:, access_token: nil, transport: nil, tags: {})
      raise ConfigurationError, "component_name must be a string" unless String === component_name
      raise ConfigurationError, "component_name cannot be blank"  if component_name.empty?

      transport = Transport::HTTPJSON.new(access_token: access_token) if !access_token.nil?
      raise ConfigurationError, "you must provide an access token or a transport" if transport.nil?
      raise ConfigurationError, "#{transport} is not a LightStep transport class" if !(LightStep::Transport::Base === transport)

      @guid = LightStep.guid

      @reporter = LightStep::Reporter.new(
        max_span_records: max_span_records,
        transport: transport,
        guid: guid,
        component_name: component_name,
        tags: tags
      )
    end

    private

    CARRIER_TRACER_STATE_PREFIX = 'ot-tracer-'.freeze
    CARRIER_BAGGAGE_PREFIX = 'ot-baggage-'.freeze

    DEFAULT_MAX_LOG_RECORDS = 1000
    MIN_MAX_LOG_RECORDS = 1
    DEFAULT_MAX_SPAN_RECORDS = 1000
    MIN_MAX_SPAN_RECORDS = 1

    def inject_to_text_map(span, carrier)
      carrier[CARRIER_TRACER_STATE_PREFIX + 'spanid'] = span.span_context.id
      carrier[CARRIER_TRACER_STATE_PREFIX + 'traceid'] = span.span_context.trace_id unless span.span_context.trace_id.nil?
      carrier[CARRIER_TRACER_STATE_PREFIX + 'sampled'] = 'true'

      span.span_context.baggage.each do |key, value|
        carrier[CARRIER_BAGGAGE_PREFIX + key] = value
      end
    end

    def extract_from_text_map(operation_name, carrier)
      span = Span.new(
        tracer: self,
        operation_name: operation_name,
        start_micros: LightStep.micros(Time.now),
        child_of_id: carrier[CARRIER_TRACER_STATE_PREFIX + 'spanid'],
        trace_id: carrier[CARRIER_TRACER_STATE_PREFIX + 'traceid'],
        max_log_records: max_log_records
      )

      baggage = carrier.reduce({}) do |baggage, tuple|
        key, value = tuple
        if key.start_with?(CARRIER_BAGGAGE_PREFIX)
          plain_key = key.to_s[CARRIER_BAGGAGE_PREFIX.length..key.to_s.length]
          baggage[plain_key] = value
        end
        baggage
      end
      span.set_baggage(baggage)

      span
    end

    def inject_to_rack(span, carrier)
      carrier[CARRIER_TRACER_STATE_PREFIX + 'spanid'] = span.span_context.id
      carrier[CARRIER_TRACER_STATE_PREFIX + 'traceid'] = span.span_context.trace_id unless span.span_context.trace_id.nil?
      carrier[CARRIER_TRACER_STATE_PREFIX + 'sampled'] = 'true'

      span.span_context.baggage.each do |key, value|
        if key =~ /[^A-Za-z0-9\-_]/
          # TODO: log the error internally
          next
        end
        carrier[CARRIER_BAGGAGE_PREFIX + key] = value
      end
    end

    def extract_from_rack(operation_name, env)
      extract_from_text_map(operation_name, env.reduce({}){|memo, tuple|
        raw_header, value = tuple
        header = raw_header.gsub(/^HTTP_/, '').gsub("_", "-").downcase

        memo[header] = value if header.start_with?(CARRIER_TRACER_STATE_PREFIX, CARRIER_BAGGAGE_PREFIX)
        memo
      })
    end
  end
end
