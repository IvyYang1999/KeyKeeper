// Synthetic-only page lifecycle tests. No browser/user clipboard is accessed.
const vm = require('node:vm');
const assert = require('node:assert/strict');
let source=''; process.stdin.setEncoding('utf8'); process.stdin.on('data',v=>source+=v);
process.stdin.on('end',()=>{main().then(()=>console.log('BROWSER_PAGE_LIFECYCLE_OK'),error=>{console.error('BROWSER_PAGE_LIFECYCLE_FAILED',error);process.exitCode=1});});
async function main(){
  const watchdog=setTimeout(()=>process.exit(2),3000);
  try {
    const code=source.split('<script>')[1].split('</script>')[0];
    function setup(hash='#'+'a'.repeat(64)){
      const elements=Object.fromEntries(['paste','cancel','result'].map(id=>[id,{disabled:false,value:'',textContent:'',events:{},addEventListener(n,f){this.events[n]=f}}]));
      const posts=[],timers=[];
      vm.runInNewContext(code,{document:{getElementById:id=>elements[id]},location:{hash},history:{replaceState(){}},TextEncoder,
        setTimeout:f=>{timers.push(f);return timers.length},clearTimeout(){},addEventListener(){},fetch:async(u,o={})=>{posts.push({u,o});return {json:async()=>u==='/status'?({state:'committed'}):({state:'pasteReceived'})}}});
      return {elements,posts,timers};
    }
    const paste=(h,value)=>h.elements.paste.events.paste({preventDefault(){},clipboardData:{getData:()=>value}});
    let h=setup();assert.equal(h.posts.length,0);await paste(h,'synthetic-key');
    assert.equal(h.posts.length,1);assert.equal(h.posts[0].u,'/import');assert.equal(h.posts[0].o.body,'synthetic-key');assert.equal(h.elements.paste.value,'');
    await h.timers.at(-1)();assert.equal(h.posts.at(-1).u,'/status');assert.equal(h.elements.paste.disabled,true);
    assert(!h.elements.result.textContent.includes('synthetic-key'));await paste(h,'synthetic-duplicate');assert.equal(h.posts.length,2);
    for(const value of ['', ' '.repeat(3), 'x'.repeat(65537)]){h=setup();await paste(h,value);assert.equal(h.posts.length,0);assert.equal(h.elements.paste.disabled,false);}
    for(const terminal of ['cancel','expire','invalid']){
      h=setup(terminal==='invalid'?'#invalid':undefined);
      if(terminal==='cancel')await h.elements.cancel.events.click();
      if(terminal==='expire')h.timers[0]();
      await paste(h,'synthetic-late');
      assert.equal(h.posts.filter(p=>p.u==='/import').length,0);
      assert.equal(h.elements.paste.disabled,true);
    }
  } finally {clearTimeout(watchdog);}
}
