import unittest
from datetime import datetime, timedelta, timezone

from app.report import markdown

T0 = datetime(2026, 11, 3, 10, 0, tzinfo=timezone.utc)


def incident(**overrides):
    return {"id": 7, "title": "Postgres is unavailable", "status": "resolved", "severity": "critical",
            "environment": "local", "opened_at": T0, "acknowledged_at": T0 + timedelta(seconds=90),
            "resolved_at": T0 + timedelta(hours=1, minutes=5),
            "alerts": [
                {"alertname": "HighHTTPErrorRate", "severity": "critical", "starts_at": T0, "ends_at": None,
                 "labels": {"alertname": "HighHTTPErrorRate", "service": "ecommerce-api"}, "annotations": {}},
                {"alertname": "DatabaseUnavailable", "severity": "critical", "starts_at": T0, "ends_at": T0,
                 "labels": {"alertname": "DatabaseUnavailable"}, "annotations": {"summary": "Postgres is unavailable"}},
            ],
            "events": [{"at": T0, "kind": "note", "actor": "ana", "detail": "a | b\nnext line"}]} | overrides


class Report(unittest.TestCase):
    def test_summary_and_durations(self):
        text = markdown(incident())
        self.assertIn("# Incident 7: Postgres is unavailable", text)
        self.assertIn("| Acknowledged | 2026-11-03 10:01:30 UTC (after 1m 30s) |", text)
        self.assertIn("| Resolved | 2026-11-03 11:05:00 UTC (after 1h 5m) |", text)
        self.assertIn("| Probable cause | DatabaseUnavailable: Postgres is unavailable |", text)
        self.assertIn("| HighHTTPErrorRate | critical | service=ecommerce-api | 2026-11-03 10:00:00 UTC | - |", text)

    def test_user_text_cannot_break_the_table(self):
        self.assertIn("| ana | note: a \\| b next line |", markdown(incident()))

    def test_severity_from_labels_cannot_break_the_table(self):
        text = markdown(incident(severity="x | y\n## Injected"))
        self.assertIn("| Severity | x \\| y ## Injected |", text)
        self.assertNotIn("\n## Injected", text)

    def test_unacknowledged(self):
        self.assertIn("| Acknowledged | - |", markdown(incident(acknowledged_at=None, resolved_at=None, status="open")))


if __name__ == "__main__":
    unittest.main()
