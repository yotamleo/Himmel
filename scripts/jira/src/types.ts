import type { ADFDocument } from './adf-render.js';

export interface JiraIssue {
  key: string;
  fields: {
    summary: string;
    status: { name: string };
    issuetype: { name: string };
    parent?: { key: string };
    assignee?: { displayName: string } | null;
    description?: ADFDocument | null;
  };
}

export interface JiraTransition {
  id: string;
  name: string;
}

export interface JiraSearchResult {
  issues: JiraIssue[];
  total: number;
}

export interface CreateIssueResponse {
  key: string;
  id: string;
}
