"""Incident report in Markdown: summary, probable cause, alerts and timeline."""
from .correlation import probable_cause

HIDDEN_LABELS = {"alertname", "severity", "environment"}   # already shown in their own columns


def _time(ts):
    return ts.strftime("%Y-%m-%d %H:%M:%S UTC") if ts else "-"


def _after(start, end):
    if not (start and end):
        return ""
    seconds = max(0, int((end - start).total_seconds()))
    h, m, s = seconds // 3600, seconds // 60 % 60, seconds % 60
    return f" (after {h}h {m}m)" if h else f" (after {m}m {s}s)"


def _cell(text):
    """Table-safe: user text (notes, labels) must not break the Markdown table."""
    return str(text).replace("\\", "\\\\").replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def markdown(incident):
    alerts, opened = incident["alerts"], incident["opened_at"]
    cause = probable_cause(alerts)
    cause_text = f"{cause['alertname']}: {cause['annotations'].get('summary', '')}" if cause else "-"
    lines = [
        f"# Incident {incident['id']}: {_cell(incident['title'])}",
        "",
        "| | |",
        "|---|---|",
        f"| Status | {_cell(incident['status'])} |",
        f"| Severity | {_cell(incident['severity'])} |",
        f"| Environment | {_cell(incident['environment'])} |",
        f"| Opened | {_time(opened)} |",
        f"| Acknowledged | {_time(incident['acknowledged_at'])}{_after(opened, incident['acknowledged_at'])} |",
        f"| Resolved | {_time(incident['resolved_at'])}{_after(opened, incident['resolved_at'])} |",
        f"| Probable cause | {_cell(cause_text)} |",
        "",
        "Probable cause is deterministic: the earliest alert that a correlation rule lists as a",
        "cause (e.g. DatabaseUnavailable explains HighHTTPErrorRate), else the earliest alert.",
        "",
        f"## Alerts ({len(alerts)})",
        "",
        "| Alert | Severity | Labels | Started | Ended |",
        "|---|---|---|---|---|",
    ]
    for a in alerts:
        labels = ", ".join(f"{k}={v}" for k, v in sorted(a["labels"].items()) if k not in HIDDEN_LABELS)
        lines.append(f"| {_cell(a['alertname'])} | {_cell(a['severity'])} | {_cell(labels)} "
                     f"| {_time(a['starts_at'])} | {_time(a['ends_at'])} |")
    lines += ["", "## Timeline", "", "| Time | Who | What |", "|---|---|---|"]
    for e in incident["events"]:
        lines.append(f"| {_time(e['at'])} | {_cell(e['actor'])} | {_cell(e['kind'])}: {_cell(e['detail'])} |")
    return "\n".join(lines) + "\n"
