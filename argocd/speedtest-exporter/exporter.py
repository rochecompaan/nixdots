import os, time, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import speedtest
except Exception as e:
    raise SystemExit(f"speedtest module missing: {e}")

INTERVAL = int(os.getenv("INTERVAL_SECONDS", "3600"))
PORT = int(os.getenv("PORT", "8000"))
METRICS = {"text": "# speedtest metrics not yet collected\n"}
LOCK = threading.Lock()


def run_speedtest():
    while True:
        try:
            s = speedtest.Speedtest()
            s.get_best_server()
            dl = s.download()
            ul = s.upload()
            ping = s.results.ping
            ts = int(time.time())
            text = f"""# HELP speedtest_download_bits_per_second Download speed in bits per second
# TYPE speedtest_download_bits_per_second gauge
speedtest_download_bits_per_second {dl}
# HELP speedtest_upload_bits_per_second Upload speed in bits per second
# TYPE speedtest_upload_bits_per_second gauge
speedtest_upload_bits_per_second {ul}
# HELP speedtest_ping_ms Ping latency in milliseconds
# TYPE speedtest_ping_ms gauge
speedtest_ping_ms {ping}
# HELP speedtest_last_run_timestamp_seconds Unix time of last test
# TYPE speedtest_last_run_timestamp_seconds gauge
speedtest_last_run_timestamp_seconds {ts}
"""
            with LOCK:
                METRICS["text"] = text
        except Exception as e:
            with LOCK:
                METRICS["text"] = f"# error: {e}\n"
        time.sleep(INTERVAL)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        with LOCK:
            body = METRICS["text"].encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        return


if __name__ == "__main__":
    threading.Thread(target=run_speedtest, daemon=True).start()
    HTTPServer(("", PORT), H).serve_forever()

