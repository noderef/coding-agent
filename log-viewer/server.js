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
const STRUCTURED_DETECTION_LINES = 20;
const MAX_STRUCTURED_LINES_PER_FILE = 2000;
const MAX_UNSTRUCTURED_LINES_PER_FILE = 12000;
const MAX_UNSTRUCTURED_BLOCKS_PER_FILE = 500;
const UNSTRUCTURED_BLOCK_DELIMITER = 'API request started';

const UNSTRUCTURED_ERROR_RE = /\b(?:error|fail(?:ed|ure)?|fatal)\b|✗/i;
const UNSTRUCTURED_WARN_RE = /\bwarn(?:ing)?\b|⚠/i;

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
    let shouldStop = false;

    while (position > 0 && !shouldStop) {
      const readSize = Math.min(CHUNK_SIZE, position);
      position -= readSize;

      const buffer = Buffer.allocUnsafe(readSize);
      await handle.read(buffer, 0, readSize, position);

      const data = buffer.toString('utf8') + leftover;
      const lines = data.split('\n');
      leftover = lines.shift() || '';

      for (let i = lines.length - 1; i >= 0; i -= 1) {
        const keepReading = await onLine(lines[i].replace(/\r$/, ''));
        if (keepReading === false) {
          shouldStop = true;
          break;
        }
      }
    }

    if (!shouldStop && leftover.length > 0) {
      await onLine(leftover.replace(/\r$/, ''));
    }
  } finally {
    await handle.close();
  }
}

async function readFirstLines(filePath, maxLines) {
  const CHUNK_SIZE = 8 * 1024;
  const handle = await fs.promises.open(filePath, 'r');

  try {
    const stats = await handle.stat();
    let position = 0;
    let leftover = '';
    const lines = [];

    while (position < stats.size && lines.length < maxLines) {
      const readSize = Math.min(CHUNK_SIZE, stats.size - position);
      const buffer = Buffer.allocUnsafe(readSize);
      await handle.read(buffer, 0, readSize, position);
      position += readSize;

      const data = leftover + buffer.toString('utf8');
      const parts = data.split('\n');
      leftover = parts.pop() || '';

      for (const part of parts) {
        lines.push(part.replace(/\r$/, ''));
        if (lines.length >= maxLines) {
          break;
        }
      }
    }

    if (lines.length < maxLines && leftover.length > 0) {
      lines.push(leftover.replace(/\r$/, ''));
    }

    return lines;
  } finally {
    await handle.close();
  }
}

async function readRecentLines(filePath, maxLines) {
  const lines = [];

  await readLinesReverse(filePath, async (line) => {
    lines.unshift(line);
    if (lines.length >= maxLines) {
      return false;
    }
    return true;
  });

  return lines;
}

async function isStructuredLogFile(filePath) {
  const firstLines = await readFirstLines(filePath, STRUCTURED_DETECTION_LINES);
  return firstLines.some((line) => LOG_LINE_RE.test(line));
}

function inferLevelFromText(text) {
  if (!text) {
    return 'INFO';
  }
  if (UNSTRUCTURED_ERROR_RE.test(text)) {
    return 'ERROR';
  }
  if (UNSTRUCTURED_WARN_RE.test(text)) {
    return 'WARN';
  }

  return 'INFO';
}

function extractTimestampFromText(text) {
  const timestampMatch = text.match(
    /\b(\d{4}-\d{2}-\d{2}[T ][0-2]\d:[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-][0-2]\d:?[0-5]\d)?)\b/
  );

  if (!timestampMatch) {
    return '';
  }

  const normalized = timestampMatch[1].replace(' ', 'T');
  const parsed = Date.parse(normalized);
  if (Number.isNaN(parsed)) {
    return '';
  }
  return new Date(parsed).toISOString();
}

function shouldIncludeEntry(level, message, levelFilter, searchFilter) {
  if (levelFilter && level.toLowerCase() !== levelFilter) {
    return false;
  }
  if (searchFilter && !message.toLowerCase().includes(searchFilter)) {
    return false;
  }
  return true;
}

function createEntry({ level, message, service, file, timestamp, fallbackTs }) {
  return {
    level,
    message,
    service,
    timestamp,
    file,
    _ts: Date.parse(timestamp) || fallbackTs,
  };
}

function collectPathMatches(text, outputSet) {
  for (const match of text.matchAll(/"path"\s*:\s*"([^"]+)"/gi)) {
    if (match[1]) {
      outputSet.add(match[1]);
    }
  }
}

function collectToolDataFromPayload(payload, toolNames, paths) {
  if (!payload) {
    return;
  }

  try {
    const parsed = JSON.parse(payload);
    if (parsed && typeof parsed === 'object') {
      if (typeof parsed.tool === 'string' && parsed.tool) {
        toolNames.add(parsed.tool);
      }
      if (typeof parsed.path === 'string' && parsed.path) {
        paths.add(parsed.path);
      }
    }
  } catch (_error) {
    // Ignore malformed JSON payloads and fall back to regex extraction.
  }

  const toolMatch = payload.match(/"tool"\s*:\s*"([^"]+)"/i);
  if (toolMatch && toolMatch[1]) {
    toolNames.add(toolMatch[1]);
  }
  collectPathMatches(payload, paths);
}

function formatPreview(items, maxItems) {
  if (items.length <= maxItems) {
    return items.join(', ');
  }
  return `${items.slice(0, maxItems).join(', ')} (+${items.length - maxItems} more)`;
}

function buildUnstructuredMessage(blockLines) {
  const toolNames = new Set();
  const paths = new Set();
  const progressItems = [];

  for (const rawLine of blockLines) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }

    if (/^tool:\s*/i.test(line)) {
      const payload = line.replace(/^tool:\s*/i, '');
      collectToolDataFromPayload(payload, toolNames, paths);
    }

    const taskProgressMatch = line.match(/^task_progress:\s*(.*)$/i);
    if (taskProgressMatch) {
      const progress = taskProgressMatch[1].trim();
      if (progress) {
        progressItems.push(progress);
      }
      continue;
    }

    if (/^-\s\[[ xX]\]/.test(line)) {
      progressItems.push(line);
    }

    collectPathMatches(line, paths);
  }

  const summaries = [];
  const toolList = [...toolNames];
  const pathList = [...paths];

  if (toolList.length > 0) {
    summaries.push(`Tools: ${formatPreview(toolList, 3)}`);
  }
  if (progressItems.length > 0) {
    summaries.push(`Task Progress: ${formatPreview(progressItems, 2)}`);
  }
  if (pathList.length > 0) {
    summaries.push(`Paths: ${formatPreview(pathList, 3)}`);
  }

  const rawMessage = blockLines.join('\n').trim();
  if (summaries.length === 0) {
    return rawMessage;
  }
  return `${summaries.join('\n')}\n\n${rawMessage}`;
}

function splitParagraphBlocks(lines) {
  const blocks = [];
  let paragraph = [];

  const flush = () => {
    if (paragraph.some((line) => line.trim() !== '')) {
      blocks.push(paragraph);
    }
    paragraph = [];
  };

  for (const line of lines) {
    if (line.trim() === '') {
      flush();
      continue;
    }
    paragraph.push(line);
  }

  flush();
  return blocks;
}

function splitUnstructuredBlocks(lines) {
  const blocks = [];
  const normalizedDelimiter = UNSTRUCTURED_BLOCK_DELIMITER.toLowerCase();
  let current = [];
  let hasDelimiter = false;

  const flush = () => {
    if (current.some((line) => line.trim() !== '')) {
      blocks.push(current);
    }
    current = [];
  };

  for (const line of lines) {
    const isDelimiter = line.trim().toLowerCase() === normalizedDelimiter;
    if (isDelimiter) {
      hasDelimiter = true;
      flush();
      current = [line];
      continue;
    }
    current.push(line);
  }

  flush();

  if (hasDelimiter) {
    return blocks;
  }

  return splitParagraphBlocks(lines);
}

async function parseStructuredLogFile(filePath, file, service, options, fallbackTimestamp, fallbackTsMs) {
  const entries = [];
  const levelFilter = options.level ? options.level.toLowerCase() : '';
  const searchFilter = options.search ? options.search.toLowerCase() : '';

  let continuation = [];
  let seenMatch = false;
  let processedLines = 0;

  await readLinesReverse(filePath, async (line) => {
    processedLines += 1;

    if (!line && continuation.length === 0 && !seenMatch) {
      return processedLines < MAX_STRUCTURED_LINES_PER_FILE;
    }

    const match = line.match(LOG_LINE_RE);
    if (!match) {
      continuation.unshift(line);
      return processedLines < MAX_STRUCTURED_LINES_PER_FILE;
    }

    seenMatch = true;

    const timestamp = match[1];
    const level = match[2].toUpperCase();
    const baseMessage = match[3] || '';

    const message = continuation.length > 0
      ? (baseMessage ? `${baseMessage}\n${continuation.join('\n')}` : continuation.join('\n'))
      : baseMessage;

    continuation = [];

    if (shouldIncludeEntry(level, message, levelFilter, searchFilter)) {
      entries.push(
        createEntry({
          level,
          message,
          service,
          file,
          timestamp,
          fallbackTs: fallbackTsMs,
        })
      );
    }

    return processedLines < MAX_STRUCTURED_LINES_PER_FILE;
  });

  if (continuation.some((line) => line.trim() !== '')) {
    const message = continuation.join('\n');
    const level = inferLevelFromText(message);
    const timestamp = extractTimestampFromText(message) || fallbackTimestamp;

    if (shouldIncludeEntry(level, message, levelFilter, searchFilter)) {
      entries.push(
        createEntry({
          level,
          message,
          service,
          file,
          timestamp,
          fallbackTs: fallbackTsMs,
        })
      );
    }
  }

  return entries;
}

async function parseUnstructuredLogFile(filePath, file, service, options, fallbackTimestamp, fallbackTsMs) {
  const entries = [];
  const levelFilter = options.level ? options.level.toLowerCase() : '';
  const searchFilter = options.search ? options.search.toLowerCase() : '';
  const lines = await readRecentLines(filePath, MAX_UNSTRUCTURED_LINES_PER_FILE);
  const allBlocks = splitUnstructuredBlocks(lines);
  const recentBlocks = allBlocks.slice(-MAX_UNSTRUCTURED_BLOCKS_PER_FILE);

  for (let index = recentBlocks.length - 1; index >= 0; index -= 1) {
    const block = recentBlocks[index];
    const blockText = block.join('\n').trim();
    if (!blockText) {
      continue;
    }

    const message = buildUnstructuredMessage(block);
    const level = inferLevelFromText(blockText);
    const timestamp = extractTimestampFromText(blockText) || fallbackTimestamp;

    if (shouldIncludeEntry(level, message, levelFilter, searchFilter)) {
      entries.push(
        createEntry({
          level,
          message,
          service,
          file,
          timestamp,
          fallbackTs: fallbackTsMs + index,
        })
      );
    }
  }

  return entries;
}

async function parseLogFile(file, options) {
  const filePath = path.join(LOG_DIR, file);
  const service = getServiceFromFilename(file);
  const stats = await fs.promises.stat(filePath);
  const fallbackTimestamp = stats.mtime.toISOString();
  const fallbackTsMs = stats.mtimeMs;
  const structured = await isStructuredLogFile(filePath);

  if (structured) {
    return parseStructuredLogFile(filePath, file, service, options, fallbackTimestamp, fallbackTsMs);
  }

  return parseUnstructuredLogFile(filePath, file, service, options, fallbackTimestamp, fallbackTsMs);
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
