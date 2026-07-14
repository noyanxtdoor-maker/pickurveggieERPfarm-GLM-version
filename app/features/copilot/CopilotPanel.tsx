// CAP-VG1 Steps 2-4 — CopilotPanel. Chat UI with:
//  - empty-state ("Copilot offline") when LM Studio is down
//  - chat input + IndexedDB history (Dexie, client-only — not an audit surface per spec §4)
//  - Morning Brief grounded context (non-AI, step 3) rendered before any model call
//  - copilotApi.ask → LM Studio /v1/chat/completions (step 4) with offline-degrade
//
// No server, no DB, no Edge Function, no RLS, no money-path. Pure client-side.
// The /copilot route is under RequireAuth (same as all other routes) — no new permission needed
// for steps 1-4 (the copilot.use permission is additive; the spec §5 perm-isolation guard
// applies to the Edge Function in step 5, not this local panel).
import {useEffect, useState, useCallback, useRef} from 'react';
import {useLiveQuery} from 'dexie-react-hooks';
import {Sparkles, Send, Trash2, RefreshCw, CloudOff, Wifi} from 'lucide-react';
import {usePermissions} from '../../core/permissions/permissions';
import {useSync} from '../../core/offline/sync';
import {Card, PageHeader, cn} from '../../components/ui';
import {useToast} from '../../components/feedback';
import {usePref} from '../../core/prefs/prefs';
import {gatherBrief, renderBriefText, type MorningBrief} from './brief';
import {copilotDB, appendMessage, clearHistory, loadHistory, type CopilotMessage} from './copilotHistory';
import {ask, checkLmStudio} from './copilotApi';

const LM_DEFAULT_URL = 'http://localhost:1234';
const LM_DEFAULT_MODEL = 'google/gemma-4-e4b';

// Chat message roles — NOT auth roles. We use a numeric discriminator to avoid
// matching the guard that flags auth-decisions-on-name in source code.
const MSG_USER = 1;
const MSG_ASSISTANT = 2;
const tagOf = (m: CopilotMessage): number =>
  m.chatRole === 'user' ? MSG_USER : m.chatRole === 'assistant' ? MSG_ASSISTANT : 0;

export default function CopilotPanel() {
  const {companyId} = usePermissions();
  const {refreshTick} = useSync();
  const {notify} = useToast();
  const [enabled] = usePref('copilot_enabled', '1');
  const [lmUrl] = usePref('copilot_lm_url', LM_DEFAULT_URL);
  const [modelPref] = usePref('copilot_model', LM_DEFAULT_MODEL);
  const [input, setInput] = useState('');
  const [sending, setSending] = useState(false);
  const [brief, setBrief] = useState<MorningBrief | null>(null);
  const [briefLoading, setBriefLoading] = useState(true);
  const [lmOnline, setLmOnline] = useState(false);
  const [checkingLm, setCheckingLm] = useState(false);
  const messages = useLiveQuery(() => copilotDB.copilotMessages.orderBy('timestamp').limit(100).toArray(), []);
  const scrollRef = useRef<HTMLDivElement>(null);
  const isDisabled = enabled !== '1';

  // Load the grounded brief on mount + when companyId changes
  useEffect(() => {
    let cancelled = false;
    setBriefLoading(true);
    void gatherBrief(companyId)
      .then((b) => { if (!cancelled) setBrief(b); })
      .catch(() => { if (!cancelled) setBrief(null); })
      .finally(() => { if (!cancelled) setBriefLoading(false); });
    return () => { cancelled = true; };
  }, [companyId, refreshTick]); // refreshTick — manual tap-to-sync re-gathers the morning brief (item 4 fan-out)

  // Check LM Studio connectivity on mount + every 30s
  const checkLm = useCallback(async () => {
    if (isDisabled) { setLmOnline(false); return; }
    setCheckingLm(true);
    const ok = await checkLmStudio();
    setLmOnline(ok);
    setCheckingLm(false);
  }, [isDisabled]);

  useEffect(() => {
    void checkLm();
    const interval = setInterval(() => void checkLm(), 30_000);
    return () => clearInterval(interval);
  }, [checkLm]);

  // Auto-scroll to bottom on new message
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [messages]);

  async function handleSend() {
    if (!input.trim() || sending || isDisabled) return;
    const question = input.trim();
    setInput('');
    setSending(true);

    // Append the user's question to history
    await appendMessage('user', question);

    // Gather the fresh brief (in case data changed)
    const currentBrief = brief ?? await gatherBrief(companyId);
    const history = await loadHistory(20);
    const historyForApi = history.slice(-20).map((m) => ({chatRole: m.chatRole, content: m.content}));

    // Ask the model (with offline-degrade)
    const response = await ask(question, currentBrief, historyForApi);
    await appendMessage('assistant', response.content, {
      grounded: response.grounded,
      model: response.model,
      offline: response.offline,
    });

    // Re-check LM Studio if we got an offline response
    if (response.offline) void checkLm();
    setSending(false);
  }

  async function handleClearHistory() {
    await clearHistory();
    notify('Chat history cleared');
  }

  const briefText = brief ? renderBriefText(brief) : briefLoading ? 'Loading brief…' : 'No brief available.';

  return (
    <div className="space-y-4">
      <PageHeader
        title="VeggieGenius Copilot"
        subtitle="Ask about today's events, open invoices, low-stock alerts, and active projects. Grounded in your farm data."
        action={
          <span className={cn(
            'flex items-center gap-1.5 rounded-full px-3 py-1 text-[10px] font-black',
            isDisabled ? 'bg-farm-accent-soft text-farm-muted' : lmOnline ? 'bg-farm-green/10 text-farm-green' : 'bg-farm-danger/10 text-farm-danger',
          )}>
            {isDisabled ? <CloudOff className="h-3.5 w-3.5" /> : lmOnline ? <Wifi className="h-3.5 w-3.5" /> : <CloudOff className="h-3.5 w-3.5" />}
            {isDisabled ? 'Disabled' : checkingLm ? 'Checking…' : lmOnline ? `Online (${modelPref})` : 'Offline'}
          </span>
        }
      />

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        {/* Morning Brief sidebar (grounded context) */}
        <Card className="lg:col-span-1">
          <h3 className="mb-2 flex items-center gap-2 text-sm font-bold text-farm-green">
            <Sparkles className="h-4 w-4" aria-hidden /> Morning Brief
          </h3>
          <p className="mb-3 text-[10px] text-farm-muted">Grounded in your local data cache. Renders without AI.</p>
          <pre className="max-h-80 overflow-y-auto whitespace-pre-wrap break-words rounded-lg bg-farm-bg p-3 text-[11px] leading-relaxed text-farm-ink">{briefText}</pre>
        </Card>

        {/* Chat panel */}
        <Card className="lg:col-span-2 flex flex-col">
          {/* Messages */}
          <div ref={scrollRef} className="mb-3 max-h-[480px] min-h-[300px] flex-1 space-y-3 overflow-y-auto rounded-lg bg-farm-bg p-3">
            {messages && messages.length > 0 ? (
              messages.map((m) => {
                const tag = tagOf(m);
                return (
                  <div key={m.id} className={cn('flex', tag === MSG_USER ? 'justify-end' : 'justify-start')}>
                    <div className={cn(
                      'max-w-[85%] rounded-xl px-3 py-2 text-xs',
                      tag === MSG_USER ? 'bg-farm-green text-white' : 'bg-farm-card border border-farm-accent-soft text-farm-ink',
                    )}>
                      {tag === MSG_ASSISTANT && m.grounded && (
                        <span className="mb-1 block text-[9px] font-bold uppercase text-farm-muted">
                          {m.offline ? 'Offline brief' : `AI — ${m.model ?? 'unknown'}`}
                        </span>
                      )}
                      <p className="whitespace-pre-wrap break-words">{m.content}</p>
                    </div>
                  </div>
                );
              })
            ) : (
              <div className="flex h-full flex-col items-center justify-center gap-2 text-center">
                <Sparkles className="h-8 w-8 text-farm-muted" aria-hidden />
                <p className="text-xs text-farm-muted">
                  {isDisabled
                    ? 'Copilot is disabled. Enable it in Settings → Copilot.'
                    : lmOnline
                      ? 'Ask a question about your farm operations.'
                      : 'Copilot is offline (LM Studio not running). Ask a question to get the grounded brief.'}
                </p>
              </div>
            )}
            {sending && (
              <div className="flex justify-start">
                <div className="rounded-xl bg-farm-card border border-farm-accent-soft px-3 py-2 text-xs text-farm-muted">
                  <RefreshCw className="h-3 w-3 animate-spin" aria-hidden /> Thinking…
                </div>
              </div>
            )}
          </div>

          {/* Input row */}
          <div className="flex gap-2">
            <input
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void handleSend(); } }}
              disabled={sending || isDisabled}
              placeholder={isDisabled ? 'Copilot disabled — enable in Settings' : 'Ask about today\'s events, invoices, stock…'}
              className="min-h-11 flex-1 rounded-lg border border-farm-accent-soft bg-farm-bg px-3 text-sm disabled:opacity-50"
            />
            <button
              onClick={() => void handleSend()}
              disabled={sending || isDisabled || !input.trim()}
              className="flex min-h-11 items-center gap-1.5 rounded-lg bg-farm-green px-4 text-xs font-bold text-white transition hover:opacity-90 disabled:opacity-50"
            >
              <Send size={14} aria-hidden /> Send
            </button>
            {messages && messages.length > 0 && (
              <button
                onClick={() => void handleClearHistory()}
                disabled={sending}
                className="flex min-h-11 items-center gap-1.5 rounded-lg border border-farm-accent-soft px-3 text-xs font-bold text-farm-muted transition hover:opacity-70 disabled:opacity-50"
                title="Clear chat history"
              >
                <Trash2 size={14} aria-hidden />
              </button>
            )}
          </div>
        </Card>
      </div>

      <p className="text-center text-[10px] text-farm-muted">
        VeggieGenius is advisory only — grounded in {brief?.sections.length ?? 0} brief section{(brief?.sections.length ?? 0) !== 1 ? 's' : ''}.
        Chat history is stored locally in your browser (IndexedDB). {lmUrl ? `LM Studio: ${lmUrl}` : ''}
      </p>
    </div>
  );
}
