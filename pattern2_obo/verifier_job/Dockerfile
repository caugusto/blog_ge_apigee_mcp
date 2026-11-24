FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY ca.crt /app/ca.crt
COPY verify_apigee_bq_obo.py /app/verify_apigee_bq_obo.py

CMD ["python3", "/app/verify_apigee_bq_obo.py"]
