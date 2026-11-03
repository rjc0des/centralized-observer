'use strict';

// Loaded with `node --require` before any other module, so the instrumentations can
// patch `http` and `pino` when they are first required.
//
// - HTTP instrumentation starts a span per request and continues an incoming W3C
//   `traceparent` header, so a trace ID from an upstream caller is kept.
// - Pino instrumentation adds trace_id / span_id / trace_flags to every log line
//   written inside a request.
//
// ponytail: no span exporter: trace IDs are used for log correlation only, because
// no trace backend is in scope. Add an OTLP exporter + Grafana Tempo to store traces.

const { NodeTracerProvider } = require('@opentelemetry/sdk-trace-node');
const { registerInstrumentations } = require('@opentelemetry/instrumentation');
const { HttpInstrumentation } = require('@opentelemetry/instrumentation-http');
const { PinoInstrumentation } = require('@opentelemetry/instrumentation-pino');

new NodeTracerProvider().register();

const UNTRACED_PATHS = new Set(['/health', '/metrics']);

registerInstrumentations({
  instrumentations: [
    new HttpInstrumentation({
      ignoreIncomingRequestHook: (req) => UNTRACED_PATHS.has(req.url),
    }),
    new PinoInstrumentation({ disableLogSending: true }),
  ],
});
