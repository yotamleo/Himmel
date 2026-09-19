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
//   sign <artifact.json>    print the artifact with a `stamp` added: an ed25519
//                           signature over its provenance fields, made with the
//                           private key in the key dir.
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
// Trust boundary. The headless reviewer (tools Read/Grep/Glob/Write, cwd = the
// snapshot, no Bash) cannot reach the key dir, so it cannot mint a stamp. The
// signer signs only after reading its own claude-headless.sh registry row
// (completed, is_error=false, a session id), and the payload binds that row's
// dispatch id and session id. The verifier needs only the public key, so the
// gate holds no secret: moving the private key to another uid later changes
// the signer alone.
// ponytail: the signer runs as the authoring leg's uid, so a leg that
// DELIBERATELY reads signing.key (or replaces the key pair) can still sign a
// forged artifact. The stamp stops the hand-written artifact (correct hash,
// invented session id); it is not cryptographically out of a same-uid leg's
// reach. block-read-secrets.sh refuses Read/cat of *.key, which catches the
// accidental path, not a determined one. The real fix is a signer running as
// a SEPARATE uid that legs cannot become; the gate side needs no change then.
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const die = (msg, rc = 1) => { process.stderr.write(`claude-floor: ${msg}\n`); process.exit(rc); };
const keyDir = () => process.env.CR_FLOOR_KEY_DIR || path.join(os.homedir(), ".himmel", "cr-floor-key");
const git = (args, opts = {}) => spawnSync("git", args, { maxBuffer: 1 << 30, ...opts });

// The signed payload. Every field the gate relies on, plus the findings, so a
// stamped artifact cannot be re-pointed at another head/diff/session or have
// its findings emptied.
function payload(a) {
    const findings = crypto.createHash("sha256").update(JSON.stringify(a.findings ?? null)).digest("hex");
    return Buffer.from(JSON.stringify(["cr-floor-stamp/v1", a.head, a.base, a.diff_hash, a.session_id, a.dispatch_id, findings]));
}
const keyId = (pub) => crypto.createHash("sha256").update(pub.export({ type: "spki", format: "der" })).digest("hex").slice(0, 16);
const readArtifact = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (_) { return die(`cannot parse ${f}`); } };

function snapshot(head, dest) {
    const ls = git(["ls-tree", "-r", "-z", "--full-tree", head]);
    if (ls.status !== 0) die(`git ls-tree ${head} failed: ${ls.stderr}`);
    const entries = [];
    for (const rec of ls.stdout.toString("utf8").split("\0")) {
        if (!rec) continue;
        const tab = rec.indexOf("\t");
        const [mode, type, sha] = rec.slice(0, tab).split(" ");
        entries.push({ mode, type, sha, file: path.join(dest, rec.slice(tab + 1)) });
    }
    const blobs = entries.filter((e) => e.type === "blob");
    // One `cat-file --batch` stream: raw object bytes, no attribute applied.
    const cat = git(["cat-file", "--batch"], { input: blobs.map((e) => e.sha).join("\n") + "\n" });
    if (cat.status !== 0) die(`git cat-file --batch failed: ${cat.stderr}`);
    const out = cat.stdout;
    let pos = 0;
    for (const e of blobs) {
        const nl = out.indexOf(0x0a, pos);
        const [sha, type, size] = out.subarray(pos, nl).toString().split(" ");
        if (nl < 0 || sha !== e.sha || type !== "blob") die(`unexpected cat-file record for ${e.sha}: ${sha} ${type}`);
        if (nl + 1 + Number(size) > out.length) die(`cat-file output truncated at ${e.sha}`);
        const body = out.subarray(nl + 1, nl + 1 + Number(size));
        pos = nl + 1 + Number(size) + 1;
        fs.mkdirSync(path.dirname(e.file), { recursive: true });
        if (e.mode === "120000") {
            // A symlink blob holds its target; where symlinks are unavailable
            // write the target as a file, as git does with core.symlinks=false.
            try { fs.symlinkSync(body.toString(), e.file); } catch (_) { fs.writeFileSync(e.file, body); }
        } else {
            fs.writeFileSync(e.file, body, { mode: e.mode === "100755" ? 0o755 : 0o644 });
        }
    }
    for (const e of entries) if (e.type === "commit") fs.mkdirSync(e.file, { recursive: true });
}

// init-key — the OPERATOR's one-time provisioning step (never run by a leg or
// a test against the real key dir). Idempotent: an existing key pair is left
// untouched, never overwritten.
function initKey() {
    const dir = keyDir(), privF = path.join(dir, "signing.key"), pubF = path.join(dir, "signing.pub");
    if (fs.existsSync(privF) || fs.existsSync(pubF)) {
        if (!(fs.existsSync(privF) && fs.existsSync(pubF))) die(`${dir} holds only half a key pair; inspect it by hand (nothing overwritten)`);
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

// A missing key fails CLOSED and names the init command — never an unsigned artifact.
function loadKey(name) {
    const f = path.join(keyDir(), name);
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

function sign(file) {
    const a = readArtifact(file);
    const priv = loadKey("signing.key");
    a.stamp = { alg: "ed25519", key_id: keyId(crypto.createPublicKey(priv)), sig: crypto.sign(null, payload(a), priv).toString("base64") };
    process.stdout.write(JSON.stringify(a) + "\n");
}

function verify(file) {
    const a = readArtifact(file);
    const s = a.stamp;
    if (!s || s.alg !== "ed25519" || typeof s.sig !== "string") die("floor artifact carries no ed25519 stamp (hand-written, or from before HIMMEL-3220)");
    if (typeof a.dispatch_id !== "string" || a.dispatch_id.trim() === "") die("floor artifact carries no dispatch id");
    const pub = loadKey("signing.pub");
    if (s.key_id !== keyId(pub)) die(`floor stamp key ${s.key_id} is not this machine's floor signing key ${keyId(pub)}`);
    if (!crypto.verify(null, payload(a), pub, Buffer.from(s.sig, "base64"))) die("floor stamp signature does not verify (the artifact was edited after signing, or signed by another key)");
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === "snapshot" && args.length === 2) snapshot(args[0], args[1]);
else if (cmd === "sign" && args.length === 1) sign(args[0]);
else if (cmd === "verify" && args.length === 1) verify(args[0]);
else if (cmd === "key-check" && args.length === 0) keyCheck();
else if (cmd === "init-key" && args.length === 0) initKey();
else die("usage: claude-floor.mjs snapshot <head> <dest> | sign <artifact.json> | verify <artifact.json> | key-check | init-key", 2);
