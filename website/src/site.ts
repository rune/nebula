/**
 * Everything that changes between releases or when the repository moves lives here.
 * After a release: bump `version`. After moving the repo: change `repo`.
 */
const mcpUrl = "http://127.0.0.1:39351/mcp";

export const site = {
	name: "Nebula",
	tagline: "Screen recordings that edit themselves.",
	description:
		"Nebula is a free, open-source screen recorder for macOS. Record, then one click adds zooms, cuts dead air, speeds up typing and smooths the cursor. Claude can edit with you over MCP.",
	repo: "rune/nebula",
	version: "1.0.0",
	requirements: "macOS 15 or later · Apple silicon & Intel",
	mcpCommand: `claude mcp add --transport http --scope user nebula ${mcpUrl}`,
};

const github = `https://github.com/${site.repo}`;

export const links = {
	github,
	releases: `${github}/releases`,
	license: `${github}/blob/main/LICENSE`,
	issues: `${github}/issues`,
};

export const installCommand = `curl -fsSL https://raw.githubusercontent.com/${site.repo}/main/scripts/install.sh | zsh`;

/** The cask lives in the `homebrew-nebula` repo next to this one, so the tap is `<org>/nebula`. */
export const brewCommand = `brew install --cask ${site.repo}/nebula`;

/** Pasted into a coding agent (Claude Code, Codex, Cursor…), it sets Nebula up end to end. */
export const setupPrompt = `Set up Nebula, the open-source screen recorder for macOS (${github}), on my Mac. You may run the commands below; ask me before running anything else.

1. Install Nebula by running: ${installCommand}
   It downloads the latest release into /Applications and opens it. If I use Homebrew, run ${brewCommand} instead, then open Nebula.
2. Connect Nebula to yourself as an MCP server while Nebula is open. It serves streamable HTTP at ${mcpUrl}. In Claude Code, run: ${site.mcpCommand}
   In any other agent, add that URL the way your MCP settings expect.
3. Walk me through the macOS permissions. Screen Recording is required: when Nebula asks, open System Settings → Privacy & Security → Screen & System Audio Recording and turn Nebula on. Microphone is optional, for voiceover. Accessibility is optional and lets Polish see clicks and text fields.
4. Check that the Nebula MCP server responds, then tell me I'm ready and that ⌥⌘↩ starts a recording.`;
