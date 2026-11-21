#!/usr/bin/env bash
# TP4 Kubernetes - exécute les parties A à D et enregistre chaque sortie dans outputs/
# Usage : bash tp4.sh            (depuis le dossier qui contient kind-config.yaml et whoami.yaml)
# Les étapes interactives (exec -it, port-forward, boucle curl, défi DNS) restent à faire à la main :
# elles sont indiquées par "A FAIRE A LA MAIN".
set -u
mkdir -p outputs
run() {  # run <fichier> <commande...>
  local f="outputs/$1"; shift
  echo -e "\n\$ $*" | tee -a "$f"
  "$@" 2>&1 | tee -a "$f"
}
pause() { echo -e "\n>>> $1 — Entrée pour continuer"; read -r; }

# ---------- Vérification des outils ----------
run 00-outils.txt docker run --rm hello-world
run 00-outils.txt kind version
run 00-outils.txt kubectl version --client
run 00-outils.txt helm version

# ---------- Partie A : cluster ----------
run A-cluster.txt kind create cluster --config kind-config.yaml
run A-cluster.txt kubectl get nodes -o wide
run A-cluster.txt kubectl wait --for=condition=Ready nodes --all --timeout=180s
run A-cluster.txt kubectl get pods -n kube-system -o wide
run A-cluster.txt docker ps

# ---------- Partie B : Pod ----------
run B-pod.txt kubectl run web --image=nginx:1.27 --port=80
run B-pod.txt kubectl wait --for=condition=Ready pod/web --timeout=120s
run B-pod.txt kubectl get pods -o wide
run B-pod.txt kubectl describe pod web
run B-pod.txt kubectl logs web
pause "A FAIRE A LA MAIN (autre terminal) : kubectl exec -it web -- sh  puis  kubectl port-forward pod/web 8080:80  et ouvrir http://localhost:8080 (capture d'écran)"
run B-pod.txt kubectl delete pod web
run B-pod.txt kubectl get pods            # web n'est PAS recréé
run B-pod.txt kubectl run web --image=nginx:1.27 --dry-run=client -o yaml
kubectl run web --image=nginx:1.27 --dry-run=client -o yaml > pod.yaml
run B-pod.txt kubectl apply -f pod.yaml
run B-pod.txt kubectl get pods

# ---------- Partie C : Deployment + Service ----------
run C-deploy.txt kubectl apply -f whoami.yaml
kubectl annotate deployment/whoami kubernetes.io/change-cause="creation whoami v1.10" --overwrite
run C-deploy.txt kubectl rollout status deployment/whoami
run C-deploy.txt kubectl get deploy,rs,pods,svc -o wide
for i in 1 2 3 4 5 6; do run C-deploy.txt curl -s http://localhost:30080; done   # Hostname change
POD=$(kubectl get pods -l app=whoami -o jsonpath='{.items[0].metadata.name}')
run C-deploy.txt kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences}'; echo
run C-deploy.txt kubectl delete pod "$POD"
run C-deploy.txt kubectl get pods -l app=whoami      # un nouveau Pod est apparu
run C-deploy.txt kubectl scale deployment whoami --replicas=6
run C-deploy.txt kubectl rollout status deployment/whoami
run C-deploy.txt kubectl get pods -l app=whoami -o wide
run C-deploy.txt kubectl get endpointslices -l kubernetes.io/service-name=whoami -o wide

# ---------- Partie D : rolling update / rollback ----------
pause "A FAIRE A LA MAIN : dans un 2e terminal lancer  while true; do curl -s localhost:30080 | grep Hostname; sleep 0.5; done  (le laisser tourner, faire des captures)"
run D-rollout.txt kubectl set image deployment/whoami whoami=traefik/whoami:v1.11
kubectl annotate deployment/whoami kubernetes.io/change-cause="maj image v1.11" --overwrite
run D-rollout.txt kubectl rollout status deployment/whoami
run D-rollout.txt kubectl rollout history deployment/whoami

run D-rollout.txt kubectl set image deployment/whoami whoami=traefik/whoami:v9.99
kubectl annotate deployment/whoami kubernetes.io/change-cause="image cassee v9.99" --overwrite
sleep 30
run D-rollout.txt kubectl get pods -l app=whoami          # ImagePullBackOff
run D-rollout.txt kubectl get deploy whoami                # READY reste a 5/6 ou plus
run D-rollout.txt kubectl get rs -l app=whoami
run D-rollout.txt kubectl get endpointslices -l kubernetes.io/service-name=whoami -o wide
run D-rollout.txt kubectl describe deployment whoami

run D-rollout.txt kubectl rollout undo deployment/whoami
run D-rollout.txt kubectl rollout status deployment/whoami
run D-rollout.txt kubectl get rs -l app=whoami -o wide     # 3 ReplicaSets
run D-rollout.txt kubectl rollout history deployment/whoami  # <- livrable "rollout history"
kubectl rollout history deployment/whoami > outputs/rollout-history.txt

echo -e "\nDÉFI (à la main) :\n  kubectl run test --rm -it --image=busybox:1.36 -- sh\n  nslookup whoami.default.svc.cluster.local\n  wget -qO- http://whoami.default.svc.cluster.local\n  cat /etc/resolv.conf"
echo -e "\nTerminé. Sorties dans ./outputs/. Nettoyage plus tard : kind delete cluster --name tp-k8s"
