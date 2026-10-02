"""Check the HTTP server, SQL backend and authenticated artifact bucket."""
import os
import sys
import urllib.request

import boto3
import psycopg2
from botocore.config import Config

try:
    with urllib.request.urlopen("http://127.0.0.1:5000/health", timeout=2) as response:
        assert response.status == 200
    with psycopg2.connect(
        host="postgres", dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"], password=os.environ["POSTGRES_PASSWORD"],
        connect_timeout=2,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
    boto3.client(
        "s3", endpoint_url=os.environ["MLFLOW_S3_ENDPOINT_URL"],
        config=Config(connect_timeout=2, read_timeout=2,
                      retries={"max_attempts": 0}, s3={"addressing_style": "path"}),
    ).head_bucket(Bucket=os.environ["MLFLOW_ARTIFACT_BUCKET"])
except Exception:
    print("MLflow HTTP/SQL/S3 health check failed", file=sys.stderr)
    sys.exit(1)
