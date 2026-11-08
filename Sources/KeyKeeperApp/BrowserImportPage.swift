import Foundation
import KeyKeeperCore

/// The local page an agent's browser opens to paste one key into KeyKeeper.
///
/// 【曾经的 bug】2026-11-07 yyt：「每次 AI 帮我复制一个 key 粘贴到我们产品中时，还会打开一个网页，那个网页也
/// 做得很丑」——浏览器默认样式、系统灰按钮、大写小标题、四段说明，进度只是一行粗体字。Now it looks like the
/// app: one card with the KeyKeeper mark, a "Save as" line like the native confirmation window, a three-step
/// progress (paste → confirm on your Mac → saved) and one large paste box. The security behaviour is unchanged:
/// paste only, never shown, sent only to this Mac with the one-time ticket, expires after 90 seconds.
enum BrowserImportPage {
    static func html(request: ClipboardSaveRequest, language: String = AppL10n.language) -> String {
        // Validated identifiers contain only alphanumerics and -_.; still escape as HTML.
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func t(_ template: String) -> String {
            escape(AppL10n.render(template, language: language))
        }
        func j(_ template: String) -> String {
            scriptString(AppL10n.render(template, language: language))
        }
        let action = request.create ? "Creates a new credential with Ask every time protection."
            : request.addField ? "Adds a new secret field. Existing read permissions stay limited to the old fields."
            : "Restores this missing field without changing its existing permissions."
        return """
        <!doctype html><html lang="\(language == "zh-Hans" ? "zh-Hans" : "en")"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(t("Import into KeyKeeper"))</title>
        <style>
        :root{color-scheme:light dark;--bg:light-dark(#efeff2,#141416);--card:light-dark(#fff,#222225);--line:light-dark(#e2e2e7,#38383d);
          --well:light-dark(#f4f4f7,#1a1a1d);--text:light-dark(#1d1d1f,#f2f2f4);--muted:light-dark(#6e6e76,#a0a0a8);
          --accent:light-dark(#0a6cff,#3d8bff);--good:light-dark(#1d9a50,#36c26c);--bad:light-dark(#d23b3b,#ff6e6e);
          font:15px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif}
        *{box-sizing:border-box}
        body{margin:0;min-height:100vh;display:grid;place-items:center;padding:32px 16px;background:var(--bg);color:var(--text)}
        main{width:100%;max-width:460px;background:var(--card);border:1px solid var(--line);border-radius:18px;padding:26px 26px 20px;
          box-shadow:0 1px 2px rgb(0 0 0/.04),0 14px 36px rgb(0 0 0/.08)}
        header{display:flex;align-items:center;gap:14px;margin-bottom:20px}
        .mark{flex:none;width:46px;height:46px;border-radius:12px;background:#f2f2f2;border:1px solid rgb(0 0 0/.06)}
        h1{margin:0;font-size:19px;line-height:1.25;font-weight:650}
        header p{margin:3px 0 0;color:var(--muted);font-size:13.5px}
        .target{margin:0 0 6px;padding:11px 14px;border-radius:11px;background:var(--well);display:flex;gap:14px;align-items:baseline;font-size:13.5px}
        .target dt{color:var(--muted);flex:none}.target dd{margin:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere}
        .target .sep{color:var(--muted);padding:0 6px}
        .what{margin:0 0 20px;color:var(--muted);font-size:13px}
        ol{list-style:none;margin:0 0 18px;padding:0;display:flex}
        ol li{flex:1;position:relative;display:flex;flex-direction:column;align-items:center;gap:6px;font-size:12.5px;color:var(--muted);text-align:center}
        ol li span{position:relative;z-index:1;width:26px;height:26px;border-radius:50%;display:grid;place-items:center;font-weight:650;font-size:13px;
          background:var(--card);border:1.5px solid var(--line)}
        ol li+li::before{content:"";position:absolute;top:12.5px;right:50%;width:100%;height:1.5px;background:var(--line)}
        #flow[data-step=paste] .s1,#flow[data-step=confirm] .s2{color:var(--text);font-weight:600}
        #flow[data-step=paste] .s1 span,#flow[data-step=confirm] .s2 span{background:var(--accent);border-color:var(--accent);color:#fff}
        #flow[data-step=confirm] .s1 span,#flow[data-step=done] li span{background:var(--good);border-color:var(--good);color:transparent}
        #flow[data-step=confirm] .s1 span::after,#flow[data-step=done] li span::after{content:"✓";position:absolute;color:#fff}
        #flow[data-step=confirm] .s2::before,#flow[data-step=done] li::before{background:var(--good)}
        #flow[data-step=done] .s3{color:var(--text);font-weight:600}
        #flow[data-step=stopped] ol{opacity:.45}
        .drop{display:block;margin:0}
        #flow:not([data-step=paste]) .drop{display:none}
        .drop b{display:block;font-size:13.5px;font-weight:600;margin-bottom:8px}
        input{width:100%;height:58px;font:inherit;font-size:16px;text-align:center;padding:0 14px;border-radius:12px;color:inherit;
          border:1.5px dashed light-dark(#b9b9c2,#55555d);background:var(--well)}
        input::placeholder{color:var(--muted)}
        input:focus{outline:none;border-style:solid;border-color:var(--accent);box-shadow:0 0 0 4px color-mix(in srgb,var(--accent) 22%,transparent)}
        input:disabled{opacity:.55}
        .drop small{display:block;margin-top:8px;color:var(--muted);font-size:12.5px}
        #result{margin:12px 0 0;font-size:13px;color:var(--muted);min-height:1.5em}
        #flow:not([data-step=paste]) #result{margin:0;padding:14px 16px;border-radius:12px;font-size:14px;font-weight:550;color:var(--text);
          display:flex;gap:10px;align-items:center;background:color-mix(in srgb,var(--accent) 10%,var(--card))}
        #flow[data-step=confirm] #result::before{content:"";flex:none;width:14px;height:14px;border-radius:50%;
          border:2px solid var(--accent);border-right-color:transparent;animation:spin .8s linear infinite}
        #flow[data-step=done] #result{background:color-mix(in srgb,var(--good) 13%,var(--card))}
        #flow[data-step=done] #result::before{content:"✓";color:var(--good);font-weight:700}
        #flow[data-step=stopped] #result{background:color-mix(in srgb,var(--bad) 11%,var(--card))}
        #flow[data-step=stopped] #result::before{content:"!";flex:none;width:18px;height:18px;border-radius:50%;display:grid;place-items:center;
          background:var(--bad);color:#fff;font-size:12px;font-weight:700}
        @keyframes spin{to{transform:rotate(360deg)}}
        footer{margin-top:20px;padding-top:14px;border-top:1px solid var(--line);display:flex;gap:16px;align-items:center}
        footer small{flex:1;color:var(--muted);font-size:12px;line-height:1.45}
        #flow[data-step=done]~footer,#flow[data-step=stopped]~footer{display:none}
        button{flex:none;font:inherit;font-size:13.5px;padding:6px 14px;border-radius:8px;cursor:pointer;color:inherit;
          background:var(--well);border:1px solid var(--line)}
        button:hover{border-color:light-dark(#c4c4cc,#4d4d55)}button:disabled{display:none}
        input:focus-visible,button:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
        </style>
        <main>
        <header>
        <svg class="mark" viewBox="6 6 52 52" aria-hidden="true"><g fill="#ffc400">
        <path d="M32 9.5a9.5 9.5 0 0 0-8.9 12.8l3-1.1A6.3 6.3 0 1 1 37.6 24l2.2 2.3A9.5 9.5 0 0 0 32 9.5z"/>
        <circle cx="26" cy="28.5" r="7"/><path d="M23.3 33.2l4.4 1.2-5.6 20.5a2.6 2.6 0 0 1-5-1.4z"/><path d="M22.2 41.2l3.6 1-1 3.6-3.6-1zM20.6 47l3.6 1-1 3.6-3.6-1z"/>
        <circle cx="38.5" cy="29.5" r="7"/><path d="M36.5 34.4l4.4-1.1 5.3 20.6a2.6 2.6 0 0 1-5 1.3z"/><path d="M42 42.2l3.6-.9.9 3.6-3.6.9zM43.5 48l3.6-.9.9 3.6-3.6.9z"/>
        </g></svg>
        <div><h1>\(t("Import into KeyKeeper"))</h1><p>\(t("Paste once. Confirm on your Mac."))</p></div>
        </header>
        <dl class="target"><dt>\(t("Save as"))</dt><dd>\(escape(request.credentialId))<span class="sep">/</span>\(escape(request.fieldName))</dd></dl>
        <p class="what">\(t(action))</p>
        <section id="flow" data-step="paste">
        <ol><li class="s1"><span>1</span>\(t("Paste"))</li><li class="s2"><span>2</span>\(t("Confirm on your Mac"))</li><li class="s3"><span>3</span>\(t("Saved"))</li></ol>
        <label class="drop" for="paste"><b>\(t("Paste the copied key here"))</b>
        <input id="paste" type="password" autocomplete="off" spellcheck="false" aria-describedby="help" placeholder="\(t("Click here, then press ⌘V"))">
        <small id="help">\(t("Paste only. The text will not appear in this field. This page sends it directly to KeyKeeper on this Mac, not to an online service."))</small></label>
        <p id="result" role="status" aria-live="polite">\(t("Waiting for paste. The request expires after 90 seconds."))</p>
        </section>
        <footer><small>\(t("Check the ID and field in the KeyKeeper confirmation window. Saving never overwrites a value or grants permission to read it."))</small>
        <button id="cancel" type="button">\(t("Cancel import"))</button></footer>
        </main>
        <script>
        'use strict';
        let ticket = location.hash.slice(1), submitted = false;
        history.replaceState(null, '', '/');
        const area = document.getElementById('paste'), result = document.getElementById('result'), cancel = document.getElementById('cancel');
        const flow = document.getElementById('flow');
        const show = step => { flow.dataset.step = step; };
        const stop = (message, step = 'stopped') => { area.disabled = true; cancel.disabled = true; ticket = ''; result.textContent = message; show(step); };
        let timer = setTimeout(() => stop(\(j("Import expired. Check the CLI result before starting again."))), 90000);
        const headers = type => ({'X-KeyKeeper-Session':ticket, ...(type ? {'Content-Type':type} : {})});
        const render = proposal => {
          if (proposal.state === 'committed') { stop(\(j("Saved in KeyKeeper. No read permission was granted. You can close this page.")), 'done'); return true; }
          if (['expired','cancelled','failed'].includes(proposal.state)) { stop(\(j("Not saved. Check the CLI result; do not retry an uncertain write."))); return true; }
          show('confirm');
          result.textContent = proposal.state === 'committing'
            ? \(j("Approved. KeyKeeper is committing the value…"))
            : \(j("Waiting for your confirmation in KeyKeeper…"));
          return false;
        };
        const lost = () => { show('stopped'); result.textContent = \(j("Connection ended. Run keykeeper proposal status with the proposal ID shown in the terminal.")); };
        const poll = async () => {
          if (!ticket) return;
          try {
            const response = await fetch('/status', {method:'POST', headers:headers('text/plain'), body:'status', cache:'no-store', credentials:'omit'});
            if (!render(await response.json())) setTimeout(poll, 750);
          } catch { lost(); }
        };
        if (!/^[a-f0-9]{64}$/.test(ticket)) stop(\(j("This import link is invalid. Start a new request from KeyKeeper.")));
        area.addEventListener('beforeinput', e => e.preventDefault());
        area.addEventListener('drop', e => e.preventDefault());
        area.addEventListener('paste', async e => {
          e.preventDefault(); area.value = '';
          if (submitted || area.disabled) return;
          let value = e.clipboardData.getData('text/plain');
          if (!value.trim() || new TextEncoder().encode(value).length > 65536) {
            result.textContent = \(j("Paste nonempty text, up to 64 KiB.")); return;
          }
          submitted = true; area.disabled = true; show('confirm');
          result.textContent = \(j("Waiting for your confirmation in KeyKeeper…"));
          try {
            const response = await fetch('/import', { method:'POST', headers:headers('text/plain;charset=UTF-8'), body:value, cache:'no-store', credentials:'omit' });
            value = ''; clearTimeout(timer);
            const proposal = await response.json();
            if (!render(proposal)) setTimeout(poll, 0);
          } catch { lost(); }
          finally { value = ''; }
        });
        cancel.addEventListener('click', async () => {
          submitted = true;
          try { await fetch('/cancel', {method:'POST',headers:headers('text/plain'),body:'cancel',credentials:'omit',cache:'no-store'}); } catch {}
          clearTimeout(timer); stop(\(j("Import cancelled. You can close this page.")));
        });
        </script></html>
        """
    }

    /// Quotes a JS string without allowing localized copy to end its enclosing script.
    static func scriptString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

extension AppL10n {
    /// Browser paste page copy (2026-11-08 redesign).
    static let browserPageChinese: [String: String] = [
        "Confirm on your Mac": "在 Mac 上确认",
    ]
}
