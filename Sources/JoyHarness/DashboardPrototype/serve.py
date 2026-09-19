"""THROWAWAY: local UI comparison only; never launches the hardware runtime."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import mimetypes

ROOT = Path(__file__).resolve().parent
RESOURCES = ROOT.parent / "Resources"
FILES = {
    "/dashboard": ROOT / "index.html",
    "/": ROOT / "index.html",
    "/prototype.css": ROOT / "prototype.css",
    "/prototype.js": ROOT / "prototype.js",
    "/assets/remote.png": RESOURCES / "controller-dashboard-xiaomi-remote.png",
    "/assets/dualsense.png": RESOURCES / "controller-dashboard-dualsense-transparent.png",
    "/assets/xbox.png": RESOURCES / "controller-dashboard.png",
    "/assets/joyconLeft.png": RESOURCES / "controller-dashboard-joycon-left.png",
    "/assets/joyconRight.png": RESOURCES / "controller-dashboard-joycon-right.png",
}


class PreviewHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = FILES.get(urlsplit(self.path).path)
        if path is None:
            self.send_error(404)
            return
        content = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(path)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(content)


if __name__ == "__main__":
    print("Dashboard 原型 → http://localhost:8769/dashboard?variant=B", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8769), PreviewHandler).serve_forever()
