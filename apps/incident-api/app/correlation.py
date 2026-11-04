"""Deterministic alert correlation: which open incident does a new alert belong to?

Every decision names the rule that made it, so the timeline explains itself. Alerts are
only compared within one environment (the caller's query guarantees it).

The cause -> symptom pairs mirror the inhibit_rules in
observability/alertmanager/alertmanager.yml: an alert Alertmanager mutes as "explained by"
another belongs to that other alert's incident. Change both together.
"""

# (rule name, cause alertnames, symptom alertnames, labels that must be equal,
#  labels the symptom must carry). A label missing on both sides counts as equal,
#  as in Alertmanager.
CAUSAL_RULES = [
    ("target-down", {"InstanceDown", "ApplicationDown"}, {"PrometheusTargetMissing"}, ("job", "instance"), {}),
    ("database-down", {"DatabaseUnavailable"},
     {"HighHTTPErrorRate", "ErrorBudgetFastBurn", "ErrorBudgetSlowBurn", "EndpointDown"}, (),
     {"service": "ecommerce-api"}),
]
CAUSES = set().union(*(causes for _, causes, *_ in CAUSAL_RULES))

SEVERITY_RANK = {"critical": 3, "warning": 2, "info": 1}


def relation(a, b):
    """Name of the rule relating two alerts' label sets, or None."""
    if a.get("alertname") == b.get("alertname") and a.get("service") == b.get("service"):
        return "same-alert"   # e.g. one disk alert per device; Alertmanager groups these too
    if a.get("service") and a.get("service") == b.get("service"):
        return "same-service"
    for name, causes, symptoms, equal, required in CAUSAL_RULES:
        for cause, symptom in ((a, b), (b, a)):
            if (cause.get("alertname") in causes and symptom.get("alertname") in symptoms
                    and all(symptom.get(k) == v for k, v in required.items())
                    and all(cause.get(k) == symptom.get(k) for k in equal)):
                return name
    return None


def match(labels, incidents):
    """First incident (in the given order) with an alert related to `labels`.

    incidents: [(incident_id, [labels of each of its alerts])], oldest first.
    Returns (incident_id, rule) or (None, None).
    """
    for incident_id, alerts in incidents:
        for other in alerts:
            rule = relation(labels, other)
            if rule:
                return incident_id, rule
    return None, None


def probable_cause(alerts):
    """The earliest alert that is a known cause, else the earliest alert.

    alerts: dicts with "labels", ordered by start time.
    """
    return next((a for a in alerts if a["labels"].get("alertname") in CAUSES), alerts[0] if alerts else None)
