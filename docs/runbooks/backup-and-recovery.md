# Runbook: バックアップと全損復旧

ADR-0003 の可用性戦略「バックアップ + IaC 再構築」の具体。物理ホストは
1 台なので、**復旧速度（RTO）と復旧地点（RPO）で守る**。

## 何をバックアップするか

| 対象 | 方式 | 保管先 | 頻度 |
|---|---|---|---|
| PostgreSQL データ | CNPG barmanObjectStore（base + WAL）| R2 / B2 | 毎日 + WAL 連続 |
| Sealed Secrets の sealing key | 手動 export → 暗号化 | パスワードマネージャ + オフライン | 生成時 & ローテーション時 |
| `homelab-k8s` リポジトリ | git（GitHub）| GitHub + ローカル clone | push ごと |
| `homelab-gitops` リポジトリ | git（GitHub）| 同上 | push ごと |
| `app-*` リポジトリ | git（GitHub）| 同上 | push ごと |
| Redis（queue 用途がある場合）| RDB/AOF を CronJob で R2 へ | R2 | 1 時間ごと等 |
| PV（上記以外の PVC）| Velero（任意）| R2 | 日次 |
| Minecraft ワールド（`data-minecraft-0`）| itzg/mc-backup（CronJob）| **worker-2 ノード内 PVC のみ** | 日次（現在 suspend 中） |

**原則: 状態は「Git」か「オブジェクトストレージ」のどちらかにあり、
物理ホストが消えても復元できること。**

> ⚠️ **Minecraft はこの原則の例外。** ワールド本体（`data-minecraft-0`）も
> バックアップ（`minecraft-backups`）も同じ worker-2 の local-path PVC にあり、
> オブジェクトストレージへの退避が無い。**worker-2 が全損すると両方消える。**
> R2 転送は ADR-0013 の「あとで見直す」に TODO として記録済みで未着手
> （`homelab-gitops/apps/gameservers/backup-cronjob.yaml` 先頭のコメント参照）。
> 復旧手順としても本 runbook には Minecraft の記載が無い — 現状「復旧できない」
> が前提なので、全損復旧の通し訓練でもワールドは対象外になる。

## Sealed Secrets の sealing key（最重要）

これを失うと `homelab-gitops` 内の全 SealedSecret が復号不能になる。

### バックアップ

```bash
export KUBECONFIG=~/homelab-k8s/ansible/kubeconfig
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-key.yaml

# 暗号化して保管（例: age）
age -r <あなたのage公開鍵> -o sealed-secrets-key.yaml.age sealed-secrets-key.yaml
shred -u sealed-secrets-key.yaml
```

`sealed-secrets-key.yaml.age` を **パスワードマネージャ**と**オフライン
メディア**の 2 か所に。復号用 age 秘密鍵も別管理。

### 復元

```bash
age -d -i <age秘密鍵> sealed-secrets-key.yaml.age | kubectl apply -f -
kubectl -n kube-system rollout restart deployment sealed-secrets-controller
```

> SOPS+age に移行済み（ADR-0006 が Superseded）なら、この項目は
> 「age 秘密鍵を保管する」だけに簡素化される。

## Redis バックアップ（queue 用途がある場合）

`homelab-gitops` の Redis に CronJob を添える:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: redis-backup }
spec:
  schedule: "0 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: dump
              image: amazon/aws-cli:2
              env:
                - name: AWS_ACCESS_KEY_ID
                  valueFrom: { secretKeyRef: { name: redis-backup-r2, key: ACCESS_KEY_ID } }
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom: { secretKeyRef: { name: redis-backup-r2, key: SECRET_ACCESS_KEY } }
              command: ["/bin/sh","-c"]
              args:
                - |
                  redis-cli -h redis SAVE && \
                  aws --endpoint-url https://<accountid>.r2.cloudflarestorage.com \
                    s3 cp /data/dump.rdb s3://<bucket>/redis/dump-$(date +%Y%m%d-%H).rdb
              volumeMounts: [{ name: data, mountPath: /data }]
          volumes:
            - name: data
              persistentVolumeClaim: { claimName: redis-data }
```

（`redis-cli` イメージが要るなら sidecar か `bitnami/redis` に差し替え）

## 全損からの復旧手順（RTO 目標: 2〜3 時間）

物理ホストが死んだ / OS が飛んだ、を想定。

### 0. 新しい物理ホストを用意

Ubuntu 24.04 をクリーンインストール。

### 1. インフラ再構築

```bash
git clone <homelab-k8s の URL> ~/homelab-k8s
cd ~/homelab-k8s
cp config.env.example config.env      # 値を復元（記録 or この runbook のメモから）
cp ansible/inventory.ini.example ansible/inventory.ini

./scripts/01-install-kvm-host.sh
newgrp libvirt
./scripts/02-create-node-vm.sh                       # k8s-cp-1
ROLE=worker NODE_NUM=1 ./scripts/02-create-node-vm.sh # k8s-worker-1
cd ansible && ansible-playbook site.yml
```

`kubectl get nodes` が Ready になるまで確認。

### 2. Argo CD を復活

```bash
cd ~/homelab-k8s/ansible
ansible-playbook playbooks/50-argocd.yml -e gitops_repo_url=<homelab-gitops URL>
```

private リポなら先に repo 資格情報を登録:

```bash
argocd login <argocd> ; argocd repo add <url> --ssh-private-key-path <deploy key>
# もしくは repo Secret を kubectl apply
```

### 3. Sealed Secrets の sealing key を復元（★同期の前に）

Argo CD が `sealed-secrets` を入れた直後、SealedSecret が復号される前に:

```bash
age -d -i <age秘密鍵> sealed-secrets-key.yaml.age | kubectl apply -f -
kubectl -n kube-system rollout restart deployment sealed-secrets-controller
```

これで `homelab-gitops` 内の SealedSecret 群（Cloudflare トークン、
R2 認証情報など）が正しく復号される。

### 4. Argo CD に全同期させる

```bash
argocd app sync root --prune
argocd app list        # platform-* / app-* が Synced/Healthy へ
```

### 5. PostgreSQL をバックアップから復元

`restore-postgres.md` の「クラスタ全損からの復旧」。`homelab-gitops` の
CNPG `Cluster` に `bootstrap.recovery` を一時追加して push → 同期 →
確認後に外す。

### 6. Redis を復元

R2 の最新 `dump.rdb` を新 PVC に配置してから Redis を起動、または
起動後に `redis-cli --pipe` で流し込み。queue の取りこぼしは
アプリ側の冪等性 / リトライで吸収。

### 7. Cloudflare Tunnel の確認

`cloudflared` Pod が Running になり、Cloudflare ダッシュボードで
Tunnel が Healthy、公開ホスト名が応答することを確認。

### 8. 動作確認

- [ ] 公開 API が 200 を返す
- [ ] DB 書き込み・読み取り
- [ ] queue 投入 → worker 処理
- [ ] Argo CD 上すべて Synced/Healthy
- [ ] 所要時間を記録し RTO 実測値を更新

## config.env / inventory.ini の値メモ（復旧用）

> ここに実際の値を書くと機密になるため、**別途パスワードマネージャ**に
> 「homelab recovery notes」として保管する。最低限:
> - NET_PREFIX / CP_IP / worker IP
> - KVM ホストの LAN IP・SSH ユーザー
> - Cloudflare アカウント / ドメイン / Tunnel 名
> - R2/B2 バケット名・エンドポイント

## 定期訓練

| 項目 | 頻度 |
|---|---|
| PostgreSQL リストア（新クラスタ）| 四半期 |
| sealing key 復元テスト（訓練クラスタ）| 半期 |
| 全損復旧の通し訓練 | 年 1 |
| Minecraft ワールドの復元（`.tgz` → PVC）| 未実施。ADR-0013 Action Item 23。ワールドがまだ空のうちに一度試すこと |
