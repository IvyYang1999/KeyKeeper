// Visual fixture only. This is NOT proof of Chrome permissions or native-host integration.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../browser-extension');
const files = new Set(['popup.html', 'popup.css', 'popup.mjs', 'import.mjs']);
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname === '/fixture-api.js') {
    res.setHeader('Content-Type', 'text/javascript');
    res.end(`const mode = new URL(location.href).searchParams.get('mode');
      globalThis.chrome = {
        tabs: { get: async () => ({ id:12, url:'https://workspace.example/account', incognito:false }) },
        permissions: { getAll: async()=>({origins:[]}), request: async()=> mode!=='denied', remove:async()=>true },
        cookies: { getAll: async()=> [{name:'fixture',value:'synthetic',domain:'workspace.example',hostOnly:true,path:'/',secure:true,httpOnly:true,sameSite:'lax'}] },
        runtime: { sendNativeMessage: async()=> {await new Promise(r=>setTimeout(r,1500)); return {success:mode!=='uncertain'};} }
      };`); return;
  }
  const name = url.pathname.slice(1);
  if (!files.has(name)) { res.writeHead(404); res.end(); return; }
  let content = fs.readFileSync(path.join(root, name));
  if (name === 'popup.html') content = content.toString().replace('<script type="module"', '<script src="/fixture-api.js"></script><script type="module"');
  res.setHeader('Content-Type', name.endsWith('.css') ? 'text/css' : name.endsWith('.html') ? 'text/html; charset=utf-8' : 'text/javascript');
  res.end(content);
});
server.listen(0, '127.0.0.1', () => process.stdout.write('Synthetic preview: http://127.0.0.1:' + server.address().port + '/popup.html?tabId=12\n'));
