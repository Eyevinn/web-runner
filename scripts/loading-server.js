const http = require("http");
const fs = require("fs");
const path = require("path");

const file = process.argv[2] || "loading-page.html";
const html = fs.readFileSync(path.join(__dirname, file));
const port = process.env.PORT || 8080;

http
  .createServer((_req, res) => {
    res.writeHead(200, {
      "Content-Type": "text/html",
      "Cache-Control": "no-cache",
    });
    res.end(html);
  })
  .listen(port, () => {
    console.log(`Loading page server listening on port ${port}`);
  });
