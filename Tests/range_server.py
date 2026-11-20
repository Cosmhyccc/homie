"""Local file server for the downloader tests: honours Range, and fakes trouble by path prefix.
/fake.gguf normal · /flaky/... drops every 3rd piece halfway · /slow/... 0.3 s per piece · /plain/... ignores Range
/stats number of file requests so far.  Usage: python3 range_server.py <dir> <port>"""
import os, re, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root, port = sys.argv[1], int(sys.argv[2])
lock, count = threading.Lock(), [0]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/stats":
            body = str(count[0]).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        parts = self.path.strip("/").split("/")
        mode, name = (parts[0], parts[-1]) if len(parts) > 1 else ("", parts[0])
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        with lock: count[0] += 1; n = count[0]
        size = os.path.getsize(path)
        m = re.match(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        if mode == "slow": time.sleep(0.3)
        with open(path, "rb") as f:
            if m and mode != "plain":
                a, b = int(m.group(1)), min(int(m.group(2)), size - 1)
                f.seek(a); data = f.read(b - a + 1)
                self.send_response(206); self.send_header("Content-Range", f"bytes {a}-{b}/{size}")
            else:
                data = f.read(); self.send_response(200)
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        if mode == "flaky" and n % 3 == 0:
            self.wfile.write(data[: len(data) // 2]); self.wfile.flush(); self.close_connection = True
            self.connection.shutdown(2); return
        self.wfile.write(data)

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
