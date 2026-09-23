#!/usr/bin/env node
/**
 * Boots the exported Godot web build in headless Chromium and waits for the
 * terrain-load line emitted by demo_match.tscn.
 *
 * Setup (once, after `npm ci`):
 *
 *     npx playwright install chromium
 *
 * Run from the repository root with:
 *
 *     make godot-web-headless-check
 *
 * Override WEB_HEADLESS_CHECK_EXPECTED_LINE or
 * WEB_HEADLESS_CHECK_TIMEOUT_MS to exercise a different success/failure
 * condition. WEB_HEADLESS_CHECK_BOOT_TIMEOUT_MS bounds waiting for the first
 * browser diagnostic during a cold pack load. WEB_HEADLESS_CHECK_PORT defaults
 * to 4173 when a different local port is needed.
 */

import { createReadStream, promises as fs } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const TOOL_DIR = path.dirname(fileURLToPath(import.meta.url));
const EXPORT_DIR = path.resolve(TOOL_DIR, "../../exports/web");
const DEFAULT_EXPECTED_LINE = "MapLoader: res://assets/converted/maps/#M25 GM Aprit Chard S 2/map_data.tres";
const DEFAULT_TIMEOUT_MS = 120_000;
const DEFAULT_BOOT_TIMEOUT_MS = 120_000;
const DEFAULT_PORT = 4173;
const MIME_TYPES = new Map([
	[".html", "text/html; charset=utf-8"],
	[".js", "text/javascript; charset=utf-8"],
	[".json", "application/json; charset=utf-8"],
	[".wasm", "application/wasm"],
	[".pck", "application/octet-stream"],
	[".png", "image/png"],
	[".svg", "image/svg+xml"],
	[".webp", "image/webp"],
	[".css", "text/css; charset=utf-8"],
]);


function readPositiveInteger(name, fallback) {
	const value = process.env[name];
	if (value === undefined || value === "") {
		return fallback;
	}
	const parsed = Number(value);
	if (!Number.isSafeInteger(parsed) || parsed <= 0) {
		throw new Error(`${name} must be a positive integer; got ${JSON.stringify(value)}`);
	}
	return parsed;
}


function responseHeaders(filePath) {
	return {
		"Content-Type": MIME_TYPES.get(path.extname(filePath).toLowerCase()) ?? "application/octet-stream",
		"Cross-Origin-Opener-Policy": "same-origin",
		"Cross-Origin-Embedder-Policy": "require-corp",
		"Cross-Origin-Resource-Policy": "same-origin",
		"Cache-Control": "no-store",
	};
}


async function resolveRequestedFile(requestUrl) {
	const url = new URL(requestUrl, "http://localhost");
	const requestPath = decodeURIComponent(url.pathname);
	const relativePath = requestPath === "/" ? "index.html" : requestPath.replace(/^[/\\]+/, "");
	const filePath = path.resolve(EXPORT_DIR, relativePath);
	if (filePath !== EXPORT_DIR && !filePath.startsWith(`${EXPORT_DIR}${path.sep}`)) {
		return null;
	}
	const details = await fs.stat(filePath);
	return details.isDirectory() ? path.join(filePath, "index.html") : filePath;
}


function startServer(port) {
	const server = http.createServer(async (request, response) => {
		try {
			const filePath = await resolveRequestedFile(request.url ?? "/");
			if (filePath === null) {
				response.writeHead(403).end("Forbidden\n");
				return;
			}
			response.writeHead(200, responseHeaders(filePath));
			createReadStream(filePath).pipe(response);
		} catch (error) {
			if (error.code === "ENOENT" || error.code === "ENOTDIR") {
				response.writeHead(404).end("Not found\n");
				return;
			}
			console.error(`Static server error: ${error.message}`);
			response.writeHead(500).end("Internal server error\n");
		}
	});
	return new Promise((resolve, reject) => {
		server.once("error", reject);
		server.listen(port, "127.0.0.1", () => {
			server.off("error", reject);
			resolve(server);
		});
	});
}


function stopServer(server) {
	return new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}


async function main() {
	const expectedLine = process.env.WEB_HEADLESS_CHECK_EXPECTED_LINE ?? DEFAULT_EXPECTED_LINE;
	if (expectedLine === "") {
		throw new Error("WEB_HEADLESS_CHECK_EXPECTED_LINE must not be empty");
	}
	const timeoutMs = readPositiveInteger("WEB_HEADLESS_CHECK_TIMEOUT_MS", DEFAULT_TIMEOUT_MS);
	const bootTimeoutMs = readPositiveInteger("WEB_HEADLESS_CHECK_BOOT_TIMEOUT_MS", DEFAULT_BOOT_TIMEOUT_MS);
	const port = readPositiveInteger("WEB_HEADLESS_CHECK_PORT", DEFAULT_PORT);
	const observed = [];
	let bootStartedAt = 0;
	let server;
	let browser;
	let expectedSeen = false;
	let resolveExpected;
	let firstOutputSeen = false;
	let resolveFirstOutput;
	let checkError = null;
	try {
		await fs.access(path.join(EXPORT_DIR, "index.html"));
		server = await startServer(port);
		console.log(`Serving ${EXPORT_DIR} at http://127.0.0.1:${port}/`);

		browser = await chromium.launch({ headless: true });
		const page = await browser.newPage();
		const captureOutput = (line, writer) => {
			observed.push(line);
			writer(line);
			firstOutputSeen = true;
			resolveFirstOutput?.();
		};
		page.on("console", message => {
			const line = `[browser:${message.type()}] ${message.text()}`;
			captureOutput(line, console.log);
			if (line.includes(expectedLine)) {
				expectedSeen = true;
				resolveExpected?.();
			}
		});
		page.on("pageerror", error => {
			const line = `[pageerror] ${error.message}`;
			captureOutput(line, console.error);
		});
		page.on("requestfailed", request => {
			const line = `[requestfailed] ${request.url()} ${request.failure()?.errorText ?? "unknown failure"}`;
			captureOutput(line, console.error);
		});

		bootStartedAt = Date.now();
		await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "domcontentloaded", timeout: timeoutMs });
		if (!firstOutputSeen) {
			await new Promise((resolve, reject) => {
				const timer = setTimeout(() => reject(new Error(`Timed out after ${bootTimeoutMs} ms waiting for initial browser output`)), bootTimeoutMs);
				resolveFirstOutput = () => {
					clearTimeout(timer);
					resolve();
				};
			});
		}
		if (!expectedSeen) {
			await new Promise((resolve, reject) => {
				const timer = setTimeout(() => reject(new Error(`Timed out after ${timeoutMs} ms waiting for ${JSON.stringify(expectedLine)}`)), timeoutMs);
				resolveExpected = () => {
					clearTimeout(timer);
					resolve();
				};
			});
		}
		console.log(`Observed expected browser console line after ${Date.now() - bootStartedAt} ms: ${expectedLine}`);
	} catch (error) {
		checkError = error;
		const captured = observed.length === 0 ? "(no browser or page output captured)" : observed.join("\n");
		throw new Error(`${error.message}\nCaptured browser/page output:\n${captured}`);
	} finally {
		let browserCleanupError = null;
		try {
			if (browser !== undefined) {
				await browser.close();
			}
		} catch (error) {
			browserCleanupError = error;
			console.error(`Browser cleanup failed: ${error.message}`);
		} finally {
			if (server !== undefined) {
				await stopServer(server);
				console.log("Stopped local web server.");
			}
		}
		if (browserCleanupError !== null && checkError === null) {
			throw browserCleanupError;
		}
	}
}


main().catch(error => {
	console.error(`Headless web check failed: ${error.message}`);
	process.exitCode = 1;
});
