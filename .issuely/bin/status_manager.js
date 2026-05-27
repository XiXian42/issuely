#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const ISSUE_RE = /^(\d{3}|\d{6})-(.+)\.md$/;
// 时间戳兼容旧分钟级 (YYYY-MM-DD HH:MM) 与新秒级 (YYYY-MM-DD HH:MM:SS)。
const STATUS_RE = /^\[(\d{3}|\d{6})\]\s+([^\[]+?)\s+\[(.+?)\]\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?)\s*$/;

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token.startsWith("--")) {
      args._.push(token);
      continue;
    }
    const eq = token.indexOf("=");
    if (eq >= 0) {
      args[token.slice(2, eq)] = token.slice(eq + 1);
      continue;
    }
    const key = token.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) {
      args[key] = true;
    } else {
      args[key] = next;
      i++;
    }
  }
  return args;
}

function nowLocalSecond(date = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}
// Backwards-compatible alias retained for legacy require()s.
const nowLocalMinute = nowLocalSecond;

function readIssues(issuesDir) {
  const entries = fs.existsSync(issuesDir) ? fs.readdirSync(issuesDir) : [];
  const issues = [];
  const invalid = [];
  for (const name of entries) {
    if (name.startsWith(".")) continue;
    const match = ISSUE_RE.exec(name);
    if (!match) {
      if (name.endsWith(".md")) invalid.push(name);
      continue;
    }
    issues.push({ number: match[1], slug: match[2], file: name, path: path.join(issuesDir, name) });
  }
  issues.sort((a, b) => Number(a.number) - Number(b.number) || a.slug.localeCompare(b.slug));
  return { issues, invalid };
}

function emptyState(issue) {
  return {
    issue,
    begin: false,
    done: false,
    files: null,
    reviewBegin: false,
    reviewed: false,
    blocked: false,
    blockedMessage: null,
    resolvedBy: null,
    resolvedByMessage: null,
    reviewFixed: [],
    raw: []
  };
}
function parseResolvedByPayload(payload) {
  const text = String(payload || "").trim();
  const match = /^(\d{3}|\d{6})(?:\s*;\s*(.*)|\s+(.*))?$/.exec(text);
  if (!match) return { number: text, message: "" };
  return { number: match[1], message: (match[2] || match[3] || "").trim() };
}

function parseStatus(statusPath, issues) {
  const byNumber = new Map(issues.map((issue) => [issue.number, emptyState(issue)]));
  const records = [];
  const invalidLines = [];
  const unknownIssueRecords = [];
  if (!fs.existsSync(statusPath)) {
    return { byNumber, records, invalidLines, unknownIssueRecords, exists: false };
  }
  const text = fs.readFileSync(statusPath, "utf8");
  const lines = text.split(/\r?\n/);
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (!line.trim() || !line.trim().startsWith("[")) continue;
    const match = STATUS_RE.exec(line);
    if (!match) {
      invalidLines.push({ line: index + 1, text: line });
      continue;
    }
    const [, number, slugRaw, stateRaw, time] = match;
    const slug = slugRaw.trim();
    const state = stateRaw.trim();
    const record = { number, slug, state, time, line: index + 1, text: line };
    records.push(record);
    const entry = byNumber.get(number);
    if (!entry) {
      unknownIssueRecords.push(record);
      continue;
    }
    entry.raw.push(record);
    if (state === "begin") entry.begin = true;
    else if (state === "done") {
      entry.done = true;
      entry.blocked = false;
      entry.blockedMessage = null;
      entry.resolvedBy = null;
      entry.resolvedByMessage = null;
    } else if (state.startsWith("files:")) entry.files = state.slice("files:".length).trim();
    else if (state === "review-begin") entry.reviewBegin = true;
    else if (state === "reviewed") entry.reviewed = true;
    else if (state.startsWith("review-fixed:")) entry.reviewFixed.push(state.slice("review-fixed:".length).trim());
    else if (state.startsWith("blocked:")) {
      entry.blocked = true;
      entry.blockedMessage = state.slice("blocked:".length).trim();
    } else if (state.startsWith("unblocked:")) {
      entry.blocked = false;
      entry.blockedMessage = null;
    } else if (state.startsWith("resolved-by:")) {
      const resolvedBy = parseResolvedByPayload(state.slice("resolved-by:".length));
      entry.resolvedBy = resolvedBy.number;
      entry.resolvedByMessage = resolvedBy.message;
      entry.blocked = false;
      entry.blockedMessage = null;
    }
  }
  return { byNumber, records, invalidLines, unknownIssueRecords, exists: true };
}

function loadState(options = {}) {
  const root = options.root || process.cwd();
  
  // 100% 对齐：所有数据都在 workspaceDir 下。
  // status.md, issues/, dev.done, review.done 全功能落盘在 workspaceDir 中！
  const workspaceDir = options.workspaceDir ? path.resolve(root, options.workspaceDir) : null;
  if (!workspaceDir && !options.status) {
    throw new Error("--workspace-dir is required unless --status is provided explicitly");
  }
  
  const issuesDir = options.issuesDir ? path.resolve(root, options.issuesDir) : path.join(workspaceDir, "issues");
  const statusPath = options.status ? path.resolve(root, options.status) : path.join(workspaceDir, "status.md");
  const statusDir = path.dirname(statusPath);
  const devDonePath = options.devDone ? path.resolve(root, options.devDone) : path.join(workspaceDir || statusDir, "dev.done");
  const reviewDonePath = options.reviewDone ? path.resolve(root, options.reviewDone) : path.join(workspaceDir || statusDir, "review.done");
  
  const { issues, invalid } = readIssues(issuesDir);
  const status = parseStatus(statusPath, issues);
  
  return {
    root,
    issuesDir,
    statusPath,
    devDonePath,
    reviewDonePath,
    workspaceDir,
    issues,
    invalidIssueFiles: invalid,
    status,
    devDone: fs.existsSync(devDonePath),
    reviewDone: fs.existsSync(reviewDonePath)
  };
}

function issueOut(issue, issues) {
  if (!issue) return null;
  return { number: issue.number, slug: issue.slug, file: issue.file, isLast: issues.length > 0 && issue.file === issues[issues.length - 1].file };
}
function isIssueClosed(entry) {
  return entry.done || Boolean(entry.resolvedBy);
}

function blockedEntries(state) {
  return state.issues
    .map((issue) => state.status.byNumber.get(issue.number))
    .filter((entry) => entry && entry.blocked && !isIssueClosed(entry));
}

function detectGaps(state) {
  const gaps = [];
  for (let i = 0; i < state.issues.length; i++) {
    const issue = state.issues[i];
    const entry = state.status.byNumber.get(issue.number);
    if (isIssueClosed(entry) || entry.blocked) continue;
    const laterDone = state.issues.slice(i + 1).find((later) => isIssueClosed(state.status.byNumber.get(later.number)));
    if (!laterDone) continue;
    gaps.push({
      issue: issueOut(issue, state.issues),
      laterIssue: issueOut(laterDone, state.issues),
      reason: "earlier issue has no done/resolved-by/blocked record while a later issue is done/resolved-by"
    });
  }
  return gaps;
}

function alternateAfterFirstGap(state, gaps) {
  if (!gaps.length) return null;
  const firstLaterIndex = state.issues.findIndex((issue) => issue.file === gaps[0].laterIssue.file);
  if (firstLaterIndex < 0) return null;
  const alternate = state.issues.slice(firstLaterIndex + 1).find((issue) => {
    const entry = state.status.byNumber.get(issue.number);
    return !isIssueClosed(entry) && !entry.blocked;
  });
  return issueOut(alternate, state.issues);
}

function withGapInfo(state, plan) {
  const gaps = detectGaps(state);
  if (gaps.length === 0) return plan;
  return {
    ...plan,
    gap: gaps[0],
    gapCount: gaps.length,
    alternateIssue: alternateAfterFirstGap(state, gaps)
  };
}

function firstState(state, predicate) {
  for (const issue of state.issues) {
    const entry = state.status.byNumber.get(issue.number);
    if (predicate(entry, issue)) return entry;
  }
  return null;
}

function allIssuesDone(state) {
  return state.issues.length > 0 && state.issues.every((issue) => isIssueClosed(state.status.byNumber.get(issue.number)));
}

function allDoneReviewed(state) {
  return state.issues
    .filter((issue) => state.status.byNumber.get(issue.number).done)
    .every((issue) => state.status.byNumber.get(issue.number).reviewed);
}

function nextDev(state) {
  const interrupted = firstState(state, (entry) => entry.begin && !isIssueClosed(entry) && !entry.blocked);
  if (interrupted) {
    return withGapInfo(state, { role: "dev", action: "continue-dev", issue: issueOut(interrupted.issue, state.issues), reason: "begin exists but done/blocked is missing" });
  }

  if (allIssuesDone(state)) {
    return withGapInfo(state, { role: "dev", action: state.devDone ? "idle" : "touch-dev-done", issue: null, reason: state.devDone ? "all issues closed and dev.done already exists" : "all issues have done or resolved-by records" });
  }

  const doneNotReviewStarted = firstState(state, (entry) => entry.done && !entry.reviewBegin && !entry.reviewed);
  if (doneNotReviewStarted) {
    return withGapInfo(state, { role: "dev", action: "wait-review", issue: issueOut(doneNotReviewStarted.issue, state.issues), reason: "done exists but review has not started" });
  }

  const reviewInProgress = firstState(state, (entry) => entry.reviewBegin && !entry.reviewed);
  if (reviewInProgress) {
    return withGapInfo(state, { role: "dev", action: "wait-reviewing", issue: issueOut(reviewInProgress.issue, state.issues), reason: "review-begin exists but reviewed is missing" });
  }

  const next = firstState(state, (entry) => !isIssueClosed(entry) && !entry.blocked);
  if (next) {
    return withGapInfo(state, { role: "dev", action: "start", issue: issueOut(next.issue, state.issues), reason: "first issue without done/resolved-by or blocked" });
  }

  const blocked = blockedEntries(state)[0];
  if (blocked) {
    return withGapInfo(state, {
      role: "dev",
      action: "resolve-blocked",
      issue: issueOut(blocked.issue, state.issues),
      blockedMessage: blocked.blockedMessage,
      reason: "no startable issue; blocked issue needs unblocked/resolved-by triage"
    });
  }

  return withGapInfo(state, { role: "dev", action: "idle", issue: null, reason: "no startable issue" });
}

function nextReview(state) {
  const interrupted = firstState(state, (entry) => entry.reviewBegin && !entry.reviewed);
  if (interrupted) {
    return withGapInfo(state, { role: "review", action: "continue-review", issue: issueOut(interrupted.issue, state.issues), files: interrupted.files, reason: "review-begin exists but reviewed is missing" });
  }

  const doneNotReviewed = firstState(state, (entry) => entry.done && !entry.reviewed);
  if (doneNotReviewed) {
    return withGapInfo(state, { role: "review", action: "start-review", issue: issueOut(doneNotReviewed.issue, state.issues), files: doneNotReviewed.files, reason: "done exists but reviewed is missing" });
  }

  const devInProgress = firstState(state, (entry) => entry.begin && !isIssueClosed(entry) && !entry.blocked);
  if (devInProgress) {
    return withGapInfo(state, { role: "review", action: "wait-dev", issue: issueOut(devInProgress.issue, state.issues), reason: "begin exists but done/blocked is missing" });
  }

  if (state.devDone && allIssuesDone(state) && allDoneReviewed(state)) {
    return withGapInfo(state, { role: "review", action: state.reviewDone ? "idle" : "touch-review-done", issue: null, reason: state.reviewDone ? "all reviews done and review.done already exists" : "dev.done exists, every issue is done or resolved-by, and every done issue is reviewed" });
  }

  return withGapInfo(state, { role: "review", action: "idle", issue: null, reason: "no issue ready for review" });
}

function nextPlan(options) {
  const state = loadState(options);
  const role = options.role;
  if (role === "dev") return nextDev(state);
  if (role === "review") return nextReview(state);
  throw new Error("--role must be dev or review");
}

function ensureStatusFile(statusPath) {
  fs.mkdirSync(path.dirname(statusPath), { recursive: true });
  if (!fs.existsSync(statusPath)) fs.writeFileSync(statusPath, "# 进度记录\n", "utf8");
}

function resolveIssue(state, issueArg) {
  if (!issueArg) throw new Error("--issue is required");
  const normalized = String(issueArg).replace(/\.md$/, "");
  const numberCandidates = /^\d{1,6}$/.test(normalized)
    ? new Set([normalized, normalized.padStart(6, "0"), normalized.padStart(3, "0")])
    : new Set();
  const found = state.issues.find((issue) => numberCandidates.has(issue.number) || `${issue.number}-${issue.slug}` === normalized || issue.file === issueArg);
  if (!found) throw new Error(`unknown issue: ${issueArg}`);
  return found;
}

// 原子追加一行或多行：单次 appendFileSync 保证 N 行之间不会被其它进程交错。
function appendLines(statusPath, lines) {
  ensureStatusFile(statusPath);
  const current = fs.readFileSync(statusPath, "utf8");
  const prefix = current.endsWith("\n") || current.length === 0 ? "" : "\n";
  fs.appendFileSync(statusPath, prefix + lines.join("\n") + "\n", "utf8");
}

function appendLine(statusPath, line) {
  appendLines(statusPath, [line]);
}

function toPosixPath(value) {
  return String(value || "").replace(/\\/g, "/").replace(/^\.\//, "");
}

function normalizeStatusFilePath(filePath, state) {
  let value = toPosixPath(filePath).trim();
  if (!value) return value;

  const workspaceAbs = toPosixPath(state.workspaceDir || path.join(state.root, "workspace"));
  let workspaceRel = toPosixPath(path.relative(state.root, workspaceAbs)) || path.basename(workspaceAbs) || "workspace";
  if (workspaceRel.startsWith("../") || workspaceRel === ".." || path.isAbsolute(workspaceRel)) {
    workspaceRel = path.basename(workspaceAbs) || "workspace";
  }
  const rootAbs = toPosixPath(state.root);

  if (value.startsWith(`${rootAbs}/`)) value = value.slice(rootAbs.length + 1);
  if (value === workspaceAbs) value = workspaceRel;
  else if (value.startsWith(`${workspaceAbs}/`)) value = `${workspaceRel}/${value.slice(workspaceAbs.length + 1)}`;

  if (value === workspaceRel || value.startsWith(`${workspaceRel}/`)) return value;
  if (value.startsWith(".issuely/") || value === "config.json" || value.startsWith("config/")) return value;
  if (path.isAbsolute(value)) throw new Error(`status files path must be relative to repository root: ${value}`);
  return `${workspaceRel}/${value}`;
}

function normalizeStatusFiles(files, state) {
  if (!files) return files;
  return String(files)
    .split(",")
    .map((raw) => {
      const item = raw.trim();
      if (!item) return "";
      const match = /^(.*?)(\((?:new|mod|del)\))$/.exec(item);
      if (!match) return normalizeStatusFilePath(item, state);
      return `${normalizeStatusFilePath(match[1], state)}${match[2]}`;
    })
    .filter(Boolean)
    .join(", ");
}

function sanitizeStatusPayload(value) {
  return String(value || "")
    .replace(/[\r\n]+/g, " ")
    .replace(/\[/g, "(")
    .replace(/\]/g, ")")
    .trim();
}

function appendStatus(kind, options) {
  const state = loadState(options);
  const issue = resolveIssue(state, options.issue);
  const entry = state.status.byNumber.get(issue.number);
  const stamp = options.time || nowLocalSecond();
  const base = `[${issue.number}] ${issue.slug}`;

  function skipped(reason) {
    return { action: "append", kind, issue: issueOut(issue, state.issues), skipped: true, reason };
  }
  function appended(line) {
    appendLine(state.statusPath, line);
    return { action: "append", kind, issue: issueOut(issue, state.issues), skipped: false, line };
  }

  if (kind === "begin") {
    if (entry.begin) return skipped("begin already exists");
    if (isIssueClosed(entry)) return skipped("issue already closed");
    return appended(`${base} [begin] ${stamp}`);
  }
  if (kind === "done") {
    if (!entry.begin) throw new Error("cannot append done before begin");
    if (entry.done) return skipped("done already exists");
    if (entry.resolvedBy) return skipped("resolved-by already exists");
    if (!options.files) throw new Error("--files is required for done");
    const normalizedFiles = sanitizeStatusPayload(normalizeStatusFiles(options.files, state));
    const doneLine = `${base} [done] ${stamp}`;
    const filesLine = `${base} [files: ${normalizedFiles}] ${stamp}`;
    appendLines(state.statusPath, [doneLine, filesLine]);
    return { action: "append", kind, issue: issueOut(issue, state.issues), skipped: false, lines: [doneLine, filesLine] };
  }
  if (kind === "review-begin") {
    if (!entry.done) throw new Error("cannot append review-begin before done");
    if (entry.reviewBegin) return skipped("review-begin already exists");
    return appended(`${base} [review-begin] ${stamp}`);
  }
  if (kind === "reviewed") {
    if (!entry.done) throw new Error("cannot append reviewed before done");
    if (entry.reviewed) return skipped("reviewed already exists");
    const lines = [];
    if (options.message) {
      const message = sanitizeStatusPayload(options.message);
      if (message) {
        const files = options.files ? `; files: ${sanitizeStatusPayload(normalizeStatusFiles(options.files, state))}` : "";
        lines.push(`${base} [review-fixed: ${message}${files}] ${stamp}`);
      }
    }
    lines.push(`${base} [reviewed] ${stamp}`);
    appendLines(state.statusPath, lines);
    return { action: "append", kind, issue: issueOut(issue, state.issues), skipped: false, lines };
  }
  if (kind === "review-fixed") {
    if (!options.message) throw new Error("--message is required for review-fixed");
    const message = sanitizeStatusPayload(options.message);
    if (!message) throw new Error("--message must contain a non-empty status payload");
    const files = options.files ? `; files: ${sanitizeStatusPayload(normalizeStatusFiles(options.files, state))}` : "";
    return appended(`${base} [review-fixed: ${message}${files}] ${stamp}`);
  }
  if (kind === "blocked") {
    const message = sanitizeStatusPayload(options.message);
    if (!message) throw new Error("--message must contain a non-empty status payload");
    if (isIssueClosed(entry)) return skipped("issue already closed");
    if (entry.blocked && entry.blockedMessage === message) return skipped("blocked already exists");
    return appended(`${base} [blocked: ${message}] ${stamp}`);
  }
  if (kind === "unblocked") {
    const message = sanitizeStatusPayload(options.message);
    if (!message) throw new Error("--message is required for unblocked");
    if (isIssueClosed(entry)) return skipped("issue already closed");
    if (!entry.blocked) return skipped("issue is not blocked");
    return appended(`${base} [unblocked: ${message}] ${stamp}`);
  }
  if (kind === "resolved-by") {
    if (!options.resolvedBy) throw new Error("--resolved-by is required");
    const resolver = resolveIssue(state, options.resolvedBy);
    const resolverEntry = state.status.byNumber.get(resolver.number);
    const message = sanitizeStatusPayload(options.message);
    if (!message) throw new Error("--message is required for resolved-by");
    if (issue.number === resolver.number) throw new Error("resolved-by cannot reference the same issue");
    if (entry.done) return skipped("done already exists");
    if (entry.resolvedBy) return skipped("resolved-by already exists");
    if (!entry.blocked) throw new Error("cannot append resolved-by unless issue is blocked");
    if (!resolverEntry.done || !resolverEntry.reviewed) throw new Error("resolved-by target must be done and reviewed");
    return appended(`${base} [resolved-by: ${resolver.number}; ${message}] ${stamp}`);
  }
  throw new Error(`unknown append kind: ${kind}`);
}
function relativeWorkspacePath(state) {
  const workspaceAbs = toPosixPath(state.workspaceDir || path.join(state.root, "workspace"));
  const rel = toPosixPath(path.relative(state.root, workspaceAbs));
  if (!rel || rel.startsWith("../") || rel === ".." || path.isAbsolute(rel)) {
    return path.basename(workspaceAbs) || "workspace";
  }
  return rel;
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function detectForbiddenDocOutputs(state) {
  const problems = [];
  const workspaceRel = escapeRegExp(relativeWorkspacePath(state));
  const outputPathRe = new RegExp("(?:^|[\\s,`])(" + workspaceRel + "/docs/([^\\s,`)]+\\.md))\\((new|mod|del)\\)", "g");
  for (const issue of state.issues) {
    const text = fs.readFileSync(issue.path, "utf8");
    for (const match of text.matchAll(outputPathRe)) {
      const filePath = match[1];
      const docName = match[2];
      if (/^_tracking-[^/]+\.md$/.test(docName)) continue;
      problems.push({
        type: "forbidden-doc-output",
        issue: issue.file,
        file: filePath,
        message: "docs files are frozen; mutable execution ledgers must use docs/_tracking-*.md"
      });
    }
  }
  return problems;
}

function validateState(options = {}) {
  const state = loadState(options);
  const problems = [];
  const seenNumbers = new Set();
  const seenNumericNumbers = new Map();

  for (const name of state.invalidIssueFiles) {
    problems.push({ type: "invalid-issue-file", file: name, message: "issue file must match NNNNNN-slug.md (legacy NNN is still readable)" });
  }
  for (const issue of state.issues) {
    if (seenNumbers.has(issue.number)) problems.push({ type: "duplicate-issue-number", issue: issue.file, message: `duplicate issue number ${issue.number}` });
    seenNumbers.add(issue.number);
    const numeric = String(Number(issue.number));
    const previous = seenNumericNumbers.get(numeric);
    if (previous) problems.push({ type: "duplicate-issue-number", issue: issue.file, message: `duplicate numeric issue number ${issue.number}; conflicts with ${previous}` });
    else seenNumericNumbers.set(numeric, issue.file);
  }
  problems.push(...detectForbiddenDocOutputs(state));
  for (const line of state.status.invalidLines) {
    problems.push({ type: "invalid-status-line", line: line.line, text: line.text, message: "status line is not parseable" });
  }
  for (const record of state.status.unknownIssueRecords) {
    problems.push({ type: "unknown-issue-in-status", line: record.line, issue: record.number, message: "status references an issue file that does not exist" });
  }
  for (const issue of state.issues) {
    const entry = state.status.byNumber.get(issue.number);
    for (const record of entry.raw) {
      if (record.slug !== issue.slug) problems.push({ type: "slug-mismatch", issue: issue.file, line: record.line, message: `status slug ${record.slug} does not match ${issue.slug}` });
    }
    if (entry.begin && !isIssueClosed(entry) && !entry.blocked) problems.push({ type: "interrupted-dev", issue: issue.file, message: "begin exists but done/resolved-by/blocked is missing" });
    if (entry.reviewBegin && !entry.reviewed) problems.push({ type: "interrupted-review", issue: issue.file, message: "review-begin exists but reviewed is missing" });
    if (entry.done && !entry.files) problems.push({ type: "missing-files", issue: issue.file, message: "done exists but files line is missing" });
    if (entry.blocked && isIssueClosed(entry)) problems.push({ type: "blocked-closed-issue", issue: issue.file, message: "closed issue has a later blocked record" });
    if (entry.resolvedBy) {
      const resolver = state.status.byNumber.get(entry.resolvedBy);
      if (entry.done) problems.push({ type: "done-and-resolved-by", issue: issue.file, message: "issue has both done and resolved-by records" });
      if (entry.reviewBegin || entry.reviewed) problems.push({ type: "resolved-by-review-record", issue: issue.file, message: "resolved-by issue must not have review records of its own" });
      if (entry.resolvedBy === issue.number) problems.push({ type: "self-resolved-by", issue: issue.file, message: "resolved-by cannot reference the same issue" });
      else if (!resolver) problems.push({ type: "unknown-resolved-by", issue: issue.file, resolvedBy: entry.resolvedBy, message: "resolved-by references an issue that does not exist" });
      else if (!resolver.done || !resolver.reviewed) problems.push({ type: "unreviewed-resolved-by", issue: issue.file, resolvedBy: entry.resolvedBy, message: "resolved-by target must be done and reviewed" });
    }
  }

  let foundMissing = null;
  for (const issue of state.issues) {
    const entry = state.status.byNumber.get(issue.number);
    if (!isIssueClosed(entry) && !entry.blocked && !foundMissing) foundMissing = issue;
    if (foundMissing && isIssueClosed(entry)) {
      problems.push({ type: "gap", issue: foundMissing.file, laterIssue: issue.file, message: "later issue is done/resolved-by while an earlier issue has no done/resolved-by/blocked record" });
      break;
    }
  }

  if (state.devDone && !allIssuesDone(state)) {
    problems.push({ type: "premature-dev-done", message: "dev.done exists but not every issue is done or resolved-by" });
  }
  if (state.reviewDone && (!state.devDone || !allIssuesDone(state) || !allDoneReviewed(state))) {
    problems.push({ type: "premature-review-done", message: "review.done exists before valid dev.done, before every issue is done or resolved-by, or before every done issue is reviewed" });
  }

  return { ok: problems.length === 0, problems, gaps: detectGaps(state), blocked: blockedSummaryFromState(state).blocked, counts: { issues: state.issues.length, statusRecords: state.status.records.length }, devDone: state.devDone, reviewDone: state.reviewDone };
}
function issuePreflight(options = {}) {
  const state = loadState(options);
  const problems = [];

  if (!fs.existsSync(state.issuesDir)) {
    problems.push({ type: "missing-issues-dir", file: path.basename(state.issuesDir), message: "issues directory does not exist" });
  }
  for (const name of state.invalidIssueFiles) {
    problems.push({ type: "invalid-issue-file", file: name, message: "issue file must match NNNNNN-slug.md (legacy NNN is still readable)" });
  }
  if (state.issues.length === 0) {
    problems.push({ type: "no-valid-issues", message: "no schedulable issue files found" });
  }

  return {
    ok: problems.length === 0,
    problems,
    counts: {
      issues: state.issues.length,
      invalidIssueFiles: state.invalidIssueFiles.length
    }
  };
}

function blockedSummaryFromState(state) {
  const blocked = blockedEntries(state).map((entry) => ({
    issue: issueOut(entry.issue, state.issues),
    message: entry.blockedMessage
  }));
  return { count: blocked.length, blocked };
}

function blockedSummary(options = {}) {
  return blockedSummaryFromState(loadState(options));
}

function print(result, json) {
  if (json) {
    console.log(JSON.stringify(result, null, 2));
  } else if (result.action || result.ok !== undefined) {
    console.log(result.action ? `${result.action}${result.issue ? ` ${result.issue.file}` : ""} - ${result.reason || ""}` : (result.ok ? "ok" : `failed ${result.problems.length}`));
  } else if (Array.isArray(result.blocked)) {
    console.log(`blocked ${result.count}`);
    for (const item of result.blocked) {
      console.log(`${item.issue.file}: ${item.message || ""}`);
    }
  } else {
    console.log(JSON.stringify(result));
  }
}

function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const command = args._[0];
  const options = {
    role: args.role,
    issue: args.issue,
    files: args.files,
    message: args.message,
    resolvedBy: args["resolved-by"],
    status: args.status,
    issuesDir: args["issues-dir"],
    devDone: args["dev-done"],
    reviewDone: args["review-done"],
    workspaceDir: args["workspace-dir"],
    time: args.time
  };

  if (command === "next") return print(nextPlan(options), Boolean(args.json));
  if (command === "append") return print(appendStatus(args._[1], options), Boolean(args.json));
  if (command === "blocked") return print(blockedSummary(options), Boolean(args.json));
  if (command === "issue-preflight") {
    const result = issuePreflight(options);
    print(result, Boolean(args.json));
    if (!result.ok) process.exitCode = 1;
    return;
  }
  if (command === "validate") {
    const result = validateState(options);
    print(result, Boolean(args.json));
    if (!result.ok) process.exitCode = 1;
    return;
  }

  console.error("Usage: node status_manager.js next --role dev|review --workspace-dir <dir> [--json]");
  console.error("       node status_manager.js append begin|done|review-begin|reviewed|review-fixed|blocked|unblocked|resolved-by --issue N [--resolved-by N] [--files ...] [--message ...] --workspace-dir <dir> [--json]");
  console.error("       node status_manager.js blocked --workspace-dir <dir> [--json]");
  console.error("       node status_manager.js validate --workspace-dir <dir> [--json]");
  console.error("       node status_manager.js issue-preflight --workspace-dir <dir> [--json]");
  process.exitCode = 2;
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exitCode = 1;
  }
}

module.exports = {
  parseArgs,
  nowLocalSecond,
  nowLocalMinute,
  readIssues,
  parseStatus,
  loadState,
  nextPlan,
  appendStatus,
  validateState,
  issuePreflight,
  detectGaps,
  blockedSummary
};
