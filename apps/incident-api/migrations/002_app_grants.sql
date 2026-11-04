-- Exactly what the API needs. Nothing is ever deleted; the timeline is insert-only.
GRANT SELECT, INSERT, UPDATE ON incidents, alerts TO incident_app;
GRANT SELECT, INSERT ON events TO incident_app;
