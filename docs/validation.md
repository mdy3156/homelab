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
再起動・SSH再接続後は通常の `docker` コマンドでversion/compose/psを実行でき、mdyのdockerグループ反映を確認しました。

| 検証 | 状態 |
| --- | --- |
| Docker version / Compose version / docker ps（sudoなし） | 成功（初回はsg docker、再起動・再接続後は通常のdockerで成功） |
| 両Composeのconfig検証 | 成功（デーモン未導入でも実施可能な構文検査） |
| MLflow image build / pip check | 成功、追加依存のhash確認・importも成功 |
| PostgreSQL healthy / MLflow SQL接続 / LAN5432非公開 | 成功、実際のPortBindingsなし・LAN IPへのTCP接続失敗 |
| SeaweedFS healthy / unsigned S3拒否 / signed CRUD / bucket | 成功、未署名list/read/write拒否、内部endpointとLAN IP endpointでCRUD成功 |
| MLflow HTTP / experiment / param / metric / artifact / SQLとS3照合 | 成功、SQLのruns/params/metricsとS3実object内容を照合 |
| MLflow Start Demo / trace・評価 / 再操作 | 成功、修正後はHTTP200・約3.57秒で完了、再操作はexists・約0.06秒 |
| Uptime Kuma HTTP / health | 成功、SQLiteのkuma.db/db-config.jsonを初期化、管理者設定は初回UIで実施 |
| owner/permission、実際の公開portと安全設定 | 成功、全service非root・capability全削除・socket mountなし |
| backup作成・checksum・dump読み取り・サービス復帰 | 成功、最終SQLiteを含む全data/config、0700/0600、停止・再開後のrun/objectも確認 |
| daemon再起動後の自動復旧・既存run/object永続化 | 成功（03:20 JSTと対策適用後04:23 JST、journalとdaemon-restart-passed・smoke結果を確認） |
| VM reboot後の自動復旧・既存run/object永続化 | 成功（対策適用後04:24 JST起動、同一4コンテナが自動復旧、SQL/S3内容一致。初回失敗の経緯は下記） |
| 別LAN端末からの到達 | 未実施 |
| 別ストレージからの完全restore演習 | 未実施 |

## 起動中コンテナと公開port

| コンテナ | image tag | health | ホストへ公開 |
| --- | --- | --- | --- |
| homelab-ml-platform-postgres-1 | postgres:18.6-bookworm | healthy | なし |
| homelab-ml-platform-seaweedfs-1 | chrislusf/seaweedfs:4.48 | healthy | 192.168.0.8:8333/tcp |
| homelab-ml-platform-mlflow-1 | homelab/mlflow:3.16.1-r4 | healthy | 192.168.0.8:5000/tcp |
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
- 最終backup: `/srv/homelab/backups/20261002T210520Z.Nx445f`（snapshot名はUTC、Start Demo修正・生成後の状態）。
- 初回backupはKumaのDB初期化前の状態です。対策前の `/srv/homelab/backups/20261002T180451Z.IdqlKs` はSQLiteと最終Compose設定を含みます。
- `/srv/homelab/backups/20261002T190913Z.KclGiD` はVM再起動後の復旧データとIPv4待機helper/systemd drop-inを含みます。
- `/srv/homelab/backups/20261002T205009Z.poqS8H` はStart Demo修正中の、telemetry設定変更前の状態を保存しています。
- 最終backupはr4 image用のCompose設定・artifactプラグインとデモ生成後のSQL/S3データを含み、全checksum・0700/0600・実.envの一致を再確認しました。
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

不具合調査時のboot IDは `fdc1b938-5db8-45af-9665-fda219165fad`。この時点のIPv4は192.168.0.8でした。
Docker/containerdはenabled・active、PostgreSQLはhealthyでしたが、SeaweedFS/Kumaの実networkと公開portがなく、MLflowもartifacts networkを失っていました。
03:54起動時のDockerはDB networkだけを復元しており、再起動前の公開network attachmentは戻っていませんでした。
この状態を自動復旧成功とは判定していません。

PostgreSQLを保持し、SeaweedFS・MLflow・KumaをComposeから再作成したところ、4serviceがhealthy、LAN3portが復旧しました。
既存run `2982be483d5c45c68c8859bcc28ee5c2` のSQL param/metric、MLflow artifact取得、S3の実objectと永続probe内容は全て一致しました。
未署名S3のlist/read/write拒否も再確認しました。データ消失は検出していません。

Dockerだけに適用するIPv4待機helperとsystemd drop-inを作成しました。
IP存在時の成功、不在時のタイムアウト、不正timeoutの拒否、全shellのbash構文/ShellCheck、両Composeのconfig検査が成功しました。
healthcheckはHostConfigの設定値に加え、NetworkSettingsの実公開portとnetwork attachmentも検査します。

## 対策適用後のdaemon・VM再起動検証

管理者が `verify-restart-and-reboot.sh` を実行し、helperをroot:root/0755、systemd drop-inをroot:root/0644で導入しました。
インストール先の実ファイルとrepoの内容が一致することを確認しました。
04:23:53 JSTのdaemon再起動時は、IPv4確認の成功ログ後にdockerdが起動し、04:24:06に既存run/objectの検証が成功しました。
続くVM再起動の前後でboot IDが以下のように変わりました。

- 再起動前: `fdc1b938-5db8-45af-9665-fda219165fad`。
- 再起動後: `0fe8d6a5-104f-43ac-876b-c899ea542761`。

VM起動ログは04:24:22 JSTに指定IPv4の確認成功、04:24:23にdockerd起動と全networkへの再接続を記録しています。
LAN3portのbind失敗やコンテナ起動失敗は再発していません。
Docker/containerdはenabled・activeで、4コンテナのIDは再起動前のbaselineと完全に一致しました。
各コンテナのStartedAtはこのVM起動直後で、全serviceがhealthy、OOM killなしです。
再接続後にコンテナの `start/up/recreate` を実行せず、`wait-healthy.sh` による読み取り確認で正常化を確認しました。

実際のLAN公開は192.168.0.8の5000/8333/3001のみで、PostgreSQL5432は非公開です。
MLflowのdatabase/artifacts、SeaweedFSのartifacts、Kumaのmonitoring network attachmentを実状態で確認しました。
再起動前の同一runでSQL param/metric、MLflow経由のartifact取得、S3実object・永続probeを照合し、全て一致しました。
未署名S3の拒否、KumaのHTTPと永続SQLite/db-configファイルも確認しました。
非secretの確認結果はGit除外の `.runtime/reboot-validation.json` に保存します。

検証後のホストはroot filesystem約94GiB空き、メモリavailable約2.8GiB、swap使用0でした。
別LAN端末からの到達確認、Kuma管理者の初回作成、独立ストレージへのバックアップと完全restore演習は今後の作業です。

## Start Demoの待機とartifact解決の修正

通常のtracking検証後、ユーザーのStart Demo操作で画面が待機したため、ボタンと同じ生成APIを調査しました。
MLflow本体はhealthyで、HTTP・通常のexperiment APIは応答していましたが、デモの評価処理が完了していませんでした。
scorerのtelemetry処理がjob関連モジュールを並列importし、スレッドのスタックにimport lockの待機を確認しました。
加えて、サーバー内部SDKがSQL tracking URIでproxy artifact URIを扱うと、HTTP tracking URIを要求するエラーが発生していました。

telemetryを公式設定で無効化し、ローカル評価workerを2に制限しました。
サーバー内部だけでproxy URIを実S3保存先へ解決するartifact repositoryプラグインを追加し、通常のHTTPクライアントは標準のproxy動作を維持しています。
image buildで6件の回帰テストとpip checkが成功しました。データの削除やDBの初期化は行っていません。

- `POST /ajax-api/3.0/mlflow/demo/generate` がHTTP200、約3.57秒で完了しました。
- 再操作はHTTP200・`exists`、約0.06秒で既存のexperiment `3` を返しました。
- 元の42件のtrace payloadとspanを取得でき、3件の評価runがFINISHED、各runに4件のmetricを確認しました。
- 内部artifactプラグインを実S3接続で検証し、upload/list/download/deleteが成功しました。検証で作成した一時objectだけを削除しました。
- 既存の通常run `2982be483d5c45c68c8859bcc28ee5c2` のSQL param/metric、HTTP経由のartifactとS3実objectも一致しました。
- 最終backupによる停止・再開後も4serviceがhealthyで、通常runの永続化検証が成功しました。Start Demoは約0.12秒で既存デモを返しました。
- 修正後のMLflowコンテナはOOM killなし、restart count 0で、以前のartifact URIエラーは再発していません。

非secretの検証記録をGit除外の `.runtime/demo-validation.json` に0600で保存しています。
VM全体の再起動検証は上記r3 image時の結果です。r4 imageでは最終backup時のコンテナ停止・再開を検証しました。
今回の修正でSSH・ネットワーク・Dockerの起動待機設定は変更していません。

## 作成したファイル

以下32ファイルをローカルGitで管理します。remote設定・pushは実施していません。

```text
.gitignore
README.md
compose/ml-platform/.dockerignore
compose/ml-platform/.env.example
compose/ml-platform/Dockerfile
compose/ml-platform/README.md
compose/ml-platform/artifact-proxy/homelab_artifact_proxy.py
compose/ml-platform/artifact-proxy/pyproject.toml
compose/ml-platform/artifact-proxy/test_artifact_proxy.py
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
