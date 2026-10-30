/**
 * Everything that changes between releases or when the repository moves lives here.
 * After a release: bump `version` and `dmgSize`. After moving the repo: change `repo`.
 */
export const site = {
	name: "Nebula",
	tagline: "Screen recordings that edit themselves.",
	description:
		"Nebula is a free, open-source screen recorder for macOS. Record, then one click adds zooms, cuts dead air, speeds up typing and smooths the cursor. Claude can edit with you over MCP.",
	repo: "rune/nebula",
	version: "1.0.0",
	dmgSize: "3.8 MB",
	requirements: "macOS 15 or later · Apple silicon & Intel",
	mcpCommand: "claude mcp add --transport http --scope user nebula http://127.0.0.1:39351/mcp",
};

const github = `https://github.com/${site.repo}`;

export const links = {
	github,
	releases: `${github}/releases`,
	dmg: `${github}/releases/download/v${site.version}/Nebula-${site.version}.dmg`,
	license: `${github}/blob/main/LICENSE`,
	issues: `${github}/issues`,
};
