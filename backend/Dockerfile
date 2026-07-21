FROM python:3.12-slim AS base

WORKDIR /app
RUN useradd -m -u 10001 appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

USER appuser
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0) if urllib.request.urlopen('http://localhost:8000/healthz').status==200 else sys.exit(1)"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
