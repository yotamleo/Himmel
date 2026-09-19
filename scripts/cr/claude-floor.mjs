#!/usr/bin/env node
// claude-floor.mjs — the claude-floor review's snapshot + provenance stamp
// (HIMMEL-3229, HIMMEL-3220). One file, so the signer (claude-floor-review.sh)
// and the verifier (clear-cr-marker.sh floor_provenance_ok) share ONE
// definition of the signed payload.
//
//   snapshot <head> <dest>  materialise every tracked file at <head> from its
//                           RAW blob (no smudge/clean filter, no eol or
//                           working-tree-encoding conversion): the reviewer
//                           reads exactly the bytes the provenance hash covers.
//                           A symlink becomes an inert file holding its target.
//   sign <artifact.json> <registry-row.json>
//                           print the artifact with a `stamp` added: an ed25519
//                           signature over its provenance fields, made with the
//                           private key in the key dir. Refuses unless the
//                           registry row is a completed, is_error=false
//                           dispatch with the artifact's dispatch + session id.
//   verify <artifact.json>  exit 0 iff the stamp verifies against the PUBLIC key
//                           in the key dir; else exit 1 with the reason on stderr.
//   key-check               exit 0 iff a matching key pair is provisioned (the
//                           signer checks this BEFORE spending a review).
//   init-key                OPERATOR, once: create the key dir (0700) with
//                           signing.key (0600) + signing.pub. Idempotent; never
//                           overwrites. A missing key fails every other command
//                           CLOSED and names this command.
//
// Key dir: $CR_FLOOR_KEY_DIR, default ~/.himmel/cr-floor-key — outside every
// worktree, git dir and review snapshot. Tests point it at a temp dir.
//
// Trust boundary. The headless reviewer runs with tools Read/Grep/Glob/Write,
// cwd = the snapshot, no Bash, under --permission-mode acceptEdits. What keeps
// it out of the key dir is Claude Code's working-directory permission model: a
// read or write outside cwd needs a grant the non-interactive session is never
// given. That is NOT OS isolation (the process could open the file), and it is
// unproven here: no test runs a live headless review. The
// signer signs only after reading its own claude-headless.sh registry row
// (completed, is_error=false, a session id), and the payload binds that row's
// dispatch id and session id. The verifier needs only the public key, so the
// gate holds no secret: moving the private key to another uid later changes
// the signer alone.
// ponytail: the signer runs as the authoring leg's uid, so any same-uid
// process can still stamp a forged artifact: run `sign` with a registry row it
// wrote itself, read signing.key, or replace the key pair. The stamp stops the
// hand-written artifact (correct hash, invented session id); it is not
// cryptographically out of a same-uid leg's reach. `sign` checking the
// registry row and block-read-secrets.sh refusing Read/cat of *.key catch the
// accidental path, not a determined one. The real fix is a signer running as
// a SEPARATE uid that legs cannot become; the gate side needs no change then.
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const die = (msg, rc = 1) => { process.stderr.write(`claude-floor: ${msg}\n`); process.exit(rc); };
const keyDir = () => process.env.CR_FLOOR_KEY_DIR || path.join(os.homedir(), ".himmel", "cr-floor-key");
const git = (args, opts = {}) => spawnSync("git", args, { maxBuffer: 1 << 30, ...opts });

// The signed payload. Every field the gate relies on, plus the findings, so a
// stamped artifact cannot be re-pointed at another head/diff/session or have
// its findings emptied.
function payload(a) {
    const findings = crypto.createHash("sha256").update(JSON.stringify(a.findings ?? null)).digest("hex");
    return Buffer.from(JSON.stringify(["cr-floor-stamp/v1", a.schema, a.head, a.base, a.diff_hash, a.session_id, a.dispatch_id, findings]));
}
const SCHEMA = 2;
const keyId = (pub) => crypto.createHash("sha256").update(pub.export({ type: "spki", format: "der" })).digest("hex").slice(0, 16);
const readArtifact = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (_) { return die(`cannot parse ${f}`); } };

// The one chokepoint every snapshot write goes through: the host path for tree
// path <name> under <dest>, or null when it could leave <dest>. Refuses (never
// normalises) any component that is empty, `.` or `..`, or holds a backslash
// or a colon (Windows splits on `\`, so `..\..\x` — one legal component on
// POSIX git — climbs out there; `C:x` is drive-relative), on every platform;
// then requires the resolved path to stay inside <dest>. <p> is path.win32 in
// the unit test.
export function snapshotPath(dest, name, p = path) {
    if (name.split("/").some((c) => c === "" || c === "." || c === ".." || c.includes("\\") || c.includes(":"))) return null;
    const file = p.resolve(dest, name), rel = p.relative(p.resolve(dest), file);
    // rel is `..` or `..<sep>…` only when the path climbs out; `..config` is an
    // ordinary in-tree name (the component check above already refused a literal `..`).
    return rel === "" || rel === ".." || rel.startsWith(".." + p.sep) || p.isAbsolute(rel) ? null : file;
}

// Blobs are read through `git cat-file --batch` in BOUNDED batches: consecutive
// blobs are grouped until their listed sizes (from ls-tree -l) reach <limit>, and
// each batch's buffer is capped at its own size plus record headers. Resident
// memory is one batch, not the whole tree. A blob larger than <limit> gets a
// batch of its own. fn(entry, body) runs per verified record; any mismatch
// throws (the caller fails closed).
// ponytail: one blob is still read into one Buffer, so a single blob beyond what
// a Buffer can hold (or than the host has memory for) still fails closed.
const BATCH_BYTES = 64 << 20, RECORD_SLACK = 128;
const catBatch = (shas, maxBuffer) => git(["cat-file", "--batch"], { input: shas.join("\n") + "\n", maxBuffer });

export function eachBlob(blobs, fn, { limit = BATCH_BYTES, cat = catBatch } = {}) {
    for (let i = 0; i < blobs.length;) {
        let j = i, bytes = 0;
        do bytes += blobs[j++].size; while (j < blobs.length && bytes + blobs[j].size <= limit);
        const batch = blobs.slice(i, j);
        i = j;
        const res = cat(batch.map((e) => e.sha), bytes + batch.length * RECORD_SLACK + 1024);
        if (res.status !== 0) throw new Error(`git cat-file --batch failed: ${res.error?.message ?? res.stderr}`);
        const out = res.stdout;
        let pos = 0;
        for (const e of batch) {
            const nl = out.indexOf(0x0a, pos);
            if (nl < 0) throw new Error(`cat-file output truncated at ${e.sha}`);
            const fields = out.subarray(pos, nl).toString().split(" ");
            const [sha, type, size] = fields;
            if (fields.length !== 3 || sha !== e.sha || type !== "blob") throw new Error(`unexpected cat-file record for ${e.sha}: ${sha} ${type}`);
            if (Number(size) !== e.size) throw new Error(`cat-file size ${size} != listed ${e.size} at ${e.sha}`);
            // the body must be followed by its own "\n": a short body would otherwise absorb it
            const bodyStart = nl + 1, bodyEnd = bodyStart + e.size;
            if (bodyEnd >= out.length || out[bodyEnd] !== 0x0a) throw new Error(`cat-file output truncated at ${e.sha}`);
            fn(e, out.subarray(bodyStart, bodyEnd));
            pos = bodyEnd + 1;
        }
        if (pos !== out.length) throw new Error("unexpected trailing cat-file output");
    }
}

function snapshot(head, dest) {
    // -l adds each blob's size (`-` for a commit entry): the batches are sized from it.
    const ls = git(["ls-tree", "-r", "-l", "-z", "--full-tree", head]);
    if (ls.status !== 0) die(`git ls-tree ${head} failed: ${ls.stderr}`);
    const listing = ls.stdout.toString("utf8");
    // A non-UTF-8 path would decode lossily (U+FFFD) and be renamed or collide
    // in the snapshot: refuse rather than review an altered tree.
    if (!Buffer.from(listing, "utf8").equals(ls.stdout)) die(`${head} has a path that is not valid UTF-8; the snapshot cannot reproduce it`);
    const entries = [];
    for (const rec of listing.split("\0")) {
        if (!rec) continue;
        const tab = rec.indexOf("\t");
        const m = /^(\d+) (\w+) ([0-9a-f]+) +(\d+|-)$/.exec(rec.slice(0, tab));
        if (!m) die(`unexpected ls-tree record in ${head}: ${JSON.stringify(rec.slice(0, tab))}`);
        const name = rec.slice(tab + 1);
        const file = snapshotPath(dest, name);
        if (file === null) die(`${head} has a path that could leave the snapshot: ${JSON.stringify(name)}`);
        entries.push({ mode: m[1], type: m[2], sha: m[3], size: m[4] === "-" ? 0 : Number(m[4]), file });
    }
    const blobs = entries.filter((e) => e.type === "blob");
    // Raw object bytes, no attribute applied.
    try {
        eachBlob(blobs, (e, body) => {
            // A symlink blob holds its target. Written as an inert file holding
            // that target (as git does with core.symlinks=false), never a real
            // link: a committed link could point the reviewer outside the
            // snapshot, at host files or the key dir. Every file is created
            // exclusively (wx): two tree paths that land on one host path (a
            // case-insensitive or normalising filesystem, a Windows backslash)
            // refuse the snapshot instead of one silently replacing the other.
            try {
                fs.mkdirSync(path.dirname(e.file), { recursive: true });
                fs.writeFileSync(e.file, body, { mode: e.mode === "100755" ? 0o755 : 0o644, flag: "wx" });
            } catch (err) {
                die(`${e.file} collides with another path in ${head} on this filesystem (${err.code}); the snapshot cannot reproduce the tree`);
            }
        });
    } catch (err) { die(err.message); }
    for (const e of entries) if (e.type === "commit") {
        try { fs.mkdirSync(e.file, { recursive: true }); } catch (err) { die(`${e.file} collides with another path in ${head} on this filesystem (${err.code})`); }
    }
}

// init-key — the OPERATOR's one-time provisioning step (never run by a leg or
// a test against the real key dir). Idempotent: an existing key pair is left
// untouched, never overwritten.
function initKey() {
    const dir = keyDir(), privF = path.join(dir, "signing.key"), pubF = path.join(dir, "signing.pub");
    if (fs.existsSync(privF) || fs.existsSync(pubF)) {
        if (!(fs.existsSync(privF) && fs.existsSync(pubF))) die(`${dir} holds only half a key pair; inspect it by hand (nothing overwritten)`);
        keyPrivate(privF);
        process.stdout.write(`claude-floor: key pair already present in ${dir} (unchanged)\n`);
        return;
    }
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dir, 0o700);
    const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
    // wx: never clobber a key a concurrent init just created.
    fs.writeFileSync(privF, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600, flag: "wx" });
    fs.writeFileSync(pubF, publicKey.export({ type: "spki", format: "pem" }), { mode: 0o644, flag: "wx" });
    process.stdout.write(`claude-floor: created the floor signing key pair in ${dir} (key ${keyId(publicKey)})\n`);
}

// A private key other users can read fails CLOSED: they could sign with it.
// ponytail: POSIX mode bits only; on Windows the ACL is not checked.
function keyPrivate(f) {
    if (process.platform !== "win32" && (fs.statSync(f).mode & 0o077) !== 0) die(`${f} is readable by other users; restrict it: chmod 600 ${f}`);
}

// A missing key fails CLOSED and names the init command — never an unsigned artifact.
function loadKey(name) {
    const f = path.join(keyDir(), name);
    if (name === "signing.key" && fs.existsSync(f)) keyPrivate(f);
    try {
        const pem = fs.readFileSync(f);
        return name === "signing.key" ? crypto.createPrivateKey(pem) : crypto.createPublicKey(pem);
    } catch (_) {
        return die(`no floor signing key at ${f}. The operator provisions it once: node scripts/cr/claude-floor.mjs init-key`);
    }
}

function keyCheck() {
    const priv = loadKey("signing.key");
    if (keyId(crypto.createPublicKey(priv)) !== keyId(loadKey("signing.pub"))) die(`signing.key and signing.pub in ${keyDir()} are not one key pair`);
}

// Stamp only an artifact its claude-headless.sh registry row backs: a
// completed, is_error=false dispatch whose id and session id are the artifact's.
function sign(file, rowFile) {
    const a = readArtifact(file), r = readArtifact(rowFile);
    if (a.schema !== SCHEMA) die(`artifact schema ${a.schema} is not ${SCHEMA}`);
    if (r.status !== "completed" || r.outcome?.is_error !== false) die(`registry row ${rowFile} is not a completed, is_error=false dispatch`);
    if (typeof r.id !== "string" || r.id === "" || r.id !== a.dispatch_id) die(`registry row id ${r.id} is not the artifact's dispatch id ${a.dispatch_id}`);
    if (typeof r.outcome.session_id !== "string" || r.outcome.session_id === "" || r.outcome.session_id !== a.session_id) die(`registry row session id is not the artifact's session id`);
    const priv = loadKey("signing.key");
    a.stamp = { alg: "ed25519", key_id: keyId(crypto.createPublicKey(priv)), sig: crypto.sign(null, payload(a), priv).toString("base64") };
    process.stdout.write(JSON.stringify(a) + "\n");
}

function verify(file) {
    const a = readArtifact(file);
    const s = a.stamp;
    if (!s || s.alg !== "ed25519" || typeof s.sig !== "string") die("floor artifact carries no ed25519 stamp (hand-written, or from before HIMMEL-3220)");
    if (a.schema !== SCHEMA) die(`floor artifact schema ${a.schema} is not ${SCHEMA}`);
    if (typeof a.dispatch_id !== "string" || a.dispatch_id.trim() === "") die("floor artifact carries no dispatch id");
    const pub = loadKey("signing.pub");
    if (s.key_id !== keyId(pub)) die(`floor stamp key ${s.key_id} is not this machine's floor signing key ${keyId(pub)}`);
    if (!crypto.verify(null, payload(a), pub, Buffer.from(s.sig, "base64"))) die("floor stamp signature does not verify (the artifact was edited after signing, or signed by another key)");
}

// Run as a CLI only; the unit test imports snapshotPath without dispatching.
const isCli = (() => { try { return import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href; } catch (_) { return false; } })();
const [cmd, ...args] = process.argv.slice(2);
if (!isCli) { /* imported */ }
else if (cmd === "snapshot" && args.length === 2) snapshot(args[0], args[1]);
else if (cmd === "sign" && args.length === 2) sign(args[0], args[1]);
else if (cmd === "verify" && args.length === 1) verify(args[0]);
else if (cmd === "key-check" && args.length === 0) keyCheck();
else if (cmd === "init-key" && args.length === 0) initKey();
else die("usage: claude-floor.mjs snapshot <head> <dest> | sign <artifact.json> <registry-row.json> | verify <artifact.json> | key-check | init-key", 2);
