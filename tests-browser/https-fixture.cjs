// Synthetic local integration fixture. Never use real account values here.
const https = require('node:https');
const fs = require('node:fs');
const dir = process.argv[2];
let forbidden = 0;
const server = https.createServer({ key: fs.readFileSync(dir + '/fixture-key.pem'), cert: fs.readFileSync(dir + '/fixture-cert.pem') }, (req, res) => {
  const pathname = new URL(req.url, 'https://localhost').pathname;
  if (pathname === '/forbidden') { forbidden++; res.end('blocked route reached'); return; }
  if (pathname === '/counts') { res.end(String(forbidden)); return; }
  const authenticated = req.headers.cookie === 'fixture=synthetic';
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.end(`<!doctype html><html><title>KeyKeeper synthetic login</title><body style="font:20px system-ui;padding:40px">
    <h1 id="state">${authenticated ? 'AUTHENTICATED' : 'NOT AUTHENTICATED'}</h1>
    <p>合成登录测试，没有真实账号。</p>
    <a id="outside" href="https://127.0.0.1:${server.address().port}/forbidden">Test blocked outside-origin navigation</a>
    <img alt="Outside image must be blocked" src="https://127.0.0.1:${server.address().port}/forbidden">
    </body></html>`);
});
server.listen(0, '127.0.0.1', () => process.stdout.write(String(server.address().port) + '\n'));
