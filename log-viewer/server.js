#!/usr/bin/env node

const express = require('express');
const fs = require('fs');
const path = require('path');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const ENV_PATH = path.join(PROJECT_ROOT, '.env');
const PUBLIC_DIR = path.join(__dirname, 'public');

function loadEnvFile(filePath) {
  const env = {};
  if (!fs.existsSync(filePath)) {
    return env;
  }

  const contents = fs.readFileSync(filePath, 'utf8');
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) {
      continue;
    }

    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!match) {
      continue;
    }

    let value = match[2] || '';
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }

    env[match[1]] = value;
  }

  return env;
}

const envFromFile = loadEnvFile(ENV_PATH);
const LOG_DIR_VALUE = process.env.LOG_DIR || envFromFile.LOG_DIR || './logs';
const PORT = Number.parseInt(process.env.LOG_VIEWER_PORT || envFromFile.LOG_VIEWER_PORT || '3000', 10);
const AUTH_TOKEN = process.env.LOG_VIEWER_AUTH_TOKEN || envFromFile.LOG_VIEWER_AUTH_TOKEN || '';

const LOG_DIR = path.isAbsolute(LOG_DIR_VALUE)
  ? LOG_DIR_VALUE
  : path.resolve(PROJECT_ROOT, LOG_DIR_VALUE);

const LOG_LINE_RE = /^(\d{4}-\d{2}-\d{2}T\S+)\s+\[(INFO|WARN|ERROR)\]\s?(.*)$/i;

function getServiceFromFilename(filename) {
  if (/^issue-worker-\d{4}-\d{2}-\d{2}\.log$/.test(filename)) return 'issue-worker';
  if (/^feedback-worker-\d{4}-\d{2}-\d{2}\.log$/.test(filename)) return 'feedback-worker';
  if (/^agent-issue-/.test(filename)) return 'agent-issue';
  if (/^agent-feedback-/.test(filename)) return 'agent-feedback';
  if (/^tests-issue-/.test(filename)) return 'tests-issue';
  if (/^tests-feedback-/.test(filename)) return 'tests-feedback';
  if (/^cron-issue\.log$/.test(filename)) return 'cron-issue';
  if (/^cron-feedback\.log$/.test(filename)) return 'cron-feedback';
  return filename;
}

async function listLogFiles() {
  if (!fs.existsSync(LOG_DIR)) {
    return [];
  }

  const dirEntries = await fs.promises.readdir(LOG_DIR, { withFileTypes: true });
  const logFiles = dirEntries
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.log'))
    .map((entry) => entry.name);

  const files = await Promise.all(
    logFiles.map(async (name) => {
      const filePath = path.join(LOG_DIR, name);
      const stats = await fs.promises.stat(filePath);
      return {
        file: name,
        size: stats.size,
        mtime: stats.mtime.toISOString(),
        mtimeMs: stats.mtimeMs,
      };
    })
  );

  files.sort((a, b) => b.mtimeMs - a.mtimeMs || a.file.localeCompare(b.file));
  return files;
}

async function readLinesReverse(filePath, onLine) {
  const CHUNK_SIZE = 64 * 1024;
  const handle = await fs.promises.open(filePath, 'r');

  try {
    const stats = await handle.stat();
    let position = stats.size;
    let leftover = '';

    while (position > 0) {
      const readSize = Math.min(CHUNK_SIZE, position);
      position -= readSize;

      const buffer = Buffer.allocUnsafe(readSize);
      await handle.read(buffer, 0, readSize, position);

      const data = buffer.toString('utf8') + leftover;
      const lines = data.split('\n');
      leftover = lines.shift() || '';

      for (let i = lines.length - 1; i >= 0; i -= 1) {
        await onLine(lines[i].replace(/\r$/, ''));
      }
    }

    if (leftover.length > 0) {
      await onLine(leftover.replace(/\r$/, ''));
    }
  } finally {
    await handle.close();
  }
}

async function parseLogFile(file, options) {
  const filePath = path.join(LOG_DIR, file);
  const service = getServiceFromFilename(file);
  const entries = [];

  const levelFilter = options.level ? options.level.toLowerCase() : '';
  const searchFilter = options.search ? options.search.toLowerCase() : '';

  let continuation = [];
  let seenMatch = false;

  await readLinesReverse(filePath, async (line) => {
    if (!line && continuation.length === 0 && !seenMatch) {
      return;
    }

    const match = line.match(LOG_LINE_RE);
    if (!match) {
      continuation.unshift(line);
      return;
    }

    seenMatch = true;

    const timestamp = match[1];
    const level = match[2].toUpperCase();
    const baseMessage = match[3] || '';

    const message = continuation.length > 0
      ? (baseMessage ? `${baseMessage}\n${continuation.join('\n')}` : continuation.join('\n'))
      : baseMessage;

    continuation = [];

    if (levelFilter && level.toLowerCase() !== levelFilter) {
      return;
    }
    if (searchFilter && !message.toLowerCase().includes(searchFilter)) {
      return;
    }

    entries.push({
      level,
      message,
      service,
      timestamp,
      file,
      _ts: Date.parse(timestamp) || 0,
    });
  });

  return entries;
}

function sanitizeFileParam(fileParam) {
  if (!fileParam) {
    return '';
  }
  if (typeof fileParam !== 'string') {
    return '';
  }

  const normalized = path.basename(fileParam);
  if (normalized !== fileParam) {
    return '';
  }

  return normalized;
}

function toPositiveInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return parsed;
}

function buildUnauthorizedHtml() {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>coding-agent log viewer</title>
  <style>
    body { margin: 0; background: #0a0a0a; color: #f5f5f5; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    .wrap { min-height: 100vh; display: grid; place-items: center; padding: 20px; }
    .card { width: 100%; max-width: 420px; background: #111; border: 1px solid #222; border-radius: 10px; padding: 18px; }
    h1 { margin: 0 0 12px; font-size: 18px; }
    p { margin: 0 0 12px; color: #c6c6c6; }
    input { width: 100%; box-sizing: border-box; padding: 10px; border-radius: 8px; border: 1px solid #333; background: #0f0f0f; color: #fff; }
    button { margin-top: 10px; width: 100%; border: 0; border-radius: 8px; padding: 10px; background: #fff; color: #111; font-weight: 700; cursor: pointer; }
    .error { margin-top: 10px; color: #ff6b6b; min-height: 1em; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Authentication required</h1>
      <p>Enter <code>LOG_VIEWER_AUTH_TOKEN</code> to open the dashboard.</p>
      <input id="token" type="password" placeholder="Bearer token" autofocus />
      <button id="submit">Open Log Viewer</button>
      <div id="error" class="error"></div>
    </div>
  </div>
  <script>
    const tokenInput = document.getElementById('token');
    const submitButton = document.getElementById('submit');
    const errorEl = document.getElementById('error');

    async function tryOpen(withPrompt) {
      const token = (tokenInput.value || localStorage.getItem('logViewerToken') || '').trim();
      if (!token) {
        if (withPrompt) errorEl.textContent = 'Token is required.';
        return;
      }

      localStorage.setItem('logViewerToken', token);
      const response = await fetch('/index.html', {
        headers: { Authorization: 'Bearer ' + token },
      });

      if (response.status === 401) {
        errorEl.textContent = 'Token is invalid.';
        return;
      }

      const html = await response.text();
      document.open();
      document.write(html);
      document.close();
    }

    submitButton.addEventListener('click', () => {
      void tryOpen(true);
    });

    tokenInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        void tryOpen(true);
      }
    });

    void tryOpen(false);
  </script>
</body>
</html>`;
}

const app = express();

if (AUTH_TOKEN) {
  app.use((req, res, next) => {
    const authHeader = req.headers.authorization || '';
    if (authHeader === `Bearer ${AUTH_TOKEN}`) {
      return next();
    }

    if (req.method === 'GET' && (req.path === '/' || req.path === '/index.html')) {
      res.status(401).type('html').send(buildUnauthorizedHtml());
      return;
    }

    if (req.path.startsWith('/api/')) {
      res.status(401).json({ error: 'Unauthorized' });
      return;
    }

    res.status(401).send('Unauthorized');
  });
}

app.get('/api/files', async (_req, res) => {
  try {
    const files = await listLogFiles();
    res.json({ files });
  } catch (error) {
    res.status(500).json({ error: `Failed to list log files: ${error.message}` });
  }
});

app.get('/api/logs', async (req, res) => {
  try {
    const rawFile = typeof req.query.file === 'string' ? req.query.file.trim() : '';
    const requestedFile = sanitizeFileParam(rawFile);
    const level = typeof req.query.level === 'string' ? req.query.level.trim() : '';
    const normalizedLevel = /^(info|warn|error)$/i.test(level) ? level.toLowerCase() : '';
    const search = typeof req.query.search === 'string' ? req.query.search.trim() : '';
    const page = toPositiveInt(req.query.page, 1);
    const limit = Math.min(toPositiveInt(req.query.limit, 50), 500);

    if (rawFile && !requestedFile) {
      res.status(400).json({ error: 'Invalid file parameter' });
      return;
    }

    const allFiles = await listLogFiles();
    let filesToRead = allFiles.map((entry) => entry.file);

    if (requestedFile) {
      if (!filesToRead.includes(requestedFile)) {
        res.status(404).json({ error: `Log file not found: ${requestedFile}`, files: allFiles });
        return;
      }
      filesToRead = [requestedFile];
    }

    const logs = [];

    for (const file of filesToRead) {
      const fileEntries = await parseLogFile(file, {
        level: normalizedLevel,
        search,
      });
      logs.push(...fileEntries);
    }

    logs.sort((a, b) => b._ts - a._ts || b.timestamp.localeCompare(a.timestamp));

    const totalLogs = logs.length;
    const totalPages = totalLogs > 0 ? Math.ceil(totalLogs / limit) : 1;
    const currentPage = Math.min(page, totalPages);
    const startIndex = (currentPage - 1) * limit;
    const endIndex = startIndex + limit;

    const pageLogs = logs.slice(startIndex, endIndex).map(({ _ts, ...entry }) => entry);

    res.json({
      logs: pageLogs,
      totalLogs,
      currentPage,
      totalPages,
      files: allFiles,
    });
  } catch (error) {
    res.status(500).json({ error: `Failed to read logs: ${error.message}` });
  }
});

app.use(express.static(PUBLIC_DIR));

app.listen(PORT, () => {
  console.log(`[log-viewer] listening on http://0.0.0.0:${PORT}`);
  console.log(`[log-viewer] log dir: ${LOG_DIR}`);
  if (AUTH_TOKEN) {
    console.log('[log-viewer] auth: enabled');
  }
});
