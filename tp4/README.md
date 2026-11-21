# TP4 Kubernetes : Deployment, Service, rolling update et rollback

GI3-GL, ENSA Al Hoceima, 2026/2027. Auteure : Nabila Boubekr

## Fichiers

| Fichier | Rôle |
|---|---|
| `kind-config.yaml` | Cluster kind `tp-k8s` : 1 control plane et 2 workers, port 30080 publié sur l'hôte |
| `pod.yaml` | Pod `web` (nginx:1.27), généré avec `--dry-run=client -o yaml` |
| `whoami.yaml` | Deployment `whoami` (3 réplicas, traefik/whoami) et Service NodePort 30080 |
| `tp4.sh` | Script qui exécute les parties A à D et enregistre les sorties dans `outputs/` |
| `outputs/rollout-history.txt` | Sortie de `kubectl rollout history deployment/whoami` |

## Démarche

1. **Partie A** : `kind create cluster --config kind-config.yaml` crée trois conteneurs Docker (`tp-k8s-control-plane`, `tp-k8s-worker`, `tp-k8s-worker2`). Chacun est un nœud Kubernetes, comme le montre `docker ps`.
2. **Partie B** : on crée un Pod « nu » avec `kubectl run`, puis on l'inspecte (`describe`, `logs`, `exec`, `port-forward`). Après `kubectl delete pod web`, le Pod disparaît définitivement. On repasse ensuite en déclaratif avec `pod.yaml` et `kubectl apply`.
3. **Partie C** : le Deployment crée un ReplicaSet, qui crée 3 Pods. Le Service NodePort les rend accessibles sur `localhost:30080`. Le champ `Hostname` change d'une requête à l'autre, ce qui montre la répartition de charge. Un Pod supprimé est recréé automatiquement. `scale` porte le nombre de Pods à 6.
4. **Partie D** : la mise à jour vers v1.11 se fait sans coupure. Avec l'image `v9.99`, qui n'existe pas, les nouveaux Pods restent en `ErrImagePull`/`ImagePullBackOff`, mais les anciens continuent de répondre. `rollout undo` remet la version v1.11.

Sortie attendue de `rollout history` (les numéros sont ceux de Kubernetes ; la révision 2 devient la 4 après le `undo`) :

```
REVISION  CHANGE-CAUSE
1         creation whoami v1.10
3         image cassee v9.99
4         maj image v1.11
```

## Réponses aux questions

### 1. Rôle des Pods de `kube-system`

| Pod | Type | Rôle |
|---|---|---|
| **etcd** | Pod statique (control plane) | Base clé-valeur distribuée et cohérente qui stocke tout l'état du cluster (objets, configuration, secrets). Seul l'API server y accède. |
| **kube-apiserver** | Pod statique | Point d'entrée unique du cluster (API REST). Il authentifie, autorise, valide (admission) puis enregistre les objets dans etcd. kubectl, le scheduler, les contrôleurs et les kubelets passent tous par lui. |
| **kube-scheduler** | Pod statique | Choisit un nœud pour chaque Pod qui n'en a pas encore. Il filtre les nœuds possibles (ressources, taints, affinités), leur donne un score, puis écrit `nodeName` dans le Pod. |
| **kube-controller-manager** | Pod statique | Exécute les boucles de réconciliation (contrôleurs Deployment, ReplicaSet, Node, EndpointSlice, ServiceAccount, Job…). Chaque boucle compare l'état réel à l'état désiré et corrige l'écart. |
| **kube-proxy** | DaemonSet (1 par nœud) | Programme les règles iptables/IPVS de chaque nœud. Le trafic envoyé à l'IP d'un Service (ClusterIP) ou à un NodePort est ainsi redirigé vers l'un des Pods qui le servent. |
| **CoreDNS** | Deployment (2 réplicas) | Serveur DNS interne du cluster. Il traduit `whoami.default.svc.cluster.local` en ClusterIP du Service. Son Service s'appelle `kube-dns`. |
| **kindnet** | DaemonSet (1 par nœud) | Plugin réseau (CNI) de kind. Il attribue une IP à chaque Pod à partir du sous-réseau de son nœud et installe les routes, pour que les Pods de nœuds différents puissent communiquer directement. |

Les quatre premiers composants sont des **Pods statiques** : le kubelet du control plane les lance à partir des manifestes placés dans `/etc/kubernetes/manifests`. C'est pour cela que leur nom se termine par `-tp-k8s-control-plane`.

### 2. Pourquoi le Pod `web` n'est-il pas recréé ?

`kubectl run` crée un Pod **nu**. Aucun contrôleur n'en est propriétaire et son champ `metadata.ownerReferences` est vide. Le supprimer revient à supprimer l'état désiré lui-même : rien n'en demande un nouveau. (Le kubelet relance un *conteneur* qui plante, selon `restartPolicy`, mais il ne recrée jamais un *Pod* supprimé.)

Les Pods `whoami`, eux, ont pour `ownerReferences` un ReplicaSet. Le contrôleur ReplicaSet surveille en continu le nombre de Pods qui correspondent à son sélecteur `app=whoami`. S'il en compte 2 au lieu de 3, il en crée un nouveau : c'est l'auto-réparation.

### 3. Relation Deployment → ReplicaSet → Pod, et nombre de ReplicaSets

- Le **Pod** est l'unité d'exécution (un ou plusieurs conteneurs).
- Le **ReplicaSet** garantit qu'un nombre fixe de Pods identiques tourne en permanence.
- Le **Deployment** gère les ReplicaSets. Il crée **un ReplicaSet par version du template de Pod**, reconnaissable au label `pod-template-hash`. Lors d'une mise à jour, il augmente progressivement le nouveau ReplicaSet et diminue l'ancien (rolling update). Il garde les anciens ReplicaSets à 0 réplica pour permettre le rollback (`revisionHistoryLimit`, 10 par défaut).

À la fin, il y a **3 ReplicaSets** :

| ReplicaSet | Image | Réplicas |
|---|---|---|
| whoami-xxxx (révision 1) | v1.10 | 0 |
| whoami-yyyy (révision 4) | v1.11 | 6 (actif) |
| whoami-zzzz (révision 3) | v9.99 | 0 |

`kubectl scale` ne change pas le template et ne crée donc pas de ReplicaSet. `rollout undo` remet le template v1.11. Ce template a le même hash qu'avant, donc Kubernetes **réutilise** le ReplicaSet v1.11 existant au lieu d'en créer un quatrième. Sa révision passe de 2 à 4.

### 4. Comment le Service trouve-t-il ses Pods ?

Grâce à son **sélecteur de labels** `app: whoami`. Le contrôleur EndpointSlice (dans kube-controller-manager) suit les Pods qui portent ce label et inscrit l'IP et le port de ceux qui sont **Ready** dans un objet EndpointSlice associé au Service (label `kubernetes.io/service-name=whoami`) :

```
kubectl get endpointslices -l kubernetes.io/service-name=whoami -o wide
```

kube-proxy lit ces EndpointSlices sur chaque nœud et programme les règles iptables : une requête vers `ClusterIP:80` ou `<nœud>:30080` est envoyée à l'une de ces IP. Un Pod qui n'est pas Ready (par exemple en `ImagePullBackOff`) n'est pas inscrit et ne reçoit donc aucun trafic.

### 5. Disponibilité pendant l'image cassée (`maxUnavailable`)

**Oui, l'application est restée disponible.** La stratégie par défaut est `RollingUpdate` avec `maxSurge: 25%` et `maxUnavailable: 25%`. Pour 6 réplicas :

- `maxUnavailable` = 25 % × 6 = 1,5, **arrondi vers le bas à 1**. Au moins 5 Pods doivent rester disponibles.
- `maxSurge` = 1,5, **arrondi vers le haut à 2**. Le Deployment peut avoir au plus 8 Pods au total.

Le Deployment crée 2 Pods v9.99 (8 au total), puis supprime 1 ancien Pod (il reste 5 disponibles, le minimum autorisé), puis crée un 3e Pod v9.99. Les nouveaux Pods ne deviennent jamais Ready (`ImagePullBackOff`), donc il ne peut plus supprimer aucun ancien Pod. Le rollout reste **bloqué** dans l'état « 5 anciens Pods Ready + 3 nouveaux en erreur » (`READY 5/6`). Après `progressDeadlineSeconds` (600 s), la condition `Progressing` passe à `ProgressDeadlineExceeded`.

Comme les Pods en erreur ne sont pas dans l'EndpointSlice, la boucle `curl` a continué d'afficher des `Hostname` (ceux des 5 Pods v1.11) **sans aucune erreur**. `rollout undo` remet ensuite le ReplicaSet v1.11 à 6 Pods et le ReplicaSet v9.99 à 0.

## Défi : accès au Service par DNS

```
kubectl run test --rm -it --image=busybox:1.36 -- sh
/ # nslookup whoami.default.svc.cluster.local
/ # wget -qO- http://whoami.default.svc.cluster.local
/ # cat /etc/resolv.conf
```

`nslookup` renvoie la ClusterIP du Service (par exemple `10.96.x.x`) et `wget` renvoie la page whoami avec le `Hostname` d'un des Pods.

| Partie | Signification |
|---|---|
| `whoami` | Nom du Service |
| `default` | Namespace du Service |
| `svc` | Type d'enregistrement : un Service (les Pods ont une autre forme de nom) |
| `cluster.local` | Domaine du cluster (`clusterDomain` du kubelet, `cluster.local` par défaut) |

Le serveur DNS indiqué dans `/etc/resolv.conf` (`nameserver 10.96.0.10`) est la ClusterIP du Service `kube-dns`, c'est-à-dire CoreDNS. La ligne `search default.svc.cluster.local svc.cluster.local cluster.local` explique pourquoi `wget -qO- http://whoami` fonctionne aussi depuis le namespace `default`, et `whoami.default` depuis n'importe quel namespace.

## Nettoyage

```
kind delete cluster --name tp-k8s
```
