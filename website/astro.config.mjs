import { defineConfig } from "astro/config";

// A static site: plain HTML and CSS, plus one small script for the scroll animations.
export default defineConfig({
	// Set to the real domain when the site is deployed (used for canonical and social links).
	site: "https://nebula.example",
	build: { inlineStylesheets: "auto" },
	devToolbar: { enabled: false },
	image: { layout: "constrained" },
	vite: { build: { assetsInlineLimit: 0 } },
});
