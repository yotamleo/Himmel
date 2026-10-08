// HIMMEL-4985: secret-free roster lookup for the API launcher. Prints key=value
// lines for HIMMEL_API_ACCOUNT from the credit config; never reads a key. Every
// value is an id-validated token or an absolute path, so the shell may read it.
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const { configuredAccount } = await import(pathToFileURL(`${HERE}/../lib/api-credit-state.mjs`).href);
const row = configuredAccount(process.env);
if (row.verdict) {
  console.log(`reason=${row.reason}`);
  process.exit(1);
}
console.log(`account=${row.account}`);
console.log(`organization_id=${row.organization_id}`);
console.log(`cycle_id=${row.cycle_id}`);
console.log(`key_id=${row.key_id ?? ''}`);
console.log(`state_dir=${dirname(row.ledger_path)}`);
