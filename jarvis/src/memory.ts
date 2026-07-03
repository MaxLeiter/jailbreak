import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

const MEMORY_ROOT = process.env.JARVIS_MEMORY_DIR || "/var/jb/var/root/jarvis/memory";
export const ROOT_MEMORY_TOPIC = "index";

export interface MemoryTopic {
  topic: string;
  path: string;
  bytes: number;
  updatedAt: number;
}

export interface MemoryHit {
  topic: string;
  path: string;
  excerpt: string;
}

export async function listMemoryTopics(): Promise<MemoryTopic[]> {
  await mkdir(MEMORY_ROOT, { recursive: true });
  const names = await readdir(MEMORY_ROOT);
  const topics = await Promise.all(
    names
      .filter((name) => name.endsWith(".md") && !isSecretName(name))
      .map(async (name) => {
        const path = join(MEMORY_ROOT, name);
        const s = await stat(path);
        return { topic: name.slice(0, -3), path, bytes: s.size, updatedAt: s.mtimeMs };
      }),
  );
  return topics.sort((a, b) => b.updatedAt - a.updatedAt);
}

export async function remember(topic: string, content: string, tags: string[] = []): Promise<{ topic: string; path: string }> {
  const cleanContent = content.trim();
  if (!cleanContent) throw new Error("memory content is empty");
  if (cleanContent.length > 4_000) throw new Error("memory content must be 4000 characters or less");

  await mkdir(MEMORY_ROOT, { recursive: true });
  const slug = slugify(topic || "general");
  const path = join(MEMORY_ROOT, `${slug}.md`);
  const exists = await Bun.file(path).exists();
  const tagLine = tags.length ? `\nTags: ${tags.map((t) => `#${slugify(t)}`).join(" ")}\n` : "";
  const entry = `${exists ? "" : `# ${slug}\n\n`}## ${new Date().toISOString()}${tagLine}\n${cleanContent}\n\n`;
  await writeFile(path, entry, { flag: "a" });
  return { topic: slug, path };
}

export async function readMemoryTopic(topic: string): Promise<{ topic: string; path: string; content: string }> {
  const slug = slugify(topic);
  const path = join(MEMORY_ROOT, `${slug}.md`);
  const content = await readFile(path, "utf8");
  return { topic: slug, path, content: cap(content, 20_000) };
}

export async function searchMemory(query: string, limit = 8): Promise<MemoryHit[]> {
  const q = query.trim().toLowerCase();
  const topics = await listMemoryTopics();
  if (!q) {
    return topics.slice(0, limit).map((t) => ({ topic: t.topic, path: t.path, excerpt: `${t.bytes} bytes` }));
  }

  const hits: MemoryHit[] = [];
  for (const topic of topics) {
    const content = await readFile(topic.path, "utf8");
    const haystack = content.toLowerCase();
    const idx = haystack.indexOf(q);
    if (idx === -1) continue;
    hits.push({ topic: topic.topic, path: topic.path, excerpt: excerpt(content, idx, q.length) });
    if (hits.length >= limit) break;
  }
  return hits;
}

export async function loadMemoryContext(maxBytes = 12_000): Promise<string> {
  const root = await readRootMemory(maxBytes);
  const preferred = ["preferences", "profile", "projects", "device", "general"];
  const topics = await listMemoryTopics();
  const byTopic = new Map(topics.map((t) => [t.topic, t]));
  const rootBytes = root ? root.length : 0;
  const ordered = [
    ...preferred.map((topic) => byTopic.get(topic)).filter((t): t is MemoryTopic => !!t),
    ...topics.filter((t) => t.topic !== ROOT_MEMORY_TOPIC && !preferred.includes(t.topic)),
  ];

  let remaining = Math.max(0, maxBytes - rootBytes);
  const chunks: string[] = root ? [root] : [];
  for (const topic of ordered) {
    if (remaining <= 0) break;
    const raw = await readFile(topic.path, "utf8");
    const content = raw.length > remaining ? `${raw.slice(0, remaining)}\n...[truncated]` : raw;
    chunks.push(`## ${topic.topic}\n${content.trim()}`);
    remaining -= content.length;
  }
  return chunks.join("\n\n").trim();
}

async function readRootMemory(maxBytes: number): Promise<string> {
  try {
    const rootPath = join(MEMORY_ROOT, `${ROOT_MEMORY_TOPIC}.md`);
    const raw = await readFile(rootPath, "utf8");
    const budget = Math.max(1_000, Math.min(maxBytes, 6_000));
    const content = raw.length > budget ? `${raw.slice(0, budget)}\n...[truncated]` : raw;
    return `## ROOT MEMORY - always injected first\n${content.trim()}`;
  } catch {
    return "";
  }
}

function slugify(input: string): string {
  const slug = input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
  if (!slug || isSecretName(slug)) return "general";
  return slug;
}

function isSecretName(name: string): boolean {
  const base = basename(name).toLowerCase();
  return base === ".env" || base.endsWith(".env") || base.includes("secret") || base.includes("token");
}

function excerpt(content: string, index: number, length: number): string {
  const start = Math.max(0, index - 160);
  const end = Math.min(content.length, index + length + 320);
  return cap(`${start > 0 ? "..." : ""}${content.slice(start, end)}${end < content.length ? "..." : ""}`, 1_200);
}

function cap(value: string, max: number): string {
  return value.length > max ? `${value.slice(0, max)}\n...[truncated]` : value;
}
