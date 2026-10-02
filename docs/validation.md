# 構築・検証記録

確認日: 2026-10-03 JST。

## 変更前

- Ubuntu Server 26.04.1 LTS / kernel 7.0.0-38-generic、hostname `ubuntu-infra`。
- KVM / Proxmox VM、4 vCPU、メモリ約5.2GiB、128GB disk、root約100GB空き。
- `ens18` は192.168.0.8/24、default gatewayは192.168.0.1。既存SSH22を維持。
- qemu-guest-agentはactive、Dockerは未導入。
- repoは既存の空Git repository（main、commitなし、remoteなし）。既存アプリファイルなし。
- `/srv/homelab` は存在せず、5000/8333/3001/5432の既存listenerなし。
- sudoは対話認証が必要。自動処理では `sudo -n` が利用不可。
- この構築処理によるSSH・Netplan・firewall・router・Proxmoxの設定変更は未実施。

## 設定の確認

- 公式GitHub release APIでSeaweedFS4.48・MLflow3.16.1・Kuma2.5.5がprereleaseでないことを確認。
- PostgreSQL公式versioningで18.6が現行stable minorであることを確認。
- Docker Hub/GHCR manifestで全固定tagとlinux/amd64の実在を確認。
- image configでPostgreSQL18のPGDATA、SeaweedFS mini entrypoint、Kuma内蔵healthcheckを確認。
- MLflow追加依存のversion・依存関係・wheel hashを公式PyPIで確認。
- `.env` はランダムなpassword/secretを0600で作成し、Git ignoreを確認。秘密値を出力していない。
- 全shell scriptの `bash -n` とShellCheck 0.11.0、および全Pythonソースの構文確認が成功。
- 公式Compose v5.6.0をチェックサム検証後に一時利用し、両Composeの `config --quiet` が成功。
- 展開済みComposeをメモリ内で検査し、LAN IP bind、DB非公開、internal DB network、bind mount保存先、非root/capability/log設定を確認。
- Git対象候補の全ファイルをscanし、生成した実secretが含まれないことを確認。

## 実行検証

管理者による `scripts/provision-host.sh` 実行後、Docker Engine Community 29.8.2 / Compose 5.6.0を確認しました。
公式APT repositoryのsuiteはresoluteで、Docker/containerdはenabled・activeです。
mdyのdockerグループ追加を確認し、既存セッションでは `sg docker` でsudoなしのversion/compose/psを検証しました。
SSH再接続後は通常の `docker` コマンドへグループ追加が反映されます。

| 検証 | 状態 |
| --- | --- |
| Docker version / Compose version / docker ps（sudoなし） | 成功（初回はsg docker、再起動・再接続後は通常のdockerで成功） |
| 両Composeのconfig検証 | 成功（デーモン未導入でも実施可能な構文検査） |
| MLflow image build / pip check | 成功、追加依存のhash確認・importも成功 |
| PostgreSQL healthy / MLflow SQL接続 / LAN5432非公開 | 成功、実際のPortBindingsなし・LAN IPへのTCP接続失敗 |
| SeaweedFS healthy / unsigned S3拒否 / signed CRUD / bucket | 成功、未署名list/read/write拒否、内部endpointとLAN IP endpointでCRUD成功 |
| MLflow HTTP / experiment / param / metric / artifact / SQLとS3照合 | 成功、SQLのruns/params/metricsとS3実object内容を照合 |
| Uptime Kuma HTTP / health | 成功、SQLiteのkuma.db/db-config.jsonを初期化、管理者設定は初回UIで実施 |
| owner/permission、実際の公開portと安全設定 | 成功、全service非root・capability全削除・socket mountなし |
| backup作成・checksum・dump読み取り・サービス復帰 | 成功、最終SQLiteを含む全data/config、0700/0600、停止・再開後のrun/objectも確認 |
| daemon再起動後の自動復旧・既存run/object永続化 | 成功（03:20 JST、journalとdaemon-restart-passed・smoke結果を確認） |
| VM reboot後の自動復旧・既存run/object永続化 | 初回はLAN公開復元失敗。手動復旧後のデータ永続化は成功。起動待機対策を準備し、再検証待ち |
| 別LAN端末からの到達 | 未実施 |
| 別ストレージからの完全restore演習 | 未実施 |

## 起動中コンテナと公開port

| コンテナ | image tag | health | ホストへ公開 |
| --- | --- | --- | --- |
| homelab-ml-platform-postgres-1 | postgres:18.6-bookworm | healthy | なし |
| homelab-ml-platform-seaweedfs-1 | chrislusf/seaweedfs:4.48 | healthy | 192.168.0.8:8333/tcp |
| homelab-ml-platform-mlflow-1 | homelab/mlflow:3.16.1-r3 | healthy | 192.168.0.8:5000/tcp |
| homelab-monitoring-uptime-kuma-1 | louislam/uptime-kuma:2.5.5 | healthy | 192.168.0.8:3001/tcp |

イメージに記載されたEXPOSE portはDocker内部の表示であり、master/filer/volume portをホストにpublishしていません。
ssでも新規listenerは上記3つのみを確認しました。既存SSH・エディタのloopback listenerは維持しています。

## 検証用の永続データとbackup

- 最終検証experiment ID: `2`。
- run ID: `2982be483d5c45c68c8859bcc28ee5c2`。
- param: `source=homelab-smoke`、metric: `score=1.0`。
- artifact: `2/2982be483d5c45c68c8859bcc28ee5c2/artifacts/probe.txt`。
- S3永続probe: `homelab-validation/persistence/2982be483d5c45c68c8859bcc28ee5c2.txt`。
- bucket: `mlflow-artifacts`。
- 最終backup: `/srv/homelab/backups/20261002T190913Z.KclGiD`（snapshot名はUTC）。
- 初回backupはKumaのDB初期化前の状態です。対策前の `/srv/homelab/backups/20261002T180451Z.IdqlKs` はSQLiteと最終Compose設定を含みます。
- 最終backupは再起動後の復旧データとIPv4待機helper/systemd drop-inも含み、全checksum・0700/0600・実.envの一致を再確認しました。
- 最終backupのCOMPLETE、checksum、SQL dump TOC、SeaweedFS全data、Kuma SQLite、config/.envの一致、owner-only権限を確認しました。
- backupのための停止・再開、およびMLflowコンテナ再作成後も既存runとS3データが残ることを確認しました。
- 同一SSD内のコピーなので、独立した場所へのバックアップと復元演習は今後の作業です。

MLflowのデフォルトGenAI job executionが複数のconsumerを起動し、1GiB上限への到達とswap使用を確認しました。
今回使わないjob executionを無効化した後、MLflowは約414MiBで、最終コンテナにOOM killはありません。
HTTP workerは1です。将来GenAI非同期jobを有効化する場合はconsumer数とメモリを再設計します。

## 初回VM再起動で判明した問題と対策

初回VM再起動前boot IDは `b7d9eb70-05b1-4713-924e-31c08d0abfcb`。
03:20 JSTのDocker daemon再起動は自動復旧・同一runのSQL/S3検証に成功しました。
しかし続くVM起動時、systemd-networkdはDHCPから192.168.0.2を取得し、03:20:47のDockerログにLAN3portの `cannot assign requested address` が記録されました。
network-online.target到達だけでは指定の192.168.0.8の存在を保証できないことが実環境で判明しました。

再接続時のboot IDは `fdc1b938-5db8-45af-9665-fda219165fad`。現在のIPv4は192.168.0.8です。
Docker/containerdはenabled・active、PostgreSQLはhealthyでしたが、SeaweedFS/Kumaの実networkと公開portがなく、MLflowもartifacts networkを失っていました。
03:54起動時のDockerはDB networkだけを復元しており、再起動前の公開network attachmentは戻っていませんでした。
この状態を自動復旧成功とは判定していません。

PostgreSQLを保持し、SeaweedFS・MLflow・KumaをComposeから再作成したところ、4serviceがhealthy、LAN3portが復旧しました。
既存run `2982be483d5c45c68c8859bcc28ee5c2` のSQL param/metric、MLflow artifact取得、S3の実objectと永続probe内容は全て一致しました。
未署名S3のlist/read/write拒否も再確認しました。データ消失は検出していません。

Dockerだけに適用するIPv4待機helperとsystemd drop-inを作成しました。
IP存在時の成功、不在時のタイムアウト、不正timeoutの拒否、全shellのbash構文/ShellCheck、両Composeのconfig検査が成功しました。
healthcheckはHostConfigの設定値に加え、NetworkSettingsの実公開portとnetwork attachmentも検査します。
対策のroot所有ファイルへの導入と、その状態でのdaemon/VM再起動は管理者による検証スクリプト実行待ちです。
再起動後の初回検証では `start/up` を使わず、boot ID・同一container ID・公開network・既存データを確認します。

## 作成したファイル

以下29ファイルをローカルGitで管理します。remote設定・pushは実施していません。

```text
.gitignore
README.md
compose/ml-platform/.dockerignore
compose/ml-platform/.env.example
compose/ml-platform/Dockerfile
compose/ml-platform/README.md
compose/ml-platform/compose.yml
compose/ml-platform/entrypoint.py
compose/ml-platform/healthcheck.py
compose/ml-platform/requirements.lock
compose/monitoring/README.md
compose/monitoring/compose.yml
docs/architecture.md
docs/networking.md
docs/operations.md
docs/validation.md
scripts/README.md
scripts/backup.sh
scripts/common.sh
scripts/healthcheck.sh
scripts/install-boot-readiness.sh
scripts/provision-host.sh
scripts/smoke-test.py
scripts/smoke-test.sh
scripts/start.sh
scripts/wait-healthy.sh
scripts/wait-lan-ip.sh
scripts/verify-restart-and-reboot.sh
systemd/docker.service.d/20-homelab-lan-ip.conf
```

別途 `compose/ml-platform/.env` を作成していますが、0600・Git除外です。
`/tmp/homelab-validation` のCompose/ShellCheckは検証用の一時ツールで、システムへインストールしていません。
