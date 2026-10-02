# ubuntu-infra homelab

Proxmox上のUbuntu VM `ubuntu-infra` を、自宅LAN向けの軽量インフラホストとして管理します。
PostgreSQL・MLflow・SeaweedFSを `ml-platform`、Uptime Kumaを `monitoring` の独立したComposeプロジェクトで運用します。
ゲームサーバー、Home Assistant、Cloudflare Tunnel、Prometheus/Grafanaは含みません。

| サービス | URL / 接続先 | 用途 |
| --- | --- | --- |
| MLflow | http://192.168.0.8:5000 | UI・Tracking API・artifact代理転送 |
| SeaweedFS S3 | http://192.168.0.8:8333 | 署名付きS3 API |
| Uptime Kuma | http://192.168.0.8:3001 | 稼働監視・初回管理者設定 |
| PostgreSQL | `postgres:5432` / Docker内部のみ | MLflow metadata |

MLflowからの接続は `postgres:5432` と `http://seaweedfs:8333` を使います。
クライアントは `MLFLOW_TRACKING_URI=http://192.168.0.8:5000` だけでartifactも操作できます。
イメージは検証済みの安定版タグとdigestで固定し、MLflow追加依存はバージョンとSHA256で固定しています。
採用版と公式情報は [architecture.md](docs/architecture.md)、構築・検証の実績は [validation.md](docs/validation.md) を参照してください。

## ディレクトリ

```text
/home/mdy/homelab/                 # Git管理する設定
├── compose/
│   ├── ml-platform/               # compose.yml, Dockerfile, Python設定, lock
│   │   ├── .env                  # 実secret・Git除外・0600
│   │   └── .env.example          # 変数名だけ・Git管理
│   └── monitoring/               # Uptime Kumaのみ
├── scripts/                      # 導入・起動・検証・バックアップ
├── docs/                         # 設計・ネットワーク・運用・検証
├── .runtime/                     # 検証run IDなど・Git除外
├── .gitignore
└── README.md

/srv/homelab/                     # 実データ・Gitの外
├── postgres/data/18/docker/      # PostgreSQL 18 PGDATA、UID 999、0700
├── seaweedfs/data/               # volumes・filer metadata・設定、UID 1000、0700
├── uptime-kuma/data/             # SQLite・設定、UID 1000、0700
└── backups/                     # 初期の一時バックアップ先、mdy、0700
```

## 初期構築

VMを確認したうえで作成した [provision-host.sh](scripts/provision-host.sh) は、Docker公式APTリポジトリを登録し、Engine・Compose・Buildxを導入します。
データ用ディレクトリを作成し、Dockerを自動起動させ、`mdy` をdockerグループに追加します。
既存データの所有権は変更せず、既存の競合パッケージがあれば停止します。

```bash
cd /home/mdy/homelab
sudo bash scripts/provision-host.sh
# いったんSSHをログアウトして再接続し、グループ追加を反映
docker version
docker compose version
docker ps
./scripts/start.sh
./scripts/smoke-test.sh
```

再ログイン前は `sg docker -c '/home/mdy/homelab/scripts/start.sh'` でも実行できます。
Dockerグループはホスト上でroot相当の操作権限を持つため、信頼するユーザーだけを追加します。
初期 `.env` は安全な乱数から作成済みです。別ホストでは `.env.example` をコピーし、DB名・ユーザー名・十分長いsecretと `MLFLOW_ARTIFACT_BUCKET=mlflow-artifacts` を設定します。

## 起動・停止・ログ

```bash
cd /home/mdy/homelab
./scripts/start.sh
./scripts/healthcheck.sh
docker compose -f compose/ml-platform/compose.yml logs --tail=100 -f
docker compose -f compose/monitoring/compose.yml logs --tail=100 -f
# 一時停止（明示的に停止したコンテナはVM再起動だけでは復旧しません）
docker compose -f compose/ml-platform/compose.yml stop
docker compose -f compose/monitoring/compose.yml stop
# 再開
./scripts/start.sh
```

`down` でコンテナを削除してもbind mountの実データは残りますが、次のVM起動ではコンテナが存在せず自動復旧しません。
通常の運用はコンテナを起動したままにします。`unless-stopped` とDockerのsystemd自動起動により復旧します。
ログは各コンテナ最大10MB × 3ファイルに制限します。

## 更新

1. `./scripts/backup.sh` を実行し、別ストレージへコピーして復元できることを確認。
2. 公式リリースとDocker registryで新しいstableタグ・digestを確認。
3. Composeのタグ/digest、MLflow Dockerfileのbase digest、必要に応じて依存lockを更新。
4. `docker compose -f compose/ml-platform/compose.yml pull postgres seaweedfs` と `docker compose -f compose/monitoring/compose.yml pull` を実行。
5. `./scripts/start.sh` と `./scripts/smoke-test.sh` で確認してGitへ記録。

PostgreSQLのmajor更新は単なるタグ変更で済みません。dump/restoreまたは `pg_upgrade` を別途計画します。
MLflow・KumaのDB schema migration後に古いイメージへ戻す場合も、対応するバックアップの復元が必要です。
自動イメージ更新は設定していません。詳しくは [operations.md](docs/operations.md)。

## バックアップとsecret

```bash
./scripts/backup.sh
# 独立したSSD/HDDを用意した後
BACKUP_DIR=/mnt/backup/homelab ./scripts/backup.sh
```

**同一SSD内のコピーは本当のバックアップではありません。** 現在の `/srv/homelab/backups` は誤操作から戻すための一時コピーです。
`backup.sh` はMLflow・SeaweedFS・Kumaを短時間停止し、PostgreSQL dump、SeaweedFSの全 `/data`、Kumaの全 `/app/data`、Compose/configを保存して再開します。
バックアップは `.env` も含むため、フォルダ0700・ファイル0600で保護し、独立ストレージへ暗号化して保管してください。
自動スケジュール、削除ポリシー、別ディスクへのmount設定は今回まだ作成していません。

`.env`・検証出力・dump・アーカイブはGitから除外します。`.dockerignore` でも `.env` をbuild contextから除外します。
secretを表示する `docker compose config` や `docker inspect` の全出力をそのまま共有しないでください。構文検証には `config --quiet` を使います。
新しい `.env` を設定しても既存PostgreSQLのpasswordは自動変更されません。SeaweedFSも永続化された認証情報との整合を確認して変更します。
このリポジトリにはremoteを設定せず、GitHubへpushしません。

## トラブルシューティング

| 症状 | 確認・対応 |
| --- | --- |
| `docker: command not found` | 管理者権限で `provision-host.sh` を実行 |
| Docker socket permission denied | SSH再接続、`id` のdockerグループを確認、または `sg docker -c 'docker ps'` |
| bind mountのpermission denied | UID・permissionを確認。PostgreSQLは999、他のデータは1000。既存データを一律chmod/chownしない |
| `Cannot assign requested address` | `ip -4 addr` で192.168.0.8を確認。Netplan/ルーターの変更は別途判断 |
| MLflow起動待ち | PostgreSQL・SeaweedFS healthとログを確認。起動時はSQL認証とS3 bucketを待機 |
| MLflow Host/CORS拒否 | 指定のURLを利用。別のLAN hostnameを使う場合はallowed-hosts/originsへ限定的に追加 |
| S3の403 | 未署名リクエストの403は正常。 `.env` のcredentialで署名し、endpointとpath-styleを確認 |
| restart後に戻らない | Dockerがenabledか、直前に `stop/down` していないか確認 |
| 容量不足・OOM | `df -h`、`free -h`、`docker stats --no-stream`、`docker inspect --format '{{.State.OOMKilled}}' <container>` を確認 |

LAN上の別端末からの到達確認、Kumaの管理者作成、独立したバックアップ先の用意は [operations.md](docs/operations.md) を参照してください。
