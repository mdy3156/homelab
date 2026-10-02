FROM ghcr.io/mlflow/mlflow:v3.16.1@sha256:06058cc872276873e9759c635e773342aca4731e240f6d20d88ea43774083984

RUN groupadd --gid 1000 mlflow \
    && useradd --uid 1000 --gid 1000 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin mlflow
COPY requirements.lock /app/requirements.lock
RUN python -m pip install --no-cache-dir --only-binary=:all: --require-hashes -r /app/requirements.lock \
    && python -m pip check \
    && python -c "import mlflow, boto3, psycopg2; assert mlflow.__version__ == '3.16.1'"
COPY artifact-proxy/ /app/artifact-proxy/
RUN python -m pip install --no-index --no-cache-dir --no-deps --no-build-isolation /app/artifact-proxy \
    && python -m pip check \
    && python /app/artifact-proxy/test_artifact_proxy.py
COPY entrypoint.py healthcheck.py /app/
WORKDIR /app
USER 1000:1000
ENTRYPOINT ["python", "/app/entrypoint.py"]
