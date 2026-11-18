FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    CA_CERT_PATH=/app/ca.crt

WORKDIR /app
COPY ca.crt verify_apigee_mcp.py /app/

CMD ["python3", "-u", "/app/verify_apigee_mcp.py"]
