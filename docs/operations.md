# 運用手順

## 日常確認

```bash
cd /home/mdy/homelab
docker version
docker compose version
docker ps
./scripts/healthcheck.sh
docker stats --no-stream
df -h / /srv/homelab
free -h
```

各スタックのREADMEに起動・停止・ログ手順を記載しています。
全コンテナのhealthと実際の公開portを確認し、Kuma UIでMLflow HTTPとS3 HTTPを監視します。
Kumaは初回UIで管理者アカウントを作成してください。初回のセットアップ画面はLANから利用可能です。
署名付きS3・SQLを含む稼働確認はMLflowコンテナのhealthcheckが行います。

## バックアップ

`./scripts/backup.sh` はアプリを短時間停止します。SeaweedFSへ直接アクセスするクライアントもこの間利用できません。
PostgreSQLは起動を保ち、MLflowを停止してmetadataへの書き込みを止め、custom-format dumpを作成します。
SeaweedFSは全 `/data`、Kumaは全 `/app/data` を停止状態でコピーします。
これによりblobだけのコピーや稼働中SQLiteの不整合を避けます。
設定アーカイブには `.env` を含みます。dumpも機密データを含み得ます。

**同一SSD内のコピーは本当のバックアップではありません。** 初期先は `/srv/homelab/backups` ですが、独立ストレージを用意したら `BACKUP_DIR` を変更します。
mount設定や自動スケジュールは未実施です。バックアップ元・先の空き容量と同一物理ディスクでないことを確認してください。
`COMPLETE` と `SHA256SUMS` を確認し、暗号化してVM外へコピーします。容量不足を避けるため保管数を運用者が管理します。

```bash
BACKUP_DIR=/mnt/backup/homelab ./scripts/backup.sh
cd /mnt/backup/homelab/<snapshot>
test -f COMPLETE
sha256sum -c SHA256SUMS
```

## 復元（既存データへの上書き前に退避が必要）

復元先VMで同じ設定・imageを用意し、Dockerを導入します。
以下は手順の説明です。稼働中の実データに自動実行するスクリプトは作成していません。

1. 保存済みsnapshotのchecksumを確認。安全な作業場所でconfig archiveを展開し、`.env` を0600で復元。
2. 両スタックを停止。現在の `/srv/homelab/.../data` を別名へ退避し、復元用の空ディレクトリを正しいowner/permissionで作成。既存データへtarを重ねない。
3. 管理者権限で `seaweedfs.tar.gz` をSeaweedFS dataへ、`uptime-kuma.tar.gz` をKuma dataへ展開。 `docker cp` のtarは親が `.` なので、archive内容を `tar -tzf` で確認してから指定先へ展開。
4. SeaweedFS/KumaデータはUID1000にし、owner-only権限を維持。PostgreSQLは空の `data/18/docker` をUID999で用意。
5. PostgreSQLだけを `docker compose -f compose/ml-platform/compose.yml up -d postgres` で起動し、healthyを待つ。元と同じPOSTGRES_USER/DBで初期化する。
6. 次のコマンドでdumpを復元。 `--no-owner --no-acl` のdumpなので、ロール再作成は `.env` の初期ユーザーで行う。

```bash
docker compose -f compose/ml-platform/compose.yml exec -T postgres sh -c \
  'pg_restore --exit-on-error --no-owner --no-acl -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < /path/to/snapshot/postgres.dump
```

7. `./scripts/start.sh`、`./scripts/healthcheck.sh`、`./scripts/smoke-test.sh --verify <保存済みRUN_ID>` を実行し、元run・artifact・S3 probe・Kuma設定の復元を確認。

config archiveだけでは派生Docker image自体は保存しません。公式registry/PyPIから固定digest/hashで再buildします。
将来オフライン復旧が必要なら `docker save` と依存wheel保管を追加してください。
checksumとdumpの読み取り成功だけで完全な復元を証明したことにはなりません。独立した場所で復元演習を行ってください。

## 再起動検証

新規runを作成してIDを記録したあと、全serviceがrunningであることを確認します。
VM再起動はSSH・エディタ・このセッションを切断します。再接続後に以下を実行します。

```bash
systemctl is-enabled docker containerd
cat /proc/sys/kernel/random/boot_id
./scripts/healthcheck.sh
./scripts/smoke-test.sh --verify <再起動前RUN_ID>
```

daemon再起動は `sudo systemctl restart docker`、VM再起動は `sudo reboot` です。
初回構築では、記録済み `.runtime/restart-baseline.json` を使い、`sudo bash scripts/verify-restart-and-reboot.sh` でdaemonの自動復旧と既存データを検証してからVMを再起動できます。
このスクリプトは既存コンテナの `start/up` を実行せず、restart policyによる自動復旧を検査します。
再接続後は `./scripts/wait-healthy.sh` で状態だけを待ち、保存済みrun IDのsmoke verifyを実行してください。
再起動後の初回確認では `start.sh` を先に実行しないでください。自動復旧を検証できなくなります。
Kumaの起動と既存dataも確認します。
実施状況は [validation.md](validation.md) に記録し、daemon再起動・container再作成・VM再起動を区別します。

## 更新とsecret変更

更新前に独立したバックアップを確保し、release notesと互換性を確認します。
stable tagとdigestを一緒に更新し、MLflowの追加依存hashも公式PyPIで確認します。
`pull` だけではdigestを固定したimageは更新されません。設定変更後にbuild/upと検証を行います。
PostgreSQL major更新、MLflow/Kuma migrationのrollbackはbackupからの復元を計画します。

`.env` の変更は単純なpassword rotationにはなりません。
PostgreSQLの既存ロールpasswordはSQLで変更し、接続側の `.env` を合わせてMLflowを再作成します。
SeaweedFSは既存の永続化credentialへの反映方法を該当版の公式手順で確認し、旧credentialが拒否されることまで検証します。
secretをコマンドライン・shell history・Git・公開ログに出さない方法で実施してください。

## 今後の追加

FastAPIやBotは独立したComposeプロジェクトとして追加できます。
DB/S3が必要な場合は専用DB・ユーザー・bucket・限定credentialを設計し、MLflowの管理用credentialを共有しないようにします。
Prometheus/Grafanaは必要になった時点で監視要件とメモリを評価して追加します。
このrepoへゲームサーバー、Home Assistant、Cloudflare Tunnelは追加しません。
