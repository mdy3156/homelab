# ネットワーク

| ホスト | IPv4 | 役割 |
| --- | --- | --- |
| Proxmox | 192.168.0.6 | VMホスト。今回変更しない |
| ubuntu-infra | 192.168.0.8/24 | このインフラVM |
| router / gateway | 192.168.0.1 | 現在のdefault gateway。今回変更しない |

VMのinterfaceは `ens18`。検査時はIPv4がDHCP由来で、global IPv6も存在します。
Netplan・DHCP・ルーターの設定は変更しません。将来IPが変わると明示bindの起動が失敗するため、このIPを維持できることを運用者が確認してください。
Docker専用のsystemd ExecStartPreで192.168.0.8の存在を確認してからdaemonを起動します。
異なるDHCPアドレスやIPv6だけでnetwork-online.targetに到達しても、LAN公開portの復元を始めません。
この待機処理はIPを設定・変更しません。指定IPが割り当てられない場合はDocker起動を待機・再試行します。

## ホストへ公開するポート

| bind address | port | service | 認証 / 用途 |
| --- | --- | --- | --- |
| 192.168.0.8 | 5000/tcp | MLflow | HTTP UI/API、信頼するLAN向け |
| 192.168.0.8 | 8333/tcp | SeaweedFS | S3署名認証必須 |
| 192.168.0.8 | 3001/tcp | Uptime Kuma | HTTP UI、初回管理者設定 |
| 既存SSHのbind | 22/tcp | SSH | 既存設定を維持 |

新規serviceは `0.0.0.0` やIPv6 wildcardではpublishしません。
PostgreSQL5432、SeaweedFS master9333・filer8888・volume9340・内部gRPC/adminポートはホストへpublishしません。
KumaのためにDocker socketを開放せず、HTTP endpointを監視します。

Dockerはbridgeネットワークとpublishに必要なNAT/packet-filterルールを自動管理します。
[Docker公式のUbuntu導入案内](https://docs.docker.com/engine/install/ubuntu/) にあるとおり、publishしたportはUFWの通常ルールを迂回することがあります。
既存UFW/firewall設定の編集や新しいallowルールの追加は行いません。
LAN IPへのbindは待受先を限定する設定で、接続元subnetのACLではありません。
ルーター等がそのIPへ外部から転送する設定を持つ場合まで、このVM内の検査だけでは確認できません。今回ルーターは変更しません。

## 到達性の検証

VM内:

```bash
./scripts/healthcheck.sh
ss -lnt
docker compose -f compose/ml-platform/compose.yml ps
docker compose -f compose/monitoring/compose.yml ps
```

別のLAN端末:

```bash
curl -f http://192.168.0.8:5000/health
curl -I http://192.168.0.8:3001/
curl -i http://192.168.0.8:8333/  # 403を期待
nc -vz -w 2 192.168.0.8 5432    # 接続失敗を期待
```

ホストのLAN IPへのHTTP到達、設定上と実際のDocker公開port・network attachment、5432接続失敗はスクリプトで確認します。
別のLAN端末からの検証とInternet側からの検証は、その端末で別途行ってください。
