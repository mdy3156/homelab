# monitoring

Uptime Kuma 2.5.5のみを配置します。Prometheus/Grafanaは未導入です。

```bash
cd /home/mdy/homelab/compose/monitoring
docker compose up -d --wait --wait-timeout 240
docker compose ps
docker compose logs --tail=100 -f
docker compose stop
```

URL: http://192.168.0.8:3001 。初回アクセス時に管理者アカウントを作成します。
dataは `/srv/homelab/uptime-kuma/data`、UID/GIDは1000:1000、permissionは0700。
`UPTIME_KUMA_DB_TYPE=sqlite` でSQLiteを初期化し、任意のembedded MariaDBを無効化します。imageに含まれるHTTP healthcheckを利用します。
restartは `unless-stopped`、ログは10MB × 3、非root・capability全削除・no-new-privilegesで起動します。

監視対象の例:

| 種別 | 対象 | 期待値 |
| --- | --- | --- |
| HTTP | `http://192.168.0.8:5000/health` | 200 |
| HTTP | `http://192.168.0.8:8333/` | 403（未署名S3拒否） |
| HTTP | `http://192.168.0.8:3001/` | 200 |

監視設定・管理者作成はUIで行います。403監視はS3 HTTPの到達性と拒否を確認するだけです。
署名付きS3とSQLを含む検証には `scripts/healthcheck.sh`、保存の検証には `scripts/smoke-test.sh` を使ってください。
Docker socketはmountしません。PostgreSQLはKumaへ直接開放しません。
Kumaの初期設定と監視対象追加は、ユーザー自身の管理者アカウントで行います。
