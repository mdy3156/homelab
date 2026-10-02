# アーキテクチャ

```mermaid
flowchart LR
    LAN[LAN clients] -->|192.168.0.8:5000 HTTP| ML[MLflow]
    LAN -->|192.168.0.8:8333 signed S3| SW[SeaweedFS weed mini]
    LAN -->|192.168.0.8:3001 HTTP| UK[Uptime Kuma]
    ML -->|postgres:5432 metadata| PG[PostgreSQL]
    ML -->|seaweedfs:8333 artifacts| SW
    PG --> PD[/srv/homelab/postgres/data]
    SW --> SD[/srv/homelab/seaweedfs/data]
    UK --> KD[/srv/homelab/uptime-kuma/data]
```

`homelab-ml-platform` のdatabase networkは `internal: true` で、PostgreSQLとMLflowだけを接続します。
artifacts bridgeにはMLflowとSeaweedFSだけを接続します。MLflowはDBとS3へDockerのservice DNSで接続し、ホストIPを経由しません。
`homelab-monitoring` は専用bridgeを持ち、KumaがLANの公開HTTP endpointを監視できます。
固定のbridge subnetは指定せず、DockerのIPAMを利用します。

## 固定バージョンと確認元

2026-10-03 JSTに、公式リリース情報とDocker Hub/GHCR manifestを直接確認しました。
いずれもstableリリースでlinux/amd64 manifestが実在します。
タグとdigestの組み合わせはComposeとDockerfileに記録しています。

| サービス | 固定image | 公式情報 |
| --- | --- | --- |
| PostgreSQL | `postgres:18.6-bookworm` | [versioning](https://www.postgresql.org/support/versioning/)、[公式Docker image](https://hub.docker.com/_/postgres) |
| SeaweedFS | `chrislusf/seaweedfs:4.48` | [4.48 release](https://github.com/seaweedfs/seaweedfs/releases/tag/4.48)、[公式README](https://github.com/seaweedfs/seaweedfs) |
| MLflow base | `ghcr.io/mlflow/mlflow:v3.16.1` | [3.16.1 release](https://github.com/mlflow/mlflow/releases/tag/v3.16.1)、[公式image](https://mlflow.org/docs/2.22.0/docker) |
| Uptime Kuma | `louislam/uptime-kuma:2.5.5` | [2.5.5 release](https://github.com/louislam/uptime-kuma/releases/tag/2.5.5)、[install](https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install) |

MLflow派生imageのローカルtagは `homelab/mlflow:3.16.1-r3`。
base imageに内包されるPython依存はbase digestで固定します。
追加する `psycopg2-binary`・`boto3` とその依存は公式PyPI wheelのversion/hashを `requirements.lock` に固定しました。
psycopg2 wheelはこのVM向けのCPython 3.11 / Linux amd64です。他architectureへ移植する場合は対応wheelのhashを再確認します。
build時の `pip check` によりbaseとの依存競合を検出します。

## 保存と復旧

MLflowはmetadataをSQLAlchemy PostgreSQL backendへ、artifactをS3互換APIへ保存します。
[MLflow tracking server](https://mlflow.org/docs/latest/self-hosting/architecture/tracking-server/) のartifact proxy方式を使い、クライアントにS3 secretを配布しません。
endpointは [S3-compatible artifact store](https://mlflow.org/docs/latest/self-hosting/architecture/artifact-store/) の `MLFLOW_S3_ENDPOINT_URL` で指定します。
大きいartifactの直接multipart転送は無効にし、常にMLflow経由で転送します。

SeaweedFSは [公式mini手順](https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini) に沿い、AWS credential環境変数で認証を有効化し、`S3_BUCKET` でbucketを作成します。
miniはsingle-nodeのmaster・volume・filer・S3をまとめます。blobとfiler metadataの両方が `/data` に永続化されます。
WebDAV・Iceberg・Lance・Admin UIは無効にし、miniが必要とする内部処理と管理portはホストへpublishしません。
認証・S3 CRUD・MLflow proxyとの実際の互換性はsmoke testで確認します。

全serviceは `unless-stopped`。Dockerはsystemdでenabledにします。
DockerのExecStartPreで公開portのbind先192.168.0.8を待ちます。一般のnetwork-online.targetだけでは、そのIPv4の存在を保証できません。
helperは `/usr/local/libexec/homelab-wait-lan-ip`、設定は `/etc/systemd/system/docker.service.d/20-homelab-lan-ip.conf` へroot所有で導入します。
120秒でアドレスが得られなければDockerの起動を失敗させ、既存systemd restart設定により再試行します。
Composeの起動時依存順はdaemon再起動時には保証されないため、MLflow entrypointは毎回SQL/S3を待機します。
healthcheck failureだけではDockerは自動再起動しません。プロセス終了時のrestart policyと、異常検知後の運用対応を区別します。

## リソースと権限

VMは4 vCPU、メモリ実測約5.2GiB、128GBディスク（構築前約100GB空き）。
コンテナのメモリ上限はPostgreSQL768MiB、SeaweedFS768MiB、MLflow1024MiB、Kuma384MiB。
これは確保量ではなく上限です。ホスト上のエディタ等と競合するため、運用時に `docker stats` と `free -h` を確認します。
CPU上限は順に1・1・1.5・0.5 CPUです。
MLflowは小規模LAN運用向けに1 HTTP workerを使用します。
MLflow 3.16のデフォルトjob executionは複数のGenAI job consumerを起動するため、`MLFLOW_SERVER_ENABLE_JOB_EXECUTION=false` で無効化します。
今回のexperiment・param・metric・artifact保存には不要で、実測で1GiB上限への到達とswapが発生したためこの設定を採用しました。
GenAIの非同期jobを使う場合は、必要なメモリとconsumer構成を別途設計して有効化します。

PostgreSQLはUID999、他はUID1000で実行し、capabilityを全削除します。
`no-new-privileges`、各serviceの10MB × 3のlog rotationを設定します。
privileged、host network、Docker socket mountは使いません。
HA構成ではなく、VMまたはSSD故障時には全serviceが停止します。独立ストレージへのバックアップが必要です。
