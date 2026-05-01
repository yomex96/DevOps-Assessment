const http = require('http');

http.createServer((req, res) => {
  if (req.url === '/health') {
    res.end('OK');
    return;
  }
  res.end('E-Permit API running');
}).listen(3000);
