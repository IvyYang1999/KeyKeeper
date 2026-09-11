import Foundation
import KeyKeeperCore

enum BrowserImportPage {
    static func html(request: ClipboardSaveRequest) -> String {
        // Validated identifiers contain only alphanumerics and -_.; still escape as HTML.
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><html lang="en"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Import into KeyKeeper</title>
        <style>
        :root{color-scheme:light dark;font:16px/1.55 system-ui,sans-serif}
        *{box-sizing:border-box}body{margin:0;background:light-dark(#f5f5f7,#171719);color:light-dark(#202024,#f2f2f4)}
        main{max-width:540px;margin:8vh auto;padding:28px}h1{font-size:28px;line-height:1.2;margin:0 0 20px}
        .eyebrow{font-size:13px;letter-spacing:.08em;font-weight:650;margin-bottom:12px}
        dl{padding:16px 20px;border:1px solid light-dark(#ceced3,#52525a);border-radius:12px}
        dt{font-size:13px}dd{margin:0 0 12px;font-family:ui-monospace,monospace;overflow-wrap:anywhere}dd:last-child{margin:0}
        label{display:block;font-weight:600;margin:24px 0 8px}input{width:100%;font:inherit;padding:14px;border:1px solid #82828c;border-radius:8px;background:light-dark(white,#252529);color:inherit}
        input:focus-visible,button:focus-visible{outline:3px solid #3977e7;outline-offset:3px}button{font:inherit;min-height:44px;padding:8px 18px;border-radius:8px;margin-top:8px;cursor:pointer}
        #result{min-height:3em;font-weight:600}small{display:block;font-size:14px}p{margin:16px 0}
        </style><main><div class="eyebrow">KEYKEEPER · LOCAL IMPORT</div>
        <h1>Paste once. Confirm on your Mac.</h1>
        <dl><dt>Credential ID</dt><dd>\(escape(request.credentialId))</dd><dt>Secret field</dt><dd>\(escape(request.fieldName))</dd></dl>
        <p>\(request.create ? "Creates a new credential with Ask every time protection." : "Restores this missing field without changing its existing permissions.")</p>
        <label for="paste">Paste the copied key here</label>
        <input id="paste" type="password" autocomplete="off" spellcheck="false" aria-describedby="help" placeholder="Click here, then press ⌘V">
        <small id="help">Paste only. The text will not appear in this field. This page sends it directly to KeyKeeper on this Mac, not to an online service.</small>
        <p id="result" role="status" aria-live="polite">Waiting for paste. The request expires after 90 seconds.</p>
        <button id="cancel" type="button">Cancel import</button>
        <p><small>Check the ID and field in the KeyKeeper confirmation window. Saving never overwrites a value or grants permission to read it.</small></p></main>
        <script>
        'use strict';
        let ticket = location.hash.slice(1), submitted = false;
        history.replaceState(null, '', '/');
        const area = document.getElementById('paste'), result = document.getElementById('result'), cancel = document.getElementById('cancel');
        const stop = message => { area.disabled = true; cancel.disabled = true; ticket = ''; result.textContent = message; };
        const abort = new AbortController();
        const timer = setTimeout(() => { abort.abort(); stop('Import expired. Check the CLI result before starting again.'); }, 90000);
        if (!/^[a-f0-9]{64}$/.test(ticket)) stop('This import link is invalid. Start a new request from KeyKeeper.');
        area.addEventListener('beforeinput', e => e.preventDefault());
        area.addEventListener('drop', e => e.preventDefault());
        area.addEventListener('paste', async e => {
          e.preventDefault(); area.value = '';
          if (submitted || area.disabled) return;
          let value = e.clipboardData.getData('text/plain');
          if (!value.trim() || new TextEncoder().encode(value).length > 65536) {
            result.textContent = 'Paste nonempty text, up to 64 KiB.'; return;
          }
          submitted = true; area.disabled = true;
          result.textContent = 'Waiting for your confirmation in KeyKeeper…';
          try {
            const pending = fetch('/import', { method:'POST', headers:{'Content-Type':'text/plain;charset=UTF-8','X-KeyKeeper-Session':ticket}, body:value, cache:'no-store', credentials:'omit', signal:abort.signal });
            value = ''; ticket = '';
            const response = await pending;
            const outcome = await response.json();
            stop(outcome.success ? 'Saved in KeyKeeper. No read permission was granted. You can close this page.' : 'Not saved. Check the CLI result; do not retry an uncertain write.');
          } catch { stop('Connection ended. Check the CLI result before retrying.'); }
          finally { value = ''; clearTimeout(timer); }
        });
        cancel.addEventListener('click', async () => {
          if (submitted) { abort.abort(); stop('Cancellation requested. Check the CLI result.'); return; }
          submitted = true;
          try { await fetch('/import', {method:'POST',headers:{'Content-Type':'text/plain','X-KeyKeeper-Session':ticket,'X-KeyKeeper-Cancel':'1'},body:'cancel',credentials:'omit',cache:'no-store'}); } catch {}
          clearTimeout(timer); stop('Import cancelled. You can close this page.');
        });
        addEventListener('pagehide', () => abort.abort());
        </script></html>
        """
    }
}
