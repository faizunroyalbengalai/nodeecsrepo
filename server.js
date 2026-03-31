const express = require('express');
const fs = require('fs');
const path = require('path');

const app = express();
const port = Number(process.env.PORT || 3000);
const host = process.env.HOST || '0.0.0.0';

app.use(express.json());
const publicDir = path.join(__dirname, 'public');
if (fs.existsSync(publicDir)) {
  app.use(express.static(publicDir));
}

let dbStatus = 'disabled';
if (process.env.DATABASE_URL) {
  dbStatus = 'configured';
}

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', db: dbStatus });
});

app.get('/api/info', (_req, res) => {
  res.json({
    app: 'node',
    port,
    db: dbStatus,
  });
});

app.get('/{*path}', (_req, res) => {
  const indexPath = path.join(__dirname, 'public', 'index.html');
  if (fs.existsSync(indexPath)) {
    return res.sendFile(indexPath);
  }
  return res.status(200).send('Node.js app is running');
});

app.listen(port, host, () => {
  console.log(`Server listening on http://%s:%d`, host, port);
});
