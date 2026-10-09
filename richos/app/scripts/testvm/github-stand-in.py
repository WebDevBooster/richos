#!/usr/bin/env python3
"""github-stand-in.py - a local stand-in for GitHub's create-an-issue endpoint, for the test VM.

    github-stand-in.py <port> <log>

Answers `POST /repos/<owner>/<repo>/issues` with `201 Created` and the issue GitHub would return
(numbers start at 412, as round 21's do), and writes every request it receives, its path, its
headers and its body, one JSON line each, to <log>. The Authorization header is logged as it
arrives: the token in the walk is a throwaway put in the guest's own keychain for this run.
Anything else is 404. It never contacts GitHub; bug-report-walk.sh points the app at it with
RICHOS_BUG_REPORT_API.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2]
NEXT = [412]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        with open(LOG, "a") as log:
            log.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
        parts = self.path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "repos" and parts[3] == "issues":
            number = NEXT[0]
            NEXT[0] += 1
            reply = {"number": number, "html_url": f"https://github.com/{parts[1]}/{parts[2]}/issues/{number}"}
            self._answer(201, reply)
        else:
            self._answer(404, {"message": "Not Found"})

    def _answer(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
