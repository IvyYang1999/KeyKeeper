import http from 'node:http';
import crypto from 'node:crypto';
const marker='synthetic-'+crypto.randomBytes(24).toString('hex');
const html=`<!doctype html><meta charset="utf-8"><title>KeyKeeper 手势诊断 · 仅假数据</title>
<style>body{font:18px system-ui;max-width:700px;margin:40px auto;padding:20px}button{font:inherit;padding:16px;margin:12px 12px 12px 0}button:focus-visible{outline:3px solid blue}pre{white-space:pre-wrap}</style>
<h1>剪贴板手势诊断 · 仅假数据</h1><p>只报告状态和是否一致，不显示内容。没有保存功能。</p>
<button id="copy">复制假数据</button><button id="read">页内读取并核对</button>
<pre id="state" role="status">尚未操作</pre>
<label for="paste">原生粘贴一致性检查</label><input id="paste" type="password" autocomplete="off"><p id="paste-state" role="status">尚未粘贴</p>
<script>
const expected=${JSON.stringify(marker)}, out=document.getElementById('state');
document.getElementById('paste').addEventListener('paste',e=>{e.preventDefault();let value=e.clipboardData.getData('text/plain');const ok=value===expected;value='';document.getElementById('paste').value='';document.getElementById('paste-state').textContent=ok?'paste=MATCH':'paste=MISMATCH';});
function context(e){return 'trusted='+e.isTrusted+'; active='+navigator.userActivation?.isActive+'; focus='+document.hasFocus()+'; visible='+document.visibilityState+'; secure='+isSecureContext;}
function failure(e){return ['NotAllowedError','SecurityError','NotFoundError','TypeError'].includes(e?.name)?e.name:'OtherError';}
document.getElementById('copy').onclick=async e=>{const info=context(e);out.textContent=info+'; copy=PENDING';try{await navigator.clipboard.writeText(expected);out.textContent=info+'; copy=OK';}catch(err){out.textContent=info+'; copy='+failure(err);}};
document.getElementById('read').onclick=async e=>{const info=context(e);out.textContent=info+'; read=PENDING';try{let value=await navigator.clipboard.readText();const ok=value===expected;value='';out.textContent=info+'; read='+(ok?'MATCH':'MISMATCH');}catch(err){out.textContent=info+'; read='+failure(err);}};
</script>`;
const handler=(req,res)=>{res.setHeader('Cache-Control','no-store');res.setHeader('Content-Type','text/html; charset=utf-8');res.end(html)};
for(const name of ['SOURCE','RECEIVER']){const server=http.createServer(handler);server.listen(0,'127.0.0.1',()=>console.log(name+'=http://127.0.0.1:'+server.address().port+'/'));}
console.log('SYNTHETIC_SHA256='+crypto.createHash('sha256').update(marker).digest('hex'));
