"""Regression checks for SQL-backed demo artifacts and unchanged HTTP clients."""
import os
import unittest
from unittest.mock import patch

from mlflow.exceptions import MlflowException
from mlflow.server import BACKEND_STORE_URI_ENV_VAR
from mlflow.store.artifact.artifact_repository_registry import get_artifact_repository
from mlflow.store.artifact.mlflow_artifacts_repo import MlflowArtifactsRepository
from mlflow.store.artifact.s3_artifact_repo import S3ArtifactRepository


class ArtifactProxyTest(unittest.TestCase):
    backend = "postgresql+psycopg2://test:test@postgres/mlflow"

    def setUp(self):
        context = patch.dict(os.environ, {
            "AWS_ACCESS_KEY_ID": "test",
            "AWS_SECRET_ACCESS_KEY": "test",
            "AWS_EC2_METADATA_DISABLED": "true",
            "_MLFLOW_SERVER_SERVE_ARTIFACTS": "true",
            "_MLFLOW_SERVER_ARTIFACT_DESTINATION": "s3://mlflow-artifacts",
            BACKEND_STORE_URI_ENV_VAR: self.backend,
        })
        context.start()
        self.addCleanup(context.stop)

    def test_internal_trace_uses_configured_s3_path(self):
        repo = get_artifact_repository("mlflow-artifacts:/3/traces/tr-test", self.backend)
        self.assertIsInstance(repo, S3ArtifactRepository)
        self.assertEqual(repo.artifact_uri, "s3://mlflow-artifacts/3/traces/tr-test")

    def test_root_maps_to_bucket(self):
        repo = get_artifact_repository("mlflow-artifacts:/", self.backend)
        self.assertIsInstance(repo, S3ArtifactRepository)
        self.assertEqual(repo.artifact_uri.rstrip("/"), "s3://mlflow-artifacts")

    def test_http_client_keeps_artifact_proxy(self):
        repo = get_artifact_repository("mlflow-artifacts:/2/run/artifacts", "http://mlflow:5000")
        self.assertIsInstance(repo, MlflowArtifactsRepository)
        self.assertEqual(repo.artifact_uri,
                         "http://mlflow:5000/api/2.0/mlflow-artifacts/artifacts/2/run/artifacts")

    def test_foreign_host_is_not_rewritten(self):
        with self.assertRaises(MlflowException):
            get_artifact_repository("mlflow-artifacts://other-server:5000/traces/x", self.backend)

    def test_different_backend_is_not_rewritten(self):
        with self.assertRaises(MlflowException):
            get_artifact_repository("mlflow-artifacts:/traces/x", "postgresql://different/store")

    def test_non_server_is_not_rewritten(self):
        os.environ["_MLFLOW_SERVER_SERVE_ARTIFACTS"] = "false"
        with self.assertRaises(MlflowException):
            get_artifact_repository("mlflow-artifacts:/traces/x", self.backend)


if __name__ == "__main__":
    unittest.main()
