#!/usr/bin/env python3
"""
Tiny local fixture HTTP server for PopDraft WebEngine GUI tests.

Python stdlib only (like scripts/llm-tts-server.py). Binds to 127.0.0.1 on an
ephemeral port and prints "PORT <n>" on stdout so the test harness can read it,
then serves a fixed set of routes:

  /article        a clean article page (Readability target)
  /portal         a landing page with a link to /article + a search box (browser nav)
  /searchresults  echoes ?q= into its body (browser_type + submit target)
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

# A landing page with a clickable link to /article (browser_click target) and a
# search box that GETs /searchresults?q=... (browser_type + submit target).
PORTAL_HTML = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Fixture Portal</title></head>
<body>
  <header><nav>Home About Contact</nav></header>
  <main>
    <h1>Fixture Portal Home</h1>
    <form action="/searchresults" method="get">
      <input type="text" name="q" placeholder="Search the fixture site" aria-label="Search">
      <button type="submit">Go</button>
    </form>
    <p>Browse our content below.</p>
    <ul>
      <li><a href="/article">Read the Full Article</a></li>
      <li><a href="/adheavy">An Ad Heavy Story</a></li>
    </ul>
  </main>
</body>
</html>"""


# An image-results-style page: several <img> elements (some with data-src lazy
# loading, some with a real src) pointing at https URLs, each wrapped in a source
# link. Exercises WebJS.imageExtractScript + ImageSearchParser.parseImageSERPJSON.
# The <img> URLs are https (so the parser keeps them) but never fetched by the
# test — only their src/data-src attributes are read out of the rendered DOM.
IMAGE_PAGE_HTML = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Image Results</title></head>
<body>
  <h1>Image Results</h1>
  <a href="https://commons.example.org/eiffel"><img
      data-src="https://images.example.com/eiffel_full.jpg"
      src="https://images.example.com/eiffel_thumb.jpg"
      width="300" height="200" alt="Eiffel Tower at dusk"></a>
  <a href="https://commons.example.org/tower2"><img
      src="https://images.example.com/tower2.png"
      width="320" height="240" title="Another tower view"></a>
  <!-- a tiny tracking pixel that must be filtered out (too small) -->
  <img src="https://images.example.com/pixel.gif" width="1" height="1" alt="">
  <!-- a non-https image that must be dropped -->
  <img src="http://insecure.example.com/nope.jpg" width="300" height="200" alt="insecure">
</body>
</html>"""


def search_results_html(query):
    """Server-side 'search results' page; echoes the query into its body so a
    typed query + submit lands on content that contains the query (proving the
    type+submit navigated and ran a search)."""
    safe = (query or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Search Results</title></head>
<body>
  <main>
    <h1>Search Results</h1>
    <p>You searched for: <strong>%s</strong>. Here is the genuine result body text
       with enough words and commas, like this, that the extractor treats it as
       the main article content for this results page.</p>
    <ul>
      <li><a href="/article">First Result: The Full Article</a></li>
    </ul>
  </main>
</body>
</html>""" % safe


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
            parts = self.path.split("?", 1)
            path = parts[0]
            query = parts[1] if len(parts) > 1 else ""
            if path == "/article":
                self._send(200, ARTICLE_HTML)
            elif path == "/portal":
                self._send(200, PORTAL_HTML)
            elif path == "/searchresults":
                from urllib.parse import parse_qs
                q = (parse_qs(query).get("q", [""]) or [""])[0]
                self._send(200, search_results_html(q))
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
            elif path == "/imagepage":
                self._send(200, IMAGE_PAGE_HTML)
            elif path == "/afile.png":
                # A tiny binary "file" with an image content-type — exercises
                # download_file (SSRF-gated fetch + write + content-type capture).
                # Minimal 1x1 PNG.
                png = bytes([
                    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
                    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
                    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
                    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                    0x42, 0x60, 0x82,
                ])
                self._send(200, png, ctype="image/png")
            elif path == "/file-redirect-internal":
                # A download whose 302 points at a loopback IP — the download
                # redirect SSRF guard must block the hop.
                self._send(302, "", extra={"Location": "http://127.0.0.1:1/secret.bin"})
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
