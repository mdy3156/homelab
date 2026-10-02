"""Wait for backend stores on every start, including daemon/VM restart."""
import os
import sys
import time

import boto3
import psycopg2
from botocore.config import Config
from sqlalchemy.engine import URL


def main():
    db = dict(
        host="postgres", port=5432, dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"], password=os.environ["POSTGRES_PASSWORD"],
        connect_timeout=5,
    )
    s3 = boto3.client(
        "s3", endpoint_url=os.environ["MLFLOW_S3_ENDPOINT_URL"],
        config=Config(connect_timeout=3, read_timeout=5,
                      retries={"max_attempts": 1}, s3={"addressing_style": "path"}),
    )
    for attempt in range(60):
        try:
            with psycopg2.connect(**db) as connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT 1")
            s3.head_bucket(Bucket=os.environ["MLFLOW_ARTIFACT_BUCKET"])
            break
        except Exception:
            # Don't log exception strings: DB URLs may include credentials.
            print(f"Waiting for PostgreSQL/S3 ({attempt + 1}/60)", flush=True)
            time.sleep(5)
    else:
        sys.exit("PostgreSQL/S3 did not become ready; inspect backend health.")

    # Keep the URI out of command arguments and correctly escape any password.
    os.environ["MLFLOW_BACKEND_STORE_URI"] = URL.create(
        "postgresql+psycopg2", username=db["user"], password=db["password"],
        host=db["host"], port=db["port"], database=db["dbname"],
    ).render_as_string(hide_password=False)
    os.execvp("mlflow", [
        "mlflow", "server", "--host", "0.0.0.0", "--port", "5000",
        "--workers", "1", "--serve-artifacts",
        "--artifacts-destination", "s3://" + os.environ["MLFLOW_ARTIFACT_BUCKET"],
    ])


if __name__ == "__main__":
    main()
