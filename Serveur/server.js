/**
 * server.js — Serveur HTTP pour MPEG-DASH SRD
 * Sert le dossier tiles_output/ avec les bons headers CORS et MIME
 *
 * Usage : node server.js [port]
 * Défaut : http://localhost:8080
 *
 * Requis : Node.js ≥ 14 (aucune dépendance externe)
 */

const http  = require('http');
const fs    = require('fs');
const path  = require('path');
const url   = require('url');

const PORT      = parseInt(process.argv[2] || process.env.PORT || '8080', 10);
const ROOT_DIR  = path.join(__dirname, 'tiles_output');
const PLAYER    = path.join(__dirname, 'player_srd.html');

// ─── Types MIME ──────────────────────────────────────────────────────────────
const MIME = {
  '.mpd'  : 'application/dash+xml',
  '.mp4'  : 'video/mp4',
  '.m4s'  : 'video/iso.segment',
  '.m4a'  : 'audio/mp4',
  '.json' : 'application/json',
  '.html' : 'text/html; charset=utf-8',
  '.js'   : 'text/javascript',
  '.css'  : 'text/css',
  '.ico'  : 'image/x-icon',
};

// ─── Headers CORS + cache ─────────────────────────────────────────────────────
function baseHeaders(ext, size) {
  const h = {
    'Access-Control-Allow-Origin'  : '*',
    'Access-Control-Allow-Methods' : 'GET, HEAD, OPTIONS',
    'Access-Control-Allow-Headers' : 'Range, Content-Type',
    'Access-Control-Expose-Headers': 'Content-Length, Content-Range',
    'Content-Type' : MIME[ext] || 'application/octet-stream',
  };
  if (size !== undefined) h['Content-Length'] = size;

  // Cache agressif pour les segments, léger pour le MPD
  if (ext === '.m4s' || ext === '.mp4') {
    h['Cache-Control'] = 'public, max-age=3600';
  } else if (ext === '.mpd' || ext === '.json') {
    h['Cache-Control'] = 'no-cache';
  }
  return h;
}

// ─── Lecture partielle (Range) ─────────────────────────────────────────────
function serveFile(req, res, filePath, ext) {
  fs.stat(filePath, (err, stat) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('404 — Fichier non trouvé : ' + filePath);
      return;
    }

    const total = stat.size;
    const rangeHeader = req.headers['range'];

    if (rangeHeader) {
      // Support Range requests (utile pour la lecture DASH)
      const parts  = rangeHeader.replace(/bytes=/, '').split('-');
      const start  = parseInt(parts[0], 10);
      const end    = parts[1] ? parseInt(parts[1], 10) : total - 1;
      const chunkSize = (end - start) + 1;

      const headers = baseHeaders(ext);
      headers['Content-Range']  = `bytes ${start}-${end}/${total}`;
      headers['Accept-Ranges']  = 'bytes';
      headers['Content-Length'] = chunkSize;

      res.writeHead(206, headers);
      const stream = fs.createReadStream(filePath, { start, end });
      stream.pipe(res);
    } else {
      const headers = baseHeaders(ext, total);
      headers['Accept-Ranges'] = 'bytes';
      res.writeHead(200, headers);
      fs.createReadStream(filePath).pipe(res);
    }
  });
}

// ─── Requête principale ───────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, baseHeaders('', undefined));
    res.end();
    return;
  }

  const parsed   = url.parse(req.url);
  let   pathname = decodeURIComponent(parsed.pathname);

  // ── Lecteur HTML à la racine ──────────────────────────────────────────────
  if (pathname === '/' || pathname === '/player' || pathname === '/index.html') {
    if (fs.existsSync(PLAYER)) {
      return serveFile(req, res, PLAYER, '.html');
    } else {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('player_srd.html non trouvé. Placez-le à côté de server.js.');
      return;
    }
  }

  // ── Fichiers statiques sous /tiles/ ──────────────────────────────────────
  if (pathname.startsWith('/tiles/')) {
    pathname = pathname.slice('/tiles/'.length);
  } else {
    pathname = pathname.replace(/^\//, '');
  }

  const filePath = path.join(ROOT_DIR, pathname);

  // Sécurité : empêcher directory traversal
  if (!filePath.startsWith(ROOT_DIR)) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('403 Interdit');
    return;
  }

  const ext = path.extname(filePath).toLowerCase();
  serveFile(req, res, filePath, ext);
});

server.listen(PORT, () => {
  console.log('');
  console.log('═══════════════════════════════════════════════════');
  console.log('  VideoROI-Impact — Serveur MPEG-DASH SRD');
  console.log('═══════════════════════════════════════════════════');
  console.log(`  Lecteur  : http://localhost:${PORT}/`);
  console.log(`  Tiles    : http://localhost:${PORT}/tiles/`);
  console.log(`  Manifest : http://localhost:${PORT}/tiles/manifest_srd.mpd`);
  console.log(`  Config   : http://localhost:${PORT}/tiles/config.json`);
  console.log('');
  console.log('  Arrêt : Ctrl+C');
  console.log('═══════════════════════════════════════════════════');
  console.log('');
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`ERREUR : Le port ${PORT} est déjà utilisé.`);
    console.error(`Essayez : node server.js ${PORT + 1}`);
  } else {
    console.error('Erreur serveur :', err.message);
  }
  process.exit(1);
});
