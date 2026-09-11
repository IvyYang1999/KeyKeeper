// Synthetic-only page lifecycle tests. No browser/user clipboard is accessed.
const vm = require('node:vm');
const assert = require('node:assert/strict');
let source=''; process.stdin.setEncoding('utf8'); process.stdin.on('data',v=>source+=v);
process.stdin.on('end',()=>{main().then(()=>console.log('BROWSER_PAGE_LIFECYCLE_OK'),()=>{console.error('BROWSER_PAGE_LIFECYCLE_FAILED');process.exitCode=1});});
async function main(){
  const watchdog=setTimeout(()=>process.exit(2),3000);
  const code=source.split('<script>')[1].split('</script>')[0];
  function setup(read=async()=> 'synthetic-key'){
    const elements=Object.fromEntries(['paste','read','cancel','result'].map(id=>[id,{disabled:false,value:'',textContent:'',events:{},addEventListener(n,f){this.events[n]=f}}]));
    let reads=0; const posts=[],timers=[];
    vm.runInNewContext(code,{document:{getElementById:id=>elements[id]},location:{hash:'#'+'a'.repeat(64)},history:{replaceState(){}},navigator:{clipboard:{readText(){reads++;return read()}}},TextEncoder,AbortController,
      setTimeout:f=>{timers.push(f);return 1},clearTimeout(){},addEventListener(){},fetch:async(u,o)=>{posts.push(o);return {json:async()=>({success:true})}}});
    assert.equal(typeof elements.read.events.click,'function');
    return {elements,posts,timers,reads:()=>reads};
  }
  let h=setup(); assert.equal(h.reads(),0); await h.elements.read.events.click();
  assert.equal(h.reads(),1);assert.equal(h.posts.length,1);assert.equal(h.posts[0].body,'synthetic-key');assert.equal(h.elements.paste.value,'');
  assert(!h.elements.result.textContent.includes('synthetic-key')); await h.elements.read.events.click();assert.equal(h.reads(),1);
  for(const result of ['', ' '.repeat(3), 'x'.repeat(65537)]) {h=setup(async()=>result);await h.elements.read.events.click();assert.equal(h.posts.length,0);assert.equal(h.elements.read.disabled,false);}
  h=setup(async()=>{throw Error('synthetic error must not appear')});await h.elements.read.events.click();assert.equal(h.posts.length,0);assert(!h.elements.result.textContent.includes('synthetic error'));assert.equal(h.elements.read.disabled,false);
  for(const cancel of [false,true]){
    let resolve;h=setup(()=>new Promise(r=>resolve=r));const pending=h.elements.read.events.click();await h.elements.read.events.click();assert.equal(h.reads(),1);
    await h.elements.paste.events.paste({preventDefault(){},clipboardData:{getData(){throw Error('paste raced a read')}}});
    if(cancel) await h.elements.cancel.events.click();else h.timers[0]();
    resolve('synthetic-key');await pending;
    assert.equal(h.posts.filter(p=>!p.headers['X-KeyKeeper-Cancel']).length,0);
    assert.equal(h.elements.read.disabled,true);
  }
  h=setup();await h.elements.paste.events.paste({preventDefault(){},clipboardData:{getData:()=> 'synthetic-paste'}});
  assert.equal(h.posts.length,1);assert.equal(h.posts[0].body,'synthetic-paste');assert.equal(h.reads(),0);
  clearTimeout(watchdog);
}
