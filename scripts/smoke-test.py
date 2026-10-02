"""Exercise SQL + signed/unsigned S3 + MLflow proxy; leave persistence probes.

Executed inside MLflow by smoke-test.sh. --verify RUN_ID checks an existing run
and object after a daemon restart or VM reboot without creating new data.
"""
import json
import contextlib
import os
import sys
import tempfile
import time
import uuid
from pathlib import Path

import boto3
import mlflow
import psycopg2
from botocore import UNSIGNED
from botocore.config import Config
from botocore.exceptions import ClientError
from mlflow import MlflowClient

bucket = os.environ["MLFLOW_ARTIFACT_BUCKET"]
endpoint = os.environ["MLFLOW_S3_ENDPOINT_URL"]
body = b"homelab: MLflow PostgreSQL and SeaweedFS persistence verified\n"
config = Config(s3={"addressing_style": "path"},
                request_checksum_calculation="when_required",
                response_checksum_validation="when_required")
s3 = boto3.client("s3", endpoint_url=endpoint, config=config)
unsigned = boto3.client("s3", endpoint_url=endpoint,
                       config=Config(signature_version=UNSIGNED, s3={"addressing_style": "path"}))
mlflow.set_tracking_uri("http://127.0.0.1:5000")
client = MlflowClient()


def check_sql(run_id):
    with psycopg2.connect(host="postgres", dbname=os.environ["POSTGRES_DB"],
                          user=os.environ["POSTGRES_USER"],
                          password=os.environ["POSTGRES_PASSWORD"], connect_timeout=5) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT status FROM runs WHERE run_uuid = %s", (run_id,))
            assert cursor.fetchone() == ("FINISHED",)
            cursor.execute("SELECT value FROM params WHERE run_uuid = %s AND key = %s", (run_id, "source"))
            assert cursor.fetchone() == ("homelab-smoke",)
            cursor.execute("SELECT value FROM metrics WHERE run_uuid = %s AND key = %s", (run_id, "score"))
            assert cursor.fetchone() == (1.0,)


def verify(run_id):
    run = client.get_run(run_id)
    assert run.data.params["source"] == "homelab-smoke"
    assert run.data.metrics["score"] == 1.0
    assert run.info.artifact_uri.startswith("mlflow-artifacts:")
    check_sql(run_id)
    with tempfile.TemporaryDirectory() as directory:
        artifact = client.download_artifacts(run_id, "probe.txt", directory)
        assert Path(artifact).read_bytes() == body
    # Check real S3 object contents rather than only the MLflow response.
    objects = s3.list_objects_v2(Bucket=bucket, Prefix=str(run.info.experiment_id) + "/" + run_id + "/")
    keys = [obj["Key"] for obj in objects.get("Contents", []) if obj["Key"].endswith("/probe.txt")]
    assert len(keys) == 1, keys
    assert s3.get_object(Bucket=bucket, Key=keys[0])["Body"].read() == body
    probe_key = "homelab-validation/persistence/" + run_id + ".txt"
    assert s3.get_object(Bucket=bucket, Key=probe_key)["Body"].read() == body
    return {"run_id": run_id, "experiment_id": run.info.experiment_id,
            "artifact_key": keys[0], "persistence_key": probe_key,
            "bucket": bucket, "result": "passed"}


def main():
    s3.head_bucket(Bucket=bucket)
    assert bucket in [b["Name"] for b in s3.list_buckets()["Buckets"]]
    for operation in [lambda: unsigned.list_buckets(),
                      lambda: unsigned.list_objects_v2(Bucket=bucket),
                      lambda: unsigned.put_object(Bucket=bucket, Key="anonymous-probe", Body=body)]:
        try:
            operation()
        except ClientError as error:
            assert error.response["ResponseMetadata"]["HTTPStatusCode"] == 403
        else:
            raise AssertionError("Unsigned S3 request was accepted")
    if len(sys.argv) == 3 and sys.argv[1] == "--verify":
        print(json.dumps(verify(sys.argv[2]), sort_keys=True))
        return
    if len(sys.argv) != 1:
        sys.exit("Usage: smoke-test.sh [--verify RUN_ID]")

    transient_key = "homelab-validation/transient/" + uuid.uuid4().hex
    try:
        s3.put_object(Bucket=bucket, Key=transient_key, Body=body)
        assert s3.get_object(Bucket=bucket, Key=transient_key)["Body"].read() == body
        listing = s3.list_objects_v2(Bucket=bucket, Prefix=transient_key)
        assert transient_key in [obj["Key"] for obj in listing.get("Contents", [])]
    finally:
        s3.delete_object(Bucket=bucket, Key=transient_key)
    assert not s3.list_objects_v2(Bucket=bucket, Prefix=transient_key).get("Contents")

    experiment_id = client.create_experiment("homelab-validation-" + str(time.time_ns()))
    # Use the Tracking API directly; this container contains no source Git repo.
    run = client.create_run(experiment_id, tags={"mlflow.runName": "infrastructure-smoke"})
    run_id = run.info.run_id
    try:
        client.log_param(run_id, "source", "homelab-smoke")
        client.log_metric(run_id, "score", 1.0)
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "probe.txt"
            artifact.write_bytes(body)
            client.log_artifact(run_id, str(artifact))
    except Exception:
        with contextlib.redirect_stdout(sys.stderr):
            client.set_terminated(run_id, status="FAILED")
        raise
    else:
        with contextlib.redirect_stdout(sys.stderr):
            client.set_terminated(run_id, status="FINISHED")
    s3.put_object(Bucket=bucket, Key="homelab-validation/persistence/" + run_id + ".txt", Body=body)
    print(json.dumps(verify(run_id), sort_keys=True))


if __name__ == "__main__":
    main()
