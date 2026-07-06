
#!/bin/sh
# =============================================================================
#  entrypoint.sh — Configure tc (traffic shaper) puis lance nginx
#
#  Variables :
#    BW_GLOBAL   : débit max total vers le client  (ex: "10mbit", "500kbit", "0")
#    BW_VIDEO    : débit max segments .m4s/.mp4    (ex: "2mbit",  "300kbit", "0")
#    "0" ou vide = pas de limitation sur ce canal
# =============================================================================
set -e

BW_GLOBAL="${BW_GLOBAL:-0}"
BW_VIDEO="${BW_VIDEO:-0}"
IFACE="eth0"

echo "========================================"
echo "  VideoROI — Traffic Shaper"
echo "  BW_GLOBAL = ${BW_GLOBAL}"
echo "  BW_VIDEO  = ${BW_VIDEO}"
echo "========================================"

is_active() {
  local v="$1"
  [ -n "$v" ] && [ "$v" != "0" ] && [ "$v" != "0mbit" ] && [ "$v" != "0kbit" ]
}

# Nettoyer les règles tc existantes
tc qdisc del dev "$IFACE" root 2>/dev/null || true

# Si rien à limiter, lancer nginx directement
if ! is_active "$BW_GLOBAL" && ! is_active "$BW_VIDEO"; then
  echo "  Aucune limitation active."
  exec nginx -g "daemon off;"
fi

# Plafond global (1gbit si BW_GLOBAL non défini)
CEIL_GLOBAL="$( is_active "$BW_GLOBAL" && echo "$BW_GLOBAL" || echo "1gbit" )"
RATE_VIDEO="$( is_active "$BW_VIDEO"  && echo "$BW_VIDEO"  || echo "$CEIL_GLOBAL" )"

echo "  Plafond global : $CEIL_GLOBAL"
echo "  Débit vidéo    : $RATE_VIDEO"

# --- HTB root ---
tc qdisc add dev "$IFACE" root handle 1: htb default 20

# Classe racine
tc class add dev "$IFACE" parent 1:  classid 1:1  htb rate "$CEIL_GLOBAL" ceil "$CEIL_GLOBAL"

# Classe vidéo (segments .m4s / init.mp4)
tc class add dev "$IFACE" parent 1:1 classid 1:10 htb rate "$RATE_VIDEO"  ceil "$RATE_VIDEO"  burst 15k
tc qdisc add dev "$IFACE" parent 1:10 handle 10: sfq perturb 10

# Classe reste du trafic
tc class add dev "$IFACE" parent 1:1 classid 1:20 htb rate "$CEIL_GLOBAL" ceil "$CEIL_GLOBAL" burst 15k
tc qdisc add dev "$IFACE" parent 1:20 handle 20: sfq perturb 10

# --- Marquage iptables ---
iptables -t mangle -F OUTPUT 2>/dev/null || true

if is_active "$BW_VIDEO"; then
  # Les réponses venant du port 8080 (server.js) = segments vidéo → mark 10
  iptables -t mangle -A OUTPUT -p tcp --sport 8080 -j MARK --set-mark 10
  tc filter add dev "$IFACE" parent 1: protocol ip prio 1 handle 10 fw classid 1:10
  echo "  Filtre vidéo (port 8080) → classe 1:10"
fi

echo "  tc configuré :"
tc qdisc show dev "$IFACE"
echo ""
echo "  Démarrage nginx..."
exec nginx -g "daemon off;"
