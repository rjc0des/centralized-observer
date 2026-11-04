"""Entry point: python -m app."""
import uvicorn

from . import logs

logs.setup("incident-api")
# log_config=None: uvicorn's loggers propagate to the JSON handler above. No access log:
# http_requests_total covers traffic, and webhook/lifecycle actions log themselves.
uvicorn.run("app.main:app", host="0.0.0.0", port=8000, log_config=None, access_log=False, server_header=False)
