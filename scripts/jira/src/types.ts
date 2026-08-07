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
  /**
   * Token-based pagination cursor (Jira Cloud `/search/jql`). Absent on the
   * last page. The endpoint caps `maxResults` at 100 server-side regardless of
   * what is asked for, so anything above that MUST be paged (HIMMEL-1602).
   */
  nextPageToken?: string;
}

export interface CreateIssueResponse {
  key: string;
  id: string;
}
