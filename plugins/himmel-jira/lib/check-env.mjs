#!/usr/bin/env node
import { ensureEnvKeys } from './init-flow.mjs';
import { envFilePath } from './jira-fetch.mjs';

const envFile = envFilePath();
const missing = ensureEnvKeys(envFile, ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_BASE_URL']);
console.log(missing.length ? `missing: ${missing.join(',')}` : 'all-set');
