"""JSON log lines: time, level, service, environment, msg (+ extra={"fields": {...}})."""
import json
import logging
import os
from datetime import datetime, timezone


class JsonFormatter(logging.Formatter):
    def __init__(self, service):
        super().__init__()
        self.service = service

    def format(self, record):
        line = {"time": datetime.fromtimestamp(record.created, timezone.utc).isoformat(timespec="milliseconds"),
                "level": record.levelname.lower(), "service": self.service,
                "environment": os.environ.get("ENVIRONMENT", "local"), "msg": record.getMessage(),
                **getattr(record, "fields", {})}
        if record.exc_info:
            line["error"] = self.formatException(record.exc_info)
        return json.dumps(line, default=str)


def setup(service):
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter(service))
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "info").upper(), handlers=[handler], force=True)
