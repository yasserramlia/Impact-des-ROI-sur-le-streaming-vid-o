
#!/usr/bin/env bash
# =============================================================================
#  deploy_proxy.sh — Déploie le reverse proxy VideoROI sur VM2
#
#  Usage : ./deploy_proxy.sh <IP_VM1>
#  Ex.   : ./deploy_proxy.sh 192.168.1.10
# =============================================================================
set -euo pipefail

IP_VM1="${1:?Usage: $0 <IP_VM1>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "================================================="
echo "  VideoROI-Impact — Déploiement Reverse Proxy"
echo "  Upstream → $IP_VM1:8080"
echo "================================================="

# ── Substitution de ADDR_VM1 dans nginx.conf ──────────────────────────────────
CONFIG="$SCRIPT_DIR/nginx.conf"
if grep -q "ADDR_VM1" "$CONFIG"; then
  sed -i "s/ADDR_VM1/$IP_VM1/g" "$CONFIG"
  echo "✓ nginx.conf mis à jour avec $IP_VM1"
else
  echo "  (nginx.conf déjà configuré)"
fi

# ── Vérifier que Docker est disponible ────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "ERREUR : Docker non trouvé. Installez Docker Engine."
  exit 1
fi

# ── Build + lancement ─────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

echo ""
echo ">>> Build de l'image..."
docker compose build

echo ""
echo ">>> Lancement du conteneur..."
docker compose up -d

echo ""
echo ">>> Statut :"
docker compose ps

echo ""
echo "================================================="
echo "  Proxy démarré !"
echo "  Client → http://$(hostname -I | awk '{print $1}')/"
echo "           → proxifié vers http://$IP_VM1:8080/"
echo "================================================="
