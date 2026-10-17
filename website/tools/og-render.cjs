// Renders tools/og.html to public/og.jpg (1200×630) with headless Chrome.
//   node tools/og-render.cjs
const { spawnSync } = require("child_process");
const path = require("path");
const os = require("os");

const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const png = path.join(os.tmpdir(), "nebula-og.png");
const jpg = path.join(__dirname, "../public/og.jpg");

const run = spawnSync(chrome, [
	"--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
	"--window-size=1200,630", "--virtual-time-budget=4000", "--allow-file-access-from-files",
	`--screenshot=${png}`, "file://" + path.join(__dirname, "og.html"),
], { stdio: "inherit", timeout: 60000 });
if (run.status !== 0) process.exit(run.status || 1);
spawnSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "92", png, "--out", jpg], { stdio: "inherit" });
