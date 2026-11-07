// Serves the demo shop page and forwards /api/* to the Nginx gateway, so the
// page and the API share one origin (Nginx exposes only the API and answers
// 404 for everything else, and the services are not opened for other origins).
//
//   node demo-results/ui/serve.mjs                      -> http://localhost:5180, API at http://localhost:8080
//   node demo-results/ui/serve.mjs --api http://<host>  -> forward to another gateway (for example the EC2 backend)
//   node demo-results/ui/serve.mjs --port 5190
//
// No dependencies. Without a reachable gateway the page falls back to its
// in-browser simulation.
import http from "node:http";
import https from "node:https";
import { readFile } from "node:fs/promises";
import { extname, join, normalize, dirname, sep } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 && args[i + 1] ? args[i + 1] : def; };
const PORT = Number(opt("--port", process.env.PORT ?? 5180));
const API = new URL(opt("--api", process.env.API ?? "http://localhost:8080"));
const ROOT = dirname(fileURLToPath(import.meta.url));
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".json": "application/json" };

function proxy(req, res) {
  const lib = API.protocol === "https:" ? https : http;
  const up = lib.request({
    protocol: API.protocol, hostname: API.hostname, port: API.port || (API.protocol === "https:" ? 443 : 80),
    method: req.method, path: req.url, headers: { ...req.headers, host: API.host },
    // Only the local development certificate is self-signed; any other host is verified.
    rejectUnauthorized: !["localhost", "127.0.0.1", "::1"].includes(API.hostname), timeout: 15000,
  }, r => { res.writeHead(r.statusCode ?? 502, r.headers); r.pipe(res); });
  up.on("timeout", () => up.destroy(new Error("upstream timeout")));
  up.on("error", e => { if (!res.headersSent) res.writeHead(502, { "Content-Type": "text/plain" }); res.end(`Gateway not reachable at ${API.origin}: ${e.message}\n`); });
  req.pipe(up);
}

async function file(req, res) {
  let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (path === "/" || path === "") path = "/index.html";
  const full = normalize(join(ROOT, path));
  if (!full.startsWith(ROOT + sep)) { res.writeHead(403); return res.end(); }
  try {
    const body = await readFile(full);
    res.writeHead(200, { "Content-Type": TYPES[extname(full)] ?? "application/octet-stream", "Cache-Control": "no-store" });
    res.end(body);
  } catch { res.writeHead(404, { "Content-Type": "text/plain" }); res.end("Not found\n"); }
}

http.createServer((req, res) => (req.url.startsWith("/api/") || req.url === "/api" ? proxy(req, res) : file(req, res)))
  .listen(PORT, () => console.log(`Demo shop on http://localhost:${PORT}  (API forwarded to ${API.origin})`));
