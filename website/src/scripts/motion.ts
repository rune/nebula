/**
 * All scroll and entrance motion for the page. One GSAP ticker drives Lenis (smooth scrolling)
 * and ScrollTrigger together. Every effect is created inside gsap.matchMedia(): with reduced
 * motion, nothing animates and each section shows its finished state.
 */
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import Lenis from "lenis";

gsap.registerPlugin(ScrollTrigger);

const $ = <T extends Element = HTMLElement>(selector: string, root: ParentNode = document) => root.querySelector<T>(selector);
const $$ = <T extends Element = HTMLElement>(selector: string, root: ParentNode = document) => Array.from(root.querySelectorAll<T>(selector));

let lenis: Lenis | null = null;

// MARK: Always on (no motion involved)

/** Plays a video only while it is on screen. */
function playWhenVisible(video: HTMLVideoElement) {
	const observer = new IntersectionObserver(
		([entry]) => {
			if (entry.isIntersecting) video.play().catch(() => {});
			else video.pause();
		},
		{ threshold: 0.15 },
	);
	observer.observe(video);
	return () => {
		observer.disconnect();
		video.pause();
	};
}

/** Seeks a video to `time`, one seek at a time so scrubbing never queues up stale frames. */
function seeker(video: HTMLVideoElement) {
	let target = 0;
	let busy = false;
	const go = () => {
		if (video.readyState < 1) return;
		const end = Number.isFinite(video.duration) ? video.duration - 0.04 : target;
		const time = Math.max(0, Math.min(target, end));
		if (Math.abs(video.currentTime - time) < 0.015) return;
		busy = true;
		video.currentTime = time;
	};
	video.addEventListener("seeked", () => {
		busy = false;
		go();
	});
	video.addEventListener("loadedmetadata", go);
	return (time: number) => {
		target = time;
		if (!busy) go();
	};
}

function setupCopy() {
	for (const button of $$<HTMLButtonElement>("[data-copy]")) {
		button.addEventListener("click", async () => {
			const text = $("[data-copy-source]", button.parentElement!)?.textContent ?? "";
			try {
				await navigator.clipboard.writeText(text.trim());
				button.classList.add("copied");
				setTimeout(() => button.classList.remove("copied"), 1600);
			} catch {
				/* Clipboard blocked: the command is still selectable. */
			}
		});
	}
}

function setupAnchors() {
	for (const link of $$<HTMLAnchorElement>('a[href^="#"]')) {
		link.addEventListener("click", (event) => {
			const id = link.getAttribute("href")!;
			const target = id === "#top" ? document.body : $(id);
			if (!target) return;
			event.preventDefault();
			if (lenis) lenis.scrollTo(target as HTMLElement, { offset: id === "#top" ? 0 : -24, duration: 1.4 });
			else target.scrollIntoView({ behavior: "auto" });
			history.replaceState(null, "", id);
		});
	}
}

/** The bar's background, the scrubber's chapter marks and playhead, and the current chapter link. */
function setupNav() {
	const nav = $("[data-nav]");
	if (!nav) return;
	const track = $(".track", nav)!;
	const playhead = $("[data-playhead]", nav)!;
	const marks = $$<HTMLAnchorElement>("[data-mark]", nav);
	const links = $$<HTMLAnchorElement>("[data-nav-link]", nav);
	let starts: number[] = [];

	const layout = () => {
		const range = Math.max(1, document.documentElement.scrollHeight - innerHeight);
		starts = marks.map((mark) => {
			const section = document.getElementById(mark.dataset.mark!);
			const top = section ? section.getBoundingClientRect().top + scrollY : 0;
			mark.style.left = `${Math.min(100, (top / range) * 100)}%`;
			return top;
		});
		update(scrollY);
	};

	const update = (y: number) => {
		nav.classList.toggle("scrolled", y > 12);
		const range = Math.max(1, document.documentElement.scrollHeight - innerHeight);
		playhead.style.transform = `translateX(${(Math.min(1, y / range) * track.clientWidth).toFixed(1)}px)`;
		let current = -1;
		starts.forEach((top, index) => {
			if (y + innerHeight * 0.4 >= top) current = index;
		});
		links.forEach((link, index) => link.classList.toggle("current", index === current));
	};

	if (lenis) lenis.on("scroll", ({ scroll }: { scroll: number }) => update(scroll));
	else addEventListener("scroll", () => update(scrollY), { passive: true });
	ScrollTrigger.addEventListener("refresh", layout);
	addEventListener("resize", layout);
	addEventListener("load", layout);
	layout();
}

// MARK: Look plates (works with and without motion)

function setupLook(animate: boolean) {
	const tabs = $$<HTMLButtonElement>("[data-look-tab]");
	const slides = $$("[data-look-slide]");
	if (!tabs.length) return () => {};
	let index = 0;
	let progress: gsap.core.Tween | null = null;
	let visible = false;

	const show = (next: number) => {
		index = (next + tabs.length) % tabs.length;
		tabs.forEach((tab, i) => {
			tab.classList.toggle("active", i === index);
			tab.setAttribute("aria-selected", String(i === index));
			if (animate) gsap.set($(".progress i", tab), { scaleX: 0 });
		});
		slides.forEach((slide, i) => slide.classList.toggle("active", i === index));
		progress?.kill();
		if (animate && visible) {
			progress = gsap.to($(".progress i", tabs[index]), { scaleX: 1, duration: 4.5, ease: "none", onComplete: () => show(index + 1) });
		}
	};

	tabs.forEach((tab, i) => tab.addEventListener("click", () => show(i)));
	const observer = new IntersectionObserver(([entry]) => {
		visible = entry.isIntersecting;
		if (visible) show(index);
		else progress?.pause();
	}, { threshold: 0.35 });
	observer.observe($("#look")!);
	return () => {
		observer.disconnect();
		progress?.kill();
	};
}

// MARK: Polish

type Segment = { start: number; end: number; kind: "cut" | "keep" | "speed" };
type Span = { start: number; end: number };

/**
 * "pin": the figure pins and scrolling plays the recording under a playhead, drawing each edit as
 * it is reached; then the cuts close up. "play": no pin; both videos loop and the timeline closes
 * up once. "still": the finished diagram, nothing moves.
 */
function setupPolish(mode: "pin" | "play" | "still") {
	const section = $("[data-polish]");
	if (!section) return () => {};
	const duration = Number(section.dataset.duration);
	const rate = Number(section.dataset.rate);
	const segments: Segment[] = JSON.parse(section.dataset.segments!);
	const zoomSpans: Span[] = JSON.parse(section.dataset.zooms!);

	const raw = $<HTMLVideoElement>("[data-polish-raw]", section)!;
	const out = $<HTMLVideoElement>("[data-polish-out]", section)!;
	const pane = $("[data-polished-pane]", section)!;
	const state = $("[data-polish-state]", section)!;
	const rawTime = $("[data-raw-time]", section)!;
	const outTime = $("[data-out-time]", section)!;
	const track = $("[data-polish-track]", section)!;
	const playhead = $("[data-polish-playhead]", section)!;
	const lengthLabel = $("[data-polish-length]", section)!;
	const notes = $$("[data-note]", section);
	const columns = $$("[data-column]", section);
	const zooms = $$("[data-zoom]", section);
	const cleanups: (() => void)[] = [];

	/** Where a moment of the recording lands in the polished video. */
	const outputTime = (t: number) => {
		let time = 0;
		for (const segment of segments) {
			if (t <= segment.start) break;
			const span = Math.min(t, segment.end) - segment.start;
			time += segment.kind === "cut" ? 0 : segment.kind === "speed" ? span / rate : span;
		}
		return time;
	};
	const clock = (seconds: number) => `0:${seconds.toFixed(1).padStart(4, "0")}`;

	const seekRaw = seeker(raw);
	const seekOut = seeker(out);

	const setTime = (t: number, withVideo = true) => {
		playhead.style.transform = `translateX(${((t / duration) * track.clientWidth).toFixed(1)}px)`;
		for (const note of notes) {
			const start = Number(note.dataset.start);
			const end = Number(note.dataset.end);
			note.classList.toggle("reached", t >= start);
			note.classList.toggle("active", t >= start && t < end + 0.3);
		}
		for (const column of columns) column.classList.toggle("on", column.dataset.column !== "keep" && t >= Number(column.dataset.start));
		for (const zoom of zooms) zoom.classList.toggle("on", t >= Number(zoom.dataset.zoom));

		const segment = segments.find((s) => t >= s.start && t < s.end) ?? segments[segments.length - 1];
		const zoomed = zoomSpans.some((z) => t >= z.start && t < z.end);
		const cut = segment.kind === "cut" && t < duration;
		pane.classList.toggle("cut", cut);
		const label = [segment.kind === "speed" ? `${rate}×` : "", zoomed ? "Zoom 1.9×" : ""].filter(Boolean).join(" · ");
		if (label) state.textContent = label;
		state.classList.toggle("visible", Boolean(label) && !cut);

		const output = outputTime(t);
		rawTime.textContent = clock(t);
		outTime.textContent = clock(output);
		if (withVideo) {
			seekRaw(t);
			seekOut(output);
		}
	};

	// The edits close up: cuts vanish, sped-up clips shorten, the length counts down.
	const collapse = () => {
		const length = { value: duration };
		const timeline = gsap.timeline({ defaults: { duration: 1, ease: "power2.inOut" } });
		for (const column of columns) {
			if (column.dataset.column === "cut") timeline.to(column, { width: "0%", paddingRight: 0, opacity: 0 }, 0);
			if (column.dataset.column === "speed") timeline.to(column, { width: column.dataset.speedWidth }, 0);
		}
		// While pinned the notes point at moments that no longer exist, so a summary replaces them.
		if (mode === "pin") timeline.to(notes, { opacity: 0, duration: 0.4 }, 0);
		timeline
			.to("[data-polish-summary]", { opacity: 1, duration: 0.5 }, 0.5)
			.to("[data-polish-axis]", { opacity: 0, duration: 0.4 }, 0)
			.to(playhead, { opacity: 0, duration: 0.3 }, 0)
			.to("[data-polish-original]", { opacity: 1, duration: 0.5 }, 0.6)
			.to(length, { value: outputTime(duration), onUpdate: () => (lengthLabel.textContent = `${length.value.toFixed(1)} s`) }, 0);
		return timeline;
	};

	if (mode === "pin") {
		const proxy = { t: 0 };
		gsap.set(playhead, { opacity: 1 });
		const master = gsap.timeline({ paused: true });
		master.to(proxy, { t: duration, duration: 8, ease: "none", onUpdate: () => setTime(proxy.t) }).add(collapse(), "+=0.3").to({}, { duration: 0.5 });
		setTime(0);
		const trigger = ScrollTrigger.create({
			trigger: $("[data-polish-pin]", section),
			start: "top 88px",
			end: () => `+=${innerHeight * 3.2}`,
			pin: true,
			scrub: 0.4,
			animation: master,
		});
		const onResize = () => setTime(proxy.t, false);
		addEventListener("resize", onResize);
		cleanups.push(() => {
			trigger.kill();
			master.kill();
			removeEventListener("resize", onResize);
		});
	} else {
		setTime(duration, false);
		for (const note of notes) note.classList.remove("active");
		pane.classList.remove("cut");
		state.classList.remove("visible");
		rawTime.textContent = "0:17.5";
		outTime.textContent = "0:10.3";
		if (mode === "play") {
			raw.loop = out.loop = true;
			cleanups.push(playWhenVisible(raw), playWhenVisible(out));
			const timeline = collapse().pause();
			const trigger = ScrollTrigger.create({ trigger: track, start: "top 75%", once: true, onEnter: () => timeline.play() });
			cleanups.push(() => {
				trigger.kill();
				timeline.progress(0).kill();
			});
		} else {
			lengthLabel.textContent = "17.5 s → 10.3 s";
			$("[data-polish-summary]", section)!.hidden = true;
		}
	}

	const result = $<HTMLVideoElement>("[data-polish-result]", section);
	if (result && mode !== "still") cleanups.push(playWhenVisible(result));
	return () => cleanups.forEach((cleanup) => cleanup());
}

// MARK: Claude conversation

function setupClaude() {
	const section = $("[data-claude]");
	if (!section) return;
	const prompt = $("[data-claude-prompt]", section)!;
	const full = prompt.dataset.text ?? prompt.textContent ?? "";
	const cursor = $("[data-claude-cursor]", section)!;
	const calls = $$("[data-claude-call]", section);
	const toasts = $$("[data-claude-toast]", section);
	const reply = $("[data-claude-reply]", section)!;

	gsap.set([...calls, reply], { opacity: 0, y: 8 });
	gsap.set(toasts, { opacity: 0, y: 14 });
	prompt.textContent = "";
	const typed = { count: 0 };

	const timeline = gsap.timeline({ paused: true });
	timeline
		.set(cursor, { opacity: 1 })
		.to(typed, {
			count: full.length,
			duration: full.length * 0.028,
			ease: "none",
			onUpdate: () => (prompt.textContent = full.slice(0, Math.round(typed.count))),
		})
		.set(cursor, { opacity: 0 }, "+=0.25");
	calls.forEach((call, index) => {
		timeline.to(call, { opacity: 1, y: 0, duration: 0.4, ease: "power2.out" }, `+=${index === 0 ? 0.35 : 0.8}`);
		if (index > 0) timeline.to(toasts[index - 1], { opacity: 0, y: -10, duration: 0.3 }, "<");
		timeline.to(toasts[index], { opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }, "<0.05");
	});
	timeline.to(reply, { opacity: 1, y: 0, duration: 0.5, ease: "power2.out" }, "+=0.6");

	ScrollTrigger.create({ trigger: $(".demo", section), start: "top 70%", once: true, onEnter: () => timeline.play() });
}

// MARK: Setup

function init() {
	const media = gsap.matchMedia();

	media.add("(prefers-reduced-motion: no-preference)", () => {
		lenis = new Lenis({ lerp: 0.11, wheelMultiplier: 1, smoothWheel: true });
		lenis.on("scroll", ScrollTrigger.update);
		const raf = (time: number) => lenis?.raf(time * 1000);
		gsap.ticker.add(raf);
		gsap.ticker.lagSmoothing(0);

		// Hero: the statement rises line by line, then violet fills the phrase from left to right.
		gsap
			.timeline({ defaults: { ease: "expo.out" } })
			.from("[data-hero-line]", { opacity: 0, y: 26, duration: 1.2, stagger: 0.12 }, 0.1)
			.fromTo("[data-hero-fill]", { "--fill": "0%" }, { "--fill": "100%", duration: 1.3, ease: "power2.inOut" }, 0.6)
			.from("[data-hero-in]", { opacity: 0, y: 16, duration: 1 }, 0.45)
			.from("[data-hero-product]", { opacity: 0, y: 56, duration: 1.5 }, 0.6);

		// Reveals.
		ScrollTrigger.batch("[data-reveal]", {
			start: "top 88%",
			once: true,
			onEnter: (elements) => gsap.to(elements, { opacity: 1, y: 0, duration: 1, ease: "power3.out", stagger: 0.07, overwrite: true }),
		});

		// Chapter rulers run out to the edge as each chapter arrives.
		for (const ruler of $$("[data-ruler]")) {
			gsap.from(ruler, { scaleX: 0, duration: 1.4, ease: "power3.inOut", scrollTrigger: { trigger: ruler, start: "top 90%", once: true } });
		}

		// Record: the window settles, its outline draws, then the bar rises.
		if ($("[data-record-scene]")) {
			gsap
				.timeline({ scrollTrigger: { trigger: "[data-record-scene]", start: "top 80%", end: "center 45%", scrub: 0.6 } })
				.from("[data-record-window]", { scale: 0.95, duration: 1 }, 0)
				.fromTo("[data-record-outline]", { strokeDasharray: 1, strokeDashoffset: 1 }, { strokeDashoffset: 0, duration: 1.1, ease: "power1.inOut" }, 0.1)
				.from("[data-record-size]", { opacity: 0, y: 8, duration: 0.4 }, 0.9)
				.from("[data-record-bar]", { opacity: 0, y: 40, duration: 0.8, ease: "power2.out" }, 0.5);
		}

		// Edit: the numbered pins drop onto the timeline one by one.
		gsap.from("[data-pin]", { scale: 0, duration: 0.5, ease: "back.out(2)", stagger: 0.12, scrollTrigger: { trigger: "[data-pins]", start: "top 70%", once: true } });

		// The closing phrase fills like the hero's.
		gsap.fromTo("[data-closing-fill]", { "--fill": "0%" }, { "--fill": "100%", duration: 1.3, ease: "power2.inOut", delay: 0.3, scrollTrigger: { trigger: "[data-closing-fill]", start: "top 85%", once: true } });

		setupClaude();
		const stopLook = setupLook(true);
		const hero = $<HTMLVideoElement>(".stage-video");
		const stopHero = hero ? playWhenVisible(hero) : () => {};

		return () => {
			gsap.ticker.remove(raf);
			lenis?.destroy();
			lenis = null;
			stopLook();
			stopHero();
		};
	});

	media.add("(prefers-reduced-motion: no-preference) and (min-width: 961px)", () => setupPolish("pin"));
	media.add("(prefers-reduced-motion: no-preference) and (max-width: 960px)", () => setupPolish("play"));
	media.add("(prefers-reduced-motion: reduce)", () => {
		const stopPolish = setupPolish("still");
		const stopLook = setupLook(false);
		return () => {
			stopPolish();
			stopLook();
		};
	});

	// The Polish pin is created after the reveals but sits above most of them on the page; order the
	// triggers by position so everything below the pin accounts for its scroll distance.
	ScrollTrigger.sort();
	ScrollTrigger.refresh();
	addEventListener("load", () => ScrollTrigger.refresh());

	setupNav();
	setupAnchors();
	setupCopy();
}

init();
