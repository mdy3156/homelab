# ml-platform

PostgreSQLにmetadata、SeaweedFS S3にartifactを保存するMLflowスタックです。

```bash
cd /home/mdy/homelab/compose/ml-platform
docker compose config --quiet
docker compose up -d --build --wait --wait-timeout 420
docker compose ps
docker compose logs --tail=100 -f mlflow
docker compose stop
```

`.env` は0600・Git除外で、`POSTGRES_DB`、`POSTGRES_USER`、`POSTGRES_PASSWORD`、`SEAWEEDFS_ACCESS_KEY`、`SEAWEEDFS_SECRET_KEY`、`MLFLOW_ARTIFACT_BUCKET` が必須です。
`.env.example` は変数名のみを記載します。初期bucket名は `mlflow-artifacts`。

PostgreSQLは5432をpublishせず、internalなdatabase networkに接続します。
18以降の公式imageに合わせ、ホスト `/srv/homelab/postgres/data` をコンテナ `/var/lib/postgresql` へmountし、PGDATAを `/var/lib/postgresql/18/docker` に設定します。
非root UID 999で起動し、`pg_isready` healthcheckを設定します。

SeaweedFSは固定版の公式 `weed mini` を使用します。認証はAWS環境変数、bucket作成は `S3_BUCKET` で初期化します。
S3だけを `192.168.0.8:8333` にpublishします。master・filer・volume・gRPC・adminポートは内部のみです。
WebDAV、Iceberg、Lance、Admin UIは無効化します。mini内部のadmin/maintenance用処理は公開しません。
SeaweedFS healthcheckはmasterとfilerの応答を確認し、MLflow healthcheckで署名付きS3 bucketアクセスも確認します。

MLflowの公式GHCR imageをdigestで固定し、PostgreSQL driverとS3 clientを `requirements.lock` のSHA256で追加します。
HTTP workerは1とし、今回使わないGenAI job executionを無効化してメモリ使用を抑えます。
build時に `pip check` とimportを実行します。build contextは必要なソースだけに限定し、secretはimageに入れません。
`entrypoint.py` は毎回SQL/S3を待ち、passwordをURLエスケープしてbackend URIを環境変数に設定します。
`--serve-artifacts --artifacts-destination s3://mlflow-artifacts` により、クライアントはS3 credentialを持たずにartifactを利用できます。
新しいexperimentのURIは `mlflow-artifacts:/...` です。 `--default-artifact-root s3://...` を併用しません。

```python
import mlflow
mlflow.set_tracking_uri("http://192.168.0.8:5000")
mlflow.set_experiment("my-experiment")
with mlflow.start_run():
    mlflow.log_param("learning_rate", 0.01)
    mlflow.log_metric("accuracy", 0.95)
    mlflow.log_text("hello", "hello.txt")
```

全コンテナを非root・capability全削除・no-new-privilegesで運用し、各ログは10MB × 3に制限します。
MLflowは信頼するLAN内向けのHTTPサービスです。アプリのユーザー認証やTLSは今回設定していません。
Host/CORSチェックはユーザー認証や送信元IP制限ではありません。LAN以外へ公開する場合は別途アクセス制御が必要です。
復旧用S3 probeとMLflow test runは `scripts/smoke-test.sh` で作成します。
