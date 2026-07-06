
#!/usr/bin/env bash

set -euo pipefail

INPUT="${1:?Usage: $0 input.mp4 [cols] [rows]}"
COLS="${2:-4}"
ROWS="${3:-3}"
TOTAL=$(( COLS * ROWS ))
OUT="./tiles_output"
SEG_DUR=4           # durée segment en secondes
PRESET="fast"       # preset FFmpeg : ultrafast, superfast, veryfast, faster, fast, medium

# ─── Bitrates par tuile (kbps) — calibré pour le player 4-états ─────────────
#
#   ÉTAT 1 (BW ≥ 21 600 kbps)   : 12 × HQ = 21 600 kbps    [tout HQ]
#   ÉTAT 2 (BW ≥ 8 400 kbps)    : 1×HQ + 11×MD = 8 400     [ROI HQ + autres MD]
#   ÉTAT 3 (BW ≥ 1 800 kbps)    : 1×HQ + 11×LQ ≈ 2 350     [ROI HQ + autres LQ]
#   ÉTAT 4 (BW < 1 800 kbps)    : 1×MD + 11×LQ ≈ 1 150     [ROI MD ⚠ + autres LQ]
#
BW_HQ=1800          # Haute qualité — ROI sélectionnée (états 1-3)
BW_MD=600           # Qualité moyenne — états 2 (toutes non-ROI) et 4 (ROI forcée)
BW_LQ=50            # Basse qualité — fond / hors ROI (états 3-4), résolution réduite

# ─── Résolution réduite pour LQ et MD ────────────────────────────────────────
# LQ : résolution ÷4 (120×90 pour grille 4×3 1080p) → segments ~3-5 KB
# MD : résolution native (480×360) car bitrate suffisant pour qualité correcte
LQ_SCALE=4          # diviseur résolution LQ (1=natif, 2=½, 4=¼)
MD_SCALE=1          # MD garde la résolution native

# ─── Résolution globale cible ─────────────────────────────────────────────────
# On force 1920x1080 divisible par COLS et ROWS
TARGET_W=1920
TARGET_H=1080

echo "================================================================="
echo "  VideoROI-Impact — Pipeline MPEG-DASH SRD (HQ + MD + LQ)"
echo "  Basé sur Niamut et al. & Le Feuvre & Concolato (MMSys 2016)"
echo "================================================================="
echo ""

# ─── Vérifier les dépendances ─────────────────────────────────────────────────
for cmd in ffmpeg ffprobe python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERREUR : '$cmd' non trouvé. Installez FFmpeg et Python3."
    exit 1
  fi
done

# ─── Calculer la taille des tuiles (alignée sur 2 pixels) ────────────────────
TW=$(( (TARGET_W / COLS / 2) * 2 ))
TH=$(( (TARGET_H / ROWS / 2) * 2 ))
TOTAL_W=$(( TW * COLS ))
TOTAL_H=$(( TH * ROWS ))
FPS=30

# Dimensions LQ et MD selon les scales
LQ_W=$(( (TW / LQ_SCALE / 2) * 2 ))
LQ_H=$(( (TH / LQ_SCALE / 2) * 2 ))
MD_W=$(( (TW / MD_SCALE / 2) * 2 ))
MD_H=$(( (TH / MD_SCALE / 2) * 2 ))

# Seuils des 4 états (kbps)
TH_S1=$(( TOTAL * BW_HQ ))
TH_S2=$(( BW_HQ + (TOTAL - 1) * BW_MD ))
TH_S3=$(( BW_HQ + (TOTAL - 1) * BW_LQ ))

echo "Source   : $INPUT"
echo "Grille   : ${COLS}×${ROWS} = ${TOTAL} tuiles"
echo "Tuile    : ${TW}×${TH} pixels"
echo "Espace   : ${TOTAL_W}×${TOTAL_H} pixels"
echo "Qualités :"
echo "  HQ : ${BW_HQ} kbps  ${TW}×${TH}    (ROI sélectionnée)"
echo "  MD : ${BW_MD} kbps  ${MD_W}×${MD_H}    (états 2 et 4)"
echo "  LQ : ${BW_LQ} kbps  ${LQ_W}×${LQ_H}    (états 3 et 4)"
echo ""
echo "Seuils des 4 états du player :"
echo "  ÉTAT 1 ≥ ${TH_S1} kbps : tout HQ"
echo "  ÉTAT 2 ≥ ${TH_S2} kbps : ROI HQ + autres MD"
echo "  ÉTAT 3 ≥ ${TH_S3} kbps : ROI HQ + autres LQ"
echo "  ÉTAT 4 < ${TH_S3} kbps : ROI MD ⚠ + autres LQ (alerte)"
echo ""

mkdir -p "$OUT"

# =============================================================================
# ÉTAPE 1 — Pré-scaling source → résolution cible
# "partitioning each frame into multiple frames of smaller resolution"
# On encode en lossless ultrafast pour éviter N re-décodages
# =============================================================================
SCALED="${OUT}/_scaled.mp4"

if [ ! -f "$SCALED" ]; then
  echo ">>> ÉTAPE 1 — Pré-scaling vers ${TOTAL_W}×${TOTAL_H}..."
  ffmpeg -y -i "$INPUT" \
    -vf "scale=${TOTAL_W}:${TOTAL_H}:flags=lanczos" \
    -c:v libx264 -crf 0 -preset ultrafast \
    -r ${FPS} -an \
    "$SCALED"
  echo "    ✓ Scaled : $SCALED"
else
  echo ">>> ÉTAPE 1 — Scaled déjà existant, on passe."
fi

# =============================================================================
# ÉTAPE 2 — Encodage vidéo globale (fond LQ)
# Le lecteur utilise la vidéo globale LQ comme arrière-plan permanent.
# =============================================================================
# echo ""
# echo ">>> ÉTAPE 2 — Encodage global (fond LQ)..."

# KEYFRAME_OPTS="-force_key_frames expr:gte(t,n_forced*${SEG_DUR}) \
#   -g $(( FPS * SEG_DUR )) \
#   -keyint_min $(( FPS * SEG_DUR )) \
#   -sc_threshold 0"

# # Fond LQ global
# if [ ! -f "${OUT}/video_bg.mp4" ]; then
#   ffmpeg -y -i "$SCALED" \
#     -c:v libx264 \
#     -b:v $(( BW_LQ * COLS * ROWS / 4 ))k \
#     -maxrate $(( BW_LQ * COLS * ROWS / 2 ))k \
#     -bufsize $(( BW_LQ * COLS * ROWS ))k \
#     -profile:v baseline -level 3.1 \
#     -force_key_frames "expr:gte(t,n_forced*${SEG_DUR})" \
#     -g $(( FPS * SEG_DUR )) -keyint_min $(( FPS * SEG_DUR )) -sc_threshold 0 \
#     -vf "scale=$((TOTAL_W/2)):$((TOTAL_H/2))" \
#     -movflags +faststart -an \
#     "${OUT}/video_bg.mp4"
#   echo "    ✓ Fond LQ : ${OUT}/video_bg.mp4"
# fi

# Audio global

# =============================================================================
# ÉTAPE 3 — Encodage individuel de chaque tuile × 3 qualités
# "tiles are defined as a spatial segmentation of the video content
#  into a regular grid of independent videos" — Niamut et al.
# "independent AVC tile encoding" — Le Feuvre & Concolato
#
# Paramètres clé :
#   - keyframes synchronisées → seek précis entre tuiles
#   - sc_threshold 0 → pas de keyframe sur changement de scène (sync)
#   - même gop_size sur HQ/MD/LQ → switching sans artefact
# =============================================================================
echo ""
echo ">>> ÉTAPE 3 — Encodage ${TOTAL} tuiles × 3 qualités (HQ/MD/LQ)..."

encode_tile_quality() {
  local tile_dir="$1"
  local quality="$2"   # hq | md | lq
  local bitrate="$3"
  local profile="$4"   # high | main | baseline
  local level="$5"     # 4.0 | 3.2 | 3.1
  local crop_filter="$6"
  local scale_div="${7:-1}"   # diviseur résolution (1=natif, 2=½, 4=¼)

  local out_file="${tile_dir}/raw_${quality}.mp4"

  if [ -f "$out_file" ]; then
    echo "      [skip] ${quality} existant"
    return
  fi

  # Construire le filtre vidéo : crop + scale optionnel
  local vf_filter="$crop_filter"
  if [ "$scale_div" -gt 1 ]; then
    local sw=$(( TW / scale_div ))
    local sh=$(( TH / scale_div ))
    # Aligner sur 2 pixels (requis H.264)
    sw=$(( (sw / 2) * 2 ))
    sh=$(( (sh / 2) * 2 ))
    vf_filter="${crop_filter},scale=${sw}:${sh}:flags=lanczos"
  fi

  ffmpeg -y -i "$SCALED" \
    -vf "$vf_filter" \
    -c:v libx264 \
    -b:v ${bitrate}k \
    -maxrate $(( bitrate * 2 ))k \
    -bufsize $(( bitrate * 4 ))k \
    -profile:v "$profile" -level "$level" \
    -force_key_frames "expr:gte(t,n_forced*${SEG_DUR})" \
    -g $(( FPS * SEG_DUR )) \
    -keyint_min $(( FPS * SEG_DUR )) \
    -sc_threshold 0 \
    -preset "$PRESET" \
    -movflags +faststart -an \
    "$out_file"
}

for (( ROW=0; ROW<ROWS; ROW++ )); do
for (( COL=0; COL<COLS; COL++ )); do

  IDX=$(( ROW * COLS + COL ))
  NAME="T$(( IDX + 1 ))"
  X=$(( COL * TW ))
  Y=$(( ROW * TH ))
  TILE_DIR="${OUT}/tile_${IDX}"
  CROP="crop=${TW}:${TH}:${X}:${Y}"

  mkdir -p "${TILE_DIR}"
  echo "  [${NAME}] col=${COL} row=${ROW}  offset=(${X},${Y})  ${TW}×${TH}"

  encode_tile_quality "$TILE_DIR" "hq" "$BW_HQ" "high"     "4.0" "$CROP" "1"
  encode_tile_quality "$TILE_DIR" "md" "$BW_MD" "main"     "3.2" "$CROP" "$MD_SCALE"
  encode_tile_quality "$TILE_DIR" "lq" "$BW_LQ" "baseline" "3.1" "$CROP" "$LQ_SCALE"

  echo "    ✓ ${NAME} — HQ + MD + LQ encodés"

done
done

# =============================================================================
# ÉTAPE 4 — Segmentation DASH de chaque tuile × 3 qualités
# "we ensure that all segments sizes are equal" — Le Feuvre & Concolato
# "the first video frame of a segment is an intra-coded frame"
# =============================================================================
echo ""
echo ">>> ÉTAPE 4 — Segmentation DASH (${SEG_DUR}s par segment)..."

segment_dash() {
  local src="$1"
  local seg_dir="$2"
  local mpd_out="$3"

  rm -rf "$seg_dir"
  mkdir -p "$seg_dir"

  # Chemins absolus pour pouvoir cd dans seg_dir sans casser les refs
  local abs_src abs_mpd abs_seg
  abs_src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
  abs_mpd="$(cd "$(dirname "$mpd_out")" && pwd)/$(basename "$mpd_out")"
  abs_seg="$(cd "$seg_dir" && pwd)"

  # ffmpeg interprète -init_seg_name et -media_seg_name
  # relativement au dossier du fichier MPD de sortie.
  # En lancant depuis abs_seg et en mettant abs_seg comme
  # dossier parent du MPD, les deux coïncident → pas de duplication.
  (
    cd "$abs_seg"
    ffmpeg -y -i "$abs_src"       -c copy       -f dash       -seg_duration ${SEG_DUR}       -use_template 0       -use_timeline 1       -init_seg_name "init.mp4"       -media_seg_name "seg%05d.m4s"       "$abs_mpd"
  )
}

for IDX in $(seq 0 $(( TOTAL - 1 ))); do
  TILE_DIR="${OUT}/tile_${IDX}"
  NAME="T$(( IDX + 1 ))"
  echo "  [${NAME}] segmentation HQ / MD / LQ..."

  segment_dash "${TILE_DIR}/raw_hq.mp4" "${TILE_DIR}/hq" "${TILE_DIR}/manifest_hq.mpd"
  segment_dash "${TILE_DIR}/raw_md.mp4" "${TILE_DIR}/md" "${TILE_DIR}/manifest_md.mpd"
  segment_dash "${TILE_DIR}/raw_lq.mp4" "${TILE_DIR}/lq" "${TILE_DIR}/manifest_lq.mpd"

  echo "    ✓ ${NAME} segmenté"
done

# =============================================================================
# ÉTAPE 5 — Segmentation DASH global (fond LQ)
# =============================================================================
echo ""
echo ">>> ÉTAPE 5 — Segmentation DASH global (fond LQ)..."

rm -rf "${OUT}/bg"
mkdir -p "${OUT}/bg"

ABS_OUT="$(cd "${OUT}" && pwd)"

( cd "${ABS_OUT}/bg"
  ffmpeg -y -i "${ABS_OUT}/video_bg.mp4" \
    -c copy -f dash \
    -seg_duration ${SEG_DUR} \
    -use_template 1 -use_timeline 0 \
    -init_seg_name "init.mp4" \
    -media_seg_name "seg\$Number%05d\$.m4s" \
    "${ABS_OUT}/bg/manifest_bg.mpd"
)
echo "    ✓ Fond LQ segmenté"


# =============================================================================
# ÉTAPE 6 — Génération du manifest SRD unifié (3 représentations par tuile)
# "SRD value = source_id, x, y, w, h, total_w, total_h" — Niamut et al.
# schemeIdUri = "urn:mpeg:dash:srd:2014"
# spatial_set_id groupe les tuiles par résolution (Le Feuvre section 5.2)
# =============================================================================
echo ""
echo ">>> ÉTAPE 6 — Génération du manifest MPEG-DASH SRD..."

DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nk=1 "${OUT}/tile_0/raw_hq.mp4" 2>/dev/null | head -1)
DURATION=${DURATION:-300}

DURATION_ISO=$(python3 -c "
d=float('${DURATION}')
h=int(d//3600); m=int((d%3600)//60); s=d%60
if h>0: print(f'PT{h}H{m}M{s:.3f}S')
elif m>0: print(f'PT{m}M{s:.3f}S')
else: print(f'PT{s:.3f}S')
" 2>/dev/null || echo "PT5M0.000S")

MPD_OUT="${OUT}/manifest_srd.mpd"

# ─── En-tête MPD ─────────────────────────────────────────────────────────────
cat > "$MPD_OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!--
  MPEG-DASH SRD Manifest — VideoROI-Impact
  Standard : ISO/IEC 23009-1:2014/Amd 2:2015
  Ref 1 : Niamut et al., "MPEG DASH SRD", MMSys 2016
  Ref 2 : Le Feuvre & Concolato, "Tiled-based Adaptive Streaming", MMSys 2016
  Grille : ${COLS}×${ROWS} = ${TOTAL} tuiles
  Qualités : HQ(${BW_HQ}k) / MD(${BW_MD}k) / LQ(${BW_LQ}k)
  SRD : source_id, object_x, object_y, object_width, object_height, total_width, total_height
-->
<MPD
  xmlns="urn:mpeg:dash:schema:mpd:2011"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="urn:mpeg:dash:schema:mpd:2011 DASH-MPD.xsd"
  profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"
  type="static"
  mediaPresentationDuration="${DURATION_ISO}"
  minBufferTime="PT${SEG_DUR}S">

  <ProgramInformation>
    <Title>VideoROI-Impact DASH SRD ${COLS}x${ROWS} — HQ/MD/LQ</Title>
  </ProgramInformation>

  <Period id="0" start="PT0S">

EOF

# ─── AdaptationSet par tuile (3 représentations : HQ / MD / LQ) ─────────────
AS_ID=1
for (( ROW=0; ROW<ROWS; ROW++ )); do
for (( COL=0; COL<COLS; COL++ )); do

  IDX=$(( ROW * COLS + COL ))
  X=$(( COL * TW ))
  Y=$(( ROW * TH ))
  TILE_DIR="${OUT}/tile_${IDX}"

  # SRD : source_id=0, x, y, w, h, total_w, total_h
  SRD="0,${X},${Y},${TW},${TH},${TOTAL_W},${TOTAL_H}"

  # Lire les vrais bitrates encodés
  get_bw() {
    local f="$1"
    local fallback="$2"
    local val
    val=$(ffprobe -v error -show_entries format=bit_rate \
      -of default=noprint_wrappers=1:nk=1 "$f" 2>/dev/null | head -1)
    echo "${val:-$fallback}"
  }

  BW_HQ_REAL=$(get_bw "${TILE_DIR}/raw_hq.mp4" "$(( BW_HQ * 1000 ))")
  BW_MD_REAL=$(get_bw "${TILE_DIR}/raw_md.mp4" "$(( BW_MD * 1000 ))")
  BW_LQ_REAL=$(get_bw "${TILE_DIR}/raw_lq.mp4" "$(( BW_LQ * 1000 ))")

  cat >> "$MPD_OUT" <<TILE_OPEN
    <!-- ═══ T$(( IDX+1 )) — col=${COL} row=${ROW} — SRD(${X},${Y},${TW},${TH}) ═══ -->
    <AdaptationSet id="${AS_ID}" contentType="video"
      mimeType="video/mp4" codecs="avc1.640028"
      width="${TW}" height="${TH}" frameRate="${FPS}"
      segmentAlignment="true" bitstreamSwitching="true">

      <!--
        SupplementalProperty → les clients legacy peuvent ignorer et quand même lire
        EssentialProperty    → les clients legacy doivent ignorer cette tuile
        Choix : SupplementalProperty (compatible large déploiement)
      -->
      <SupplementalProperty
        schemeIdUri="urn:mpeg:dash:srd:2014"
        value="${SRD}"/>

      <!-- Représentation HQ — Haute Qualité (ROI sélectionnée) -->
      <Representation id="${AS_ID}_hq" bandwidth="${BW_HQ_REAL}"
        width="${TW}" height="${TH}">
        <SegmentList timescale="1000" duration="$(( SEG_DUR * 1000 ))">
          <Initialization sourceURL="tile_${IDX}/hq/init.mp4"/>
TILE_OPEN

  for seg in "${TILE_DIR}/hq/"seg*.m4s; do
    [ -f "$seg" ] || continue
    echo "          <SegmentURL media=\"tile_${IDX}/hq/$(basename "$seg")\"/>" >> "$MPD_OUT"
  done

  cat >> "$MPD_OUT" <<TILE_MD
        </SegmentList>
      </Representation>

      <!-- Représentation MD — Qualité Moyenne (${MD_W}×${MD_H}) -->
      <Representation id="${AS_ID}_md" bandwidth="${BW_MD_REAL}"
        width="${MD_W}" height="${MD_H}">
        <SegmentList timescale="1000" duration="$(( SEG_DUR * 1000 ))">
          <Initialization sourceURL="tile_${IDX}/md/init.mp4"/>
TILE_MD

  for seg in "${TILE_DIR}/md/"seg*.m4s; do
    [ -f "$seg" ] || continue
    echo "          <SegmentURL media=\"tile_${IDX}/md/$(basename "$seg")\"/>" >> "$MPD_OUT"
  done

  cat >> "$MPD_OUT" <<TILE_LQ
        </SegmentList>
      </Representation>

      <!-- Représentation LQ — Basse Qualité (hors ROI, ${LQ_W}×${LQ_H}) -->
      <Representation id="${AS_ID}_lq" bandwidth="${BW_LQ_REAL}"
        width="${LQ_W}" height="${LQ_H}">
        <SegmentList timescale="1000" duration="$(( SEG_DUR * 1000 ))">
          <Initialization sourceURL="tile_${IDX}/lq/init.mp4"/>
TILE_LQ

  for seg in "${TILE_DIR}/lq/"seg*.m4s; do
    [ -f "$seg" ] || continue
    echo "          <SegmentURL media=\"tile_${IDX}/lq/$(basename "$seg")\"/>" >> "$MPD_OUT"
  done

  cat >> "$MPD_OUT" <<TILE_CLOSE
        </SegmentList>
      </Representation>

    </AdaptationSet>

TILE_CLOSE

  AS_ID=$(( AS_ID + 1 ))

done
done

cat >> "$MPD_OUT" <<MPD_FOOT

  </Period>
</MPD>
MPD_FOOT

echo "    ✓ Manifest SRD : $MPD_OUT"

# =============================================================================
# ÉTAPE 7 — Config JSON pour le lecteur
# =============================================================================
cat > "${OUT}/config.json" <<JSON
{
  "version": "4.0",
  "standard": "MPEG-DASH SRD ISO/IEC 23009-1:2014/Amd 2:2015",
  "cols": ${COLS},
  "rows": ${ROWS},
  "total_tiles": ${TOTAL},
  "video_width": ${TOTAL_W},
  "video_height": ${TOTAL_H},
  "tile_width": ${TW},
  "tile_height": ${TH},
  "tile_width_lq": ${LQ_W},
  "tile_height_lq": ${LQ_H},
  "tile_width_md": ${MD_W},
  "tile_height_md": ${MD_H},
  "lq_scale": ${LQ_SCALE},
  "md_scale": ${MD_SCALE},
  "fps": ${FPS},
  "segment_duration_s": ${SEG_DUR},
  "qualities": {
    "hq": { "bitrate_kbps": ${BW_HQ}, "profile": "high",     "level": "4.0",
            "width": ${TW}, "height": ${TH},
            "use": "ROI sélectionnée (états 1-3)" },
    "md": { "bitrate_kbps": ${BW_MD}, "profile": "main",     "level": "3.2",
            "width": ${MD_W}, "height": ${MD_H},
            "use": "Toutes non-ROI (état 2) / ROI forcée (état 4)" },
    "lq": { "bitrate_kbps": ${BW_LQ}, "profile": "baseline", "level": "3.1",
            "width": ${LQ_W}, "height": ${LQ_H},
            "use": "Toutes non-ROI (états 3-4)" }
  },
  "states": {
    "s1_threshold_kbps": ${TH_S1},
    "s2_threshold_kbps": ${TH_S2},
    "s3_threshold_kbps": ${TH_S3},
    "s1_desc": "BW ≥ ${TH_S1} kbps : tout HQ",
    "s2_desc": "BW ≥ ${TH_S2} kbps : ROI HQ + autres MD",
    "s3_desc": "BW ≥ ${TH_S3} kbps : ROI HQ + autres LQ",
    "s4_desc": "BW < ${TH_S3} kbps : ROI MD ⚠ + autres LQ (alerte)"
  },
  "manifest_srd":   "manifest_srd.mpd",
  "manifest_bg":    "manifest_bg.mpd"
}
JSON
echo "    ✓ Config : ${OUT}/config.json"
echo ""
echo "  Seuils des 4 états calculés :"
echo "    ÉTAT 1 ≥ ${TH_S1} kbps  : tout HQ"
echo "    ÉTAT 2 ≥ ${TH_S2} kbps  : ROI HQ + autres MD"
echo "    ÉTAT 3 ≥ ${TH_S3} kbps  : ROI HQ + autres LQ"
echo "    ÉTAT 4 < ${TH_S3} kbps  : ROI MD ⚠ + autres LQ"

# =============================================================================
# RÉSUMÉ
# =============================================================================
N_SEG=$(ls "${OUT}/tile_0/hq/"seg*.m4s 2>/dev/null | wc -l)
TOTAL_FILES=$(find "$OUT" -name "*.m4s" | wc -l)

echo ""
echo "================================================================="
echo "  Pipeline terminé !"
echo "================================================================="
echo ""
echo "  Vidéo source     : $INPUT"
echo "  Grille           : ${COLS}×${ROWS} = ${TOTAL} tuiles"
echo "  Résolution tuile : ${TW}×${TH} pixels"
echo "  Segments / tuile : ${N_SEG} × 3 qualités = $(( N_SEG * 3 )) segments/tuile"
echo "  Total segments   : ${TOTAL_FILES}"
echo "  Durée segment    : ${SEG_DUR}s"
echo ""
echo "  Fichiers clés :"
echo "    ${OUT}/manifest_srd.mpd     ← manifest SRD principal"
echo "    ${OUT}/config.json          ← config lecteur"
echo "    ${OUT}/tile_N/hq|md|lq/    ← segments par qualité"
echo ""
echo "  Vérification rapide :"
echo "    SRD dans le MPD :"
grep 'srd:2014' "$MPD_OUT" | head -3
echo ""
echo "  Prochaine étape :"
echo "    node server.js"
echo "    → http://localhost:8080"
echo "================================================================="
