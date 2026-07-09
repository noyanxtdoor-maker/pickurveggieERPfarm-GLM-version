// CAP-VG1 Step 4 — LM Studio API call. Wires copilotApi.ask → LM Studio /v1/chat/completions
// with the grounded context (brief text). Degrades gracefully when LM Studio is down (spec §5
// offline-degrade: the ERP's full functional surface still works without the model).
//
// No server, no Edge Function, no RLS, no money-path — pure client-to-local-model HTTP.
import {getPref} from '../../core/prefs/prefs';
import {renderBriefText, type MorningBrief} from './brief';

export interface CopilotResponse {
  content: string;
  grounded: boolean;
  model: string;
  offline: boolean; // true if the model was unavailable and we degraded
}

const DEFAULT_LM_URL = 'http://localhost:1234';
const DEFAULT_MODEL = 'google/gemma-4-e4b'; // the model confirmed loaded in this terminal's LM Studio

/**
 * Ask the Copilot. Builds a chat-completions request with:
 *  - a system prompt describing the Copilot's role (advisory, grounded, no money paths)
 *  - the grounded brief as context
 *  - the user's question
 * Then calls LM Studio's /v1/chat/completions endpoint.
 *
 * Offline-degrade: if LM Studio is unreachable, returns the brief text + an offline notice
 * instead of throwing. The panel stays usable (grounding path works without the model).
 */
export async function ask(
  question: string,
  brief: MorningBrief,
  history: Array<{chatRole: string; content: string}> = [],
): Promise<CopilotResponse> {
  const lmUrl = getPref('copilot_lm_url', DEFAULT_LM_URL).replace(/\/$/, '');
  const model = getPref('copilot_model', DEFAULT_MODEL);
  const enabled = getPref('copilot_enabled', '1') === '1';

  if (!enabled) {
    return {
      content: 'Copilot is disabled in Settings. Enable it to ask questions.',
      grounded: true,
      model: 'none',
      offline: true,
    };
  }

  const briefText = renderBriefText(brief);
  const systemPrompt = [
    'You are VeggieGenius, an AI farm operations assistant for PickUrVeggieFarm ERP.',
    'You are advisory only — you help farmers understand their data, but you do not write to any database,',
    'authorize transactions, or touch financial records. Every answer must be grounded in the provided brief.',
    'If the brief does not contain relevant data, say so explicitly rather than inventing.',
    '',
    '--- GROUNDED BRIEF ---',
    briefText,
    '--- END BRIEF ---',
  ].join('\n');

  const messages = [
    {role: 'system', content: systemPrompt},
    ...history.slice(-10).map((m) => ({role: m.chatRole, content: m.content})),
    {role: 'user', content: question},
  ];

  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30_000); // 30s timeout — local model can be slow

    const res = await fetch(`${lmUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        model,
        messages,
        temperature: 0.7,
        max_tokens: 1024,
      }),
      signal: controller.signal,
    });

    clearTimeout(timeout);

    if (!res.ok) {
      const errText = await res.text().catch(() => 'Unknown error');
      return {
        content: `Copilot error (HTTP ${res.status}): ${errText.slice(0, 200)}`,
        grounded: true,
        model,
        offline: false,
      };
    }

    const data = (await res.json()) as {
      choices: Array<{message: {role: string; content: string}}>;
    };

    const answer = data.choices?.[0]?.message?.content ?? '(empty response from model)';
    return {
      content: answer,
      grounded: true,
      model,
      offline: false,
    };
  } catch {
    // Offline-degrade: LM Studio unreachable. Return the brief + an offline notice.
    return {
      content: [
        `Copilot is offline (LM Studio not responding at ${lmUrl}).`,
        'Here is today\'s grounded brief without the AI layer:',
        '',
        briefText,
      ].join('\n'),
      grounded: true,
      model,
      offline: true,
    };
  }
}

/** Quick health check — is LM Studio reachable? Used by the panel status indicator. */
export async function checkLmStudio(): Promise<boolean> {
  const lmUrl = getPref('copilot_lm_url', DEFAULT_LM_URL).replace(/\/$/, '');
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 3_000);
    const res = await fetch(`${lmUrl}/v1/models`, {signal: controller.signal});
    clearTimeout(timeout);
    return res.ok;
  } catch {
    return false;
  }
}
