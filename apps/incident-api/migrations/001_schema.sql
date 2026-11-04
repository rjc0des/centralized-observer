-- Incidents get small sequential ids: people say "incident 42", not a UUID.

CREATE TABLE incidents (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title           text NOT NULL,
  severity        text NOT NULL,   -- highest severity among its alerts
  environment     text NOT NULL,
  status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'resolved')),
  opened_at       timestamptz NOT NULL,   -- startsAt of its first alert
  acknowledged_at timestamptz,
  resolved_at     timestamptz
);
-- Correlation only looks at unresolved incidents of one environment.
CREATE INDEX incidents_unresolved_idx ON incidents (environment) WHERE status <> 'resolved';
CREATE INDEX incidents_opened_at_idx ON incidents (opened_at);

-- One row per firing of one alert. Alertmanager re-sends notifications (repeat_interval,
-- group changes); (fingerprint, starts_at) identifies the firing, so re-sends dedupe here.
CREATE TABLE alerts (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id      bigint NOT NULL REFERENCES incidents (id),
  fingerprint      text NOT NULL,
  starts_at        timestamptz NOT NULL,
  ends_at          timestamptz,
  status           text NOT NULL CHECK (status IN ('firing', 'resolved')),
  alertname        text NOT NULL,
  severity         text NOT NULL,
  labels           jsonb NOT NULL,
  annotations      jsonb NOT NULL,
  first_received_at timestamptz NOT NULL DEFAULT now(),
  last_received_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fingerprint, starts_at)
);
CREATE INDEX alerts_incident_id_idx ON alerts (incident_id);

-- Append-only timeline (the app role cannot update or delete it).
CREATE TABLE events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  incident_id bigint NOT NULL REFERENCES incidents (id),
  at          timestamptz NOT NULL DEFAULT now(),
  kind        text NOT NULL CHECK (kind IN ('alert_firing', 'alert_resolved', 'severity_raised',
                                            'acknowledged', 'resolved', 'note')),
  actor       text NOT NULL,   -- "alertmanager" or the person who acted
  detail      text NOT NULL
);
CREATE INDEX events_incident_id_idx ON events (incident_id, at);
