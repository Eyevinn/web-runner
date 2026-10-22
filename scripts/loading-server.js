const http = require("http");
const fs = require("fs");
const path = require("path");

const file = process.argv[2] || "loading-page.html";
const buildStatus = process.argv[3] || "building";
const html = fs.readFileSync(path.join(__dirname, file));
const port = process.env.PORT || 8080;

const server = http
  .createServer((req, res) => {
    if (req.url === "/__osc/commit-info") {
      try {
        const info = fs.readFileSync("/usercontent/.commit-info.json", "utf8");
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(info);
      } catch {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "no commit info available" }));
      }
      return;
    }
    if (req.url === "/healthz") {
      if (buildStatus === "failed") {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ status: "build-failed" }));
      } else {
        res.writeHead(503, { "Content-Type": "text/plain" });
        res.end("Building");
      }
      return;
    }
    const statusCode = buildStatus === "failed" || buildStatus === "building" ? 503 : 200;
    res.writeHead(statusCode, {
      "Content-Type": "text/html",
      "Cache-Control": "no-cache",
    });
    res.end(html);
  })
  .listen(port, () => {
    console.log(`Loading page server listening on port ${port} (status: ${buildStatus})`);
  });

// Exit promptly on SIGTERM/SIGINT so a restart of a building or failed app does
// not wait out the platform's grace period (this process can be the container's
// main process in the failed state, where Node has no default handler for
// PID 1).
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000).unref();
  });
}
