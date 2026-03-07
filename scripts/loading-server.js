const http = require("http");
const fs = require("fs");
const path = require("path");

const file = process.argv[2] || "loading-page.html";
const buildStatus = process.argv[3] || "building";
const html = fs.readFileSync(path.join(__dirname, file));
const port = process.env.PORT || 8080;

http
  .createServer((req, res) => {
    if (req.url === '/healthz') {
      if (buildStatus === "failed") {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ status: "build-failed" }));
      } else {
        res.writeHead(503, { "Content-Type": "text/plain" });
        res.end("Building");
      }
      return;
    }
    res.writeHead(200, {
      "Content-Type": "text/html",
      "Cache-Control": "no-cache",
    });
    res.end(html);
  })
  .listen(port, () => {
    console.log(`Loading page server listening on port ${port} (status: ${buildStatus})`);
  });
