# Runbook: 物理 worker ノードを追加する

ADR-0003 の「物理ノード到着時」の手順。2 台目の物理マシンを
`k8s-worker-2` としてクラスタに join し、暫定策（cp の taint 解除）を解除する。

## 前提

- 2 台目の物理マシン（Ubuntu 24.04、CPU 仮想化支援有効）が LAN 上にある
- KVM ホスト（1 台目）と同じ L2 セグメントにいる、または相互に到達可能
- クラスタは既に稼働（`k8s-cp-1` + `k8s-worker-1`(VM)）

## 方針

物理マシン上でも **VM を 1 つ立ててそれを worker にする**（物理を直接
bare-metal ノードにしてもよいが、作り直しやすさで VM 推奨）。
libvirt NAT は他ホストから到達できないので、**ブリッジ接続**にする。

## 手順

### 1. 2 台目に KVM をセットアップ

```bash
git clone <homelab-k8s の URL> ~/homelab-k8s
cd ~/homelab-k8s
cp config.env.example config.env
./scripts/01-install-kvm-host.sh
newgrp libvirt
```

### 2. ブリッジ `br0` を作成（2 台目のホスト）

`/etc/netplan/*.yaml` を編集（インターフェース名は `ip a` で確認）:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp1s0:
      dhcp4: no
  bridges:
    br0:
      interfaces: [enp1s0]
      dhcp4: yes            # or 固定
      parameters:
        stp: false
        forward-delay: 0
```

```bash
sudo netplan apply
```

### 3. `config.env` をブリッジ用に（2 台目のホスト）

```bash
LIBVIRT_NET=br0
NET_PREFIX=192.168.1          # 自宅 LAN の /24 に合わせる
WORKER_IP_BASE=20             # → worker-2 = 192.168.1.22
```

LAN に libvirt の DHCP 予約は効かないので、`02-create-node-vm.sh` の
DHCP 予約タスクは実質無効。VM 側に **cloud-init で固定 IP** を書くか、
ルーターの DHCP 予約で MAC → IP を固定する（スクリプトが表示する MAC を使う）。

> ブリッジ運用では `scripts/02-create-node-vm.sh` の
> `virsh net-update ... ip-dhcp-host` は失敗しても無害（`|| true` 済み）。
> IP 固定はルーター側 or cloud-init network-config で行う。

### 4. worker-2 VM を作成（2 台目のホスト）

```bash
ROLE=worker NODE_NUM=2 ./scripts/02-create-node-vm.sh
```

SSH できることを確認: `ssh ubuntu@192.168.1.22`

### 5. インベントリに追加（1 台目 = Ansible 実行ホスト）

`ansible/inventory.ini`:

```ini
[workers]
k8s-worker-1 ansible_host=192.168.122.21
k8s-worker-2 ansible_host=192.168.1.22
```

`k8s-worker-2` へ SSH 鍵で入れること（同じ `~/.ssh/id_ed25519`）。
ルーティング的に 1 台目から `192.168.1.22` に到達できることを確認。

### 6. 暫定策を解除して join

`ansible/group_vars/all.yml`:

```yaml
single_node_cluster: false      # ← cp に taint を戻す
```

```bash
cd ansible
ansible-playbook site.yml
```

- `10-common.yml` が worker-2 に containerd/kubeadm を入れる
- `30-workers.yml` が worker-2 を join
- `20-control-plane.yml` が cp に taint を付け直す

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide      # worker-2 が Ready
kubectl describe node k8s-cp-1 | grep Taints   # NoSchedule
```

### 7. ワークロードを worker 群へ寄せる

cp の taint を戻したので、cp 上の Pod は退避される。プラットフォーム
（Argo CD 等）は自動で worker に再スケジュールされる。手動で確認:

```bash
kubectl get pods -A -o wide | grep k8s-cp-1
```

`kube-system` 以外が残っていなければ OK。

### 8. ステートフルの移行（PostgreSQL）

`restore-postgres.md` も参照。無停止で新ノードへ移す:

1. `homelab-gitops` の CNPG `Cluster` の `instances: 1` → `2` にして push
   （新インスタンスが worker-2 に作られる。affinity で分散させる）
2. レプリカが `streaming` になったのを確認
   ```bash
   kubectl -n <ns> get cluster <name> -o jsonpath='{.status.instancesStatus}'
   ```
3. スイッチオーバー
   ```bash
   kubectl cnpg promote <cluster> <cluster>-2 -n <ns>
   ```
4. 落ち着いたら `instances: 2` のまま（HA）か、旧ノード分を減らす場合は
   `instances: 1` + `nodeSelector` を worker-2 に

### 9. Redis の移行

Redis はレプリカを常設していない場合、メンテ枠で:

1. `BGSAVE` で RDB を取る、または AOF をコピー
2. `homelab-gitops` の Redis manifest の `nodeSelector` を worker-2 に変更して push
3. PVC は付け替えできないので、新 PVC + データリストア
   （`redis-cli --rdb` / AOF 再生）
4. アプリを一時的に queue 処理停止 → 切替 → 再開

## ロールバック

- worker-2 の join がおかしい → `kubectl delete node k8s-worker-2`、
  VM 側で `sudo kubeadm reset -f`、原因を潰して `site.yml` 再実行
- taint を戻したくない → `single_node_cluster: true` に戻して `site.yml`

## 完了条件

- [ ] `kubectl get nodes` に worker-1 / worker-2 が Ready
- [ ] cp に `NoSchedule` taint
- [ ] Argo CD / ingress-nginx / cloudflared が worker 上で Running
- [ ] PostgreSQL が worker-2（または HA 構成）
- [ ] `single_node_cluster: false` がコミットされている
