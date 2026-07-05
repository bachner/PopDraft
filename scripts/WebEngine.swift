// PopDraft - Popup Menu App
// A menu bar app that shows a floating action popup for text processing
//
// Built by co-compiling with scripts/Core.swift:
//   swiftc -O scripts/PopDraft.swift scripts/Core.swift \
//       -framework Cocoa -framework Carbon -framework WebKit -framework AVFoundation

import Cocoa
import SwiftUI
import Carbon.HIToolbox
import WebKit
import CryptoKit
import Network

// MARK: - PR6: Web Engine (WebKit-backed orchestration)
//
// An in-app, agent-optimized headless browser. The pure logic (SSRF, DDG
// parsing, Markdown sanitizing, BM25 ranking, config knobs) lives in
// Core.swift and is unit-tested without WebKit. This file wires that logic
// to one persistent offscreen NSWindow hosting a bounded pool of fresh
// WKWebViews, plus a keyless DuckDuckGo search path and an on-disk cache.
//
// Public entry point: `WebEngine.shared` (@MainActor) with async methods
// search / open / read / screenshot / extract — each runnable in parallel
// up to the renderer cap. PR7 registers these as tools.
// =====================================================================

// MARK: - Bundled JS (Readability + HTML→Markdown)

/// JavaScript injected into a loaded page to (1) run a trimmed Mozilla
/// Readability pass on a clone of the document and (2) convert the cleaned
/// node tree to Markdown. Returns a JSON object the Swift side decodes.
/// This is a compact, self-contained reimplementation of Readability's core
/// scoring heuristics (no external file needed; nothing to bundle on disk).
enum WebJS {
    /// Returns `{title, byline, siteName, markdown, textLen}` as a JSON string,
    /// or `{error: "..."}`. `dropImages` controls image handling.
    static func extractScript(dropImages: Bool) -> String {
        return """
        (function() {
          try {
            function txt(n){ return (n.textContent || '').replace(/\\s+/g,' ').trim(); }
            function tag(n){ return n.nodeType===1 ? n.tagName.toUpperCase() : ''; }

            // ---- meta helpers ----
            function meta(names){
              for (var i=0;i<names.length;i++){
                var m = document.querySelector('meta[property="'+names[i]+'"]') ||
                        document.querySelector('meta[name="'+names[i]+'"]');
                if (m && m.content) return m.content.trim();
              }
              return '';
            }
            var docTitle = (document.title||'').trim();
            var ogTitle = meta(['og:title','twitter:title']);
            var title = ogTitle || docTitle || '';
            var byline = meta(['author','article:author','og:article:author']);
            var siteName = meta(['og:site_name','application-name']) ||
                           (location.hostname||'').replace(/^www\\./,'');

            // ---- candidate scoring (trimmed Readability) ----
            var UNLIKELY = /(combx|comment|community|disqus|extra|foot|header|menu|remark|rss|shoutbox|sidebar|sponsor|ad-break|agegate|pagination|pager|popup|nav|breadcrumb|share|social|promo|cookie|consent|subscribe|newsletter|related|recommend)/i;
            var POSITIVE = /(article|body|content|entry|hentry|main|page|post|text|blog|story)/i;
            var BLOCK_TAGS = {DIV:1,ARTICLE:1,SECTION:1,MAIN:1,TD:1};

            function classId(n){ return ((n.className||'')+' '+(n.id||'')); }

            var candidates = [];
            var all = document.body ? document.body.getElementsByTagName('*') : [];
            for (var i=0;i<all.length;i++){
              var node = all[i];
              var t = tag(node);
              if (!BLOCK_TAGS[t]) continue;
              var ci = classId(node);
              if (UNLIKELY.test(ci) && !POSITIVE.test(ci)) continue;
              // Count paragraph-ish text length.
              var ps = node.getElementsByTagName('p');
              var plen = 0, pcount = 0;
              for (var j=0;j<ps.length;j++){ var tl = txt(ps[j]).length; if (tl>20){ plen += tl; pcount++; } }
              var direct = txt(node).length;
              var score = plen + pcount*25 + Math.min(direct/100, 50);
              if (POSITIVE.test(ci)) score += 30;
              if (t==='ARTICLE' || t==='MAIN') score += 40;
              var commas = (txt(node).match(/,/g)||[]).length;
              score += commas;
              if (score > 25) candidates.push({node:node, score:score});
            }
            candidates.sort(function(a,b){return b.score-a.score;});

            var root = candidates.length ? candidates[0].node :
                       (document.querySelector('article') || document.querySelector('main') || document.body);
            if (!root) return JSON.stringify({error:'no-root'});

            // ---- HTML -> Markdown walk ----
            var SKIP = {SCRIPT:1,STYLE:1,NOSCRIPT:1,NAV:1,ASIDE:1,FORM:1,BUTTON:1,SVG:1,IFRAME:1,FOOTER:1,HEADER:1};
            var dropImages = \(dropImages ? "true" : "false");
            var TRACK = /^(utm_[a-z]+|gclid|fbclid|dclid|gclsrc|msclkid|yclid|mc_cid|mc_eid|igshid|vero_id|vero_conv|_hsenc|_hsmi|mkt_tok|ref|ref_src|ref_url|spm|scm|_openstat|wt_mc|trk|trkcampaign)$/i;
            function cleanURL(u){
              if(!u) return '';
              try{
                var a=document.createElement('a'); a.href=u;
                // Strip tracking query params, preserving the rest.
                if (a.search && a.search.length>1){
                  var parts = a.search.substring(1).split('&');
                  var kept = [];
                  for (var i=0;i<parts.length;i++){
                    var kv = parts[i].split('=');
                    if (!TRACK.test(kv[0])) kept.push(parts[i]);
                  }
                  a.search = kept.length ? ('?'+kept.join('&')) : '';
                }
                return a.href;
              }catch(e){ return u; }
            }
            function inline(n){
              if (n.nodeType===3) return n.nodeValue.replace(/\\s+/g,' ');
              if (n.nodeType!==1) return '';
              var t = tag(n);
              if (SKIP[t]) return '';
              var inner='';
              for (var c=n.firstChild;c;c=c.nextSibling) inner += inline(c);
              if (t==='STRONG'||t==='B'){ return inner.trim()? '**'+inner.trim()+'**' : ''; }
              if (t==='EM'||t==='I'){ return inner.trim()? '*'+inner.trim()+'*' : ''; }
              if (t==='CODE'){ return inner.trim()? '`'+inner.trim()+'`' : ''; }
              if (t==='BR'){ return ' '; }
              if (t==='A'){
                var href = cleanURL(n.getAttribute('href'));
                var label = inner.trim();
                if (!label) return '';
                if (!href || href.indexOf('javascript:')===0) return label;
                return '['+label+']('+href+')';
              }
              if (t==='IMG'){
                if (dropImages) return '';
                var src = cleanURL(n.getAttribute('src'));
                var alt = (n.getAttribute('alt')||'').trim();
                return src ? '!['+alt+']('+src+')' : '';
              }
              return inner;
            }
            var out = [];
            function block(n, depth){
              if (n.nodeType===3){ var s=n.nodeValue.replace(/\\s+/g,' ').trim(); if(s) out.push(s); return; }
              if (n.nodeType!==1) return;
              var t = tag(n);
              if (SKIP[t]) return;
              var ci = classId(n);
              if (UNLIKELY.test(ci) && !POSITIVE.test(ci) && t!=='P') return;
              if (t==='H1'){ out.push('# '+txt(n)); return; }
              if (t==='H2'){ out.push('## '+txt(n)); return; }
              if (t==='H3'){ out.push('### '+txt(n)); return; }
              if (t==='H4'){ out.push('#### '+txt(n)); return; }
              if (t==='H5'){ out.push('##### '+txt(n)); return; }
              if (t==='H6'){ out.push('###### '+txt(n)); return; }
              if (t==='P'){ var p=inline(n).replace(/\\s+/g,' ').trim(); if(p) out.push(p); return; }
              if (t==='BLOCKQUOTE'){
                var q=''; for (var c=n.firstChild;c;c=c.nextSibling) q+=inline(c);
                q=q.replace(/\\s+/g,' ').trim(); if(q) out.push('> '+q); return;
              }
              if (t==='PRE'){
                var code = (n.textContent||'').replace(/\\s+$/,'');
                if (code.trim()) out.push('```\\n'+code+'\\n```'); return;
              }
              if (t==='UL' || t==='OL'){
                var ordered = (t==='OL'); var idx=1;
                for (var c=n.firstChild;c;c=c.nextSibling){
                  if (c.nodeType===1 && tag(c)==='LI'){
                    var li=inline(c).replace(/\\s+/g,' ').trim();
                    if (li){ out.push((ordered? (idx++)+'. ' : '- ')+li); }
                  }
                }
                out.push('');
                return;
              }
              if (t==='TABLE'){
                var rows = n.querySelectorAll('tr');
                var lines=[]; var headerDone=false;
                for (var r=0;r<rows.length;r++){
                  var cells = rows[r].querySelectorAll('th,td');
                  if (!cells.length) continue;
                  var cols=[];
                  for (var k=0;k<cells.length;k++){ cols.push(inline(cells[k]).replace(/\\s+/g,' ').replace(/\\|/g,'\\\\|').trim()); }
                  lines.push('| '+cols.join(' | ')+' |');
                  if (!headerDone){ var sep=[]; for (var s2=0;s2<cols.length;s2++) sep.push('---'); lines.push('| '+sep.join(' | ')+' |'); headerDone=true; }
                }
                if (lines.length) out.push(lines.join('\\n'));
                return;
              }
              if (t==='IMG' && !dropImages){ var im=inline(n); if(im) out.push(im); return; }
              if (t==='FIGURE' || t==='HR'){ if(t==='HR') out.push('---'); }
              // Recurse into generic containers.
              for (var ch=n.firstChild;ch;ch=ch.nextSibling) block(ch, depth+1);
            }
            for (var c=root.firstChild;c;c=c.nextSibling) block(c, 0);

            var md = out.join('\\n\\n');
            return JSON.stringify({
              title: title, byline: byline, siteName: siteName,
              markdown: md, textLen: txt(root).length
            });
          } catch(e){
            return JSON.stringify({error: String(e)});
          }
        })();
        """
    }

    /// Tiny probe used by `open()`: returns `{title, text}` (first chunk of body text).
    static let openProbeScript = """
    (function(){
      var t=(document.title||'').trim();
      var b=document.body? (document.body.innerText||'').replace(/\\s+/g,' ').trim():'';
      return JSON.stringify({title:t, text:b.slice(0,2000)});
    })();
    """

    /// Returns the document's full scroll height for full-page screenshots.
    static let scrollHeightScript = """
    (function(){
      var b=document.body, e=document.documentElement;
      return Math.max(b?b.scrollHeight:0, b?b.offsetHeight:0, e?e.scrollHeight:0, e?e.offsetHeight:0, e?e.clientHeight:0);
    })();
    """

    static let readyStateScript = "document.readyState"

    /// Extract search results from a RENDERED SERP DOM (DuckDuckGo or Bing).
    /// Returns a JSON array string of `{title,url,snippet}`. Engine-agnostic:
    /// tries each engine's known result-container selectors, then a generic
    /// fallback over organic-looking links. Skips ads, internal DDG/Bing links,
    /// and javascript/# hrefs. Decodes Bing's `/ck/a?...&u=` redirect wrappers.
    static let serpExtractScript = #"""
    (function(){
      function clean(s){ return (s||'').replace(/\s+/g,' ').trim(); }
      function host(u){ try { return new URL(u, location.href).hostname; } catch(e){ return ''; } }
      // Bing wraps real URLs in /ck/a?...&u=a1<base64url>. Best-effort decode;
      // if it fails, keep the wrapper (still a valid clickable link).
      function unwrap(u){
        try{
          var url=new URL(u, location.href);
          if(/bing\.com$/.test(url.hostname) && url.pathname.indexOf('/ck/a')===0){
            var raw=url.searchParams.get('u');
            if(raw){
              if(raw.slice(0,2)==='a1'){ raw=raw.slice(2); }
              var b64=raw.replace(/-/g,'+').replace(/_/g,'/');
              while(b64.length%4){ b64+='='; }
              try{ var dec=atob(b64); if(/^https?:\/\//.test(dec)) return dec; }catch(e){}
            }
          }
        }catch(e){}
        return u;
      }
      var out=[]; var seen={};
      function push(title,url,snippet){
        url=unwrap(url);
        if(!url || !/^https?:\/\//.test(url)) return;
        var h=host(url);
        if(!h) return;
        // Drop the engine's own chrome / ads / verticals.
        if(/(^|\.)duckduckgo\.com$/.test(h)) return;
        if(/(^|\.)bing\.com$/.test(h)) return;
        if(/(^|\.)microsoft(translator)?\.com$/.test(h) && /\/ck\//.test(url)) return;
        title=clean(title);
        if(!title) return;
        var key=url.split('#')[0];
        if(seen[key]) return; seen[key]=1;
        out.push({title:title, url:url, snippet:clean(snippet)});
      }
      // 1) DuckDuckGo (react SERP): each result is an article[data-testid=result].
      document.querySelectorAll('article[data-testid="result"], li[data-layout="organic"], .result').forEach(function(el){
        var a=el.querySelector('a[data-testid="result-title-a"]') || el.querySelector('h2 a') || el.querySelector('a.result__a') || el.querySelector('a[href]');
        if(!a) return;
        var sn=el.querySelector('[data-result="snippet"]') || el.querySelector('.result__snippet') || el.querySelector('span');
        push(a.innerText||a.textContent, a.href, sn?(sn.innerText||sn.textContent):'');
      });
      // 2) Bing: organic results live in li.b_algo with an h2 > a.
      document.querySelectorAll('li.b_algo').forEach(function(el){
        var a=el.querySelector('h2 a'); if(!a) return;
        var sn=el.querySelector('.b_caption p') || el.querySelector('p');
        push(a.innerText||a.textContent, a.href, sn?(sn.innerText||sn.textContent):'');
      });
      // 3) Generic fallback: any heading link if the above found nothing.
      if(out.length===0){
        document.querySelectorAll('h2 a[href], h3 a[href]').forEach(function(a){
          push(a.innerText||a.textContent, a.href, '');
        });
      }
      return JSON.stringify(out.slice(0,15));
    })();
    """#

    /// Extract IMAGE results from a rendered image-search results page (the
    /// WKWebView render fallback for `image_search`). Walks `<img>` elements,
    /// resolves the best full-size source (data-src / srcset / src), the nearest
    /// enclosing link as the source page, and the alt/title as a caption. Returns
    /// a JSON array of `{image, thumbnail, source, title}` (https only). Mirrors
    /// `serpExtractScript`'s output-contract style for `ImageSearchParser`.
    static let imageExtractScript = #"""
    (function(){
      function abs(u){ try { return new URL(u, location.href).href; } catch(e){ return ''; } }
      // Pick the largest candidate from a srcset string ("url 320w, url 640w").
      function fromSrcset(ss){
        if(!ss) return '';
        var best='', bestW=-1;
        ss.split(',').forEach(function(part){
          var seg=part.trim().split(/\s+/); if(!seg.length) return;
          var u=seg[0]; var w=0;
          if(seg[1]){ var m=seg[1].match(/(\d+)w/); if(m) w=parseInt(m[1],10); }
          if(w>bestW){ bestW=w; best=u; }
        });
        return best;
      }
      function bigSrc(img){
        // Prefer explicit full-res hints, then srcset, then src. Many image SERPs
        // lazy-load via data-src / data-iurl and keep a tiny placeholder in src.
        var cands=[img.getAttribute('data-iurl'), img.getAttribute('data-src'),
                   fromSrcset(img.getAttribute('srcset')||img.getAttribute('data-srcset')),
                   img.getAttribute('src')];
        for(var i=0;i<cands.length;i++){ if(cands[i]) return abs(cands[i]); }
        return '';
      }
      function srcPage(img){
        var a=img.closest ? img.closest('a[href]') : null;
        return a ? abs(a.getAttribute('href')) : '';
      }
      var out=[]; var seen={};
      var imgs=document.querySelectorAll('img');
      for(var i=0;i<imgs.length;i++){
        var img=imgs[i];
        var u=bigSrc(img);
        if(!u || u.indexOf('https://')!==0) continue;       // chat renders https only
        // Skip obvious sprites / icons / 1px trackers.
        var w=img.naturalWidth||img.width||0, h=img.naturalHeight||img.height||0;
        if((w&&w<60)||(h&&h<60)) continue;
        var key=u.split('#')[0];
        if(seen[key]) continue; seen[key]=1;
        var thumb=abs(img.getAttribute('src')||'') ;
        if(thumb.indexOf('https://')!==0) thumb=u;
        var title=(img.getAttribute('alt')||img.getAttribute('title')||'').replace(/\s+/g,' ').trim();
        out.push({image:u, thumbnail:thumb, source:srcPage(img), title:title});
        if(out.length>=40) break;
      }
      return JSON.stringify(out);
    })();
    """#
}

// MARK: - Bundled JS for interactive browsing (Playwright-style)

/// JavaScript injected into the persistent session webview to DRIVE a page:
/// build an accessibility summary, find + click an element by text/selector,
/// and focus + type into an input. Every function is a self-contained, bundled
/// string — agent-supplied strings are passed ONLY as a JSON `args` object that
/// the Swift side builds with `BrowserTargets.argLiteral` (JSON-encoded), so the
/// page never contributes a raw string to the evaluated script.
enum BrowserJS {
    /// Shared prelude: helpers to read visible text, compute a stable selector for
    /// an element, test visibility, and find the best match for a target. Prepended
    /// to each action script. `__ARGS__` is replaced by a JSON object literal.
    private static let prelude = #"""
    function __pdText(n){ return (n && (n.innerText || n.textContent) || '').replace(/\s+/g,' ').trim(); }
    function __pdVisible(n){
      if(!n) return false;
      var s = window.getComputedStyle(n);
      if(!s || s.display==='none' || s.visibility==='hidden' || parseFloat(s.opacity||'1')===0) return false;
      var r = n.getBoundingClientRect();
      return (r.width>1 && r.height>1);
    }
    function __pdSelector(n){
      if(!n || n.nodeType!==1) return '';
      if(n.id){ return '#'+CSS.escape(n.id); }
      var tag = n.tagName.toLowerCase();
      // name attr is stable + common on inputs.
      var nm = n.getAttribute && n.getAttribute('name');
      if(nm){ return tag+'[name="'+nm.replace(/"/g,'\\"')+'"]'; }
      // Build an nth-of-type path (short, deterministic).
      var path=[]; var el=n; var depth=0;
      while(el && el.nodeType===1 && depth<5 && el.tagName.toLowerCase()!=='html'){
        var t=el.tagName.toLowerCase();
        var parent=el.parentNode;
        if(!parent){ path.unshift(t); break; }
        var sibs=[]; var c=parent.firstElementChild;
        for(; c; c=c.nextElementSibling){ if(c.tagName===el.tagName) sibs.push(c); }
        if(sibs.length>1){ var idx=sibs.indexOf(el)+1; path.unshift(t+':nth-of-type('+idx+')'); }
        else { path.unshift(t); }
        el=parent; depth++;
      }
      return path.join(' > ');
    }
    function __pdLabel(n){
      var t = __pdText(n);
      if(t) return t.slice(0,120);
      var v = n.getAttribute && (n.getAttribute('aria-label') || n.getAttribute('placeholder') || n.value || n.getAttribute('name') || n.getAttribute('title'));
      return (v||'').toString().replace(/\s+/g,' ').trim().slice(0,120);
    }
    function __pdRole(n){
      var tag=n.tagName.toLowerCase();
      if(tag==='a') return 'link';
      if(tag==='button') return 'button';
      if(tag==='textarea') return 'textarea';
      if(tag==='select') return 'select';
      if(tag==='input'){
        var ty=(n.getAttribute('type')||'text').toLowerCase();
        if(ty==='submit'||ty==='button') return 'button';
        return 'input';
      }
      var role=n.getAttribute && n.getAttribute('role');
      if(role==='button') return 'button';
      if(role==='link') return 'link';
      return 'button';
    }
    // Candidate clickable / typeable elements (visible only).
    function __pdClickables(){
      var sel = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [onclick]';
      var nodes = Array.prototype.slice.call(document.querySelectorAll(sel));
      return nodes.filter(__pdVisible);
    }
    // Find the best element for a target. If asSelector, querySelector first.
    // Else: exact visible-text match, then case-insensitive contains, over
    // clickable candidates; falls back to querySelector if the text looks usable.
    function __pdFind(args){
      var target=(args.target||'').trim();
      if(!target) return null;
      if(args.asSelector){
        try{ var q=document.querySelector(target); if(q) return q; }catch(e){}
      }
      var cands=__pdClickables();
      var lt=target.toLowerCase();
      // 1) exact text/label match.
      for(var i=0;i<cands.length;i++){ if(__pdText(cands[i]).toLowerCase()===lt) return cands[i]; }
      for(var i2=0;i2<cands.length;i2++){
        var lab=(__pdLabel(cands[i2])||'').toLowerCase();
        if(lab===lt) return cands[i2];
      }
      // 2) contains.
      for(var j=0;j<cands.length;j++){ if(__pdText(cands[j]).toLowerCase().indexOf(lt)>=0) return cands[j]; }
      for(var j2=0;j2<cands.length;j2++){
        var lab2=(__pdLabel(cands[j2])||'').toLowerCase();
        if(lab2.indexOf(lt)>=0) return cands[j2];
      }
      // 3) last resort: try it as a selector even if it didn't "look like" one.
      try{ var q2=document.querySelector(target); if(q2) return q2; }catch(e){}
      return null;
    }
    // Find the best INPUT/textarea for a target (placeholder/label/name/aria/selector).
    function __pdFindInput(args){
      var target=(args.target||'').trim();
      if(args.asSelector){
        try{ var q=document.querySelector(target); if(q) return q; }catch(e){}
      }
      var inputs=Array.prototype.slice.call(document.querySelectorAll('input, textarea, [contenteditable="true"]')).filter(__pdVisible);
      // Skip hidden/checkbox/radio/submit inputs for typing.
      inputs=inputs.filter(function(n){
        if(n.tagName.toLowerCase()!=='input') return true;
        var ty=(n.getAttribute('type')||'text').toLowerCase();
        return ['hidden','checkbox','radio','submit','button','image','file','range','color'].indexOf(ty)<0;
      });
      if(!target){ return inputs.length?inputs[0]:null; }
      var lt=target.toLowerCase();
      function attrMatch(n){
        var a=[n.getAttribute('placeholder'), n.getAttribute('aria-label'), n.getAttribute('name'), n.getAttribute('title'), n.getAttribute('id')];
        for(var k=0;k<a.length;k++){ if(a[k] && a[k].toLowerCase().indexOf(lt)>=0) return true; }
        // <label for=id> text.
        if(n.id){ var lbl=document.querySelector('label[for="'+CSS.escape(n.id)+'"]'); if(lbl && __pdText(lbl).toLowerCase().indexOf(lt)>=0) return true; }
        return false;
      }
      for(var i=0;i<inputs.length;i++){ if(attrMatch(inputs[i])) return inputs[i]; }
      // selector fallback.
      try{ var q2=document.querySelector(target); if(q2) return q2; }catch(e){}
      return inputs.length?inputs[0]:null;
    }
    var __pdArgs = __ARGS__;
    """#

    /// Build the DOM-accessibility summary: title, a short readable text snapshot,
    /// and up to `cap` clickable/typeable elements with role/label/selector.
    /// Returns a JSON string `{title, summary, elements:[{role,label,selector}]}`.
    static func summaryScript(cap: Int) -> String {
        return #"""
        (function(){
          try{
        """# + prelude.replacingOccurrences(of: "__ARGS__", with: "{}") + #"""
            var CAP = \#(cap);
            var els = [];
            var cands = __pdClickables();
            var seen = {};
            for(var i=0;i<cands.length && els.length<CAP;i++){
              var n=cands[i];
              var label=__pdLabel(n);
              if(!label) continue;
              var role=__pdRole(n);
              var sel=__pdSelector(n);
              var key=role+'|'+label;
              if(seen[key]) continue; seen[key]=1;
              els.push({role:role, label:label, selector:sel});
            }
            var body = (document.body ? (document.body.innerText||'') : '').replace(/\s+/g,' ').trim();
            return JSON.stringify({
              title: (document.title||'').trim(),
              summary: body.slice(0, 800),
              elements: els
            });
          }catch(e){ return JSON.stringify({title:(document.title||''), summary:'', elements:[], error:String(e)}); }
        })();
        """#
    }

    /// Click script. `argLiteral` is `{target, asSelector}` from `BrowserTargets`.
    /// Returns `{ok, clicked, role}` JSON. Splices in no page-derived string.
    static func clickScript(argLiteral: String) -> String {
        return #"""
        (function(){
          try{
        """# + prelude.replacingOccurrences(of: "__ARGS__", with: argLiteral) + #"""
            var el = __pdFind(__pdArgs);
            if(!el){ return JSON.stringify({ok:false, error:'not-found'}); }
            var label = __pdLabel(el) || __pdText(el);
            var role = __pdRole(el);
            try{ el.scrollIntoView({block:'center'}); }catch(e){}
            try{ el.focus(); }catch(e){}
            // Prefer a native click (fires navigation for <a>/<button>).
            if(typeof el.click==='function'){ el.click(); }
            else {
              var ev=document.createEvent('MouseEvents');
              ev.initEvent('click', true, true);
              el.dispatchEvent(ev);
            }
            return JSON.stringify({ok:true, clicked:label, role:role});
          }catch(e){ return JSON.stringify({ok:false, error:String(e)}); }
        })();
        """#
    }

    /// Type script. `argLiteral` is `{target, asSelector, text}`. `submit` triggers
    /// an Enter keydown + form.submit() fallback. Returns `{ok, typedInto, submitted}`.
    static func typeScript(argLiteral: String, submit: Bool) -> String {
        return #"""
        (function(){
          try{
        """# + prelude.replacingOccurrences(of: "__ARGS__", with: argLiteral) + #"""
            var SUBMIT = \#(submit ? "true" : "false");
            var el = __pdFindInput(__pdArgs);
            if(!el){ return JSON.stringify({ok:false, error:'no-input'}); }
            var label = __pdLabel(el);
            try{ el.scrollIntoView({block:'center'}); }catch(e){}
            try{ el.focus(); }catch(e){}
            var text = (__pdArgs.text!=null) ? String(__pdArgs.text) : '';
            if(el.isContentEditable){ el.textContent = text; }
            else { el.value = text; }
            try{ el.dispatchEvent(new Event('input', {bubbles:true})); }catch(e){}
            try{ el.dispatchEvent(new Event('change', {bubbles:true})); }catch(e){}
            var submitted=false;
            if(SUBMIT){
              try{
                var kd=new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true});
                el.dispatchEvent(kd);
                var ku=new KeyboardEvent('keyup', {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true});
                el.dispatchEvent(ku);
              }catch(e){}
              // Fallback: submit the enclosing form if no navigation kicked off.
              var f = el.form || (el.closest && el.closest('form'));
              if(f){ try{ if(typeof f.requestSubmit==='function'){ f.requestSubmit(); } else { f.submit(); } submitted=true; }catch(e){} }
              else { submitted=true; }
            }
            return JSON.stringify({ok:true, typedInto:label||'(input)', submitted:submitted});
          }catch(e){ return JSON.stringify({ok:false, error:String(e)}); }
        })();
        """#
    }
}

// MARK: - Content blocking ruleset

/// Compiles small `WKContentRuleList`s once at startup and caches them. Two
/// variants: ads/trackers only (screenshots need images) and a read-mode
/// variant that also drops image/media to save bandwidth.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    private var adsList: WKContentRuleList?
    private var readList: WKContentRuleList?
    private var compiled = false

    private init() {}

    /// A small bundled ad/tracker blocklist (host-suffix triggers).
    private static let adHosts: [String] = [
        "doubleclick.net", "googlesyndication.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com",
        "facebook.net", "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
        "scorecardresearch.com", "quantserve.com", "adnxs.com", "criteo.com",
        "taboola.com", "outbrain.com", "amazon-adsystem.com", "adsrvr.org",
        "hotjar.com", "mixpanel.com", "segment.io", "segment.com",
        "moatads.com", "bidswitch.net", "rubiconproject.com", "pubmatic.com",
        "openx.net", "casalemedia.com", "yieldmo.com", "branch.io",
    ]

    /// Build the JSON rule source. When `blockMedia`, also block image/media types.
    private static func ruleJSON(blockMedia: Bool) -> String {
        var rules: [[String: Any]] = []
        // Block ad/tracker hosts entirely.
        for host in adHosts {
            let esc = host.replacingOccurrences(of: ".", with: "\\.")
            rules.append([
                "trigger": ["url-filter": ".*\(esc).*"],
                "action": ["type": "block"],
            ])
        }
        if blockMedia {
            // Block images + media everywhere (read mode: we don't render).
            rules.append([
                "trigger": ["url-filter": ".*", "resource-type": ["image", "media"]],
                "action": ["type": "block"],
            ])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Compile both rule lists once (idempotent). Safe to call at startup.
    func compileIfNeeded() async {
        if compiled { return }
        compiled = true
        let store = WKContentRuleListStore.default()
        if let store = store {
            adsList = try? await store.compileContentRuleList(
                forIdentifier: "popdraft-ads",
                encodedContentRuleList: Self.ruleJSON(blockMedia: false))
            readList = try? await store.compileContentRuleList(
                forIdentifier: "popdraft-read",
                encodedContentRuleList: Self.ruleJSON(blockMedia: true))
        }
    }

    /// Ruleset for read/extract (drops images+media).
    func readModeList() -> WKContentRuleList? { readList }
    /// Ruleset for screenshots/open (ads only; keeps images).
    func adsOnlyList() -> WKContentRuleList? { adsList }
}

// MARK: - Offscreen render host

/// ONE persistent borderless window positioned far offscreen. WKWebViews are
/// added as subviews with an explicit non-zero frame so they actually render
/// (a zero-frame / detached webview snapshots blank). Never made key.
@MainActor
final class OffscreenRenderHost {
    static let shared = OffscreenRenderHost()

    private let window: NSWindow

    private init() {
        let frame = NSRect(x: -10000, y: -10000, width: 1400, height: 2200)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.ignoresMouseEvents = true
        window.alphaValue = 1.0
        window.hasShadow = false
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        window.contentView = host
        // Render offscreen without stealing focus.
        window.orderBack(nil)
    }

    /// Attach a webview as a subview with an explicit frame so it renders.
    func attach(_ webView: WKWebView, frame: NSRect) {
        webView.frame = frame
        window.contentView?.addSubview(webView)
    }

    func detach(_ webView: WKWebView) {
        webView.removeFromSuperview()
    }
}

// MARK: - One-shot navigation delegate

/// Bridges a single navigation to an async continuation: resolves on
/// didFinish, throws on didFail / didFailProvisional / process crash, and
/// enforces the SSRF/scheme policy on the initial request and EVERY redirect.
///
/// SSRF NOTE: the host/IP checks here (and in `WebEngine.guardURL`) classify the
/// address(es) we resolve via `getaddrinfo`. On macOS 14+ the PRIMARY control is
/// the `PinningProxy`: WebKit routes through our localhost proxy, which resolves
/// once, validates every address, and dials the exact validated public IP — so
/// WebKit never resolves the host itself and DNS-rebinding / TOCTOU is closed.
/// These navigation-delegate checks remain as defense-in-depth (a backstop). On
/// macOS 13 (no `proxyConfigurations`) they are the only line: we mitigate by
/// (a) requiring ALL of our resolved addresses to be public, (b) capping
/// redirects, and (c) re-checking every redirect AND the final response URL —
/// a residual rebinding risk remains on 13 only.
@MainActor
final class NavigationBridge: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    /// Max redirects we follow before refusing (defense against redirect loops /
    /// rebinding chains). Exceeding this cancels with an error.
    static let maxRedirects = 8
    private var redirectCount = 0

    /// Called for every navigation action — enforce SSRF + scheme here so a
    /// redirect to an internal IP is blocked mid-flight.
    var policyCheck: ((URL) -> Bool)?
    /// Max bytes allowed for the response body; checked against the response's
    /// `expectedContentLength` in `decidePolicyForNavigationResponse`.
    var maxBytes: Int = .max
    /// Re-validates the response URL's host (resolve + all-public) on the
    /// committed response, catching a host that differs from the request.
    var responseHostCheck: ((URL) -> Bool)?
    /// The REAL HTTP status code of the main-frame response (0 if unknown, e.g.
    /// non-HTTP). Captured in `decidePolicyForNavigationResponse`.
    private(set) var httpStatus: Int = 0

    func wait(_ body: @escaping () -> Void) async throws {
        // Cancellation-aware: if the surrounding task is cancelled (e.g. the
        // renderer-pool timeout wins), resume the continuation with an error so
        // the caller always returns and the pool's `defer` releases its permit.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                self.continuation = cont
                body()
            }
        } onCancel: {
            Task { @MainActor in self.resolve(.failure(CancellationError())) }
        }
    }

    private func resolve(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        let cont = continuation
        continuation = nil
        switch result {
        case .success: cont?.resume()
        case .failure(let e): cont?.resume(throwing: e)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            // about:blank is allowed (reset); everything else passes the guard.
            if url.absoluteString.lowercased() != "about:blank" {
                // A redirect re-uses the same navigation; count it and cap.
                if navigationAction.navigationType == .other && webView.isLoading {
                    redirectCount += 1
                    if redirectCount > Self.maxRedirects {
                        decisionHandler(.cancel)
                        resolve(.failure(WebEngineError.navigationFailed("too many redirects")))
                        return
                    }
                }
                if let check = policyCheck, check(url) == false {
                    decisionHandler(.cancel)
                    resolve(.failure(WebEngineError.blockedHost(url.host ?? url.absoluteString)))
                    return
                }
            }
        }
        decisionHandler(.allow)
    }

    /// Enforce the byte cap (via `expectedContentLength`) and re-validate the
    /// response host before the body is fetched.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        // Capture the real HTTP status for the main-frame response.
        if navigationResponse.isForMainFrame, let http = response as? HTTPURLResponse {
            httpStatus = http.statusCode
        }
        // Size cap: reject up-front when the server declares an oversized body.
        let expected = response.expectedContentLength
        if expected > 0, SizeGuard.rejectByContentLength(Int(expected), max: maxBytes) {
            decisionHandler(.cancel)
            resolve(.failure(WebEngineError.tooLarge(Int(expected))))
            return
        }
        // Re-validate the committed response URL's host (catches a late rebind).
        if let url = response.url, url.absoluteString.lowercased() != "about:blank" {
            if let check = responseHostCheck, check(url) == false {
                decisionHandler(.cancel)
                resolve(.failure(WebEngineError.blockedHost(url.host ?? url.absoluteString)))
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resolve(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resolve(.failure(WebEngineError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resolve(.failure(WebEngineError.navigationFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resolve(.failure(WebEngineError.renderProcessCrashed))
    }
}

// MARK: - Async semaphore (continuation-based)

/// A small FIFO async semaphore bounding concurrent renderers. MainActor-bound
/// so its state is single-threaded by construction.
@MainActor
final class AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { permits = max(1, value) }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            w.resume()
        } else {
            permits += 1
        }
    }
}

// MARK: - Renderer pool

/// Bounds concurrent WKWebViews. `withRenderer` acquires a permit, creates a
/// FRESH webview (non-persistent store, desktop UA, content-blocking ruleset),
/// attaches it offscreen, runs the body, and detaches + releases in `defer`.
/// Recreate-per-job (no reuse). Per-job timeout cancels and stops loading.
@MainActor
final class RendererPool {
    private let semaphore: AsyncSemaphore
    private let userAgent: String
    let navTimeoutMs: Int

    init(maxRenderers: Int, navTimeoutMs: Int) {
        self.semaphore = AsyncSemaphore(value: WebTuning.clampRenderers(maxRenderers))
        self.navTimeoutMs = navTimeoutMs
        self.userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    }

    /// `readMode` selects the image/media-blocking ruleset; otherwise ads-only.
    func withRenderer<T: Sendable>(
        readMode: Bool,
        frame: NSRect = NSRect(x: 0, y: 0, width: 1280, height: 2000),
        _ body: @escaping @MainActor (WKWebView) async throws -> T
    ) async throws -> T {
        await semaphore.acquire()

        let config = WKWebViewConfiguration()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        // PR11: route ALL of this webview's traffic through the in-process
        // localhost pinning proxy so the IP WebKit connects to is the exact IP
        // our SafetyGuard validated (closes DNS-rebinding). 14+ only; on 13 we
        // fall back to the PR6 mitigation (redirect cap + response re-validation).
        if #available(macOS 14.0, *) {
            let proxyPort = PinningProxy.shared.startIfNeeded()
            if proxyPort != 0, let nwPort = NWEndpoint.Port(rawValue: proxyPort) {
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: nwPort)
                // One config covers both CONNECT (HTTPS) and plain-HTTP loads.
                let proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
                dataStore.proxyConfigurations = [proxy]
            }
        }
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: frame, configuration: config)
        webView.customUserAgent = userAgent

        // Attach the compiled content-blocking ruleset.
        let blocker = ContentBlocker.shared
        if let list = readMode ? blocker.readModeList() : blocker.adsOnlyList() {
            webView.configuration.userContentController.add(list)
        }

        OffscreenRenderHost.shared.attach(webView, frame: frame)

        // Run the body under a timeout. The timeout task cancels the body and
        // stops loading; the body task races it.
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            OffscreenRenderHost.shared.detach(webView)
            semaphore.release()
        }

        let timeoutNs = UInt64(max(1000, navTimeoutMs)) * 1_000_000
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in
                try await body(webView)
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: timeoutNs)
                webView.stopLoading()
                throw WebEngineError.timeout
            }
            // First to finish wins; cancel the rest.
            guard let first = try await group.next() else {
                throw WebEngineError.navigationFailed("no result")
            }
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Search providers

protocol SearchProvider: Sendable {
    var name: String { get }
    /// Returns nil if this provider is not configured (so the router can cascade).
    func isConfigured(keys: [String: String]) -> Bool
    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult]
}

/// Keyless DuckDuckGo provider via the lite endpoint (HTML fallback), plain
/// URLSession GET — no webview, no JS. Parsing lives in `DDGParser` (Core).
struct DuckDuckGoProvider: SearchProvider {
    let name = "ddg"
    /// Search HTML is tiny; cap the body well under the engine's page cap.
    static let maxSearchBytes = 4 * 1024 * 1024
    func isConfigured(keys: [String: String]) -> Bool { true }  // always available

    // NOTE: earlier builds routed this scrape through the PR11 localhost pinning
    // proxy (`pinnedSession()`). That broke search — DuckDuckGo 202-blocks proxied
    // traffic — so the keyless scrape now uses a PLAIN ephemeral URLSession (see
    // `search` below). Rebinding-sensitive rendering of untrusted result pages
    // still goes through the proxy via the WebEngine browse-SERP fallback.

    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult] {
        let trimmed = q.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // NB: the keyless DDG scrape is fetched with a PLAIN URLSession, NOT the
        // PR11 pinning proxy. DuckDuckGo rate-limits / 202-blocks traffic that
        // arrives via the localhost CONNECT proxy (observed: every proxied query
        // returns "HTTP 202"), which silently killed the in-app search. A public
        // search engine over HTTPS is low SSRF risk, so we go direct here. The
        // browse-SERP fallback (which renders untrusted result pages) still goes
        // through the SSRF guard + proxy via WebEngine.
        let session = URLSession(configuration: .ephemeral)

        // Use the LITE endpoint only. The `html.duckduckgo.com` endpoint now
        // serves an "anomaly"/captcha page to scrapers, so it's a dead end; lite
        // returns real results to a desktop UA. (POST also works but GET is fine.)
        let endpoints = [
            "https://lite.duckduckgo.com/lite/",
        ]
        var lastError: Error?
        for endpoint in endpoints {
            guard var comps = URLComponents(string: endpoint) else { continue }
            comps.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            // A real, current desktop Safari UA + language headers; the bare
            // "text/html" Accept and an old UA invite the anomaly page.
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            do {
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Reject an oversized response up-front (Content-Length) or after read.
                let declared = (response as? HTTPURLResponse)?.expectedContentLength
                if let len = declared, len > 0, SizeGuard.rejectByContentLength(Int(len), max: Self.maxSearchBytes) {
                    lastError = WebEngineError.tooLarge(Int(len)); continue
                }
                if SizeGuard.exceeds(received: data.count, max: Self.maxSearchBytes) {
                    lastError = WebEngineError.tooLarge(data.count); continue
                }
                guard status == 200, let html = String(data: data, encoding: .utf8) else {
                    lastError = WebEngineError.searchFailed("HTTP \(status)")
                    continue
                }
                let results = DDGParser.parseLite(html, maxResults: q.maxResults)
                if !results.isEmpty { return results }
                // Empty parse — try the next endpoint.
            } catch {
                lastError = error
                continue
            }
        }
        if let e = lastError { throw WebEngineError.searchFailed(String(describing: e)) }
        return []
    }
}

/// Key-based provider stubs. They declare configuration via `apiKeys` but are
/// not yet wired to their APIs (PR-later); the router falls through to DDG.
struct TavilyProvider: SearchProvider {
    let name = "tavily"
    func isConfigured(keys: [String: String]) -> Bool { !(keys["tavily"] ?? "").isEmpty }
    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult] {
        throw WebEngineError.searchFailed("tavily provider not implemented")
    }
}

struct BraveProvider: SearchProvider {
    let name = "brave"
    func isConfigured(keys: [String: String]) -> Bool { !(keys["brave"] ?? "").isEmpty }
    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult] {
        throw WebEngineError.searchFailed("brave provider not implemented")
    }
}

struct ExaProvider: SearchProvider {
    let name = "exa"
    func isConfigured(keys: [String: String]) -> Bool { !(keys["exa"] ?? "").isEmpty }
    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult] {
        throw WebEngineError.searchFailed("exa provider not implemented")
    }
}

/// Cascades: a configured-key provider first, DuckDuckGo as the always-on
/// fallback. Dedupes results by host+path. Politely rate-limited.
actor SearchRouter {
    private let apiKeys: [String: String]
    private let preferred: String
    private let ddg = DuckDuckGoProvider()
    private let keyed: [SearchProvider]
    private var lastRequest: Date = .distantPast
    private let minInterval: TimeInterval = 0.5

    init(apiKeys: [String: String], preferred: String) {
        self.apiKeys = apiKeys
        self.preferred = preferred
        self.keyed = [TavilyProvider(), BraveProvider(), ExaProvider()]
    }

    private func rateLimit() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequest)
        if elapsed < minInterval {
            let waitNs = UInt64((minInterval - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: waitNs)
        }
        lastRequest = Date()
    }

    func search(_ q: SearchQuery) async throws -> [SearchResult] {
        await rateLimit()

        // 1) A configured keyed provider matching the preferred name first.
        var providers: [SearchProvider] = []
        if let pref = keyed.first(where: { $0.name == preferred && $0.isConfigured(keys: apiKeys) }) {
            providers.append(pref)
        }
        // 2) Any other configured keyed provider.
        for p in keyed where p.isConfigured(keys: apiKeys) && p.name != preferred {
            providers.append(p)
        }
        // 3) DDG always last as the keyless fallback.
        providers.append(ddg)

        var lastError: Error?
        for p in providers {
            do {
                let results = try await p.search(q, keys: apiKeys)
                if !results.isEmpty { return Self.dedupe(results, limit: q.maxResults) }
            } catch {
                lastError = error
                continue
            }
        }
        if let e = lastError { throw e }
        return []
    }

    /// Dedupe by normalized host+path (drops scheme + query + trailing slash).
    static func dedupe(_ results: [SearchResult], limit: Int) -> [SearchResult] {
        var seen = Set<String>()
        var out: [SearchResult] = []
        for r in results {
            let key: String
            if let comps = URLComponents(string: r.url), let host = comps.host {
                var path = comps.path
                if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                key = (host + path).lowercased()
            } else {
                key = r.url.lowercased()
            }
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(r)
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - Web cache (actor)

/// On-disk + in-memory cache keyed by sha256(method+url+variant), with TTLs per
/// kind and in-flight coalescing so duplicate concurrent requests share one
/// fetch. Bounded with simple LRU eviction.
actor WebCache {
    struct Entry {
        let data: Data
        let storedAt: Date
        let ttl: TimeInterval
        var isFresh: Bool { Date().timeIntervalSince(storedAt) < ttl }
    }

    private var memory: [String: Entry] = [:]
    private var order: [String] = []                  // LRU: oldest first
    private var inFlight: [String: Task<Data, Error>] = [:]
    private let maxEntries: Int
    private let diskDir: String

    init(diskDir: String, maxEntries: Int = 128) {
        self.diskDir = diskDir
        self.maxEntries = maxEntries
        try? FileManager.default.createDirectory(atPath: diskDir, withIntermediateDirectories: true)
    }

    static func key(method: String, url: String, variant: String) -> String {
        let raw = "\(method)|\(url)|\(variant)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func touch(_ k: String) {
        if let i = order.firstIndex(of: k) { order.remove(at: i) }
        order.append(k)
    }

    private func evictIfNeeded() {
        while memory.count > maxEntries, let oldest = order.first {
            memory.removeValue(forKey: oldest)
            order.removeFirst()
        }
    }

    /// Fetch-or-compute with coalescing. `compute` runs at most once per key
    /// while in flight; the result is cached for `ttl` ONLY when `shouldStore`
    /// returns true (default: always). A transient bad render (e.g. empty
    /// Markdown) can thus be returned to THIS caller without poisoning the cache.
    func value(
        forKey key: String,
        ttl: TimeInterval,
        shouldStore: @escaping @Sendable (Data) -> Bool = { _ in true },
        compute: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        // Fresh memory hit?
        if let e = memory[key], e.isFresh {
            touch(key)
            return e.data
        }
        // Coalesce concurrent identical requests.
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { try await compute() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        if shouldStore(data) {
            memory[key] = Entry(data: data, storedAt: Date(), ttl: ttl)
            touch(key)
            evictIfNeeded()
        }
        return data
    }

    /// Path for an on-disk artifact (e.g. a screenshot PNG) under the cache dir.
    func diskPath(for name: String) -> String {
        return (diskDir as NSString).appendingPathComponent(name)
    }
}

// =====================================================================
// MARK: - PinningProxy (PR11: connection-level IP pinning)
// =====================================================================
//
// An in-process forward proxy on 127.0.0.1:<ephemeral>, built on the Network
// framework. WKWebView (macOS 14+) is configured to send ALL of its traffic
// here via `WKWebsiteDataStore.proxyConfigurations`. For each connection the
// proxy:
//   1. parses the client's first request (CONNECT or absolute-form HTTP),
//   2. resolves the target host ONCE (getaddrinfo),
//   3. runs EVERY resolved address through SafetyGuard — rejects if ANY is
//      private/loopback/metadata (FAIL CLOSED), picks one validated PUBLIC IP,
//   4. dials that exact IP (never the hostname) and tunnels/forwards bytes.
//
// Because we dial the resolved-and-validated IP, WebKit never performs its own
// DNS resolution → the classic DNS-rebinding / TOCTOU window is closed: the IP
// the guard approved is the IP the socket connects to.
//
// No TLS interception: for CONNECT we blind-tunnel the opaque TLS bytes, so TLS
// still terminates inside WKWebView exactly as normal (cert validation intact).
//
// Sendable note: Network's state/receive handlers are @Sendable. Each connection
// is its own reference-type `ProxyConnection` whose mutable state is confined to
// its own serial queue; the handlers capture only `self` (a class ref, which is
// Sendable here because all access is funnelled onto that queue) — never an
// outer captured `var`.

/// One in-process forward proxy bound to loopback. Lazily started; thread-safe.
final class PinningProxy: @unchecked Sendable {
    static let shared = PinningProxy()

    /// Hard ceiling on simultaneously-tunnelled connections (back-pressure).
    private static let maxConnections = 16
    /// Per-leg dial timeout. WebKit retries; we keep this tight.
    private static let dialTimeoutSeconds: Double = 12
    /// Cap on a plain-HTTP response body we relay (matches the engine's page cap
    /// ceiling; CONNECT tunnels are not byte-capped since they're opaque TLS).
    private static let httpMaxBytes = 16 * 1024 * 1024

    /// Connections run on this concurrent queue. Mutable bookkeeping below is
    /// guarded by `lock` (a plain lock — NOT a serial queue — so the bind wait
    /// can't re-enter and deadlock).
    private let queue = DispatchQueue(label: "com.popdraft.pinningproxy", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var started = false
    private var active: [ObjectIdentifier: ProxyConnection] = [:]
    /// Signalled by the listener's `.ready` transition so the first
    /// `startIfNeeded()` can return a usable port synchronously.
    private let bindSignal = DispatchSemaphore(value: 0)

    /// True only when the env-gated test hook is set (loopback fixtures allowed).
    private let allowTestLoopback: Bool

    private init() {
        self.allowTestLoopback = (SafetyGuard.allowedLoopbackTestPort() != nil)
    }

    /// Start the listener if not already running; returns the bound loopback port
    /// (0 if it could not start). Idempotent and synchronous on first call.
    @discardableResult
    func startIfNeeded() -> UInt16 {
        lock.lock()
        if started {
            let p = boundPort
            lock.unlock()
            return p
        }
        started = true
        lock.unlock()

        do {
            let params = NWParameters.tcp
            // Loopback-only: bind explicitly to 127.0.0.1 so nothing off-box can
            // reach the proxy. Single-user, ephemeral port.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"), port: .any)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                if case .ready = state, let p = l.port?.rawValue {
                    self.lock.lock()
                    let firstReady = (self.boundPort == 0)
                    self.boundPort = p
                    self.lock.unlock()
                    if firstReady { self.bindSignal.signal() }
                }
            }
            l.newConnectionHandler = { [weak self] nwconn in
                self?.accept(nwconn)
            }
            l.start(queue: queue)
            lock.lock(); self.listener = l; lock.unlock()

            // Wait (bounded) for the listener to bind so callers get a usable port.
            _ = bindSignal.wait(timeout: .now() + 3.0)
            lock.lock(); let p = boundPort; lock.unlock()
            return p
        } catch {
            lock.lock(); started = false; lock.unlock()
            return 0
        }
    }

    /// The bound port (0 if not started). For diagnostics.
    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return boundPort }

    private func accept(_ nwconn: NWConnection) {
        lock.lock()
        let shouldDrop = active.count >= Self.maxConnections
        lock.unlock()
        if shouldDrop {
            nwconn.cancel()
            return
        }
        // Each connection gets its OWN serial queue so all of its callbacks —
        // across BOTH the client and the upstream NWConnection — are mutually
        // exclusive. (The proxy's `queue` is concurrent; running two different
        // NWConnections of one tunnel on it could race the connection's mutable
        // state / teardown.) `target: queue` keeps it on the proxy's thread pool.
        let connQueue = DispatchQueue(label: "com.popdraft.pinningproxy.conn", target: queue)
        let conn = ProxyConnection(
            client: nwconn,
            queue: connQueue,
            allowTestLoopback: allowTestLoopback,
            dialTimeout: Self.dialTimeoutSeconds,
            httpMaxBytes: Self.httpMaxBytes,
            onClose: { [weak self] c in
                guard let self = self else { return }
                self.lock.lock()
                self.active.removeValue(forKey: ObjectIdentifier(c))
                self.lock.unlock()
            })
        lock.lock()
        active[ObjectIdentifier(conn)] = conn
        lock.unlock()
        conn.start()
    }
}

// MARK: PinningProxy — per-connection handler

/// Handles ONE client connection's lifecycle: read the first request, classify
/// + pin the target, dial the validated IP, then either blind-tunnel (CONNECT)
/// or forward+stream (plain HTTP). Self-contained reference type; all mutable
/// state is touched only on `queue` (the receive/send/state handlers run there).
private final class ProxyConnection: @unchecked Sendable {
    private let client: NWConnection
    private let queue: DispatchQueue
    private let allowTestLoopback: Bool
    private let dialTimeout: Double
    private let httpMaxBytes: Int
    private let onClose: @Sendable (ProxyConnection) -> Void

    private var upstream: NWConnection?
    private var requestBuffer = Data()
    /// Bytes the client pipelined after the request head (e.g. a TLS ClientHello
    /// sent in the same segment as CONNECT); flushed upstream when the tunnel opens.
    private var pendingClientBytes = Data()
    private var closed = false
    private var relayedBytes = 0
    private var phase: Phase = .reading
    /// Guards the upstream `.ready` handler so a duplicate ready transition does
    /// not re-arm the tunnel/forward. Touched only on `queue`, so safe without a
    /// captured-var (avoids new SendableClosureCaptures diagnostics).
    private var upstreamArmed = false

    private enum Phase { case reading, tunneling, forwarding, done }

    init(client: NWConnection,
         queue: DispatchQueue,
         allowTestLoopback: Bool,
         dialTimeout: Double,
         httpMaxBytes: Int,
         onClose: @escaping @Sendable (ProxyConnection) -> Void) {
        self.client = client
        self.queue = queue
        self.allowTestLoopback = allowTestLoopback
        self.dialTimeout = dialTimeout
        self.httpMaxBytes = httpMaxBytes
        self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.teardown()
            default:
                break
            }
        }
        client.start(queue: queue)
        // Bound the request-head read: a client that opens a socket and never
        // completes a header (slow-loris) would otherwise hold its `active` slot
        // forever. If we're still reading after this deadline, tear down.
        queue.asyncAfter(deadline: .now() + dialTimeout) { [weak self] in
            guard let self = self else { return }
            if self.phase == .reading && !self.closed {
                self.teardown()
            }
        }
        readRequestHeader()
    }

    // MARK: Read the request head (until CRLFCRLF)

    private func readRequestHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.requestBuffer.append(data)
                // Guard against an unbounded header (malicious client).
                if self.requestBuffer.count > 256 * 1024 {
                    self.rejectAndClose(status: "431 Request Header Fields Too Large")
                    return
                }
                if let headerEnd = self.indexOfHeaderTerminator(self.requestBuffer) {
                    self.handleRequestHead(headerEndExclusive: headerEnd)
                    return
                }
            }
            if isComplete || error != nil {
                self.teardown()
                return
            }
            // Need more bytes for the header.
            self.readRequestHeader()
        }
    }

    /// Returns the index just past the CRLFCRLF (or LFLF) terminator, or nil.
    private func indexOfHeaderTerminator(_ buf: Data) -> Int? {
        let crlfcrlf: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let lflf: [UInt8] = [0x0A, 0x0A]
        let bytes = [UInt8](buf)
        if let r = firstRange(of: crlfcrlf, in: bytes) { return r + crlfcrlf.count }
        if let r = firstRange(of: lflf, in: bytes) { return r + lflf.count }
        return nil
    }

    private func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        let upper = haystack.count - needle.count
        var i = 0
        while i <= upper {
            var j = 0
            while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i }
            i += 1
        }
        return nil
    }

    // MARK: Dispatch on the parsed request

    private func handleRequestHead(headerEndExclusive: Int) {
        let headData = requestBuffer.prefix(headerEndExclusive)
        let remainder = requestBuffer.suffix(from: headerEndExclusive)   // pipelined body bytes
        guard let headText = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1) else {
            rejectAndClose(status: "400 Bad Request")
            return
        }
        let lines = headText.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            rejectAndClose(status: "400 Bad Request")
            return
        }
        let headerLines = Array(lines.dropFirst()).filter { !$0.isEmpty }

        // CONNECT (HTTPS tunnel) — the common case.
        if let target = ProxyParser.parseConnect(requestLine) {
            // A client may coalesce the TLS ClientHello into the same segment as
            // the CONNECT head; preserve those bytes to flush upstream once the
            // tunnel is open (otherwise the handshake stalls until dial timeout).
            pendingClientBytes = Data(remainder)
            pinAndConnect(host: target.host, port: target.port)
            return
        }
        // Plain HTTP (absolute-form or origin-form + Host header).
        let hostHeader = ProxyParser.header("Host", in: headerLines)
        if let t = ProxyParser.parseHTTP(requestLine: requestLine, hostHeader: hostHeader) {
            pinAndForwardHTTP(target: t, headerLines: headerLines, pipelinedBody: Data(remainder))
            return
        }
        // Anything else (unknown method / malformed) → refuse.
        rejectAndClose(status: "405 Method Not Allowed")
    }

    // MARK: Resolve + pin to a validated public IP

    /// Resolve `host`, run SafetyGuard over every address, and return the picked
    /// IP to dial — or nil after sending a 403 and closing.
    private func resolvePinned(host: String) -> String? {
        let addrs = DNSResolver.resolve(host)
        let result = SafetyGuard.pinnedAddress(forResolved: addrs, allowTestLoopback: allowTestLoopback)
        switch result {
        case .allowed(let ip):
            return ip
        case .blocked(let reason):
            rejectAndClose(status: "403 Forbidden", body: "blocked by SSRF guard: \(host) (\(reason))")
            return nil
        }
    }

    /// Build an NWConnection to a validated IP literal + port.
    private func dial(ip: String, port: Int) -> NWConnection {
        let host = NWEndpoint.Host(ip)
        let nwport = NWEndpoint.Port(rawValue: UInt16(port)) ?? .https
        return NWConnection(host: host, port: nwport, using: .tcp)
    }

    // MARK: CONNECT — blind TLS tunnel to the validated IP

    private func pinAndConnect(host: String, port: Int) {
        guard let ip = resolvePinned(host: host) else { return }
        let up = dial(ip: ip, port: port)
        upstream = up
        up.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if self.upstreamArmed { return }
                self.upstreamArmed = true
                self.onUpstreamConnected_CONNECT()
            case .failed, .cancelled:
                self.teardown()
            default:
                break
            }
        }
        armDialTimeout(up)
        up.start(queue: queue)
    }

    private func onUpstreamConnected_CONNECT() {
        // Tell the client the tunnel is up, then pump bytes both ways opaquely.
        let ok = "HTTP/1.1 200 Connection Established\r\n\r\n"
        client.send(content: Data(ok.utf8), completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if err != nil { self.teardown(); return }
            self.phase = .tunneling
            // Any bytes the client already sent after the CONNECT head are TLS
            // ClientHello — they live in requestBuffer beyond the header; flush them.
            // (We read header up to CRLFCRLF; with CONNECT there is no body, but a
            // client may pipeline the ClientHello — forward any leftover now.)
            self.pumpTunnel()
        })
    }

    private func pumpTunnel() {
        guard let up = upstream else { teardown(); return }
        // Flush any ClientHello bytes the client pipelined with the CONNECT head.
        if !pendingClientBytes.isEmpty {
            let pending = pendingClientBytes
            pendingClientBytes = Data()
            up.send(content: pending, completion: .contentProcessed { [weak self] err in
                guard let self = self else { return }
                if err != nil { self.teardown() }
            })
        }
        relay(from: client, to: up)
        relay(from: up, to: client)
    }

    /// Continuously copy bytes from `src` to `dst` until either side closes.
    private func relay(from src: NWConnection, to dst: NWConnection) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                dst.send(content: data, completion: .contentProcessed { [weak self] err in
                    guard let self = self else { return }
                    if err != nil { self.teardown(); return }
                    if !isComplete && error == nil {
                        self.relay(from: src, to: dst)
                    } else {
                        self.teardown()
                    }
                })
            } else if isComplete || error != nil {
                self.teardown()
            } else {
                self.relay(from: src, to: dst)
            }
        }
    }

    // MARK: Plain HTTP — forward request, stream response (byte-capped)

    private func pinAndForwardHTTP(target: ProxyParser.HTTPTarget, headerLines: [String], pipelinedBody: Data) {
        guard let ip = resolvePinned(host: target.host) else { return }
        let up = dial(ip: ip, port: target.port)
        upstream = up

        // Rebuild the request in origin-form for the upstream, forcing a correct
        // Host header and dropping any proxy-only headers.
        var rebuilt = "\(target.method) \(target.path) \(target.version)\r\n"
        let portSuffix = (target.port == 80) ? "" : ":\(target.port)"
        rebuilt += "Host: \(target.host)\(portSuffix)\r\n"
        for line in headerLines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            // Skip headers we set ourselves or that are proxy-hop-only.
            if key == "host" || key == "proxy-connection" || key == "connection" { continue }
            rebuilt += line + "\r\n"
        }
        rebuilt += "Connection: close\r\n\r\n"
        var outbound = Data(rebuilt.utf8)
        outbound.append(pipelinedBody)
        let requestBytes = outbound

        up.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if self.upstreamArmed { return }
                self.upstreamArmed = true
                self.onUpstreamConnected_HTTP(sending: requestBytes)
            case .failed, .cancelled:
                self.teardown()
            default:
                break
            }
        }
        armDialTimeout(up)
        up.start(queue: queue)
    }

    private func onUpstreamConnected_HTTP(sending requestBytes: Data) {
        guard let up = upstream else { teardown(); return }
        self.phase = .forwarding
        up.send(content: requestBytes, completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if err != nil { self.teardown(); return }
            // Stream the upstream response straight back to the client, capped.
            self.streamResponse(from: up)
        })
    }

    private func streamResponse(from up: NWConnection) {
        up.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.relayedBytes += data.count
                if self.relayedBytes > self.httpMaxBytes {
                    self.teardown()
                    return
                }
                self.client.send(content: data, completion: .contentProcessed { [weak self] err in
                    guard let self = self else { return }
                    if err != nil { self.teardown(); return }
                    if !isComplete && error == nil {
                        self.streamResponse(from: up)
                    } else {
                        self.teardown()
                    }
                })
            } else if isComplete || error != nil {
                self.teardown()
            } else {
                self.streamResponse(from: up)
            }
        }
    }

    // MARK: Helpers

    private func armDialTimeout(_ up: NWConnection) {
        let deadline = DispatchTime.now() + dialTimeout
        queue.asyncAfter(deadline: deadline) { [weak self, weak up] in
            guard let self = self, let up = up else { return }
            if up.state != .ready && !self.closed {
                self.teardown()
            }
        }
    }

    private func rejectAndClose(status: String, body: String? = nil) {
        let payload = body ?? ""
        let resp = "HTTP/1.1 \(status)\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
        client.send(content: Data(resp.utf8), completion: .contentProcessed { [weak self] _ in
            self?.teardown()
        })
    }

    private func teardown() {
        if closed { return }
        closed = true
        phase = .done
        upstream?.cancel()
        upstream = nil
        client.cancel()
        onClose(self)
    }
}

// MARK: - Persistent browsing session (Playwright-style)

/// ONE long-lived offscreen `WKWebView` the agent DRIVES across tool calls
/// (open → type → click → read), distinct from the one-shot read/screenshot
/// `RendererPool` (which recreates a fresh webview per job and never persists
/// state). The session keeps cookies/history/scroll position alive so a flow
/// like "search → click a result → read it" works.
///
/// SSRF: every navigation (initial load, click-triggered nav, redirect, response
/// host, and Back) is gated by the SAME `policyCheck`/`responseHostCheck` the
/// pool uses — supplied by `WebEngine` — and, on macOS 14+, routed through the
/// `PinningProxy`. The session webview uses a NON-persistent data store so it
/// leaves nothing on disk, but keeps that store alive for the session's lifetime.
@MainActor
final class BrowserSession {
    /// The live webview (lazily created on first use). A persistent navigation
    /// delegate stays attached so click-initiated navigations are still SSRF-gated
    /// (the per-call `NavigationBridge` only spans an explicit load).
    private var webView: WKWebView?
    private let frame = NSRect(x: 0, y: 0, width: 1280, height: 2000)
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// SSRF policy + byte cap supplied by `WebEngine`. `policyCheck` runs on every
    /// navigation action (incl. click-triggered + redirects); `responseHostCheck`
    /// re-validates the committed response URL; `maxBytes` caps the body.
    private let policyCheck: @MainActor (URL) -> Bool
    private let responseHostCheck: @MainActor (URL) -> Bool
    private let maxBytes: Int
    private let navTimeoutMs: Int
    private let settleMs: Int

    /// The persistent delegate enforcing SSRF on background (click) navigations.
    private let guardDelegate: SessionGuardDelegate

    init(policyCheck: @escaping @MainActor (URL) -> Bool,
         responseHostCheck: @escaping @MainActor (URL) -> Bool,
         maxBytes: Int, navTimeoutMs: Int, settleMs: Int) {
        self.policyCheck = policyCheck
        self.responseHostCheck = responseHostCheck
        self.maxBytes = maxBytes
        self.navTimeoutMs = navTimeoutMs
        self.settleMs = settleMs
        self.guardDelegate = SessionGuardDelegate(
            policyCheck: policyCheck, responseHostCheck: responseHostCheck, maxBytes: maxBytes)
    }

    /// Whether a page has ever been loaded into the session.
    var hasPage: Bool { (webView?.url) != nil }

    /// Lazily build the session webview (non-persistent store, proxy on 14+).
    private func ensureWebView() -> WKWebView {
        if let wv = webView { return wv }
        let config = WKWebViewConfiguration()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        if #available(macOS 14.0, *) {
            let proxyPort = PinningProxy.shared.startIfNeeded()
            if proxyPort != 0, let nwPort = NWEndpoint.Port(rawValue: proxyPort) {
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: nwPort)
                let proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
                dataStore.proxyConfigurations = [proxy]
            }
        }
        config.websiteDataStore = dataStore
        let wv = WKWebView(frame: frame, configuration: config)
        wv.customUserAgent = userAgent
        // Ads-only ruleset (interactive pages need their images/layout).
        if let list = ContentBlocker.shared.adsOnlyList() {
            wv.configuration.userContentController.add(list)
        }
        OffscreenRenderHost.shared.attach(wv, frame: frame)
        webView = wv
        return wv
    }

    /// Tear down the session webview (called on engine reload / app teardown).
    func reset() {
        if let wv = webView {
            wv.stopLoading()
            wv.navigationDelegate = nil
            OffscreenRenderHost.shared.detach(wv)
        }
        webView = nil
    }

    /// Navigate to `url`, wait for load + a bounded settle. SSRF-gated on the
    /// initial request, every redirect, and the response host. Throws on
    /// blocked host / nav failure / timeout.
    @discardableResult
    func load(_ url: URL) async throws -> Int {
        let wv = ensureWebView()
        return try await runNavigation(wv) {
            wv.load(URLRequest(url: url))
        }
    }

    /// Run `body` (a navigation trigger) under a fresh `NavigationBridge` so we
    /// get a precise load completion + SSRF gate + timeout, then restore the
    /// persistent guard delegate so background navigations stay gated.
    private func runNavigation(_ wv: WKWebView, _ body: @escaping @MainActor () -> Void) async throws -> Int {
        let bridge = NavigationBridge()
        bridge.policyCheck = { [policyCheck] u in policyCheck(u) }
        bridge.responseHostCheck = { [responseHostCheck] u in responseHostCheck(u) }
        bridge.maxBytes = maxBytes
        wv.navigationDelegate = bridge
        defer { wv.navigationDelegate = guardDelegate }

        let timeoutNs = UInt64(max(1000, navTimeoutMs)) * 1_000_000
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await bridge.wait { body() }
            }
            group.addTask { @MainActor [wv] in
                try await Task.sleep(nanoseconds: timeoutNs)
                wv.stopLoading()
                throw WebEngineError.timeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
        try await settle(wv)
        return bridge.httpStatus
    }

    /// Poll readyState==complete (bounded) then apply the bounded settle delay.
    private func settle(_ wv: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            try Task.checkCancellation()
            let state = (try? await wv.evaluateJavaScript(WebJS.readyStateScript)) as? String
            if state == "complete" { break }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        let settleNs = UInt64(max(0, settleMs)) * 1_000_000
        if settleNs > 0 { try await Task.sleep(nanoseconds: settleNs) }
    }

    /// Evaluate a click. If the click triggers a navigation, wait for it (bounded)
    /// and re-settle; otherwise just settle. Returns the JS result JSON string.
    /// `argLiteral` is built by `BrowserTargets.argLiteral` (JSON-encoded).
    func click(argLiteral: String) async throws -> String {
        guard let wv = webView else { throw WebEngineError.navigationFailed("no page open") }
        let script = BrowserJS.clickScript(argLiteral: argLiteral)
        let urlBefore = wv.url?.absoluteString ?? ""
        let raw = (try? await wv.evaluateJavaScript(script) as? String) ?? "{}"
        // Give a click-triggered navigation a moment to start, then settle either
        // way. We do NOT throw on no-navigation (many clicks mutate the DOM in
        // place). SSRF on any nav is enforced by the persistent guard delegate.
        try? await Task.sleep(nanoseconds: 250_000_000)
        try await waitForNavIfLoading(wv, urlBefore: urlBefore)
        return raw
    }

    /// Type into an input; same navigation-aware settle as `click` (submit may
    /// navigate). Returns the JS result JSON string.
    func type(argLiteral: String, submit: Bool) async throws -> String {
        guard let wv = webView else { throw WebEngineError.navigationFailed("no page open") }
        let script = BrowserJS.typeScript(argLiteral: argLiteral, submit: submit)
        let urlBefore = wv.url?.absoluteString ?? ""
        let raw = (try? await wv.evaluateJavaScript(script) as? String) ?? "{}"
        if submit {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try await waitForNavIfLoading(wv, urlBefore: urlBefore)
        } else {
            try await settle(wv)
        }
        return raw
    }

    /// Go back one history entry. Returns the resulting HTTP status (0 unknown).
    /// Throws when there's no back entry.
    @discardableResult
    func back() async throws -> Int {
        guard let wv = webView else { throw WebEngineError.navigationFailed("no page open") }
        guard wv.canGoBack else { throw WebEngineError.navigationFailed("no back history") }
        return try await runNavigation(wv) { wv.goBack() }
    }

    /// Bounded wait while the webview is mid-load (after a click/submit that
    /// kicked off navigation), then settle. SSRF on the navigation is enforced by
    /// the persistent `guardDelegate`. Tolerant: a stuck load just falls through
    /// after the timeout instead of hanging.
    private func waitForNavIfLoading(_ wv: WKWebView, urlBefore: String) async throws {
        let deadline = Date().addingTimeInterval(Double(max(1000, navTimeoutMs)) / 1000.0)
        // Wait until it stops loading OR the URL changed and readyState completes.
        while Date() < deadline {
            if Task.isCancelled { break }
            if !wv.isLoading {
                let state = (try? await wv.evaluateJavaScript(WebJS.readyStateScript)) as? String
                if state == "complete" { break }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try await settle(wv)
    }

    /// Current URL/title for result assembly.
    func currentURL() -> String { webView?.url?.absoluteString ?? "" }
    func currentTitle() async -> String {
        guard let wv = webView else { return "" }
        return (try? await wv.evaluateJavaScript("document.title") as? String) ?? ""
    }

    /// Run an arbitrary BUNDLED script on the current page (no page-derived input)
    /// and return its string result. Used for the accessibility summary + read.
    func evaluate(_ script: String) async throws -> String {
        guard let wv = webView else { throw WebEngineError.navigationFailed("no page open") }
        return (try? await wv.evaluateJavaScript(script) as? String) ?? ""
    }

    /// Run `script` (a scroll trigger), then wait `waitNs` for lazy-loaded
    /// (JS/AJAX) content to fetch + render. No navigation is expected — SPA content
    /// injection mutates the DOM in place — so we just pause; the caller re-snapshots.
    func scrollAndWait(_ script: String, waitNs: UInt64) async throws {
        guard let wv = webView else { throw WebEngineError.navigationFailed("no page open") }
        _ = try? await wv.evaluateJavaScript(script)
        if waitNs > 0 { try await Task.sleep(nanoseconds: waitNs) }
    }

    /// Evaluate ARBITRARY caller-supplied JS on the current page and coerce ANY
    /// result type to a String (backing `browser_evaluate`). Unlike `evaluate`,
    /// numbers/bools are stringified and arrays/objects JSON-encoded, so the model
    /// can grab e.g. `document.documentElement.innerHTML` or a computed value.
    /// A JS error propagates (the tool layer turns it into a readable message).
    func evaluateAny(_ script: String) async throws -> String {
        guard let wv = webView else { throw WebEngineError.navigationFailed("no page open") }
        let result = try await wv.evaluateJavaScript(script)
        return BrowserSession.coerce(result)
    }

    /// Coerce a JS `evaluateJavaScript` result (`Any?`) to a String. Strings pass
    /// through; true booleans (distinguished from 0/1 via CFBoolean) render
    /// true/false; other numbers stringify; JSON-serializable arrays/objects are
    /// encoded; everything else falls back to `String(describing:)`.
    nonisolated static func coerce(_ value: Any?) -> String {
        guard let value = value else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: value)
    }

    /// Take a snapshot PNG of the current page (delegates frame sizing to caller).
    func snapshot(fullPage: Bool, scrollHeightScript: String) async throws -> (Data, Int) {
        guard let wv = webView else { throw WebEngineError.navigationFailed("no page open") }
        var targetHeight = 2000
        if fullPage {
            let raw = try? await wv.evaluateJavaScript(scrollHeightScript)
            let maxH = 12000
            if let h = raw as? Int { targetHeight = min(max(h, 400), maxH) }
            else if let hd = raw as? Double { targetHeight = min(max(Int(hd), 400), maxH) }
            else if let hn = raw as? NSNumber { targetHeight = min(max(hn.intValue, 400), maxH) }
            wv.frame = NSRect(x: 0, y: 0, width: 1280, height: targetHeight)
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let snapConfig = WKSnapshotConfiguration()
        if fullPage { snapConfig.rect = NSRect(x: 0, y: 0, width: 1280, height: targetHeight) }
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            wv.takeSnapshot(with: snapConfig) { img, err in
                if let img = img { cont.resume(returning: img) }
                else { cont.resume(throwing: err ?? WebEngineError.noContent) }
            }
        }
        // Restore the default viewport height after a full-page resize.
        if fullPage { wv.frame = frame }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw WebEngineError.noContent
        }
        return (png, targetHeight)
    }
}

/// The persistent navigation delegate the session webview keeps attached when no
/// explicit `NavigationBridge` is in flight. It exists solely to keep SSRF
/// enforcement on background navigations a click/script can trigger (a redirect
/// to an internal IP after the click resolved). It does NOT bridge a
/// continuation — it just allows/cancels per the same policy closures.
@MainActor
final class SessionGuardDelegate: NSObject, WKNavigationDelegate {
    private let policyCheck: @MainActor (URL) -> Bool
    private let responseHostCheck: @MainActor (URL) -> Bool
    private let maxBytes: Int

    init(policyCheck: @escaping @MainActor (URL) -> Bool,
         responseHostCheck: @escaping @MainActor (URL) -> Bool,
         maxBytes: Int) {
        self.policyCheck = policyCheck
        self.responseHostCheck = responseHostCheck
        self.maxBytes = maxBytes
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           url.absoluteString.lowercased() != "about:blank",
           policyCheck(url) == false {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let expected = response.expectedContentLength
        if expected > 0, SizeGuard.rejectByContentLength(Int(expected), max: maxBytes) {
            decisionHandler(.cancel)
            return
        }
        if let url = response.url, url.absoluteString.lowercased() != "about:blank",
           responseHostCheck(url) == false {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - Download redirect SSRF guard (URLSession)

/// A `URLSessionTaskDelegate` that re-runs the SSRF host check on EVERY redirect
/// the server tries, so a download URL that 30x-bounces to an internal IP (e.g.
/// `http://169.254.169.254/...`) is blocked mid-flight. Cancels the request
/// (returns a nil redirect request) when the next hop fails the check.
///
/// `@unchecked Sendable`: `allow` is an immutable `@Sendable` closure captured at
/// init; there is no mutable state. The delegate is called on the URLSession's
/// own delegate queue (off-main), so it must NOT be MainActor-isolated.
final class DownloadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allow: @Sendable (URL) -> Bool
    init(allow: @escaping @Sendable (URL) -> Bool) { self.allow = allow }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url else { completionHandler(nil); return }
        // Only http(s) redirects, and only to hosts that pass the SSRF check.
        let scheme = url.scheme?.lowercased() ?? ""
        if (scheme == "http" || scheme == "https"), allow(url) {
            completionHandler(request)
        } else {
            // Block: cancel the redirect (the data task then fails).
            completionHandler(nil)
        }
    }
}

// MARK: - WebEngine (public async API)

/// The public façade. Owns the renderer pool, search router, content blocker,
/// cache, and safety guard. All methods are async + parallel-safe up to the
/// renderer cap. PR7 registers these as agent tools.
@MainActor
final class WebEngine {
    static let shared = WebEngine()

    private var pool: RendererPool
    private var router: SearchRouter
    private let cache: WebCache
    private let shotsDir: String
    private var config: AppConfig
    /// The persistent interactive browsing session (created on first browser_*
    /// call). Distinct from the one-shot renderer pool; survives across tool
    /// calls so a search → click → read flow keeps the same page/history.
    private var browserSessionStore: BrowserSession?

    private init() {
        let cfg = AppConfig.load(dir: LLMConfig.configDir)
        self.config = cfg
        let cacheDir = (LLMConfig.configDir as NSString).appendingPathComponent("web-cache")
        self.shotsDir = (cacheDir as NSString).appendingPathComponent("shots")
        try? FileManager.default.createDirectory(atPath: shotsDir, withIntermediateDirectories: true)
        self.cache = WebCache(diskDir: cacheDir)
        self.pool = RendererPool(maxRenderers: cfg.webMaxRenderers, navTimeoutMs: cfg.webNavTimeoutMs)
        self.router = SearchRouter(apiKeys: cfg.webSearch.apiKeys, preferred: cfg.webSearch.provider)
    }

    /// Re-read config (renderer cap, timeouts, search keys) and rebuild the pool
    /// and router. Call after the user changes settings. Also drops the live
    /// browsing session so it picks up the new timeouts/byte cap on next use.
    func reloadConfig() {
        let cfg = AppConfig.load(dir: LLMConfig.configDir)
        config = cfg
        pool = RendererPool(maxRenderers: cfg.webMaxRenderers, navTimeoutMs: cfg.webNavTimeoutMs)
        router = SearchRouter(apiKeys: cfg.webSearch.apiKeys, preferred: cfg.webSearch.provider)
        browserSessionStore?.reset()
        browserSessionStore = nil
    }

    /// The persistent session, lazily created with the current SSRF policy + caps.
    private var browserSession: BrowserSession {
        if let s = browserSessionStore { return s }
        let s = BrowserSession(
            policyCheck: { [weak self] u in self?.redirectAllowed(u) ?? false },
            responseHostCheck: { [weak self] u in self?.redirectAllowed(u) ?? false },
            maxBytes: config.webMaxBytes,
            navTimeoutMs: config.webNavTimeoutMs,
            settleMs: config.webSettleMs)
        browserSessionStore = s
        return s
    }

    /// Compile content-blocking rules at startup (call once from AppDelegate).
    /// Also primes the PR11 pinning proxy (14+) so the first navigation doesn't
    /// pay the bind latency.
    func warmUp() async {
        await ContentBlocker.shared.compileIfNeeded()
        if #available(macOS 14.0, *) {
            _ = PinningProxy.shared.startIfNeeded()
        }
    }

    // MARK: SSRF gate

    /// Core SSRF host check, FAIL-CLOSED. Returns nil when the host is safe to
    /// fetch, or a reason string when it must be blocked.
    ///
    /// Rules (in order):
    ///   - TEST-ONLY loopback escape hatch (env-gated; never set in the app).
    ///   - obvious-local literal host (localhost / *.local / *.internal / IP literal) → block.
    ///   - resolve via getaddrinfo: ZERO resolved addresses → block (FAIL CLOSED —
    ///     a non-resolving name is not provably public).
    ///   - ANY resolved address private/loopback/metadata → block (require ALL public).
    ///
    /// Residual DNS-rebinding risk: WebKit resolves independently of us, so this
    /// is TOCTOU. Mitigated by re-checking redirects + the response URL and
    /// capping redirects; full per-socket IP pinning is a tracked follow-up.
    private func ssrfBlockReason(for url: URL) -> String? {
        return WebEngine.ssrfBlockReasonPure(for: url)
    }

    /// Pure (nonisolated) form of `ssrfBlockReason` — uses only `SafetyGuard` +
    /// `DNSResolver` (both nonisolated), so it can run off-main inside the
    /// download redirect guard's `@Sendable` closure. Same fail-closed rules.
    nonisolated static func ssrfBlockReasonPure(for url: URL) -> String? {
        guard SafetyGuard.isSchemeAllowed(url) else { return "scheme \(url.scheme ?? "(none)")" }
        guard let host = url.host, !host.isEmpty else { return "no host" }
        if SafetyGuard.isTestLoopback(host: host, port: url.port) { return nil }
        if SafetyGuard.isLiteralHostBlocked(host) { return host }
        let addrs = DNSResolver.resolve(host)
        if addrs.isEmpty {
            // FAIL CLOSED: an unresolvable, non-literal host is not provably public.
            return "\(host) (unresolvable)"
        }
        // Require EVERY resolved address to be public.
        for ip in addrs where SafetyGuard.isBlockedIP(ip) {
            return "\(host) -> \(ip)"
        }
        return nil
    }

    /// Validate a URL's scheme + resolved IP BEFORE navigation. Throws on any
    /// blocked scheme/host.
    private func guardURL(_ url: URL) throws {
        guard SafetyGuard.isSchemeAllowed(url) else {
            throw WebEngineError.blockedScheme(url.scheme ?? "(none)")
        }
        guard let host = url.host, !host.isEmpty else {
            throw WebEngineError.invalidURL(url.absoluteString)
        }
        if let reason = ssrfBlockReason(for: url) {
            throw WebEngineError.blockedHost(reason)
        }
    }

    /// A synchronous policy closure used inside `decidePolicyFor` (and the
    /// response check) so redirects / responses to internal IPs are blocked
    /// mid-navigation. Returns true if allowed (fail-closed via `ssrfBlockReason`).
    private func redirectAllowed(_ url: URL) -> Bool {
        return ssrfBlockReason(for: url) == nil
    }

    // MARK: Load + settle

    /// Navigate `webView` to `url`, wait for didFinish, then poll readyState and
    /// apply a bounded settle. Enforces SSRF on the initial request + redirects.
    /// Navigate + settle; returns the real main-frame HTTP status (0 if unknown).
    @discardableResult
    private func loadAndSettle(_ webView: WKWebView, url: URL) async throws -> Int {
        let bridge = NavigationBridge()
        bridge.policyCheck = { [weak self] u in self?.redirectAllowed(u) ?? false }
        bridge.responseHostCheck = { [weak self] u in self?.redirectAllowed(u) ?? false }
        bridge.maxBytes = config.webMaxBytes
        webView.navigationDelegate = bridge
        try await bridge.wait {
            webView.load(URLRequest(url: url))
        }
        // Poll readyState == complete (bounded). Check cancellation explicitly so
        // a renderer-pool timeout propagates out (the pool's `defer` then releases
        // the permit instead of hanging); a transient JS-eval error is tolerated,
        // but the `Task.sleep` uses plain `try` so cancellation isn't swallowed.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            try Task.checkCancellation()
            let state = (try? await webView.evaluateJavaScript(WebJS.readyStateScript)) as? String
            if state == "complete" { break }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        // Bounded settle. Plain `try` so cancellation surfaces.
        let settleNs = UInt64(max(0, config.webSettleMs)) * 1_000_000
        if settleNs > 0 { try await Task.sleep(nanoseconds: settleNs) }
        return bridge.httpStatus
    }

    // MARK: search

    func search(_ q: SearchQuery) async throws -> [SearchResult] {
        let key = WebCache.key(method: "GET", url: "search:\(q.query)", variant: "n=\(q.maxResults)")
        // Capture sendable copies for the closure.
        let router = self.router
        let query = q
        let data = try await cache.value(forKey: key, ttl: 300) {
            // 1) Keyless lite scrape (+ any configured keyed provider) first.
            var results: [SearchResult] = []
            do {
                results = try await router.search(query)
            } catch {
                Logger.shared.error("web_search: router failed: \(error)")
            }
            // 2) Browse-the-SERP fallback: when the scrape yields nothing
            // (blocked / empty / rate-limited), render a real SERP in a WKWebView
            // and extract results from the rendered DOM. WKWebView loads like a
            // real browser, bypassing the scrape block. Still goes through the
            // SSRF guard + pinning proxy. Don't cache a 0-result page.
            if results.isEmpty {
                Logger.shared.info("web_search: scrape empty for \"\(query.query)\" — browsing SERP fallback")
                results = (try? await self.browseSERP(query)) ?? []
                if results.isEmpty {
                    Logger.shared.error("web_search: SERP fallback also empty for \"\(query.query)\"")
                    throw WebEngineError.searchFailed("no results (scrape + SERP fallback both empty)")
                }
                Logger.shared.info("web_search: SERP fallback returned \(results.count) results")
            }
            return (try? JSONEncoder().encode(results)) ?? Data("[]".utf8)
        }
        return (try? JSONDecoder().decode([SearchResult].self, from: data)) ?? []
    }

    /// Browse-the-SERP fallback. Renders a real search-results page in an
    /// offscreen WKWebView (through the SSRF guard + PR11 pinning proxy) and
    /// extracts result links/titles/snippets from the rendered DOM via injected
    /// JS. Tries DuckDuckGo's full (JS) site first, then Bing as a backstop.
    private func browseSERP(_ q: SearchQuery) async throws -> [SearchResult] {
        let encoded = q.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q.query
        // Engines to try in order. Each renders client-side, so a plain scrape
        // can't read them — but a real WKWebView can.
        let serps = [
            "https://duckduckgo.com/?q=\(encoded)&ia=web",
            "https://www.bing.com/search?q=\(encoded)",
        ]
        for serp in serps {
            guard let url = URL(string: serp) else { continue }
            do {
                try guardURL(url)
            } catch {
                Logger.shared.error("web_search SERP guard blocked \(serp): \(error)")
                continue
            }
            do {
                let results = try await pool.withRenderer(readMode: false) { webView in
                    try await self.loadAndSettle(webView, url: url)
                    // Give a client-rendered SERP a moment to paint its results.
                    try await Task.sleep(nanoseconds: 700_000_000)
                    let raw = (try? await webView.evaluateJavaScript(WebJS.serpExtractScript) as? String) ?? "[]"
                    return DDGParser.parseSERPJSON(raw, maxResults: q.maxResults)
                }
                if !results.isEmpty { return results }
            } catch {
                Logger.shared.error("web_search SERP render failed for \(serp): \(error)")
                continue
            }
        }
        return []
    }

    // MARK: image search

    /// Search the web for IMAGES. Reuses the same two-tier pattern as
    /// `web_search`: first a keyless scrape of a reliable source (DuckDuckGo's
    /// `vqd`-gated `i.js` JSON), then — if that's empty/blocked — render an
    /// image-results page (Bing Images) in the offscreen, SSRF-gated WKWebView
    /// and extract `<img>` sources via injected JS. Results are cached 5 min.
    func imageSearch(_ q: SearchQuery) async throws -> [ImageResult] {
        let key = WebCache.key(method: "GET", url: "image:\(q.query)", variant: "n=\(q.maxResults)")
        let query = q
        let data = try await cache.value(forKey: key, ttl: 300) {
            // 1) Keyless DuckDuckGo image API (vqd → i.js JSON). A plain ephemeral
            //    session like the web_search keyless scrape (DDG 202-blocks the
            //    localhost proxy, so we go direct over public HTTPS — low SSRF risk).
            var results = (try? await self.ddgImageSearch(query)) ?? []
            // 2) Render-the-SERP fallback (SSRF-gated, like browseSERP).
            if results.isEmpty {
                Logger.shared.info("image_search: DDG scrape empty for \"\(query.query)\" — browsing image SERP fallback")
                results = (try? await self.browseImageSERP(query)) ?? []
                if results.isEmpty {
                    Logger.shared.error("image_search: SERP fallback also empty for \"\(query.query)\"")
                    throw WebEngineError.searchFailed("no image results (scrape + SERP fallback both empty)")
                }
                Logger.shared.info("image_search: SERP fallback returned \(results.count) images")
            }
            return (try? JSONEncoder().encode(results)) ?? Data("[]".utf8)
        }
        return (try? JSONDecoder().decode([ImageResult].self, from: data)) ?? []
    }

    /// Body cap for the DDG image-search HTTP responses (HTML token page + i.js).
    private static let imageSearchMaxBytes = 4 * 1024 * 1024

    /// DuckDuckGo image search: GET the results page to obtain the per-session
    /// `vqd` token, then GET `i.js` (its JSON image endpoint) with that token.
    /// Parsing is pure (`ImageSearchParser`). Plain ephemeral session + desktop UA.
    private func ddgImageSearch(_ q: SearchQuery) async throws -> [ImageResult] {
        let trimmed = q.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        let session = URLSession(configuration: .ephemeral)

        func get(_ urlString: String, referer: String?) async throws -> (Data, Int) {
            guard let url = URL(string: urlString) else { throw WebEngineError.invalidURL(urlString) }
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/json,*/*;q=0.8", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            if let r = referer { req.setValue(r, forHTTPHeaderField: "Referer") }
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let len = (response as? HTTPURLResponse)?.expectedContentLength, len > 0,
               SizeGuard.rejectByContentLength(Int(len), max: Self.imageSearchMaxBytes) {
                throw WebEngineError.tooLarge(Int(len))
            }
            if SizeGuard.exceeds(received: data.count, max: Self.imageSearchMaxBytes) {
                throw WebEngineError.tooLarge(data.count)
            }
            return (data, status)
        }

        // Step 1: the token page.
        let tokenURL = "https://duckduckgo.com/?q=\(encoded)&iax=images&ia=images"
        let (htmlData, htmlStatus) = try await get(tokenURL, referer: nil)
        guard htmlStatus == 200, let html = String(data: htmlData, encoding: .utf8),
              let vqd = ImageSearchParser.parseVQD(html) else {
            return []
        }
        // Step 2: the i.js JSON endpoint (US English). `p=-1` = safe search OFF
        // (unfiltered results); `p=1` would be strict SFW, `p=-2` moderate.
        let apiURL = "https://duckduckgo.com/i.js?l=us-en&o=json&q=\(encoded)&vqd=\(vqd)&f=,,,,,&p=-1"
        let (jsonData, jsonStatus) = try await get(apiURL, referer: tokenURL)
        guard jsonStatus == 200, let json = String(data: jsonData, encoding: .utf8) else { return [] }
        return ImageSearchParser.parseDDGImageJSON(json, maxResults: q.maxResults)
    }

    /// Render-the-SERP image fallback: load Bing Images (then DDG images) in the
    /// offscreen WKWebView (through the SSRF guard + pinning proxy), let it paint,
    /// and extract `<img>` sources via `WebJS.imageExtractScript`.
    private func browseImageSERP(_ q: SearchQuery) async throws -> [ImageResult] {
        let encoded = q.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q.query
        // Safe search OFF on both engines: Bing `adlt=off`, DuckDuckGo `kp=-1`.
        let serps = [
            "https://www.bing.com/images/search?q=\(encoded)&adlt=off",
            "https://duckduckgo.com/?q=\(encoded)&iax=images&ia=images&kp=-1",
        ]
        for serp in serps {
            guard let url = URL(string: serp) else { continue }
            do { try guardURL(url) } catch {
                Logger.shared.error("image_search SERP guard blocked \(serp): \(error)")
                continue
            }
            do {
                let results = try await pool.withRenderer(readMode: false) { webView in
                    try await self.loadAndSettle(webView, url: url)
                    // Let a client-rendered image grid paint its thumbnails.
                    try await Task.sleep(nanoseconds: 900_000_000)
                    let raw = (try? await webView.evaluateJavaScript(WebJS.imageExtractScript) as? String) ?? "[]"
                    return ImageSearchParser.parseImageSERPJSON(raw, maxResults: q.maxResults)
                }
                if !results.isEmpty { return results }
            } catch {
                Logger.shared.error("image_search SERP render failed for \(serp): \(error)")
                continue
            }
        }
        return []
    }

    // MARK: download

    /// Default directory downloads land in. The user's ~/Downloads.
    private static var defaultDownloadsDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Downloads")
    }

    /// Download an https file to disk (default ~/Downloads). SSRF-gated on the
    /// initial URL AND every redirect hop (`DownloadRedirectGuard`), size-capped
    /// (`config.webMaxBytes`), and writes atomically. The CONFIRM gate + dry-run
    /// are enforced by the TOOL before this is reached — this method does the I/O.
    /// Returns the saved `DownloadResult`.
    func downloadFile(url: URL, filename: String?) async throws -> DownloadResult {
        try guardURL(url)   // scheme + initial-host SSRF check (fail-closed)

        // Re-validate the host on every redirect: a 30x to an internal IP is
        // blocked. Uses the nonisolated pure check (the delegate runs off-main).
        let guardDelegate = DownloadRedirectGuard(allow: { u in
            WebEngine.ssrfBlockReasonPure(for: u) == nil
        })
        let session = URLSession(configuration: .ephemeral, delegate: guardDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("PopDraft/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw WebEngineError.searchFailed("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw WebEngineError.searchFailed("HTTP \(http.statusCode)")
        }
        // Size cap (declared + actual).
        let declaredLen = http.expectedContentLength
        if declaredLen > 0, SizeGuard.rejectByContentLength(Int(declaredLen), max: config.webMaxBytes) {
            throw WebEngineError.tooLarge(Int(declaredLen))
        }
        if SizeGuard.exceeds(received: data.count, max: config.webMaxBytes) {
            throw WebEngineError.tooLarge(data.count)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // The URL we actually ended on (after redirects) seeds the derived name.
        let finalURLString = http.url?.absoluteString ?? url.absoluteString
        let defaultExt = WebEngine.extensionForContentType(contentType)
        let name = DownloadPlanner.resolveFilename(requested: filename, url: finalURLString, defaultExt: defaultExt)

        let dir = WebEngine.defaultDownloadsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var dest = DownloadPlanner.destination(baseDir: dir, filename: name)
        dest = WebEngine.uniquePath(dest)   // never clobber an existing file
        try data.write(to: URL(fileURLWithPath: dest), options: .atomic)

        return DownloadResult(url: finalURLString, path: dest, bytes: data.count, contentType: contentType)
    }

    /// A short default file extension for a MIME type (only when the URL/filename
    /// has none). Best-effort; empty string means "leave the name as-is".
    nonisolated static func extensionForContentType(_ ct: String) -> String {
        switch ct.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        case "application/zip": return "zip"
        case "application/json": return "json"
        default: return ""
        }
    }

    /// If `path` exists, append " (n)" before the extension until it doesn't.
    nonisolated static func uniquePath(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        let ext = ns.pathExtension
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        var n = 1
        while n < 1000 {
            let candidateName = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidate = (dir as NSString).appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate) { return candidate }
            n += 1
        }
        return path
    }

    // MARK: open

    func open(_ url: URL) async throws -> OpenResult {
        try guardURL(url)
        return try await pool.withRenderer(readMode: false) { webView in
            let status = try await self.loadAndSettle(webView, url: url)
            let finalURL = webView.url?.absoluteString ?? url.absoluteString
            let title = (try? await webView.evaluateJavaScript("document.title") as? String) ?? ""
            let probeRaw = (try? await webView.evaluateJavaScript(WebJS.openProbeScript) as? String) ?? "{}"
            var preview = ""
            if let pdata = probeRaw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] {
                preview = String((obj["text"] as? String ?? "").prefix(500))
            }
            // Real HTTP status (0 → unknown, e.g. non-HTTP); fall back to 200 only
            // when WebKit gave us nothing.
            return OpenResult(finalURL: finalURL, status: status > 0 ? status : 200, title: title, preview: preview)
        }
    }

    // MARK: read

    /// Minimum char count for a read to be cached. A render that yields fewer
    /// chars is returned to the caller but NOT cached, so a transient bad render
    /// doesn't poison the 15-min cache. Plain `nonisolated` so the @Sendable
    /// cache predicate can read it.
    nonisolated static let minCacheableReadChars = 20

    func read(_ url: URL, maxChars: Int) async throws -> ReadResult {
        try guardURL(url)
        let cap = maxChars > 0 ? maxChars : config.webReadMaxChars
        let key = WebCache.key(method: "GET", url: url.absoluteString, variant: "read:\(cap)")
        let minChars = WebEngine.minCacheableReadChars   // capture for the @Sendable closure
        let data = try await cache.value(
            forKey: key,
            ttl: 900,
            shouldStore: { d in
                // Only cache a substantial result (decode + check charCount).
                guard let r = try? JSONDecoder().decode(ReadResult.self, from: d) else { return false }
                return r.charCount >= minChars
            },
            compute: { [self] in
                let result = try await self.performRead(url: url, maxChars: cap)
                return (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
            })
        if let decoded = try? JSONDecoder().decode(ReadResult.self, from: data) { return decoded }
        throw WebEngineError.noContent
    }

    private func performRead(url: URL, maxChars: Int) async throws -> ReadResult {
        return try await pool.withRenderer(readMode: true) { webView in
            let status = try await self.loadAndSettle(webView, url: url)
            let finalURL = webView.url?.absoluteString ?? url.absoluteString
            let script = WebJS.extractScript(dropImages: true)
            let raw = (try? await webView.evaluateJavaScript(script) as? String) ?? "{}"
            guard let jdata = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jdata) as? [String: Any] else {
                throw WebEngineError.noContent
            }
            if let err = obj["error"] as? String, !err.isEmpty, obj["markdown"] == nil {
                throw WebEngineError.navigationFailed("extract: \(err)")
            }
            let title = (obj["title"] as? String) ?? ""
            let byline = (obj["byline"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let siteName = (obj["siteName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var markdown = (obj["markdown"] as? String) ?? ""
            markdown = MarkdownSanitizer.collapseWhitespace(markdown)
            let (capped, truncated) = MarkdownSanitizer.truncate(markdown, maxChars: maxChars)
            return ReadResult(
                finalURL: finalURL, status: status > 0 ? status : 200, title: title,
                byline: byline, siteName: siteName,
                markdown: capped, charCount: capped.count, truncated: truncated)
        }
    }

    // MARK: screenshot

    func screenshot(_ url: URL, fullPage: Bool) async throws -> ShotResult {
        try guardURL(url)
        let hashName = WebCache.key(method: "GET", url: url.absoluteString, variant: "shot:\(fullPage)")
        let path = (shotsDir as NSString).appendingPathComponent("\(hashName).png")
        // Disk cache: if a fresh PNG exists, reuse it.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mod = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) < 900,
           let img = NSImage(contentsOfFile: path) {
            return ShotResult(finalURL: url.absoluteString, path: path, width: Int(img.size.width), height: Int(img.size.height), fullPage: fullPage)
        }

        return try await pool.withRenderer(readMode: false, frame: NSRect(x: 0, y: 0, width: 1280, height: 2000)) { webView in
            try await self.loadAndSettle(webView, url: url)
            let finalURL = webView.url?.absoluteString ?? url.absoluteString

            // Full-page height cap. Lowered from 20000 → 12000 to bound the
            // bitmap memory spike (1280 × 12000 × 4 bytes ≈ 61 MB).
            let maxFullPageHeight = 12000
            var targetHeight = 2000
            if fullPage {
                // Evaluate scrollHeight ONCE; it can come back as Int or Double.
                let raw = try? await webView.evaluateJavaScript(WebJS.scrollHeightScript)
                if let h = raw as? Int {
                    targetHeight = min(max(h, 400), maxFullPageHeight)
                } else if let hd = raw as? Double {
                    targetHeight = min(max(Int(hd), 400), maxFullPageHeight)
                } else if let hn = raw as? NSNumber {
                    targetHeight = min(max(hn.intValue, 400), maxFullPageHeight)
                } else {
                    // Could not read the scroll height — log and fall back to the
                    // default viewport height instead of silently guessing.
                    Logger.shared.log("screenshot: scrollHeight unreadable (got \(String(describing: raw))); falling back to \(targetHeight)px")
                }
                webView.frame = NSRect(x: 0, y: 0, width: 1280, height: targetHeight)
                // Let layout settle after resize.
                try await Task.sleep(nanoseconds: 250_000_000)
            }

            let png = try await self.snapshotPNG(webView, height: targetHeight, fullPage: fullPage)
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            let img = NSImage(data: png)
            let w = Int(img?.size.width ?? 1280)
            let h = Int(img?.size.height ?? CGFloat(targetHeight))
            return ShotResult(finalURL: finalURL, path: path, width: w, height: h, fullPage: fullPage)
        }
    }

    /// Take a WKSnapshot and encode it as PNG.
    private func snapshotPNG(_ webView: WKWebView, height: Int, fullPage: Bool) async throws -> Data {
        let snapConfig = WKSnapshotConfiguration()
        if fullPage {
            snapConfig.rect = NSRect(x: 0, y: 0, width: 1280, height: height)
        }
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            webView.takeSnapshot(with: snapConfig) { img, err in
                if let img = img { cont.resume(returning: img) }
                else { cont.resume(throwing: err ?? WebEngineError.noContent) }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw WebEngineError.noContent
        }
        return png
    }

    // MARK: extract

    func extract(_ url: URL, instruction: String) async throws -> ExtractResult {
        let read = try await read(url, maxChars: config.webReadMaxChars)
        let chunks = ChunkRanker.chunk(read.markdown)
        let ranked = ChunkRanker.rank(chunks: chunks, instruction: instruction, limit: 5)
        return ExtractResult(finalURL: read.finalURL, title: read.title, instruction: instruction, chunks: ranked)
    }

    // MARK: - Interactive browsing session (Playwright-style)

    /// Max clickable/typeable elements surfaced in a `BrowserState`.
    private static let browserElementCap = 25

    /// Read the DOM-accessibility summary (title, short text, clickable elements)
    /// off the current session page and assemble a `BrowserState`.
    private func browserSnapshotState(action: String) async throws -> BrowserState {
        let session = browserSession
        let finalURL = session.currentURL()
        let raw = try await session.evaluate(BrowserJS.summaryScript(cap: Self.browserElementCap))
        var title = ""
        var summary = ""
        var elements: [BrowserElement] = []
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = (obj["title"] as? String) ?? ""
            summary = (obj["summary"] as? String) ?? ""
            if let arr = obj["elements"] as? [[String: Any]] {
                for e in arr {
                    let role = (e["role"] as? String) ?? "button"
                    let label = (e["label"] as? String) ?? ""
                    let sel = (e["selector"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if label.isEmpty { continue }
                    elements.append(BrowserElement(role: role, label: label, selector: sel))
                }
            }
        }
        if title.isEmpty { title = await session.currentTitle() }
        return BrowserState(finalURL: finalURL, title: title, action: action,
                            summary: summary, elements: elements)
    }

    /// `browser_open` — navigate the session to `url`, wait for load+settle,
    /// return a `BrowserState`. SSRF-gated up-front + on every redirect.
    func browserOpen(_ url: URL) async throws -> BrowserState {
        try guardURL(url)
        _ = try await browserSession.load(url)
        return try await browserSnapshotState(action: "opened \(browserSession.currentURL())")
    }

    /// `browser_click` — click an element (by visible text or CSS selector) on the
    /// current page. Throws `noContent` with a helpful message when nothing matches
    /// (the tool layer turns this into a non-fatal error result).
    func browserClick(target: String) async throws -> BrowserState {
        let argLiteral = BrowserTargets.argLiteral(target: target)
        let raw = try await browserSession.click(argLiteral: argLiteral)
        let (ok, info, errMsg) = Self.parseActionResult(raw)
        if !ok {
            let reason = (errMsg == "not-found")
                ? "No clickable element matched \"\(target)\". Try a different visible text or a CSS selector; the page's clickable elements are listed in the previous result."
                : "Click failed: \(errMsg)"
            throw WebEngineError.navigationFailed(reason)
        }
        let what = info["clicked"] ?? target
        let role = info["role"].map { "\($0) " } ?? ""
        return try await browserSnapshotState(action: "clicked \(role)\"\(what)\"")
    }

    /// `browser_type` — focus an input (by label/placeholder/name/selector), type
    /// `text`, optionally submit. Throws when no input matches.
    func browserType(target: String, text: String, submit: Bool) async throws -> BrowserState {
        let argLiteral = BrowserTargets.argLiteral(target: target, text: text)
        let raw = try await browserSession.type(argLiteral: argLiteral, submit: submit)
        let (ok, info, errMsg) = Self.parseActionResult(raw)
        if !ok {
            let reason = (errMsg == "no-input")
                ? "No input field matched \"\(target)\". Try the field's placeholder/label/name or a CSS selector."
                : "Type failed: \(errMsg)"
            throw WebEngineError.navigationFailed(reason)
        }
        let into = info["typedInto"] ?? target
        let submitted = (info["submitted"] == "true" || info["submitted"] == "1")
        let action = submitted
            ? "typed into \"\(into)\" and submitted"
            : "typed into \"\(into)\""
        return try await browserSnapshotState(action: action)
    }

    /// `browser_read` — Readability-extract the CURRENT session page to Markdown.
    /// Reuses the same extract script as `web_read` (no re-navigation).
    func browserRead(maxChars: Int) async throws -> ReadResult {
        let session = browserSession
        guard session.hasPage else { throw WebEngineError.navigationFailed("no page open — call browser_open first") }
        let cap = maxChars > 0 ? maxChars : config.webReadMaxChars
        let finalURL = session.currentURL()
        let script = WebJS.extractScript(dropImages: true)
        let raw = try await session.evaluate(script)
        guard let jdata = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jdata) as? [String: Any] else {
            throw WebEngineError.noContent
        }
        if let err = obj["error"] as? String, !err.isEmpty, obj["markdown"] == nil {
            throw WebEngineError.navigationFailed("extract: \(err)")
        }
        let title = (obj["title"] as? String) ?? ""
        let byline = (obj["byline"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let siteName = (obj["siteName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var markdown = (obj["markdown"] as? String) ?? ""
        markdown = MarkdownSanitizer.collapseWhitespace(markdown)
        let (capped, truncated) = MarkdownSanitizer.truncate(markdown, maxChars: cap)
        return ReadResult(
            finalURL: finalURL, status: 200, title: title,
            byline: byline, siteName: siteName,
            markdown: capped, charCount: capped.count, truncated: truncated)
    }

    /// `browser_screenshot` — snapshot the CURRENT session page to a PNG on disk.
    func browserScreenshot(fullPage: Bool) async throws -> ShotResult {
        let session = browserSession
        guard session.hasPage else { throw WebEngineError.navigationFailed("no page open — call browser_open first") }
        let finalURL = session.currentURL()
        let hashName = WebCache.key(method: "GET", url: "session:\(finalURL)", variant: "shot:\(fullPage)")
        let path = (shotsDir as NSString).appendingPathComponent("\(hashName).png")
        let (png, height) = try await session.snapshot(fullPage: fullPage, scrollHeightScript: WebJS.scrollHeightScript)
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        let img = NSImage(data: png)
        let w = Int(img?.size.width ?? 1280)
        let h = Int(img?.size.height ?? CGFloat(height))
        return ShotResult(finalURL: finalURL, path: path, width: w, height: h, fullPage: fullPage)
    }

    /// `browser_back` — history back, then return a fresh `BrowserState`.
    func browserBack() async throws -> BrowserState {
        let session = browserSession
        guard session.hasPage else { throw WebEngineError.navigationFailed("no page open — call browser_open first") }
        _ = try await session.back()
        return try await browserSnapshotState(action: "went back to \(session.currentURL())")
    }

    /// `browser_scroll` — scroll the CURRENT session page to trigger lazy-loaded
    /// (JS/AJAX-rendered) content — infinite-scroll grids, deferred images, etc. —
    /// wait for it to fetch + paint, then return a fresh `BrowserState`. Follow with
    /// `browser_read` / `browser_screenshot` to capture the now-populated DOM.
    /// `to`: "bottom" (default) or "top"; `pixels` overrides with a relative scroll;
    /// `steps` repeats the scroll+wait to page through progressive loaders (1–10).
    func browserScroll(to: String?, pixels: Int?, steps: Int) async throws -> BrowserState {
        let session = browserSession
        guard session.hasPage else { throw WebEngineError.navigationFailed("no page open — call browser_open first") }
        let n = min(max(steps, 1), 10)
        // Give lazy content time to fetch + render after each scroll (≥700ms).
        let waitNs = UInt64(max(config.webSettleMs, 700)) * 1_000_000
        let js: String
        let label: String
        if let px = pixels {
            js = "window.scrollBy(0, \(px));"
            label = "scrolled \(px)px"
        } else if to?.lowercased() == "top" {
            js = "window.scrollTo(0, 0);"
            label = "scrolled to top"
        } else {
            js = "window.scrollTo(0, document.body.scrollHeight);"
            label = "scrolled to bottom"
        }
        for _ in 0..<n { try await session.scrollAndWait(js, waitNs: waitNs) }
        let action = n > 1 ? "\(label) (\(n)×)" : label
        return try await browserSnapshotState(action: action)
    }

    /// `browser_evaluate` — run arbitrary JavaScript in the CURRENT session page and
    /// return its (string-coerced, char-capped) result. Lets the model grab the
    /// fully-rendered DOM (`document.documentElement.innerHTML`) or a computed value
    /// after JS has run. Runs in the page's content world (no native access).
    func browserEvaluate(script: String, maxChars: Int) async throws -> String {
        let session = browserSession
        guard session.hasPage else { throw WebEngineError.navigationFailed("no page open — call browser_open first") }
        let raw = try await session.evaluateAny(script)
        let cap = maxChars > 0 ? maxChars : 8000
        guard raw.count > cap else { return raw }
        let idx = raw.index(raw.startIndex, offsetBy: cap)
        return String(raw[..<idx]) + "\n…(truncated to \(cap) chars)"
    }

    /// Decode a `{ok, ...}` JSON result from a bundled action script into
    /// (ok, stringified-fields, error). All values are flattened to strings so the
    /// caller can read them uniformly. `nonisolated` + pure (no engine state).
    nonisolated private static func parseActionResult(_ raw: String) -> (ok: Bool, info: [String: String], err: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, [:], "no result")
        }
        let ok = (obj["ok"] as? Bool) ?? ((obj["ok"] as? NSNumber)?.boolValue ?? false)
        var info: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { info[k] = s }
            else if let b = v as? Bool { info[k] = b ? "true" : "false" }
            else if let n = v as? NSNumber { info[k] = n.stringValue }
        }
        let err = (obj["error"] as? String) ?? ""
        return (ok, info, err)
    }

    // MARK: Tool schemas (re-exported for PR7)

    static let webSearchToolSchema = WebToolSchemas.webSearch
    static let webOpenToolSchema = WebToolSchemas.webOpen
    static let webReadToolSchema = WebToolSchemas.webRead
    static let webScreenshotToolSchema = WebToolSchemas.webScreenshot
    static let webExtractToolSchema = WebToolSchemas.webExtract
    static let imageSearchToolSchema = WebToolSchemas.imageSearch
    static let downloadFileToolSchema = WebToolSchemas.downloadFile
    static let browserOpenToolSchema = WebToolSchemas.browserOpen
    static let browserClickToolSchema = WebToolSchemas.browserClick
    static let browserTypeToolSchema = WebToolSchemas.browserType
    static let browserReadToolSchema = WebToolSchemas.browserRead
    static let browserScreenshotToolSchema = WebToolSchemas.browserScreenshot
    static let browserBackToolSchema = WebToolSchemas.browserBack
    static let browserScrollToolSchema = WebToolSchemas.browserScroll
    static let browserEvaluateToolSchema = WebToolSchemas.browserEvaluate
}

// =====================================================================
// MARK: - PR7: Agent tools (WebEngine-backed + text) + PopDraftAgent
//
// Concrete `AgentTool`s. The web tools wrap `WebEngine.shared` (PR6) and
// return compact JSON/text the model can read; the text tools are local
// transforms that need no network. `PopDraftAgent` builds the registry and
// runs `AgentLoop` using `LLMClient.chatCompletion` as the injected model.
// =====================================================================

/// Encode a Codable result as compact JSON for a tool's string output. On
/// failure, falls back to a short description so the tool never returns nothing.
/// (promoted from `private` to `internal` so the text tools, now in Agent.swift
///  of the same target, can share this helper)
func toolJSON<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "\(value)"
}

/// Parse a `WebToolSchemas` constant into a `ToolSpec`, degrading to a minimal
/// spec (named, no params) instead of crashing if the JSON is ever broken. The
/// constants are valid today (a test asserts it), so this is purely defensive.
private func webToolSpec(_ json: String, fallbackName: String, fallbackDescription: String) -> ToolSpec {
    return ToolSpec.fromOpenAIJSON(json)
        ?? ToolSpec(name: fallbackName, description: fallbackDescription)
}

/// `web_search` — search the web, return [{title,url,snippet}].
struct WebSearchTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webSearch, fallbackName: "web_search", fallbackDescription: "Search the web.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let query = (d["query"] as? String) ?? ""
        guard !query.isEmpty else { return "Error: 'query' is required." }
        var maxResults = 8
        if let n = d["max_results"] as? Int { maxResults = n }
        else if let n = d["max_results"] as? NSNumber { maxResults = n.intValue }
        maxResults = min(10, max(1, maxResults))
        let results = try await WebEngine.shared.search(SearchQuery(query: query, maxResults: maxResults))
        if results.isEmpty { return "No results found for \"\(query)\"." }
        return toolJSON(results)
    }
}

/// Shared helper to validate + build a URL from a tool argument.
private func toolURL(_ raw: Any?) throws -> URL {
    func err(_ msg: String) -> NSError {
        // Put the message in localizedDescription so the model reads a clean
        // "Error: ..." string (not "Error Domain=...").
        NSError(domain: "PopDraftTool", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
    guard let s = raw as? String, !s.isEmpty else {
        throw err("Error: 'url' is required.")
    }
    guard let url = URL(string: s), let scheme = url.scheme, scheme == "http" || scheme == "https" else {
        throw err("Error: 'url' must be an absolute http(s) URL.")
    }
    return url
}

/// `web_open` — load a URL, return {finalURL,status,title,preview}.
struct WebOpenTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webOpen, fallbackName: "web_open", fallbackDescription: "Open a URL.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let url = try toolURL(args.dictionary["url"])
        return toolJSON(try await WebEngine.shared.open(url))
    }
}

/// `web_read` — load a URL, return its main content as clean Markdown.
struct WebReadTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webRead, fallbackName: "web_read", fallbackDescription: "Read a URL as Markdown.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let url = try toolURL(d["url"])
        var maxChars = 0
        if let n = d["max_chars"] as? Int { maxChars = n }
        else if let n = d["max_chars"] as? NSNumber { maxChars = n.intValue }
        let r = try await WebEngine.shared.read(url, maxChars: maxChars)
        // The model mostly wants the Markdown + a little provenance; keep it compact.
        var header = "# \(r.title)\nURL: \(r.finalURL)"
        if let byline = r.byline, !byline.isEmpty { header += "\nBy: \(byline)" }
        if r.truncated { header += "\n(truncated to \(r.charCount) chars)" }
        return header + "\n\n" + r.markdown
    }
}

/// `web_screenshot` — render a URL, save a PNG, return {path,width,height}.
struct WebScreenshotTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webScreenshot, fallbackName: "web_screenshot", fallbackDescription: "Screenshot a URL.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let url = try toolURL(d["url"])
        let fullPage = (d["full_page"] as? Bool) ?? ((d["full_page"] as? NSNumber)?.boolValue ?? false)
        return toolJSON(try await WebEngine.shared.screenshot(url, fullPage: fullPage))
    }
}

/// `web_extract` — read a URL and return the chunks most relevant to an instruction.
struct WebExtractTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webExtract, fallbackName: "web_extract", fallbackDescription: "Extract relevant chunks from a URL.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let url = try toolURL(d["url"])
        let instruction = (d["instruction"] as? String) ?? ""
        guard !instruction.isEmpty else { return "Error: 'instruction' is required." }
        let r = try await WebEngine.shared.extract(url, instruction: instruction)
        if r.chunks.isEmpty { return "No content on \(r.finalURL) matched: \(instruction)" }
        return toolJSON(r)
    }
}

/// `image_search` — search the web for IMAGES, return [{imageURL, thumbnailURL,
/// sourcePage, title}]. The agent is prompted to then present the top results as
/// inline Markdown images so the user actually sees them.
struct ImageSearchTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.imageSearch, fallbackName: "image_search", fallbackDescription: "Search the web for images.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let query = (d["query"] as? String) ?? ""
        guard !query.isEmpty else { return "Error: 'query' is required." }
        var count = 8
        if let n = d["count"] as? Int { count = n }
        else if let n = d["count"] as? NSNumber { count = n.intValue }
        count = min(12, max(1, count))
        let results = try await WebEngine.shared.imageSearch(SearchQuery(query: query, maxResults: count))
        if results.isEmpty { return "No images found for \"\(query)\"." }
        // Compact JSON the model reads; it then emits ![title](imageURL) for each.
        return toolJSON(results)
    }
}

/// `download_file` — download an https file to ~/Downloads. CONFIRM-gated through
/// the SAME `MacControlConfirmer` seam as run_shell (writing to disk is an
/// action). In headless/dry-run it records "would download" and writes nothing.
/// `enableWebSearch`-gated at registration; this struct gates the WRITE per call.
struct DownloadFileTool: AgentTool, @unchecked Sendable {
    // `@unchecked Sendable`: `confirmer` is a MainActor-isolated class touched only
    // via `await`; `settings` is a Sendable value. No mutable shared state.
    let confirmer: (any MacControlConfirmer)?
    let settings: AgentSettings

    var spec: ToolSpec { webToolSpec(WebToolSchemas.downloadFile, fallbackName: "download_file", fallbackDescription: "Download a file to disk (user must approve).") }

    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let url = try toolURL(d["url"])
        guard url.scheme?.lowercased() == "https" else {
            return "Error: 'url' must be an https URL to download."
        }
        let filename = (d["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // What the user will see on the confirm card + dry-run line.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let derivedName = DownloadPlanner.resolveFilename(requested: filename, url: url.absoluteString)
        let destPreview = ((home as NSString).appendingPathComponent("Downloads") as NSString)
            .appendingPathComponent(derivedName)
        let summary = "Download \(url.absoluteString)\n  → \(destPreview)"

        // (1) Dry-run / headless: never write; record "would download".
        if settings.macControlDryRun {
            Logger.shared.info("[download_file] DRY-RUN would download: \(url.absoluteString) → \(destPreview)")
            return "Dry-run: would download (awaiting confirm): \(summary)\n(Dry-run mode is on, so nothing was written.)"
        }

        // (2) Confirm-gate through the Mac-control seam. No confirmer → deny.
        guard let confirmer = confirmer else {
            return "Error: no confirmation UI is available, so this file was NOT downloaded."
        }
        let req = ConfirmationRequest(
            id: UUID().uuidString, kind: .download, command: summary,
            explanation: "Download this file to your Downloads folder.")
        let decision = await confirmer.requestConfirmation(req)
        switch decision {
        case .deny:
            return "The user declined the download. The file was NOT downloaded. Ask what they'd prefer or continue without it."
        case .approve, .edit:
            break   // Edit isn't offered for downloads; treat like approve.
        }

        // (3) Perform the SSRF-gated, size-capped download.
        do {
            let r = try await WebEngine.shared.downloadFile(url: url, filename: filename)
            Logger.shared.info("[download_file] saved \(r.bytes)B \(r.contentType) → \(r.path)")
            return "Downloaded \(r.bytes) bytes (\(r.contentType.isEmpty ? "unknown type" : r.contentType)) to:\n\(r.path)"
        } catch {
            return "Error: download failed — \(error.localizedDescription)"
        }
    }
}

// MARK: - Interactive browser tools (Playwright-style, session-backed)

/// Render a `BrowserState` into a compact, model-friendly string: a header with
/// the action + current page, a short page summary, and a numbered list of the
/// elements the agent can act on next (with a stable selector hint). Kept terse
/// so it doesn't blow up the context on every step.
private func formatBrowserState(_ s: BrowserState) -> String {
    var out = "\(s.action)\nNow on: \(s.title.isEmpty ? "(untitled)" : s.title)\nURL: \(s.finalURL)"
    if !s.summary.isEmpty {
        let trimmed = String(s.summary.prefix(600))
        out += "\n\nPage summary:\n\(trimmed)"
    }
    if !s.elements.isEmpty {
        out += "\n\nClickable elements / inputs you can act on:"
        for (i, e) in s.elements.prefix(20).enumerated() {
            let sel = e.selector.map { "  [\($0)]" } ?? ""
            out += "\n\(i + 1). (\(e.role)) \(e.label)\(sel)"
        }
    }
    return out
}

/// `browser_open` — navigate the persistent session to a URL.
struct BrowserOpenTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.browserOpen, fallbackName: "browser_open", fallbackDescription: "Open a URL in the browsing session.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let url = try toolURL(args.dictionary["url"])
        return formatBrowserState(try await WebEngine.shared.browserOpen(url))
    }
}

/// `browser_click` — click by visible text or CSS selector.
struct BrowserClickTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.browserClick, fallbackName: "browser_click", fallbackDescription: "Click an element on the current page.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let target = (args.dictionary["target"] as? String) ?? ""
        guard !target.isEmpty else { return "Error: 'target' is required (visible text or CSS selector)." }
        return formatBrowserState(try await WebEngine.shared.browserClick(target: target))
    }
}

/// `browser_type` — focus an input, type text, optionally submit.
struct BrowserTypeTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.browserType, fallbackName: "browser_type", fallbackDescription: "Type text into an input on the current page.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let target = (d["target"] as? String) ?? ""
        let text = (d["text"] as? String) ?? ""
        guard !target.isEmpty else { return "Error: 'target' is required (input label/placeholder/name or CSS selector)." }
        guard !text.isEmpty else { return "Error: 'text' is required." }
        let submit = (d["submit"] as? Bool) ?? ((d["submit"] as? NSNumber)?.boolValue ?? false)
        return formatBrowserState(try await WebEngine.shared.browserType(target: target, text: text, submit: submit))
    }
}

/// `browser_read` — read the current session page as Markdown.
struct BrowserReadTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.browserRead, fallbackName: "browser_read", fallbackDescription: "Read the current page as Markdown.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        var maxChars = 0
        if let n = d["max_chars"] as? Int { maxChars = n }
        else if let n = d["max_chars"] as? NSNumber { maxChars = n.intValue }
        let r = try await WebEngine.shared.browserRead(maxChars: maxChars)
        var header = "# \(r.title)\nURL: \(r.finalURL)"
        if let byline = r.byline, !byline.isEmpty { header += "\nBy: \(byline)" }
        if r.truncated { header += "\n(truncated to \(r.charCount) chars)" }
        return header + "\n\n" + r.markdown
    }
}

/// `browser_screenshot` — screenshot the current session page.
struct BrowserScreenshotTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.browserScreenshot, fallbackName: "browser_screenshot", fallbackDescription: "Screenshot the current page.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let fullPage = (d["full_page"] as? Bool) ?? ((d["full_page"] as? NSNumber)?.boolValue ?? false)
        return toolJSON(try await WebEngine.shared.browserScreenshot(fullPage: fullPage))
    }
}

/// `browser_back` — history back in the session.
struct BrowserBackTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.browserBack, fallbackName: "browser_back", fallbackDescription: "Go back in the browsing session.") }
    func invoke(_ args: JSONObject) async throws -> String {
        return formatBrowserState(try await WebEngine.shared.browserBack())
    }
}

/// `browser_scroll` — scroll the current page to trigger lazy-loaded content.
struct BrowserScrollTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.browserScroll, fallbackName: "browser_scroll", fallbackDescription: "Scroll the current page to load dynamic content.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let to = d["to"] as? String
        var pixels: Int? = nil
        if let n = d["pixels"] as? Int { pixels = n }
        else if let n = d["pixels"] as? NSNumber { pixels = n.intValue }
        var steps = 1
        if let n = d["steps"] as? Int { steps = n }
        else if let n = d["steps"] as? NSNumber { steps = n.intValue }
        return formatBrowserState(try await WebEngine.shared.browserScroll(to: to, pixels: pixels, steps: steps))
    }
}

/// `browser_evaluate` — run JS in the current page and return the result.
struct BrowserEvaluateTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.browserEvaluate, fallbackName: "browser_evaluate", fallbackDescription: "Run JavaScript on the current page and return its result.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let script = (d["script"] as? String) ?? ""
        guard !script.isEmpty else { return "Error: 'script' is required (JavaScript to run on the current page)." }
        var maxChars = 0
        if let n = d["max_chars"] as? Int { maxChars = n }
        else if let n = d["max_chars"] as? NSNumber { maxChars = n.intValue }
        do {
            return try await WebEngine.shared.browserEvaluate(script: script, maxChars: maxChars)
        } catch {
            // A JS syntax/runtime error is a normal outcome — surface it as text
            // rather than a tool crash so the model can adjust its script.
            return "Error evaluating JavaScript: \(error.localizedDescription)"
        }
    }
}

// MARK: - Web tool self-registration

/// Self-registration of the web + interactive-browser tools. Gated on the same
/// `enableWebSearch` master switch as before; when off, none are registered.
enum WebTools {
    static func register() {
        AgentToolCatalog.register(BuiltinToolGroup(
            gate: { $0.agentSettings.enableWebSearch },
            make: { config, confirmer in
                // download_file writes to disk → confirm-gated via the same seam
                // as run_shell (the type-erased Mac-control confirmer).
                let c = confirmer as? (any MacControlConfirmer)
                return [
                    // web_* (single-shot fetch/search)
                    WebSearchTool(), WebOpenTool(), WebReadTool(),
                    WebScreenshotTool(), WebExtractTool(),
                    // image_search (return image URLs to render inline)
                    ImageSearchTool(),
                    // download_file (confirm-gated write to ~/Downloads)
                    DownloadFileTool(confirmer: c, settings: config.agentSettings),
                    // browser_* (Playwright-style persistent session)
                    BrowserOpenTool(), BrowserClickTool(), BrowserTypeTool(),
                    BrowserReadTool(), BrowserScreenshotTool(), BrowserBackTool(),
                    BrowserScrollTool(), BrowserEvaluateTool(),
                ]
            }))
    }
}
