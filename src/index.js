'use strict';

const http = require('http');

const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: 'epermit-api' }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ message: 'E-Permit API running' }));
});

// Graceful shutdown — handles SIGTERM from Docker/ECS correctly
process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});

server.listen(PORT, () => {
  console.log(`E-Permit API listening on port ${PORT}`);
});
