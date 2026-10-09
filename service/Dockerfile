FROM python:3.13.16-slim-bookworm AS builder

WORKDIR /build

COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt


FROM python:3.13.16-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app \
        --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY app.py .

USER 10001:10001

EXPOSE 8080

CMD ["gunicorn", "--no-control-socket", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "2", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
