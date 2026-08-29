# Runbook: 物理 worker ノードを追加する（ADR-0003 / ADR-0009）

2 台目の物理マシン（`192.168.1.188`）上に VM を立て、`k8s-worker-2` として
クラスタに join する。既存クラスタは止めない。

## 構成

```
LAN 192.168.1.0/24
 ├─ ルーター 192.168.1.1
 ├─ KVM ホストA 192.168.1.35 ── libvirt NAT 192.168.122.0/24
 │                                 ├─ k8s-cp-1     .11
 │                                 └─ k8s-worker-1 .21
 └─ KVM ホストB 192.168.1.188 ── br0（LAN 直結）
                                   └─ k8s-worker-2  192.168.1.22   ← 今回作る
```

- ホスト A で「libvirt subnet ↔ LAN」の NAT だけ無効化（`04-interconnect.sh`）
- worker-2 VM に `192.168.122.0/24 via 192.168.1.35` の経路（cloud-init）
- → Flannel VXLAN がサブネット跨ぎで通る

## 事前準備

- [ ] ホスト B に Ubuntu 24.04 インストール済み
- [ ] ホスト A から `ssh tukapai@192.168.1.188` が鍵で通る
      （`ssh-copy-id tukapai@192.168.1.188` or 公開鍵を authorized_keys に）
- [ ] ホスト A / B とも `git pull` で最新の `homelab-k8s`

---

## 1. ホスト A: サブネット間の相互接続（ダウンタイムなし）

```bash
cd ~/homelab-k8s
./scripts/04-interconnect.sh add
./scripts/04-interconnect.sh status
```

`config.env` の `LIBVIRT_SUBNET_CIDR` / `LAN_CIDR` / `KVM_HOST_LAN_IP` を
自環境に合わせておくこと（既定 192.168.122.0/24 ↔ 192.168.1.0/24 / .35）。

---

## 2. ホスト B: KVM とブリッジ

```bash
git clone <homelab-k8s の URL> ~/homelab-k8s && cd ~/homelab-k8s
cp config.env.example config.env
./scripts/01-install-kvm-host.sh
newgrp libvirt
```

### br0 ブリッジ（netplan）

`ip -br link` で物理 NIC 名を確認（例 `enp1s0`）。
**SSH が切れる可能性があるので、できれば物理コンソール or `--timeout` で。**

`/etc/netplan/60-br0.yaml`:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp1s0:
      dhcp4: false
  bridges:
    br0:
      interfaces: [enp1s0]
      dhcp4: true            # ホストB 自身は DHCP のまま（.188）でよい
      parameters:
        stp: false
        forward-delay: 0
```

```bash
sudo netplan try        # 120 秒以内に Enter しなければ自動ロールバック
sudo netplan apply
ip -br addr show br0
```

### config.env（ホスト B）

```bash
$EDITOR ~/homelab-k8s/config.env
```

```sh
LIBVIRT_NET="br0"
NET_MODE="bridge"
NET_PREFIX="192.168.1"           # worker-2 → 192.168.1.(20+2)=.22
WORKER_IP_BASE="20"
VM_GATEWAY="192.168.1.1"
VM_NAMESERVERS="192.168.1.1"
VM_ROUTES="192.168.122.0/24,192.168.1.35"   # 1台目 subnet への経路
WORKER_VCPUS="<フルスペック>"     # 例: nproc - 1
WORKER_RAM_MB="<フルスペック>"    # 例: 総メモリ - 2048
WORKER_DISK_GB="<空きに応じて>"   # 例: 200
```

---

## 3. ホスト B: worker-2 VM を作成

```bash
cd ~/homelab-k8s
ROLE=worker NODE_NUM=2 ./scripts/02-create-node-vm.sh
```

- LAN 直結・静的 IP `192.168.1.22`・GW `192.168.1.1`
- `192.168.122.0/24` への経路を cloud-init で設定
- 最後に `ssh ubuntu@192.168.1.22` が通ることを確認

疎通確認（worker-2 VM 内から）:

```bash
ssh ubuntu@192.168.1.22
ping -c2 192.168.122.11      # cp に届く（04-interconnect + 静的経路）
ping -c2 192.168.122.21      # worker-1
```

---

## 4. ホスト A: inventory と Ansible

```bash
cd ~/homelab-k8s/ansible
$EDITOR inventory.ini
```

```ini
[workers]
k8s-worker-1 ansible_host=192.168.122.21
k8s-worker-2 ansible_host=192.168.1.22
```

`group_vars/all.yml` は既に `single_node_cluster: false`（cp を再 taint する）。

```bash
ansible k8s-worker-2 -m ping
ansible-playbook site.yml
```

- `10-common.yml` が worker-2 に containerd / kubeadm を入れる
- `30-workers.yml` が worker-2 を join
- `20-control-plane.yml` が cp に `NoSchedule` taint を付け直す

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide          # worker-2 が Ready、INTERNAL-IP=192.168.1.22
kubectl describe node k8s-cp-1 | grep Taints
```

---

## 5. Flannel のサブネット跨ぎ疎通を確認

```bash
# 別ノードに Pod を置いて相互 ping
kubectl run p1 --image=nicolaka/netshoot --overrides='{"spec":{"nodeName":"k8s-worker-1"}}' -- sleep 3600
kubectl run p2 --image=nicolaka/netshoot --overrides='{"spec":{"nodeName":"k8s-worker-2"}}' -- sleep 3600
kubectl exec p1 -- ping -c3 "$(kubectl get pod p2 -o jsonpath='{.status.podIP}')"
kubectl exec p2 -- nslookup kubernetes.default
kubectl delete pod p1 p2
```

疎通しない場合:

- host A: `./scripts/04-interconnect.sh status`、`iptables -t nat -S POSTROUTING`
- worker-2: `ip route`（`192.168.122.0/24 via 192.168.1.35` があるか）
- Flannel Pod ログ: `kubectl -n kube-flannel logs -l app=flannel`
- UDP 8472 が host A / B 間で通っているか（`nc -u -z`）

---

## 6. ワークロードを worker 群へ寄せる

cp の taint が戻ったので、cp 上の非システム Pod は退避される。

```bash
kubectl get pods -A -o wide | grep k8s-cp-1     # kube-system 以外が無いこと
```

Argo CD / ingress / cloudflared などが自動で worker に再スケジュールされる。
ステートフル（CloudNativePG / Redis）の `nodeSelector` を見直す
（`homelab-gitops` の values。worker-1 固定 → worker-2 も可 or 分散）。

PostgreSQL の無停止移行が要る場合は [restore-postgres.md](restore-postgres.md)
の「新ノードへの移行」。

---

## 7.（任意・推奨）ルーターに静的ルート

`192.168.122.0/24` → `192.168.1.35` をホームルーターに追加すると:

- LAN の全機器からクラスタ subnet に直接到達
- `mac/` の SSH トンネルが不要（`~/.kube/config` の `server` を
  `https://192.168.122.11:6443` のまま、トンネルなしで使える）

Mac だけで済ませるなら（ルーター不可の場合）:

```bash
sudo route -n add 192.168.122.0/24 192.168.1.35     # macOS。再起動で消える
```

---

## ロールバック

| やり直したい | 手順 |
|---|---|
| worker-2 の join 失敗 | `kubectl delete node k8s-worker-2` → VM で `sudo kubeadm reset -f` → 原因対処 → `site.yml` |
| worker-2 VM 作り直し | ホスト B で `./scripts/03-destroy-node-vm.sh k8s-worker-2` → 手順 3 から |
| 相互接続をやめる | ホスト A で `./scripts/04-interconnect.sh remove` |
| taint を戻したくない | `single_node_cluster: true` → `site.yml` |

## 完了条件

- [ ] `kubectl get nodes` に cp / worker-1 / worker-2 が Ready
- [ ] worker-2 の INTERNAL-IP が `192.168.1.22`
- [ ] cp に `NoSchedule` taint
- [ ] 別ノード間の Pod 疎通・DNS OK
- [ ] Argo CD / platform が worker 上で Running
- [ ] `04-interconnect.sh` の systemd ユニットが enabled（再起動で復元）
- [ ] `single_node_cluster: false` と `inventory.ini` がコミット済み
