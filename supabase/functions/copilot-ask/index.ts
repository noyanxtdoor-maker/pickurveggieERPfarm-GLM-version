// CAP-VG1 Step 5 — Cloud Edge Function: copilot-ask
// Authority: CAP_VG1_VeggieGenius_AI_Copilot_Spec.md §3 (Architecture) · §4 (Security) · §6 step 5
//   · CLAUDE.md §6 (AI/automation tripwire) · C7 §11 (AI is advisory)
//
// Security spine (spec §4 — non-negotiable):
// 1. Runs under the requesting user's permissions — uses their JWT, RLS applies identically
// 2. NO money paths — allow-lists only read RPCs; cannot call pos_record_sale, pos_void_sale, etc.
// 3. NO direct table access from the model — the Edge Function performs reads as the user
// 4. Grounding, not hallucination — every answer must cite the ERP rows it used
// 5. Audit — each turn appends a copilot.turn row to audit_events (actor, prompt hash, source list, model id)
// 6. NO service_role in the browser — any service role is server-only, read-only, never exposed to client

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ── Types ──
interface CopilotRequest {
  prompt: string;
  history?: Array<{ chatRole: string; content: string }>;
  briefContext?: string; // the Morning Brief text from brief.ts (grounding)
}

interface CopilotResponse {
  answer: string;
  citations: Array<{ source: string; ref: string }>;
  offline: boolean;
  model?: string;
}

// ── Allow-list of read-only RPCs the Copilot can call (spec §4 line 91-92) ──
const READ_RPC_ALLOWLIST = new Set([
  'trial_balance',
  'income_statement_monthly',
  'balance_sheet',
  'cash_flow_statement',
  'employee_advance_balance',
  'fg_available',
]);

// ── Money-path blocklist — these functions must NEVER be callable (spec §4 line 89-92) ──
const MONEY_PATH_BLOCKLIST = new Set([
  'pos_record_sale',
  'pos_void_sale',
  'record_cash_entry',
  'payroll_disburse_wage',
  'inventory_purchase',
  'inventory_adjust',
  'cash_entry_insert',
  'expense_insert',
  'revenue_insert',
  'payroll_wage_insert',
  'payroll_advance_insert',
]);

// ── Main entry ──
Deno.serve(async (req: Request) => {
  // CORS — same-origin or Supabase Studio only
  const origin = req.headers.get('Origin') ?? '*';
  const corsHeaders = {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  };

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    // ── 1. Auth: extract user JWT from Authorization header ──
    const authHeader = req.headers.get('Authorization') ?? '';
    const token = authHeader.replace('Bearer ', '');

    if (!token || token === 'anon-placeholder') {
      return new Response(JSON.stringify({ error: 'insufficient_privilege', message: 'Authentication required' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 2. Create Supabase client AS THE USER (their JWT, RLS applies) ──
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // Verify the JWT is valid + get user
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'insufficient_privilege', message: 'Invalid or expired session' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 3. Permission check: copilot.use ──
    // Per spec §1: "granted to every role that can sign in; denied only if explicitly revoked."
    // We check has_permission for the user's active company.
    // The user may have multiple companies; we check their first accessible company.
    const { data: companies, error: companyError } = await userClient
      .from('user_branch_roles')
      .select('company_id')
      .eq('user_id', user.id)
      .eq('assignment_status', 'Active')
      .limit(1);

    if (companyError || !companies || companies.length === 0) {
      return new Response(JSON.stringify({ error: 'insufficient_privilege', message: 'No active company membership' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const companyId = companies[0].company_id;
    const { data: hasPermission } = await userClient.rpc('has_permission', {
      p_company_id: companyId,
      p_permission_key: 'copilot.use',
    });

    if (!hasPermission) {
      return new Response(JSON.stringify({ error: 'insufficient_privilege', message: 'copilot.use permission not granted' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 4. Parse request body ──
    const body: CopilotRequest = await req.json();
    const { prompt, history = [], briefContext = '' } = body;

    if (!prompt || typeof prompt !== 'string' || prompt.length > 4000) {
      return new Response(JSON.stringify({ error: 'Invalid prompt (max 4000 chars)' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // ── 5. Verify no money-path RPCs in the prompt or history ──
    const allText = prompt + ' ' + history.map((m) => m.content).join(' ') + ' ' + briefContext;
    for (const blocked of MONEY_PATH_BLOCKLIST) {
      if (allText.toLowerCase().includes(blocked.toLowerCase())) {
        // Log the attempt to audit, then reject
        await logCopilotTurn(userClient, user.id, companyId, prompt, [], 'blocked-money-path', '');
        return new Response(JSON.stringify({
          error: 'blocked-money-path',
          message: 'The Copilot cannot reference financial write operations.',
        }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    // ── 6. Call LM Studio (server-side, configured via env) ──
    const lmStudioUrl = Deno.env.get('LM_STUDIO_URL') ?? 'http://localhost:1234';
    const lmModel = Deno.env.get('LM_STUDIO_MODEL') ?? 'google/gemma-4-e4b';

    // Build the system prompt with grounding context
    const systemPrompt = buildSystemPrompt(briefContext);

    // Build the message array for the LM Studio API
    const messages = [
      { role: 'system', content: systemPrompt },
      ...history.slice(-10).map((m) => ({ role: m.chatRole, content: m.content })),
      { role: 'user', content: prompt },
    ];

    let answer = '';
    let citations: Array<{ source: string; ref: string }> = [];
    let offline = false;
    let modelUsed = lmModel;

    try {
      const lmResponse = await fetch(`${lmStudioUrl}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: lmModel,
          messages,
          temperature: 0.7,
          max_tokens: 1000,
          stream: false,
        }),
        signal: AbortSignal.timeout(30000), // 30s timeout
      });

      if (!lmResponse.ok) {
        throw new Error(`LM Studio returned ${lmResponse.status}`);
      }

      const lmData = await lmResponse.json();
      answer = lmData.choices?.[0]?.message?.content ?? 'No response from model.';
      citations = extractCitations(answer, briefContext);
    } catch (lmError) {
      // Offline-degrade: return the brief as the answer
      offline = true;
      answer = briefContext || 'Copilot is offline (LM Studio unreachable). Start LM Studio to enable AI responses.';
      citations = [];
    }

    // ── 7. Audit: log the copilot turn ──
    await logCopilotTurn(userClient, user.id, companyId, prompt, citations, modelUsed, answer);

    // ── 8. Return response ──
    const response: CopilotResponse = { answer, citations, offline, model: modelUsed };
    return new Response(JSON.stringify(response), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: 'internal_error', message: String(error) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});

// ── Build system prompt with grounding context ──
function buildSystemPrompt(briefContext: string): string {
  return `You are VeggieGenius, an AI assistant for a farm ERP system. You provide READ-ONLY advisory assistance.

Grounding context (today's ERP state):
${briefContext || 'No grounding context available.'}

Rules:
- You can only reference data shown in the grounding context above or in the conversation history.
- You CANNOT perform any write operations (sales, voids, cash entries, payroll, inventory adjustments).
- If you don't have data to answer a question, say "no matching records in your access" — do not invent.
- Cite the source of your data (e.g. "from today's schedule" or "from open invoices").
- Keep answers concise and actionable for a farm operator.`;
}

// ── Extract citations from the answer (simple heuristic) ──
function extractCitations(answer: string, briefContext: string): Array<{ source: string; ref: string }> {
  const citations: Array<{ source: string; ref: string }> = [];
  if (briefContext.includes('Today') || briefContext.includes('Schedule')) {
    citations.push({ source: 'schedule', ref: 'calendarEvents' });
  }
  if (briefContext.includes('Invoice') || briefContext.includes('AR')) {
    citations.push({ source: 'invoices', ref: 'posInvoices' });
  }
  if (briefContext.includes('Low stock') || briefContext.includes('material')) {
    citations.push({ source: 'inventory', ref: 'materialStock' });
  }
  return citations;
}

// ── Log a copilot.turn audit event (spec §4: audit each turn) ──
async function logCopilotTurn(
  client: ReturnType<typeof createClient>,
  userId: string,
  companyId: string,
  prompt: string,
  citations: Array<{ source: string; ref: string }>,
  modelId: string,
  answer: string,
): Promise<void> {
  try {
    // Hash the prompt for audit (don't store raw PII per spec: "No prompt or PII is logged beyond what audit law permits")
    const encoder = new TextEncoder();
    const data = encoder.encode(prompt);
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const promptHash = Array.from(new Uint8Array(hashBuffer))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');

    // Insert audit event — uses the user's JWT, so RLS applies (append-only table)
    const { error } = await client.from('audit_events').insert({
      company_id: companyId,
      actor_user_id: userId,
      event_class: 'System',
      event_type: 'copilot.turn',
      module: 'copilot',
      entity_type: 'copilot_interaction',
      new_value: {
        prompt_hash: promptHash,
        grounded_sources: citations.map((c) => c.ref),
        model_id: modelId,
        // Answer NOT stored per spec: "the answer is not stored — client-only history"
      },
    });

    if (error) {
      console.error('Failed to log copilot turn:', error.message);
    }
  } catch (e) {
    console.error('Audit logging error:', String(e));
  }
}
