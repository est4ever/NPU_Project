const fs = require("node:fs");
const path = require("node:path");

const distDir = path.resolve(__dirname, "..", "dist");
const indexPath = path.join(distDir, "index.html");
const fallbackPath = path.join(distDir, "404.html");

if (fs.existsSync(indexPath)) {
  fs.copyFileSync(indexPath, fallbackPath);
  console.log("Created dist/404.html for GitHub Pages SPA routing.");
} else {
  console.warn("Skipping 404 fallback copy: dist/index.html not found.");
}
