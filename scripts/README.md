# 運用スクリプト

| ファイル | 操作 | 権限 / 注意 |
| --- | --- | --- |
| `provision-host.sh` | Docker公式版導入・IPv4起動待機・自動起動・mdyグループ追加・保存先作成 | sudo必須、既存データ・競合パッケージを上書きしない |
| `install-boot-readiness.sh` | Docker起動前のIPv4確認helperとsystemd drop-inを導入 | sudo必須、既存の異なるファイルは上書きしない、Docker再起動は行わない |
| `wait-lan-ip.sh` | 指定IPv4の存在を待機（default 192.168.0.8 / 120秒） | 読み取り専用、root所有のhelperとして導入 |
| `start.sh` | 固定imageからMLflowをbuildし両スタックを起動、health待機 | dockerグループ |
| `healthcheck.sh` | 全health、HTTP、未署名S3拒否、実際の公開portと安全設定 | dockerグループ、読み取り専用 |
| `smoke-test.sh` | S3 CRUD・未認証拒否・MLflow param/metric/artifact・SQL/S3実データ照合 | dockerグループ、検証用run/objectを作成 |
| `smoke-test.py` | MLflowコンテナ内で上記検証を実行 | shell wrapper経由 |
| `wait-healthy.sh` | 起動操作をせずhealth回復を待機 | dockerグループ、最大約7.5分 |
| `verify-restart-and-reboot.sh` | IPv4起動待機を導入、daemon再起動で元run/objectを検証、成功後VM再起動 | sudo必須、SSH/エディタ切断あり、直前boot IDとcontainer IDも記録 |
| `backup.sh` | SQL dump・停止中のSeaweedFS/Kuma全データ・configを保存して再開 | dockerグループ、一時停止あり |
| `common.sh` | パスとComposeコマンドの共通定義 | 他のshell scriptからsource |

スクリプトは任意のカレントディレクトリから実行できます。

```bash
/home/mdy/homelab/scripts/start.sh
/home/mdy/homelab/scripts/healthcheck.sh
/home/mdy/homelab/scripts/smoke-test.sh
# 再起動前のrun IDを指定して永続化を確認
/home/mdy/homelab/scripts/smoke-test.sh --verify <RUN_ID>
BACKUP_DIR=/mnt/backup/homelab /home/mdy/homelab/scripts/backup.sh
```

`smoke-test.sh` の `.runtime/last-smoke.json` にはsecretを含めません。run IDは画面にも出ます。
`healthcheck.sh` はホスト内からの検証です。他のLAN端末やInternet側からの到達性までは証明しません。
バックアップは `flock` で重複実行を防ぎ、失敗時も停止したサービスを再開するtrapを設定します。
SeaweedFSはblobだけでなく、filerのmetadata・master情報・認証情報等も含む `/data` 全体を保存します。
KumaはSQLite/WALを整合させるため停止して `/app/data` 全体をコピーします。
成功判定は `COMPLETE`、未完了は `INCOMPLETE`。`SHA256SUMS` で破損を検出し、SQL dumpは `pg_restore --list` で読めることを確認します。
自動削除は行いません。運用者が容量・保管数を確認します。

**同一SSD内のコピーは本当のバックアップではありません。** 保存先を `BACKUP_DIR` で独立したディスクへ変更し、復元検証を実施してください。
アーカイブはsecretを含みます。Gitへ置かず、owner-only権限と暗号化で保護してください。
