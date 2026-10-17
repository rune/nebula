// Renders Nebula's demo recording: orbit.html frame by frame into a 60 fps video, plus the input
// track (cursor, clicks, typing, focused field) that a real Nebula recording would have, and a
// desktop wallpaper. Run with Electron:
//   ELECTRON=/path/to/Electron electron render.cjs <out-dir>
// Writes <out-dir>/recording.mp4, input.json and desktop.jpg.
const { app, BrowserWindow } = require("electron");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const FPS = 60;
const WIDTH = 1440; // CSS px of the recorded window
const HEIGHT = 900;
const SCALE = 2;
// Where the window sat on a 1728×1117 pt screen (a 16" MacBook Pro).
const SCREEN = { width: 1728, height: 1117 };
const WINDOW_ORIGIN = { x: 144, y: 118 };

const outDir = path.resolve(process.argv.filter((a) => !a.startsWith("--")).slice(-1)[0]);
fs.mkdirSync(outDir, { recursive: true });

async function makeWindow(file, width, height) {
	const win = new BrowserWindow({
		width: width * SCALE, height: height * SCALE, show: false, useContentSize: true,
		enableLargerThanScreen: true, webPreferences: { zoomFactor: SCALE, backgroundThrottling: false },
	});
	// A load can report ERR_FAILED when the page finishes in the same tick; check the page instead.
	await win.loadFile(path.join(__dirname, file)).catch((error) => console.warn("load:", error.message));
	await win.webContents.executeJavaScript("document.readyState").then((state) => console.log(file, state));
	win.webContents.setZoomFactor(SCALE);
	await new Promise((r) => setTimeout(r, 600));
	return win;
}

async function capture(win, width, height) {
	let image = await win.webContents.capturePage();
	if (image.getSize().width !== width * SCALE) image = image.resize({ width: width * SCALE, height: height * SCALE, quality: "best" });
	return image;
}

// Cursor keyframes in CSS px of the window, eased between with a slight arc like a real hand.
function cursorPath(L, S) {
	const center = (b, dx = 0.5, dy = 0.5) => ({ x: b.x + b.width * dx, y: b.y + b.height * dy });
	const keys = [
		{ t: 0, ...{ x: 1060, y: 720 } },
		{ t: 1.1, x: 1060, y: 720 },
		{ t: 2.25, ...center(L.newBtn, 0.55, 0.55) },
		{ t: 2.75, ...center(L.newBtn, 0.55, 0.55) },
		{ t: 3.35, ...center(L.name, 0.2, 0.55) },
		{ t: 9.0, ...center(L.name, 0.2, 0.55) },
		{ t: 9.55, ...center(L.invite, 0.25, 0.55) },
		{ t: 15.7, ...center(L.invite, 0.25, 0.55) },
		{ t: 16.7, x: 760, y: 330 },
		{ t: S.duration, x: 760, y: 330 },
	];
	const ease = (v) => (v < 0.5 ? 4 * v * v * v : 1 - Math.pow(-2 * v + 2, 3) / 2);
	return (t) => {
		let i = keys.findIndex((k) => k.t > t);
		if (i <= 0) return i === 0 ? keys[0] : keys[keys.length - 1];
		const a = keys[i - 1], b = keys[i];
		const u = ease((t - a.t) / (b.t - a.t));
		const arc = Math.sin(u * Math.PI) * Math.min(40, Math.hypot(b.x - a.x, b.y - a.y) * 0.08);
		return { x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u - arc };
	};
}

function inputTrack(L, S) {
	const norm = (p) => ({ x: p.x / WIDTH, y: p.y / HEIGHT });
	const rect = (b) => ({ x: b.x / WIDTH, y: b.y / HEIGHT, width: b.width / WIDTH, height: b.height / HEIGHT });
	const at = cursorPath(L, S);
	const cursor = [];
	for (let t = 0; t <= S.duration; t += 1 / 120) {
		const p = norm(at(t));
		cursor.push({ t: +t.toFixed(4), x: +p.x.toFixed(5), y: +p.y.toFixed(5), shape: 0 });
	}
	const click = (t) => ({ t, ...norm(at(t)), button: "left", upT: t + 0.09 });
	const typing = ([a, b], count) => Array.from({ length: count }, (_, i) => ({ t: +(a + ((b - a) * i) / count).toFixed(3), kind: "typing", keys: [] }));
	const invites = S.invites.join(", ");
	return {
		formatVersion: 1,
		captureRect: { x: WINDOW_ORIGIN.x, y: WINDOW_ORIGIN.y, width: WIDTH, height: HEIGHT },
		scale: SCALE,
		cursor,
		cursorShapes: [{ kind: "arrow", hotspotX: 0, hotspotY: 0, width: 0, height: 0 }],
		clicks: [click(S.clickNew), click(S.nameClick), click(S.inviteClick)],
		keys: [
			...typing(S.nameType, S.name.length),
			...typing(S.inviteType, invites.length),
			{ t: S.submit, kind: "shortcut", keys: ["⌘", "↩"] },
		],
		scrolls: [],
		focus: [
			{ t: S.nameClick, rect: rect(L.name) },
			{ t: S.inviteClick, rect: rect(L.invite) },
			{ t: S.submit, rect: null },
		],
	};
}

app.disableHardwareAcceleration();
// Windows come and go between steps; don't let Electron quit when none is open.
app.on("window-all-closed", () => {});
app.whenReady().then(async () => {
	// Wallpaper.
	const wall = await makeWindow("wallpaper.html", SCREEN.width, SCREEN.height);
	fs.writeFileSync(path.join(outDir, "desktop.jpg"), (await capture(wall, SCREEN.width, SCREEN.height)).toJPEG(92));
	wall.destroy();

	// Recording.
	const win = await makeWindow("orbit.html", WIDTH, HEIGHT);
	const S = await win.webContents.executeJavaScript("window.SCRIPT");
	const L = await win.webContents.executeJavaScript("window.layout()");
	const track = inputTrack(L, S);
	fs.writeFileSync(path.join(outDir, "input.json"), JSON.stringify(track));
	const screen = {
		width: SCREEN.width * SCALE, height: SCREEN.height * SCALE,
		captureRect: { x: WINDOW_ORIGIN.x / SCREEN.width, y: WINDOW_ORIGIN.y / SCREEN.height, width: WIDTH / SCREEN.width, height: HEIGHT / SCREEN.height },
	};
	fs.writeFileSync(path.join(outDir, "screen.json"), JSON.stringify(screen));

	const ffmpeg = spawn("ffmpeg", [
		"-y", "-v", "error", "-f", "image2pipe", "-framerate", String(FPS), "-c:v", "mjpeg", "-i", "-",
		"-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
		path.join(outDir, "recording.mp4"),
	], { stdio: ["pipe", "inherit", "inherit"] });
	const frames = Math.round(S.duration * FPS);
	for (let i = 0; i < frames; i++) {
		await win.webContents.executeJavaScript(`window.render(${i / FPS})`);
		const jpeg = (await capture(win, WIDTH, HEIGHT)).toJPEG(95);
		if (!ffmpeg.stdin.write(jpeg)) await new Promise((r) => ffmpeg.stdin.once("drain", r));
		if (i % 120 === 0) console.log(`frame ${i}/${frames}`);
	}
	ffmpeg.stdin.end();
	await new Promise((r) => ffmpeg.on("close", r));
	console.log("wrote", outDir);
	app.quit();
});
