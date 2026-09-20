# syntax=docker/dockerfile:1.7

##############################################################################
# CONJURR container image
#
# Multi-stage build:
#   1. "builder" installs build tooling + Python dependencies into an
#      isolated virtual environment (keeps compilers out of the final image).
#   2. "runtime" copies only the venv + application source into a slim,
#      non-root image and serves the app with Gunicorn.
##############################################################################

ARG PYTHON_VERSION=3.12

##############################
# 1. Builder
##############################
FROM python:${PYTHON_VERSION}-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Build tooling needed to compile wheels for packages such as rapidfuzz
# on architectures without prebuilt wheels. Removed automatically since
# this stage is discarded from the final image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

# Create an isolated virtual environment so the runtime stage only needs
# to copy /opt/venv (no pip/build tooling leaks into the final image).
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

COPY requirements.txt ./
RUN pip install --upgrade pip \
    && pip install -r requirements.txt

##############################
# 2. Runtime
##############################
FROM python:${PYTHON_VERSION}-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    HOME=/app \
    PORT=2665

# Create an unprivileged, dedicated user/group to run the application.
RUN groupadd --system conjurr \
    && useradd --system --gid conjurr --home-dir /app --create-home conjurr

WORKDIR /app

# Bring in the prebuilt virtual environment from the builder stage.
COPY --from=builder /opt/venv /opt/venv

# Copy application source (see .dockerignore for excluded paths).
COPY --chown=conjurr:conjurr . .

# Directories the app writes to at runtime (settings/.env, TMDb cache,
# uploaded Tautulli DB copies). Declared as volumes so persistent state
# can be mounted from the host/orchestrator instead of living in the
# container's writable layer.
RUN mkdir -p /app/env /app/data \
    && chown -R conjurr:conjurr /app

USER conjurr

EXPOSE 2665

VOLUME ["/app/env", "/app/data"]

# Lightweight healthcheck hitting the static favicon route (no external
# service calls, so it reflects whether the WSGI server itself is up).
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:2665/favicon.ico', timeout=3)" || exit 1

# Gunicorn serves the Flask "app" object defined in app.py.
CMD ["gunicorn", "--bind", "0.0.0.0:2665", "--workers", "2", "--threads", "4", "--timeout", "120", "app:app"]
