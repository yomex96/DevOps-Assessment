'use strict';

const http = require('http');

const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OK');
    return;
  }

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ service: 'E-Permit API', status: 'running' }));
});

server.listen(PORT, () => {
  console.log(`E-Permit API listening on port ${PORT}`);
});

// Graceful shutdown — required for the container to handle SIGTERM cleanly
// (Docker stop / Kubernetes pod termination sends SIGTERM before SIGKILL)
process.on('SIGTERM', () => {
  console.log('SIGTERM received. Closing HTTP server...');
  server.close(() => {
    console.log('HTTP server closed. Exiting.');
    process.exit(0);
  });
});

process.on('SIGINT', () => {
  console.log('SIGINT received. Closing HTTP server...');
  server.close(() => {
    process.exit(0);
  });
});
