import { defineConfig } from "astro/config";

// A static site: plain HTML and CSS, plus one small script for the scroll animations.
export default defineConfig({
	// Served by GitHub Pages at rune.github.io/nebula/ (used for canonical and social links).
	site: "https://rune.github.io",
	base: "/nebula/",
	build: { inlineStylesheets: "auto" },
	devToolbar: { enabled: false },
	image: { layout: "constrained" },
	vite: { build: { assetsInlineLimit: 0 } },
});
