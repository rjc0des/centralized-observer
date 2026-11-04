import unittest

from app.correlation import match, probable_cause, relation


def alert(name, **labels):
    return {"alertname": name, "environment": "local", **labels}


class Relation(unittest.TestCase):
    def test_same_alertname(self):
        self.assertEqual(relation(alert("DiskSpaceLow", device="sda"), alert("DiskSpaceLow", device="sdb")), "same-alert")

    def test_same_alertname_of_different_services_is_unrelated(self):
        self.assertIsNone(relation(alert("HighHTTPErrorRate", service="shop"), alert("HighHTTPErrorRate", service="cart")))

    def test_same_service(self):
        self.assertEqual(relation(alert("ApplicationDown", service="shop"), alert("HighRequestLatency", service="shop")),
                         "same-service")

    def test_different_services_are_unrelated(self):
        self.assertIsNone(relation(alert("ApplicationDown", service="shop"), alert("HighRequestLatency", service="cart")))

    def test_missing_service_on_both_is_not_same_service(self):
        self.assertIsNone(relation(alert("HighCPUUsage"), alert("RedisUnavailable")))

    def test_database_down_explains_app_errors_either_order(self):
        db, errors = alert("DatabaseUnavailable"), alert("HighHTTPErrorRate", service="ecommerce-api")
        self.assertEqual(relation(db, errors), "database-down")
        self.assertEqual(relation(errors, db), "database-down")
        self.assertEqual(relation(db, alert("EndpointDown", service="ecommerce-api", instance="x")), "database-down")

    def test_database_down_does_not_explain_other_services(self):
        self.assertIsNone(relation(alert("DatabaseUnavailable"), alert("HighHTTPErrorRate", service="incident-api")))
        self.assertIsNone(relation(alert("DatabaseUnavailable"), alert("EndpointDown", instance="http://loki:3100/ready")))

    def test_target_down_needs_same_target(self):
        down = alert("InstanceDown", job="node", instance="n1:9100")
        self.assertEqual(relation(down, alert("PrometheusTargetMissing", job="node", instance="n1:9100")), "target-down")
        self.assertIsNone(relation(down, alert("PrometheusTargetMissing", job="node", instance="n2:9100")))

    def test_symptom_alone_is_not_a_cause(self):
        self.assertIsNone(relation(alert("HighHTTPErrorRate", service="a"), alert("EndpointDown", service="b")))


class Match(unittest.TestCase):
    def test_first_matching_incident_wins(self):
        incidents = [(1, [alert("HighCPUUsage")]), (2, [alert("DatabaseUnavailable")]), (3, [alert("DatabaseUnavailable")])]
        self.assertEqual(match(alert("ErrorBudgetFastBurn", service="ecommerce-api"), incidents), (2, "database-down"))

    def test_no_match(self):
        self.assertEqual(match(alert("RedisUnavailable"), [(1, [alert("HighCPUUsage")])]), (None, None))


class ProbableCause(unittest.TestCase):
    def test_cause_beats_earlier_symptom(self):
        alerts = [{"labels": alert("HighHTTPErrorRate", service="ecommerce-api")}, {"labels": alert("DatabaseUnavailable")}]
        self.assertEqual(probable_cause(alerts)["labels"]["alertname"], "DatabaseUnavailable")

    def test_falls_back_to_first(self):
        self.assertEqual(probable_cause([{"labels": alert("A")}, {"labels": alert("B")}])["labels"]["alertname"], "A")
        self.assertIsNone(probable_cause([]))


if __name__ == "__main__":
    unittest.main()
