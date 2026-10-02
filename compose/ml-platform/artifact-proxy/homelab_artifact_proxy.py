"""Keep HTTP clients proxied; resolve the server's own SDK artifacts directly.

MLflow 3.16.1's demo handler uses the SQL backend as its SDK tracking URI.
Its default mlflow-artifacts repository requires an HTTP tracking URI instead.
Use the same URI-to-destination resolver that MLflow's trace API already uses,
only inside the artifact-serving server and for its configured backend URI.
"""
import os
import posixpath
from urllib.parse import urlsplit


def artifact_repository(artifact_uri, tracking_uri=None, registry_uri=None):
    from mlflow.store.artifact.mlflow_artifacts_repo import MlflowArtifactsRepository

    destination = os.environ.get("_MLFLOW_SERVER_ARTIFACT_DESTINATION")
    if (os.environ.get("_MLFLOW_SERVER_SERVE_ARTIFACTS") == "true"
            and destination and not urlsplit(artifact_uri).netloc):
        from mlflow.server import BACKEND_STORE_URI_ENV_VAR
        from mlflow.tracking._tracking_service.utils import get_tracking_uri

        effective_tracking_uri = tracking_uri or get_tracking_uri()
        if effective_tracking_uri == os.environ.get(BACKEND_STORE_URI_ENV_VAR):
            from mlflow.server.handlers import _get_proxied_run_artifact_destination_path
            from mlflow.store.artifact.artifact_repository_registry import get_artifact_repository

            path = _get_proxied_run_artifact_destination_path(artifact_uri)
            return get_artifact_repository(
                posixpath.join(destination, path),
                tracking_uri=effective_tracking_uri, registry_uri=registry_uri,
            )

    return MlflowArtifactsRepository(
        artifact_uri, tracking_uri=tracking_uri, registry_uri=registry_uri,
    )
