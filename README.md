# Impact-des-ROI-sur-le-streaming-vid-o
Lecteur vidéo adaptatif basé sur MPEG-DASH SRD (Spatial Relationship Description) avec sélection de région d'intérêt (ROI) et allocation dynamique de la qualité selon la bande passante disponible.  

  Implémentation de référence d'après :  Niamut et al., "MPEG DASH SRD", MMSys 2016 

  Le Feuvre &amp; Concolato, "Tiled-based Adaptive Streaming", MMSys 2016

## Principe

La vidéo source est découpée en une grille de tuiles indépendantes (par défaut 4×3 = 12 tuiles). Chaque tuile est encodée en 3 qualités (HQ / MD / LQ). Le lecteur attribue automatiquement la meilleure qualité à la tuile sur laquelle l'utilisateur clique (la ROI), et dégrade les tuiles restantes en fonction du débit réseau disponible.

## Les 4 états adaptatifs

| État | Condition | ROI | Autres tuiles |
|---|---|---|---|
| **État 1** | BW ≥ 21 600 kbps | HQ | HQ |
| **État 2** | BW ≥ 8 400 kbps | HQ | MD |
| **État 3** | BW ≥ 1 800 kbps | HQ | LQ |
| **État 4** | BW < 1 800 kbps | MD ⚠ | LQ |

## Architecture

```text
VideoROI-Impact/
├── encode_srd_pipeline.sh   # Pipeline FFmpeg : encodage + segmentation + manifest SRD
├── player_srd.html          # Lecteur DASH SRD à 4 états (HTML/JS, sans dépendance)
├── server.js                # Serveur HTTP Node.js (CORS, Range, MIME)
└── tiles_output/            # Généré par le pipeline
    ├── manifest_srd.mpd     # Manifest MPEG-DASH SRD unifié
    ├── config.json          # Configuration du lecteur (grille, seuils, qualités)
    ├── video_bg.mp4         # Fond LQ global (source brute)
    ├── bg/                  # Fond LQ segmenté en DASH
    └── tile_N/              # Une entrée par tuile (N = 0 … TOTAL-1)
        ├── hq/              # Segments haute qualité  (init.mp4, seg*.m4s)
        ├── md/              # Segments qualité moyenne
        └── lq/              # Segments basse qualité
```
## Prérequis

* **FFmpeg ≥ 4.x** avec support libx264
* **Python 3** (calcul de la durée ISO 8601 dans le pipeline)
* **Node.js ≥ 14** (serveur HTTP, aucune dépendance npm)

```bash
# Vérification rapide
ffmpeg -version
python3 --version
node --version
```
## Utilisation

### 1. Encoder la vidéo

```bash
./encode_srd_pipeline.sh input.mp4 [cols] [rows]

# Exemple : grille 4×3 (défaut)
./encode_sr
d_pipeline.sh video.mp4 4 3
```
Le script exécute 7 étapes automatiques :
1. Pré-scaling de la source vers 1920×1080
2. Encodage du fond LQ global
3. Encodage de chaque tuile × 3 qualités (HQ / MD / LQ)
4. Segmentation DASH de chaque tuile (segments de 4 s)
5. Segmentation DASH du fond LQ
6. Génération du manifest SRD unifié (`manifest_srd.mpd`)
7. Génération de `config.json` pour le lecteur

### 2. Lancer le serveur

```bash
node server.js          # port 8080 par défaut
node server.js 9090     # port personnalisé
```
### 3. Ouvrir le lecteur
```
http://localhost:8080/
```
## Paramètres d'encodage

Les valeurs par défaut peuvent être modifiées en tête du script `encode_srd_pipeline.sh` :

| Paramètre | Défaut | Description |
|---|---|---|
| `SEG_DUR` | 4 s | Durée d'un segment DASH |
| `PRESET` | fast | Preset x264 (ultrafast → slow) |
| `BW_HQ` | 1 800 kbps | Bitrate cible par tuile HQ |
| `BW_MD` | 600 kbps | Bitrate cible par tuile MD |
| `BW_LQ` | 50 kbps | Bitrate cible par tuile LQ |
| `LQ_SCALE` | 4 | Diviseur de résolution LQ (¼ natif) |
| `MD_SCALE` | 1 | Diviseur de résolution MD (natif) |

## Serveur HTTP

`server.js` est un serveur Node.js natif (zéro dépendance) qui expose :

| URL | Contenu |
|---|---|
| `http://localhost:8080/` | Lecteur `player_srd.html` |
| `http://localhost:8080/tiles/` | Dossier `tiles_output/` |
| `http://localhost:8080/tiles/manifest_srd.mpd` | Manifest SRD |
| `http://localhost:8080/tiles/config.json` | Config lecteur |

**Fonctionnalités :** headers CORS complets, support des Range requests (lecture DASH), cache agressif sur les segments `.m4s`, no-cache sur le manifest `.mpd`.

## Références

* ISO/IEC 23009-1:2014/Amd 2:2015 — MPEG-DASH SRD
* O. A. Niamut et al., "MPEG DASH SRD: Spatial Relationship Description", ACM MMSys 2016
* J. Le Feuvre & C. Concolato, "Tiled-based Adaptive Streaming using MPEG-DASH", ACM MMSys 2016
