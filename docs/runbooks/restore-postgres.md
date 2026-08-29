# Runbook: PostgreSQL のバックアップとリストア（CloudNativePG）

ADR-0004 の DB。単一インスタンス + オブジェクトストレージ（R2/B2）への
継続バックアップ。**リストアは定期的に実際に試すこと**（四半期ごと目安）。

## バックアップ構成（前提）

`homelab-gitops` の CNPG `Cluster` に以下があること:

```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://<bucket>/<cluster>
      endpointURL: https://<accountid>.r2.cloudflarestorage.com   # R2 の例
      s3Credentials:
        accessKeyId:     { name: pg-backup-r2, key: ACCESS_KEY_ID }
        secretAccessKey: { name: pg-backup-r2, key: SECRET_ACCESS_KEY }
      wal:
        compression: gzip
      data:
        compression: gzip
    retentionPolicy: "30d"
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
spec:
  schedule: "0 0 3 * * *"        # 毎日 03:00
  backupOwnerReference: self
  cluster: { name: <cluster> }
```

`pg-backup-r2` Secret は Sealed Secret 化してコミット（ADR-0006）。

## 状態確認

```bash
NS=<namespace>; CL=<cluster>
kubectl -n $NS get cluster $CL
kubectl -n $NS get backup                       # 直近バックアップの状態
kubectl -n $NS get scheduledbackup
kubectl cnpg status $CL -n $NS                   # cnpg プラグイン
```

WAL アーカイブが回っているか:

```bash
kubectl -n $NS get cluster $CL -o jsonpath='{.status.conditions}' | jq
```

## 手動バックアップ（リストア前・大きな変更前）

```bash
kubectl -n $NS apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: manual-$(date +%Y%m%d-%H%M), namespace: $NS }
spec:
  cluster: { name: $CL }
EOF
```

## リストア: 新クラスタとして復元（推奨・非破壊）

既存クラスタは触らず、バックアップから**別名の新クラスタ**を作る。

`homelab-gitops` に一時的に追加（またはローカルで `kubectl apply`）:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <cluster>-restore
  namespace: <namespace>
spec:
  instances: 1
  storage: { size: 20Gi }
  nodeSelector: { kubernetes.io/hostname: k8s-worker-1 }
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      barmanObjectStore:
        destinationPath: s3://<bucket>/<cluster>
        endpointURL: https://<accountid>.r2.cloudflarestorage.com
        s3Credentials:
          accessKeyId:     { name: pg-backup-r2, key: ACCESS_KEY_ID }
          secretAccessKey: { name: pg-backup-r2, key: SECRET_ACCESS_KEY }
```

PITR（特定時刻へ）にするなら `bootstrap.recovery` に:

```yaml
      recoveryTarget:
        targetTime: "2026-08-29 02:30:00+09"
```

確認:

```bash
kubectl -n $NS get cluster <cluster>-restore -w
kubectl cnpg psql <cluster>-restore -n $NS -- -c '\dt'
```

問題なければ、アプリの接続先 Secret / Service 名を新クラスタに向け替え
（`homelab-gitops` の overlay で `host` を変更）→ 旧クラスタを削除。

## リストア: クラスタ全損からの復旧（DR）

クラスタごと作り直した後（IaC 再構築）:

1. `50-argocd.yml` まで実行して Argo CD を復活
2. **Sealed Secrets の sealing key を先に復元**（`backup-and-recovery.md`）
   → `pg-backup-r2` Secret が復号できる状態にする
3. `homelab-gitops` の CNPG `Cluster` を、平常時の manifest に
   `bootstrap.recovery`（上記 externalClusters）を**一時的に足して** push
4. Argo CD が同期 → バックアップから復元されたクラスタが立ち上がる
5. 復旧を確認したら `bootstrap.recovery` を外して通常の manifest に戻す
   （以降は初期化済みなので recovery は不要）

## よくある失敗

| 症状 | 原因 / 対処 |
|---|---|
| `barman-cloud-wal-archive` エラー | R2/B2 の認証情報・bucket・endpointURL を確認。`forcePathStyle: true` が要ることがある |
| recovery が `LSN` で止まる | WAL の欠損。`targetTime` を直近のバックアップ以降に |
| 新クラスタが `pending` | `nodeSelector` 先にリソース/PV 容量なし。local-path の空きを確認 |

## 完了条件（定期リストア訓練）

- [ ] `<cluster>-restore` が `Cluster in healthy state`
- [ ] アプリのスキーマ / 主要テーブルの件数が妥当
- [ ] 所要時間を記録（RTO の実測）
- [ ] 訓練用クラスタを削除
