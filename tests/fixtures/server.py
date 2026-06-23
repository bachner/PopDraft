#!/usr/bin/env python3
"""
Tiny local fixture HTTP server for PopDraft WebEngine GUI tests.

Python stdlib only (like scripts/llm-tts-server.py). Binds to 127.0.0.1 on an
ephemeral port and prints "PORT <n>" on stdout so the test harness can read it,
then serves a fixed set of routes:

  /article        a clean article page (Readability target)
  /jsrendered     a page whose body text is injected by JS after load
  /adheavy        an article wrapped in ad/tracker noise
  /redirect       302 -> /article
  /redirect-internal  302 -> http://127.0.0.1:1/  (SSRF: redirect to loopback)
  /slow           sleeps a few seconds before responding (timeout test)
  /missing        404
  /big            a response larger than a few MB (size-cap test)

Run:  python3 server.py            (ephemeral port)
      python3 server.py 8123       (fixed port)
"""

import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn


ARTICLE_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>The Title of the Article</title>
  <meta property="og:title" content="The Title of the Article">
  <meta name="author" content="Ada Lovelace">
  <meta property="og:site_name" content="Fixture News">
</head>
<body>
  <header><nav>Home About Contact</nav></header>
  <div class="sidebar">Subscribe to our newsletter! Ads ads ads.</div>
  <article class="post-content">
    <h1>The Title of the Article</h1>
    <p>This is the <strong>first paragraph</strong> of the article body. It has
       enough words and commas, like this, to be picked up as the main content
       by the Readability scoring heuristic in the engine.</p>
    <h2>A Subheading</h2>
    <p>Here is a second paragraph with a <a href="https://example.com/dest?utm_source=x&id=9">link to example</a>
       that should keep its id but drop the utm tracking parameter.</p>
    <ul>
      <li>First bullet point</li>
      <li>Second bullet point</li>
    </ul>
    <pre><code>let x = 42
print(x)</code></pre>
    <blockquote>A quoted sentence worth remembering.</blockquote>
    <p>A closing paragraph that wraps the article up nicely with more text so the
       content scorer is confident this is the real article body and not chrome.</p>
  </article>
  <footer>Copyright fixture. All rights reserved. More ads here.</footer>
</body>
</html>"""

JS_RENDERED_HTML = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>JS Rendered Page</title></head>
<body>
  <article id="root"><p>placeholder</p></article>
  <script>
    setTimeout(function() {
      var a = document.getElementById('root');
      a.innerHTML = '<h1>Dynamically Loaded Heading</h1>' +
        '<p>This sentence, with commas, was injected by JavaScript after the ' +
        'page finished its initial load, so only a real renderer will see it ' +
        'in the extracted Markdown content body here.</p>';
    }, 120);
  </script>
</body>
</html>"""

AD_HEAVY_HTML = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Ad Heavy Article</title></head>
<body>
  <div class="ad-banner"><img src="https://doubleclick.net/ad.gif"></div>
  <div class="promo">BUY NOW! Sponsored content. Cookie consent popup.</div>
  <script src="https://www.google-analytics.com/analytics.js"></script>
  <article class="entry-content">
    <h1>Ad Heavy Article</h1>
    <p>Despite all the advertising noise around it, this is the genuine article
       body text, with several commas, clauses, and enough length that the
       content extractor confidently selects it over the ad chrome.</p>
    <p>A second real paragraph of article content continues the story here with
       more words so the scoring heuristic is decisive about the main content.</p>
  </article>
  <aside class="sidebar-ads">Taboola recommends these stories you must read.</aside>
</body>
</html>"""


def make_handler():
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # quiet

        def _send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
            data = body.encode("utf-8") if isinstance(body, str) else body
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            if extra:
                for k, v in extra.items():
                    self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/article":
                self._send(200, ARTICLE_HTML)
            elif path == "/jsrendered":
                self._send(200, JS_RENDERED_HTML)
            elif path == "/adheavy":
                self._send(200, AD_HEAVY_HTML)
            elif path == "/redirect":
                self._send(302, "", extra={"Location": "/article"})
            elif path == "/redirect-internal":
                # SSRF: redirect to a loopback address that the engine must block.
                self._send(302, "", extra={"Location": "http://127.0.0.1:1/secret"})
            elif path == "/slow":
                time.sleep(30)
                self._send(200, "<html><body><p>too slow</p></body></html>")
            elif path == "/big":
                # ~12 MB body to exercise the size cap.
                chunk = "<p>" + ("x" * 1000) + "</p>\n"
                body = "<!DOCTYPE html><html><body>" + chunk * 12000 + "</body></html>"
                self._send(200, body)
            elif path == "/missing":
                self._send(404, "<html><body><h1>404 Not Found</h1></body></html>")
            else:
                self._send(404, "<html><body>unknown route</body></html>")

    return Handler


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler())
    actual = server.server_address[1]
    # Announce the bound port so the harness can read it.
    print("PORT %d" % actual, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
