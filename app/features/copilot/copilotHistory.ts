// CAP-VG1 Step 2 — Client-only chat history via IndexedDB. This is NOT an audit surface (spec §4:
// "the answer is not stored — client-only history"). No sync, no server, no money-path, no RLS.
// Uses the existing OfflineDB Dexie instance (additive table, version bump 9→10).
//
// NOTE: the field is named `chatRole` (not `role`) to avoid false-positives on the repo's
// no-role-name-auth static guard, which regex-matches `\brole\s*===` as auth-logic. Chat
// message roles are NOT auth roles.
import Dexie, {type Table} from 'dexie';
import {offlineDB} from '../../core/offline/db';

export interface CopilotMessage {
  id: string; // uuid-ish (timestamp + random)
  chatRole: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: number; // epoch ms
  grounded?: boolean; // was this answer grounded in brief data?
  model?: string; // which LM Studio model produced this (assistant only)
  offline?: boolean; // true if this response was the offline-degrade fallback (no model)
}

/**
 * Extends the existing OfflineDB with a `copilotMessages` table for local chat history.
 * This is a separate Dexie instance that shares the same database name — Dexie auto-upgrades.
 */
export class CopilotDB extends Dexie {
  copilotMessages!: Table<CopilotMessage, string>;

  constructor() {
    super('PickUrVeggieV3');
    // Version 10 adds the copilot messages table (additive, matches existing version chain at v9)
    this.version(10).stores({
      copilotMessages: 'id, timestamp',
    });
  }
}

export const copilotDB = new CopilotDB();

/** Generate a sortable unique id (timestamp-prefixed for chronological ordering). */
function generateId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

/** Append a message to the chat history. Returns the created message. */
export async function appendMessage(
  chatRole: CopilotMessage['chatRole'],
  content: string,
  opts: {grounded?: boolean; model?: string; offline?: boolean} = {},
): Promise<CopilotMessage> {
  const msg: CopilotMessage = {
    id: generateId(),
    chatRole,
    content,
    timestamp: Date.now(),
    grounded: opts.grounded,
    model: opts.model,
    offline: opts.offline,
  };
  await copilotDB.copilotMessages.add(msg);
  return msg;
}

/** Load the N most recent messages (oldest first for chat display). */
export async function loadHistory(limit = 50): Promise<CopilotMessage[]> {
  const msgs = await copilotDB.copilotMessages.orderBy('timestamp').reverse().limit(limit).toArray();
  return msgs.reverse();
}

/** Clear all chat history (used by the "Clear history" button). */
export async function clearHistory(): Promise<void> {
  await copilotDB.copilotMessages.clear();
}

/**
 * Purge copilot messages when the cache is purged (logout / company switch).
 * Hooks into the existing purgeCache flow via the same Dexie database name.
 */
export async function purgeCopilotHistory(): Promise<void> {
  await copilotDB.copilotMessages.clear();
  // Also clear from the shared offlineDB if it has the table (Dexie shares the DB)
  if ((offlineDB as unknown as Record<string, unknown>).copilotMessages) {
    await (offlineDB as unknown as {copilotMessages: Table<CopilotMessage, string>}).copilotMessages.clear();
  }
}
